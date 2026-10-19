#!/usr/bin/env node
/**
 * Renders a CapCut draft to a video file via the Remotion Node API.
 *
 * Usage:
 *   node src/render.mjs --draft <path-to-draft.json> --output <path.mp4> [--codec h264] [--concurrency N]
 *
 * Protocol with the Elixir side (`CapcutMcp.Remotion.Renderer`):
 *   - progress -> stderr (human-readable)
 *   - exactly ONE final line on stdout: a JSON summary
 *     `{"ok":true,...}` on success, `{"ok":false,"error":"..."}` on failure
 *   - exit code 0 on success, 1 on failure
 *
 * Draft input props passed to the composition are pre-filtered: media
 * materials whose file cannot be resolved on disk are REMOVED before the
 * render, so a missing file skips its segment (reported in the summary)
 * instead of failing the whole render. Stats are computed from the full
 * draft (with a filesystem resolver) so the summary reflects everything.
 */

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { parseArgs } from 'node:util';
import { bundle } from '@remotion/bundler';
import { renderMedia, selectComposition } from '@remotion/renderer';

import { buildTimelineModel } from './model.mjs';

const COMPOSITION_ID = 'CapcutDraft';

const CODEC_CONTAINERS = {
  h264: ['.mp4', '.mov', '.mkv'],
  h265: ['.mp4', '.mov', '.mkv'],
  vp8: ['.webm'],
  vp9: ['.webm'],
  prores: ['.mov', '.mkv'],
};

const main = async () => {
  const { values } = parseArgs({
    options: {
      draft: { type: 'string' },
      output: { type: 'string' },
      codec: { type: 'string', default: 'h264' },
      concurrency: { type: 'string' },
    },
  });

  if (!values.draft || !values.output) {
    fail('missing --draft or --output argument');
    return;
  }

  const codec = values.codec;
  if (!Object.prototype.hasOwnProperty.call(CODEC_CONTAINERS, codec)) {
    fail(`unsupported codec: ${codec}. Supported: ${Object.keys(CODEC_CONTAINERS).join(', ')}`);
    return;
  }
  const output = path.resolve(values.output);
  const ext = path.extname(output).toLowerCase();
  if (!CODEC_CONTAINERS[codec].includes(ext)) {
    fail(`codec ${codec} requires one of ${CODEC_CONTAINERS[codec].join(', ')} output extensions, got ${ext}`);
    return;
  }

  const draftPath = path.resolve(values.draft);
  if (!fs.existsSync(draftPath)) {
    fail(`draft file not found: ${draftPath}`);
    return;
  }

  let draft;
  try {
    draft = JSON.parse(fs.readFileSync(draftPath, 'utf8'));
  } catch (err) {
    fail(`cannot parse draft JSON: ${err instanceof Error ? err.message : String(err)}`);
    return;
  }

  const draftDir = path.dirname(draftPath);
  const fileResolver = (p) => (fs.existsSync(p) && fs.statSync(p).isFile() ? p : null);

  // Full stats (including unresolvable media) for the summary...
  const fullModel = buildTimelineModel(draft, draftDir, fileResolver);
  if (fullModel.stats.rendered === 0) {
    fail('project has no renderable segments (timeline is empty or all segments were skipped)');
    return;
  }

  // ...and a render draft with media STAGED: Remotion cannot serve absolute
  // file paths through its bundle server (they resolve against the server
  // root and 404), so every resolvable local file gets a symlink inside a
  // temporary public dir and its material path is rewritten to the served
  // URL. Unresolvable files are dropped; their segments are reported in the
  // summary as "material not found".
  const staging = stageMedia(draft, draftDir, fileResolver);
  const renderDraft = staging.renderDraft;
  const renderModel = buildTimelineModel(renderDraft, draftDir, undefined);
  const inputProps = { draft: renderDraft, draftDir };

  try {
    log(`Bundling renderer (Remotion)...`);
    const entryPoint = path.resolve(import.meta.dirname, 'index.ts');
    const bundleLocation = await bundle({
      entryPoint,
      publicDir: staging.publicDir,
      symlinkPublicDir: true,
      onProgress: (progress) => {
        if (progress === 100) log('Bundle ready.');
      },
    });

    log(`Selecting composition (${fullModel.width}x${fullModel.height} @ ${fullModel.fps}fps, ${fullModel.durationFrames} frames)...`);
    const composition = await selectComposition({
      serveUrl: bundleLocation,
      id: COMPOSITION_ID,
      inputProps,
    });

    const concurrency = values.concurrency ? Number.parseInt(values.concurrency, 10) : undefined;
    if (concurrency !== undefined && (!Number.isInteger(concurrency) || concurrency < 1)) {
      fail(`invalid --concurrency: ${values.concurrency}`);
      return;
    }

    fs.mkdirSync(path.dirname(output), { recursive: true });

    const startedAt = Date.now();
    log(`Rendering ${composition.durationInFrames} frames...`);
    await renderMedia({
      composition,
      serveUrl: bundleLocation,
      codec,
      outputLocation: output,
      inputProps,
      concurrency,
      onProgress: ({ progress }) => {
        const pct = Math.round(progress * 100);
        if (pct > 0 && pct % 10 === 0) log(`Render progress: ${pct}%`);
      },
    });

    const elapsedMs = Date.now() - startedAt;
    const sizeBytes = fs.existsSync(output) ? fs.statSync(output).size : 0;

    emit({
      ok: true,
      output,
      codec,
      width: renderModel.width,
      height: renderModel.height,
      fps: renderModel.fps,
      durationMs: Math.round(renderModel.durationMs),
      durationFrames: renderModel.durationFrames,
      layers: renderModel.stats.rendered,
      skipped: fullModel.stats.skipped,
      sizeBytes,
      elapsedMs,
    });
    process.exit(0);
  } finally {
    fs.rmSync(staging.publicDir, { recursive: true, force: true });
  }
};

