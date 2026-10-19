#!/usr/bin/env node
// Runway MCP — stdio server for Runway's video generation API.
//
// Zero dependencies: implements the MCP JSON-RPC stdio protocol directly and
// talks to https://api.dev.runwayml.com with the built-in fetch.
//
// Configuration (environment or runway-mcp/.env, then ../.env):
//   RUNWAYML_API_SECRET   required — Runway API key (Bearer)
//   RUNWAY_VIDEO_MODEL    default model (default: gen4.5)
//   RUNWAY_OUTPUT_DIR     where generated MP4s are saved (default: ~/Movies/runway)
//   RUNWAY_TIMEOUT_MS     poll budget per generation (default: 900000)
//   RUNWAY_POLL_INTERVAL_MS  poll interval, min 5000 (default: 5000)
//   RUNWAY_API_BASE       override API base (used by tests)

import { createInterface } from "node:readline";
import { execFile } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));

loadEnvFile(path.join(HERE, ".env"));
loadEnvFile(path.join(HERE, "..", ".env"));

const API_BASE = (process.env.RUNWAY_API_BASE || "https://api.dev.runwayml.com").replace(
  /\/+$/,
  ""
);
const API_VERSION = process.env.RUNWAY_API_VERSION || "2024-11-06";
const DEFAULT_MODEL = process.env.RUNWAY_VIDEO_MODEL || "gen4.5";
const OUTPUT_DIR =
  process.env.RUNWAY_OUTPUT_DIR || path.join(os.homedir(), "Movies", "runway");
const DEFAULT_TIMEOUT_MS = positiveInt(process.env.RUNWAY_TIMEOUT_MS, 900_000);
const DEFAULT_POLL_MS = Math.max(5_000, positiveInt(process.env.RUNWAY_POLL_INTERVAL_MS, 5_000));

const TEXT_MODELS = [
  "gen4.5",
  "veo3.1",
  "veo3.1_fast",
  "kling2.5_turbo_pro",
  "kling3.0_pro",
  "kling3.0_standard",
  "seedance2",
  "seedance2_fast",
  "seedance2_mini",
  "seedance2_5",
  "gemini_omni_flash",
  "wan3",
  "wan3_prime",
  "hailuo3",
  "h3_max",
  "grok_imagine_1_5",
];

const IMAGE_MODELS = ["gen4.5", "gen4_turbo", ...TEXT_MODELS.filter((m) => m !== "gen4.5")];

const MODELS_REQUIRING_RATIO = new Set([
  "gen4.5",
  "gen4_turbo",
  "veo3.1",
  "veo3.1_fast",
  "klingO3_4k",
  "kling3.0_4k",
  "kling3.0_pro",
  "kling3.0_standard",
  "klingO3_pro",
  "klingO3_standard",
]);

const RATIO_ALIASES = {
  "16:9": "1280:720",
  "9:16": "720:1280",
  "4:3": "1104:832",
  "3:4": "832:1104",
  "21:9": "1584:672",
};

const TERMINAL_STATUSES = new Set(["SUCCEEDED", "FAILED", "CANCELLED"]);

const TOOLS = [
  {
    name: "generate_video",
    description:
      "Generates a video with Runway (text-to-video, or image-to-video when `image` is given), " +
      "waits for the task, downloads the MP4 to `output_path` and returns its absolute path. " +
      "Use `wait=false` to submit and return the task id immediately, then poll with get_task. " +
      "Defaults to model gen4.5, 1280:720, 5s. Generation usually takes 1-5 minutes.",
    inputSchema: {
      type: "object",
      properties: {
        prompt: {
          type: "string",
          description: "Detailed description of the video to generate.",
        },
        image: {
          type: "string",
          description:
            "Optional image for image-to-video: public HTTPS URL, data URI, or absolute " +
            "local path (max 5 MB).",
        },
        model: {
          type: "string",
          description: `Runway model (default: ${DEFAULT_MODEL}; e.g. gen4.5, veo3.1, seedance2, kling3.0_pro).`,
        },
        ratio: {
          type: "string",
          description: "Output ratio in Runway format, e.g. '1280:720' or '720:1280'.",
        },
        aspect_ratio: {
          type: "string",
          description: "Convenience alias: '16:9' or '9:16' (overridden by `ratio`).",
        },
        duration_seconds: {
          type: "integer",
          description: "Clip duration in seconds (model dependent, usually 2-10).",
        },
        seed: { type: "integer", description: "Seed for reproducible generations." },
        audio: {
          type: "boolean",
          description: "Generate native audio (only for models that support it, e.g. veo3.1).",
        },
        negative_prompt: {
          type: "string",
          description: "What to avoid in the output (only for models that support it).",
        },
        output_path: {
          type: "string",
          description:
            "Absolute path for the MP4, or an existing directory. Default: " +
            `${OUTPUT_DIR}/runway-<model>-<timestamp>-<task>.mp4`,
        },
        wait: {
          type: "boolean",
          description: "Wait for completion and download the file (default: true).",
        },
        timeout_ms: {
          type: "integer",
          description: `Polling budget in ms (default: ${DEFAULT_TIMEOUT_MS}).`,
        },
      },
      required: ["prompt"],
    },
  },
  {
    name: "get_task",
    description:
      "Returns the status, progress, cost and output URLs of a Runway task. When the task " +
      "succeeded and `download` is true, downloads the MP4 to `output_path` and returns its path.",
    inputSchema: {
      type: "object",
      properties: {
        task_id: { type: "string", description: "Runway task id (UUID)." },
        download: {
          type: "boolean",
          description: "Download the output when the task succeeded (default: false).",
        },
        output_path: {
          type: "string",
          description: "Absolute path for the download (only with `download`).",
        },
      },
      required: ["task_id"],
    },
  },
  {
    name: "cancel_task",
    description: "Cancels a pending/running Runway task (deletes it if already finished).",
    inputSchema: {
      type: "object",
      properties: {
        task_id: { type: "string", description: "Runway task id (UUID)." },
      },
      required: ["task_id"],
    },
  },
  {
    name: "list_models",
    description: "Lists the Runway video models exposed by this server and the current default.",
    inputSchema: { type: "object", properties: {} },
  },
];

