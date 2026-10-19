defmodule CapcutMcp.Remotion.Renderer do
  @moduledoc """
  Runs the bundled Remotion renderer (Node) to export a CapCut draft as a
  video file.

  The renderer lives in `renderer/` (a self-contained Node project whose CLI
  is `src/render.mjs`). This module resolves it, shells out to Node, and
  parses the one-line JSON summary the CLI prints on stdout:

      {"ok":true,"output":"...","layers":2,"skipped":[...],...}

  Resolution order for the renderer directory:

  1. `Application.get_env(:capcut_mcp, :remotion_renderer_path)`
  2. The `REMOTION_RENDERER_PATH` environment variable
  3. `renderer/` in the current working directory, or the first parent that
     has one (covers both `mix run` and the release launched by
     `start-mcp.sh`, which `cd`s into the repo root)

  A render runs synchronously (the MCP client waits for the tool response
  anyway) but under a timeout — default 15 minutes, configurable via
  `Application.get_env(:capcut_mcp, :remotion_render_timeout_ms)` or the
  `:timeout_ms` option.
  """

  @script "src/render.mjs"
  @default_codec "h264"
  @default_timeout_ms 900_000

  @codec_containers %{
    "h264" => [".mp4", ".mov", ".mkv"],
    "h265" => [".mp4", ".mov", ".mkv"],
    "vp8" => [".webm"],
    "vp9" => [".webm"],
    "prores" => [".mov", ".mkv"]
  }

  @type summary :: %{
          optional(String.t()) => term()
        }

  @doc """
  Verifies the render environment is usable without starting a render:
  renderer directory resolvable, CLI script present, `node` on PATH (or
  overridden), and renderer dependencies installed.
  """
  @spec ensure_available(keyword()) ::
          {:ok, %{renderer_dir: String.t(), node_path: String.t()}} | {:error, String.t()}
  def ensure_available(opts \\ []) do
    with {:ok, renderer_dir} <- resolve_renderer_dir(opts),
         :ok <- validate_renderer_dir(renderer_dir),
         {:ok, node_path} <- resolve_node_path(opts) do
      {:ok, %{renderer_dir: renderer_dir, node_path: node_path}}
    end
  end

  @doc """
  Renders a draft JSON file to `output_path`. Returns the parsed renderer
  summary map on success.
  """
  @spec render(String.t(), String.t(), keyword()) :: {:ok, summary()} | {:error, String.t()}
  def render(draft_path, output_path, opts \\ []) do
    draft_path = Path.expand(draft_path)
    output_path = Path.expand(output_path)
    timeout_ms = Keyword.get(opts, :timeout_ms, render_timeout_config())

    with {:ok, env} <- ensure_available(opts),
         {:ok, codec} <- resolve_codec(opts),
         {:ok, args} <- build_args(draft_path, output_path, codec, opts),
         :ok <- validate_output_extension(output_path, codec),
         :ok <- validate_draft_file(draft_path),
         :ok <- File.mkdir_p(Path.dirname(output_path)) do
      run(env, args, timeout_ms)
    end
  end

  @doc "Supported video codecs (constraint: output extension must match)."
  @spec supported_codecs() :: [String.t()]
  def supported_codecs, do: Map.keys(@codec_containers)

  @doc "File extensions a codec can be muxed into (first is the default)."
  @spec container_extensions(String.t()) :: [String.t()]
  def container_extensions(codec) when is_binary(codec), do: Map.get(@codec_containers, codec, [])

  # ── Internals ────────────────────────────────────────────────────────────────

  @spec resolve_renderer_dir(keyword()) :: {:ok, String.t()} | {:error, String.t()}
  defp resolve_renderer_dir(opts) do
    configured =
      Keyword.get(opts, :renderer_dir) ||
        Application.get_env(:capcut_mcp, :remotion_renderer_path) ||
        System.get_env("REMOTION_RENDERER_PATH")

    case configured do
      dir when is_binary(dir) ->
        {:ok, dir}

      nil ->
        case discover_renderer_dir() do
          {:ok, dir} ->
            {:ok, dir}

          :error ->
            {:error,
             "Remotion renderer not found. Set REMOTION_RENDERER_PATH to the renderer/ directory."}
        end
    end
  end

  defp discover_renderer_dir do
    candidate_dirs()
    |> Enum.find(:error, fn dir ->
      File.exists?(Path.join(dir, @script))
    end)
    |> case do
      :error -> :error
      dir -> {:ok, dir}
    end
  end

  defp candidate_dirs do
    cwd = File.cwd!() |> Path.expand()

    # No pipes here: `a ++ b |> f()` binds the pipe to the WHOLE `a ++ b`
    # expression (Elixir precedence), which appends "renderer" to every
    # element — including the already-suffixed first candidate.
    [Path.join(cwd, "renderer")] ++ Enum.map(parents_of(cwd), &Path.join(&1, "renderer"))
  end

  defp parents_of(dir) do
    case Path.dirname(dir) do
      ^dir -> []
      parent -> [parent | parents_of(parent)]
    end
    |> Enum.take(6)
  end

  @spec validate_renderer_dir(String.t()) :: :ok | {:error, String.t()}
  defp validate_renderer_dir(renderer_dir) do
    script = Path.join(renderer_dir, @script)

    cond do
      not File.exists?(script) ->
        {:error, "Remotion renderer script not found at #{script}"}

      not File.exists?(Path.join(renderer_dir, "node_modules/@remotion/renderer/package.json")) ->
        {:error,
         "Remotion renderer dependencies not installed. Run `npm install` inside #{renderer_dir} first."}

      true ->
        :ok
    end
  end

  @spec resolve_node_path(keyword()) :: {:ok, String.t()} | {:error, String.t()}
  defp resolve_node_path(opts) do
    configured =
      Keyword.get(opts, :node_path) ||
        Application.get_env(:capcut_mcp, :remotion_node_path)

    case configured || System.find_executable("node") do
      node when is_binary(node) ->
        # find_executable resolves bare names from PATH and verifies
        # absolute paths actually exist and are executable.
        case System.find_executable(node) do
          nil ->
            {:error,
             "Node.js executable not found: #{node}. Install Node.js 18+ to render projects."}

          resolved ->
            {:ok, resolved}
        end

      nil ->
        {:error, "Node.js not found on PATH. Install Node.js 18+ to render projects."}
    end
  end

  @spec resolve_codec(keyword()) :: {:ok, String.t()} | {:error, String.t()}
  defp resolve_codec(opts) do
    codec = Keyword.get(opts, :codec, @default_codec)

    if Map.has_key?(@codec_containers, codec) do
      {:ok, codec}
    else
      {:error,
       "Unsupported codec: #{inspect(codec)}. Supported: #{Enum.join(Map.keys(@codec_containers), ", ")}"}
    end
  end

  @spec validate_output_extension(String.t(), String.t()) :: :ok | {:error, String.t()}
  defp validate_output_extension(output_path, codec) do
    ext = output_path |> Path.extname() |> String.downcase()
    allowed = Map.fetch!(@codec_containers, codec)

    if ext in allowed do
      :ok
    else
      # Path.extname/1 always returns a binary ("" when no extension), so
      # `ext || "(none)"` would never fall back — compare explicitly instead.
      {:error,
       "Codec #{codec} requires one of #{Enum.join(allowed, ", ")} output extensions, got #{if(ext == "", do: "(none)", else: ext)}"}
    end
  end

  # Reader.resolve_draft_json_file/1 logic mirrored: prefer draft_content.json
  # (Windows + this repo's historical format), fall back to draft_info.json
  # (what current macOS CapCut writes for new projects).
  @spec validate_draft_file(String.t()) :: :ok | {:error, String.t()}
  defp validate_draft_file(draft_path) do
    if File.exists?(draft_path) do
      :ok
    else
      {:error, "Draft file not found: #{draft_path}"}
    end
  end

  @spec build_args(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, [String.t()]} | {:error, String.t()}
  defp build_args(draft_path, output_path, codec, opts) do
    with {:ok, concurrency_args} <- concurrency_args(Keyword.get(opts, :concurrency)) do
      {:ok,
       [@script, "--draft", draft_path, "--output", output_path, "--codec", codec] ++
         concurrency_args}
    end
  end

  defp concurrency_args(nil), do: {:ok, []}

  defp concurrency_args(n) when is_integer(n) and n >= 1,
    do: {:ok, ["--concurrency", Integer.to_string(n)]}

  defp concurrency_args(other),
    do: {:error, "Invalid concurrency: #{inspect(other)} (must be a positive integer)"}

  @spec run(%{renderer_dir: String.t(), node_path: String.t()}, [String.t()], pos_integer()) ::
          {:ok, summary()} | {:error, String.t()}
  defp run(env, args, timeout_ms) do
    task =
      Task.async(fn ->
        System.cmd(env.node_path, args, cd: env.renderer_dir, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, {output, 0}} ->
        parse_summary(output)

      {:ok, {output, _exit_code}} ->
        {:error, "Renderer failed (exit code). #{truncated(output)}"}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, "Render timed out after #{div(timeout_ms, 1000)}s"}
    end
  end

  @spec parse_summary(String.t()) :: {:ok, summary()} | {:error, String.t()}
  defp parse_summary(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reverse()
    |> Enum.find(fn line -> String.contains?(line, ~s("ok":)) end)
    |> case do
      nil ->
        {:error, "Renderer produced no summary. #{truncated(output)}"}

      line ->
        case Jason.decode(line) do
          {:ok, %{"ok" => true} = summary} -> {:ok, summary}
          {:ok, %{"ok" => false, "error" => message}} -> {:error, "Renderer failed: #{message}"}
          {:ok, other} -> {:error, "Unexpected renderer summary: #{inspect(other, limit: 5)}"}
          {:error, _} -> {:error, "Renderer produced unparseable output. #{truncated(output)}"}
        end
    end
  end

  defp truncated(output), do: "Output: #{String.slice(output, 0, 400)}"

  defp render_timeout_config,
    do: Application.get_env(:capcut_mcp, :remotion_render_timeout_ms, @default_timeout_ms)
end