/**
 * Stages resolvable local media into a temporary public directory via
 * symlinks and rewrites the corresponding material paths to bundle-served
 * URLs ("/media-<n>.<ext>"). Remote http(s) assets are kept as-is; anything
 * unresolvable is dropped so its segment is reported as skipped.
 */
function stageMedia(draft, draftDir, resolver) {
  const publicDir = fs.mkdtempSync(path.join(os.tmpdir(), 'capcut-mcp-render-public-'));
  const materials = draft && draft.materials;
  if (!materials) return { renderDraft: draft, publicDir };

  const clone = { ...draft, materials: { ...materials } };
  let index = 0;
  for (const bucket of ['videos', 'audios', 'photos']) {
    const list = materials[bucket];
    if (!Array.isArray(list)) continue;
    clone.materials[bucket] = [];
    for (const mat of list) {
      if (!mat) continue;
      const raw = mat.path;
      if (typeof raw !== 'string' || raw.trim() === '') continue;
      if (/^https?:\/\//i.test(raw)) {
        clone.materials[bucket].push(mat);
        continue;
      }
      const resolved = resolveLocal(raw, draftDir, resolver);
      if (!resolved) continue;
      const name = `media-${index}${path.extname(raw).toLowerCase() || '.bin'}`;
      index += 1;
      const stagedPath = path.join(publicDir, name);
      // Remotion's serve-handler rejects per-file symlinks (lstat sees the
      // final component as a symlink and 404s), so hardlink when possible
      // (same volume, no data copy) and fall back to a full copy.
      try {
        fs.linkSync(resolved, stagedPath);
      } catch {
        try {
          fs.copyFileSync(resolved, stagedPath);
        } catch {
          continue;
        }
      }
      clone.materials[bucket].push({ ...mat, path: `/public/${name}` });
    }
  }
  return { renderDraft: clone, publicDir };
}

function resolveLocal(rawPath, draftDir, resolver) {
  if (resolver(rawPath)) return rawPath;
  if (draftDir && !path.isAbsolute(rawPath)) {
    const joined = draftDir.replace(/\/$/, '') + '/' + rawPath;
    if (resolver(joined)) return joined;
  }
  return null;
}

function log(message) {
  process.stderr.write(`[render] ${message}\n`);
}

function emit(summary) {
  process.stdout.write(`${JSON.stringify(summary)}\n`);
}

function fail(message) {
  emit({ ok: false, error: message });
  process.exit(1);
}

// Bundle/render failures (missing Chrome, codec errors, ...) must still
// produce the one-line JSON summary for the Elixir side.
main().catch((err) => {
  fail(err instanceof Error ? err.message : String(err));
});
