defmodule CapcutMcp.Tools.RenderProject do
  @moduledoc """
  MCP tool: render a CapCut project to a video file with the bundled
  Remotion renderer (`renderer/`, invoked via Node).

  This closes the "no export" gap: CapCut itself has no CLI for exporting,
  but the draft JSON is a complete-enough description of the timeline that
  Remotion can render an approximation of it — clips (video/image/audio),
  text overlays, transforms, opacity, keyframes, blend modes and the curated
  text animations. See `CapcutMcp.Remotion.Renderer` and the README for the
  documented approximation limits.
  """

  @behaviour CapcutMcp.Tool

  alias CapcutMcp.CapCut.ProjectStore
  alias CapcutMcp.Remotion.Renderer
  alias CapcutMcp.Tools.ToolArgs

  @impl true
  def definition do
    %{
      "name" => "render_project",
      "description" =>
        "Renders a CapCut project to a video file using the bundled Remotion renderer. " <>
          "Renders clips (video/image/audio), text overlays, transforms, opacity, keyframes, " <>
          "blend modes and curated text animations; transitions/effects/stickers/filters are " <>
          "not rendered. Requires Node.js 18+ and `npm install` inside the renderer/ directory.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "project_id" => %{"type" => "string", "description" => "The draft_id of the project"},
          "output_path" => %{
            "type" => "string",
            "description" =>
              "Absolute path for the output file (default: <project>/renders/render-<timestamp>.mp4)"
          },
          "codec" => %{
            "type" => "string",
            "description" => "Video codec: h264 (default), h265, vp8, vp9, prores"
          },
          "concurrency" => %{
            "type" => "integer",
            "description" => "Remotion render concurrency (number of browser tabs)"
          }
        },
        "required" => ["project_id"]
      }
    }
  end

  @impl true
  def execute(%{"project_id" => id} = args) do
    with {:ok, %{meta: meta}} <- fetch_project(id),
         {:ok, draft_file} <- resolve_draft_file(meta.path),
         {:ok, output} <- resolve_output(meta, args),
         {:ok, opts} <- build_opts(args) do
      case Renderer.render(draft_file, output, opts) do
        {:ok, summary} -> {:ok, format_summary(summary)}
        {:error, reason} -> {:error, reason}
      end
    end
    |> ToolArgs.format_tool_result(id)
  end

  def execute(args),
    do: {:error, ToolArgs.missing_required_message(args, ["project_id"])}

  # Surfaces Reader's `:draft_json_not_found` (project folder with neither
  # draft_content.json nor draft_info.json) as a human-readable tool error.
  defp fetch_project(id) do
    case ProjectStore.get_project_with_meta(id) do
      {:ok, _} = ok -> ok
      {:error, :draft_json_not_found} -> {:error, "Draft file not found for project #{id}"}
      {:error, other} -> {:error, other}
    end
  end

  # Reader's draft-file lookup order: prefer draft_content.json (Windows +
  # this repo's historical format), fall back to draft_info.json (what
  # current macOS CapCut writes for new projects).
  defp resolve_draft_file(project_path) do
    content_path = Path.join(project_path, "draft_content.json")
    info_path = Path.join(project_path, "draft_info.json")

    cond do
      File.exists?(content_path) -> {:ok, content_path}
      File.exists?(info_path) -> {:ok, info_path}
      true -> {:error, "No draft_content.json or draft_info.json in #{project_path}"}
    end
  end

  defp resolve_output(meta, args) do
    case Map.get(args, "output_path") do
      nil ->
        {:ok, default_output(meta, args)}

      path when is_binary(path) ->
        if String.trim(path) == "" do
          {:error, "Invalid output_path: path is empty"}
        else
          {:ok, Path.expand(path)}
        end

      other ->
        {:error, "Invalid output_path: #{inspect(other, limit: 20)}"}
    end
  end

  # The default extension must match the requested codec's container, so a
  # `codec: "vp9"` call without an explicit output_path lands on .webm.
  defp default_output(meta, args) do
    codec = args |> Map.get("codec") |> default_codec()
    ext = codec |> Renderer.container_extensions() |> List.first(".mp4")
    filename = "render-#{System.system_time(:millisecond)}#{ext}"
    Path.join([meta.path, "renders", filename])
  end

  defp default_codec(codec) when is_binary(codec) and codec != "", do: codec
  defp default_codec(_), do: "h264"

  defp build_opts(args) do
    with {:ok, opts} <- codec_opts(args) do
      with_concurrency(args, opts)
    end
  end

  defp codec_opts(args) do
    case Map.get(args, "codec") do
      nil -> {:ok, []}
      codec when is_binary(codec) -> {:ok, [codec: codec]}
      other -> {:error, "Invalid codec: #{inspect(other, limit: 20)}"}
    end
  end

  defp with_concurrency(args, opts) do
    case Map.get(args, "concurrency") do
      nil ->
        {:ok, opts}

      n when is_integer(n) ->
        {:ok, Keyword.put(opts, :concurrency, n)}

      other ->
        {:error, "Invalid concurrency: #{inspect(other, limit: 20)} (must be a positive integer)"}
    end
  end

  defp format_summary(summary) do
    lines = [
      "Render complete.",
      "Output: #{summary["output"]}",
      "Codec: #{summary["codec"]}",
      "Canvas: #{summary["width"]}x#{summary["height"]} @ #{summary["fps"]}fps",
      "Duration: #{format_seconds(summary["durationMs"])} (#{summary["durationFrames"]} frames)",
      "Layers: #{summary["layers"]} rendered#{format_skipped(summary["skipped"])}",
      "Size: #{format_bytes(summary["sizeBytes"])}",
      "Render time: #{format_seconds(summary["elapsedMs"])}"
    ]

    Enum.join(lines, "\n")
  end

  defp format_skipped([]), do: ""
  defp format_skipped(nil), do: ""

  defp format_skipped(skipped) do
    details =
      skipped
      |> Enum.take(5)
      |> Enum.map_join("\n  ", fn item -> "- #{item["reason"]}" end)

    suffix = if length(skipped) > 5, do: "\n  (…and #{length(skipped) - 5} more)", else: ""
    ", #{length(skipped)} skipped:\n  #{details}#{suffix}"
  end

  defp format_seconds(ms) when is_number(ms),
    do: :erlang.float_to_binary(ms / 1000, decimals: 1) <> "s"

  defp format_seconds(_), do: "?"

  defp format_bytes(bytes) when is_number(bytes) and bytes >= 0 do
    cond do
      bytes >= 1_048_576 -> :erlang.float_to_binary(bytes / 1_048_576, decimals: 1) <> " MB"
      bytes >= 1024 -> :erlang.float_to_binary(bytes / 1024, decimals: 1) <> " KB"
      true -> "#{trunc(bytes)} bytes"
    end
  end

  defp format_bytes(_), do: "?"
end