// ── MCP stdio plumbing ────────────────────────────────────────────────────────

const rl = createInterface({ input: process.stdin, crlfDelay: Infinity });

rl.on("line", (line) => {
  if (!line.trim()) return;
  let msg;
  try {
    msg = JSON.parse(line);
  } catch {
    send({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } });
    return;
  }
  handle(msg);
});

function send(payload) {
  process.stdout.write(JSON.stringify(payload) + "\n");
}

function reply(id, result) {
  send({ jsonrpc: "2.0", id, result });
}

function fail(id, code, message) {
  send({ jsonrpc: "2.0", id, error: { code, message } });
}

async function handle(msg) {
  const { id, method } = msg;
  if (id === undefined) return; // notification

  if (method === "initialize") {
    reply(id, {
      protocolVersion: "2024-11-05",
      capabilities: { tools: {} },
      serverInfo: { name: "runway-mcp", version: "0.1.0" },
    });
    return;
  }

  if (method === "ping") return reply(id, {});

  if (method === "tools/list") return reply(id, { tools: TOOLS });

  if (method !== "tools/call") {
    return fail(id, -32601, `Method not found: ${method}`);
  }

  const name = msg.params?.name;
  const args = msg.params?.arguments || {};
  const tool = TOOLS.find((t) => t.name === name);
  if (!tool) return reply(id, toolError(`Tool not found: ${name}`));

  const missing = (tool.inputSchema.required || []).filter((k) => args[k] === undefined);
  if (missing.length) {
    return reply(id, toolError(`Missing required arguments: ${missing.join(", ")}`));
  }

  try {
    const text = await runTool(name, args);
    reply(id, { content: [{ type: "text", text }] });
  } catch (error) {
    reply(id, toolError(error instanceof Error ? error.message : String(error)));
  }
}

function toolError(text) {
  return { content: [{ type: "text", text }], isError: true };
}

async function runTool(name, args) {
  switch (name) {
    case "generate_video":
      return generateVideo(args);
    case "get_task":
      return getTask(args);
    case "cancel_task":
      return cancelTask(args);
    case "list_models":
      return [
        `Default model: ${DEFAULT_MODEL}`,
        "",
        `Text to video: ${TEXT_MODELS.join(", ")}`,
        "",
        `Image to video: ${IMAGE_MODELS.join(", ")}`,
      ].join("\n");
    default:
      throw new Error(`Unhandled tool: ${name}`);
  }
}

// ── Tools ─────────────────────────────────────────────────────────────────────

async function generateVideo(args) {
  const prompt = String(args.prompt || "").trim();
  if (!prompt) throw new Error("Invalid prompt: prompt is empty");

  const model = String(args.model || DEFAULT_MODEL);
  validateModel(model);

  const image = args.image ? await resolveImage(String(args.image)) : null;
  const endpoint = image ? "/v1/image_to_video" : "/v1/text_to_video";
  const body = buildBody({ ...args, prompt, model, image });
  const submitted = await api("POST", endpoint, body);
  const taskId = submitted?.id;
  if (!taskId) throw new Error(`Unexpected Runway response: ${short(submitted)}`);

  const wait = args.wait !== false;
  if (!wait) {
    return [
      "Video generation submitted.",
      `Task ID: ${taskId}`,
      `Model: ${model}`,
      "Poll it with get_task (and download=true when it succeeds).",
    ].join("\n");
  }

  const timeoutMs = positiveInt(args.timeout_ms, DEFAULT_TIMEOUT_MS);
  const task = await waitForTask(taskId, timeoutMs);
  return finishAndDownload(task, model, args);
}

async function getTask(args) {
  const taskId = String(args.task_id || "").trim();
  if (!/^[0-9a-fA-F-]{36}$/.test(taskId)) throw new Error(`Invalid task_id: ${taskId}`);

  const task = await api("GET", `/v1/tasks/${taskId}`);
  const lines = [
    `Task: ${task.id}`,
    `Status: ${task.status}`,
    `Model: ${task.model || "unknown"}`,
  ];
  if (task.progress != null) lines.push(`Progress: ${task.progress}`);
  if (task.estimatedCost?.credits != null)
    lines.push(`Estimated credits: ${task.estimatedCost.credits}`);
  if (task.cost?.credits != null) lines.push(`Credits charged: ${task.cost.credits}`);
  if (task.failure) lines.push(`Failure: ${task.failure}`);
  if (Array.isArray(task.output) && task.output.length)
    lines.push(`Output: ${task.output.join(", ")}`);

  if (args.download && task.status === "SUCCEEDED") {
    const saved = await saveTaskOutput(task, args.output_path);
    lines.push("", `File: ${saved.path}`, ...durationLines(saved.durationSeconds));
  }

  return lines.join("\n");
}

async function cancelTask(args) {
  const taskId = String(args.task_id || "").trim();
  if (!/^[0-9a-fA-F-]{36}$/.test(taskId)) throw new Error(`Invalid task_id: ${taskId}`);
  await api("DELETE", `/v1/tasks/${taskId}`);
  return `Task ${taskId} cancelled.`;
}

// ── Runway API ────────────────────────────────────────────────────────────────

function buildBody({ prompt, model, ratio, aspect_ratio, duration_seconds, seed, audio, negative_prompt, image }) {
  const body = { model, promptText: prompt };

  const resolvedRatio = normalizeRatio(ratio || aspect_ratio);
  if (resolvedRatio) body.ratio = resolvedRatio;
  else if (MODELS_REQUIRING_RATIO.has(model)) body.ratio = "1280:720";

  if (duration_seconds != null) body.duration = integer(duration_seconds, "duration_seconds");
  else if (model === "gen4.5") body.duration = 5;

  if (seed != null) body.seed = integer(seed, "seed");
  if (typeof audio === "boolean") body.audio = audio;
  if (negative_prompt) body.negativePrompt = String(negative_prompt);
  if (image) body.promptImage = image;

  return body;
}

async function api(method, endpoint, body) {
  const apiKey = process.env.RUNWAYML_API_SECRET || process.env.RUNWAY_API_KEY || "";
  if (!apiKey) {
    throw new Error(
      "Runway API key not configured. Set RUNWAYML_API_SECRET in runway-mcp/.env " +
        "(from https://dev.runwayml.com) and restart the server."
    );
  }

  let response;
  try {
    response = await fetch(`${API_BASE}${endpoint}`, {
      method,
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "X-Runway-Version": API_VERSION,
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(120_000),
    });
  } catch (error) {
    throw new Error(`Runway request failed: ${error.message}`);
  }

  if (response.status === 204) return null;

  const text = await response.text();
  const payload = text ? safeJson(text) : null;

  if (!response.ok) {
    const detail = payload?.error || payload?.message || text.slice(0, 300);
    const hint =
      response.status === 401 || response.status === 403
        ? " (check RUNWAYML_API_SECRET)"
        : response.status === 402
          ? " (insufficient Runway credits)"
          : response.status === 429
            ? " (rate limited)"
            : "";
    throw new Error(`Runway request failed (HTTP ${response.status})${hint}. ${detail}`);
  }

  return payload;
}

async function waitForTask(taskId, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  let announced = 0;

  for (;;) {
    const task = await api("GET", `/v1/tasks/${taskId}`);
    if (TERMINAL_STATUSES.has(task.status)) return task;

    if (task.status === "THROTTLED" && Date.now() >= deadline) {
      throw new Error(`Runway task ${taskId} is throttled; retry later with get_task.`);
    }

    if (task.progress != null && task.progress >= announced + 25) {
      announced = task.progress;
      process.stderr.write(`runway-mcp: task ${taskId} ${task.status} ${task.progress}%\n`);
    }

    if (Date.now() >= deadline) {
      throw new Error(
        `Runway generation timed out after ${Math.round(timeoutMs / 1000)}s ` +
          `(task ${taskId} is still running). Fetch it later with get_task, ` +
          "or retry with a longer timeout_ms."
      );
    }

    await sleep(DEFAULT_POLL_MS);
  }
}

async function finishAndDownload(task, model, args) {
  if (task.status !== "SUCCEEDED") {
    const reason = task.failure ? `: ${task.failure}` : "";
    throw new Error(`Runway generation ${task.status}${reason} (task ${task.id}).`);
  }

  const saved = await saveTaskOutput(task, args.output_path, model);
  const credits = task.cost?.credits;

  return [
    "Video generated.",
    `File: ${saved.path}`,
    "Provider: runway",
    `Model: ${model}`,
    `Task ID: ${task.id}`,
    ...durationLines(saved.durationSeconds),
    credits != null ? `Credits charged: ${credits}` : null,
  ]
    .filter(Boolean)
    .join("\n");
}

async function saveTaskOutput(task, outputPath, model = "runway") {
  const url = Array.isArray(task.output) ? task.output[0] : null;
  if (!url) throw new Error(`Task ${task.id} has no output URL.`);

  let response;
  try {
    response = await fetch(url, { redirect: "follow", signal: AbortSignal.timeout(180_000) });
  } catch (error) {
    throw new Error(`Video download failed: ${error.message}`);
  }
  if (!response.ok) throw new Error(`Video download failed (HTTP ${response.status}).`);

  const bytes = Buffer.from(await response.arrayBuffer());
  if (!bytes.length) throw new Error("Video download returned an empty file.");

  const target = resolveOutputPath(outputPath, model, task.id);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, bytes);

  return { path: target, durationSeconds: await probeDuration(target) };
}

function resolveOutputPath(outputPath, model, taskId) {
  const name = `runway-${sanitize(model)}-${timestamp()}-${String(taskId).slice(0, 8)}.mp4`;

  if (!outputPath) return path.join(OUTPUT_DIR, name);

  const absolute = path.resolve(String(outputPath));
  if (fs.existsSync(absolute) && fs.statSync(absolute).isDirectory()) {
    return path.join(absolute, name);
  }
  if (outputPath.endsWith(path.sep) || outputPath.endsWith("/")) {
    return path.join(absolute, name);
  }
  return absolute;
}

function probeDuration(file) {
  return new Promise((resolve) => {
    execFile(
      "ffprobe",
      ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", file],
      { timeout: 5_000 },
      (error, stdout) => {
        if (error) return resolve(null);
        const seconds = Number.parseFloat(String(stdout).trim());
        resolve(Number.isFinite(seconds) ? Math.round(seconds * 1000) / 1000 : null);
      }
    );
  });
}

function durationLines(seconds) {
  if (seconds == null) return [];
  return [`Duration: ${seconds}s`, `Duration (ms): ${Math.round(seconds * 1000)}`];
}

// ── Helpers ───────────────────────────────────────────────────────────────────

async function resolveImage(value) {
  if (/^(https:\/\/|data:image\/|runway:\/\/)/.test(value)) return value;

  const file = path.resolve(value);
  if (!fs.existsSync(file)) {
    throw new Error(`Image not found: ${value} (use an HTTPS URL, data URI, or local path).`);
  }

  const bytes = fs.readFileSync(file);
  if (bytes.length > 5 * 1024 * 1024) throw new Error("Image exceeds Runway's 5 MB limit.");

  const mime =
    {
      ".png": "image/png",
      ".jpg": "image/jpeg",
      ".jpeg": "image/jpeg",
      ".webp": "image/webp",
      ".gif": "image/gif",
    }[path.extname(file).toLowerCase()] || "image/png";

  return `data:${mime};base64,${bytes.toString("base64")}`;
}

function normalizeRatio(value) {
  if (!value) return null;
  const raw = String(value).trim();
  return RATIO_ALIASES[raw] || raw;
}

function validateModel(model) {
  if (!/^[A-Za-z0-9._-]+$/.test(model)) throw new Error(`Invalid model name: ${model}`);
}

function integer(value, field) {
  const n = Number(value);
  if (!Number.isInteger(n)) throw new Error(`Invalid ${field}: ${value} (must be an integer)`);
  return n;
}

function positiveInt(value, fallback) {
  const n = Number(value);
  return Number.isInteger(n) && n > 0 ? n : fallback;
}

function sanitize(value) {
  return String(value).replace(/[^A-Za-z0-9._-]/g, "-");
}

function timestamp() {
  return new Date().toISOString().replace(/[-:]/g, "").replace(/\..*/, "").replace("T", "-");
}

function safeJson(text) {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

function short(value) {
  const text = typeof value === "string" ? value : JSON.stringify(value);
  return String(text).slice(0, 300);
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function loadEnvFile(file) {
  if (!fs.existsSync(file)) return;
  for (const line of fs.readFileSync(file, "utf8").split(/\r?\n/)) {
    const match = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$/);
    if (!match || line.trim().startsWith("#")) continue;
    const key = match[1];
    if (process.env[key] !== undefined) continue;
    let value = match[2].trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    process.env[key] = value;
  }
}
