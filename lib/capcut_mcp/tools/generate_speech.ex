defmodule CapcutMcp.Tools.GenerateSpeech do
  @moduledoc """
  MCP tool: generate speech audio (voiceover/narration) from text with
  ElevenLabs, save it to disk and optionally add it to a project timeline as
  an audio clip.

  Needs `ELEVENLABS_API_KEY`; output is MP3.
  """

  @behaviour CapcutMcp.Tool

  alias CapcutMcp.CapCut.ProjectStore
  alias CapcutMcp.Tools.{AddClip, ToolArgs}
  alias CapcutMcp.Voice.{ElevenLabs, Mp3Duration, Output}

  @impl true
  def definition do
    %{
      "name" => "generate_speech",
      "description" =>
        "Generates speech audio (voiceover/narration) from text with ElevenLabs " <>
          "(needs ELEVENLABS_API_KEY) and saves it as an MP3. Optionally adds the audio to a " <>
          "project timeline as a clip.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "text" => %{"type" => "string", "description" => "Text to convert to speech"},
          "voice_id" => %{
            "type" => "string",
            "description" => "ElevenLabs voice id (see list_voices)"
          },
          "voice_name" => %{
            "type" => "string",
            "description" => "ElevenLabs voice name, e.g. \"Rachel\" (resolved via list_voices)"
          },
          "project_id" => %{
            "type" => "string",
            "description" => "Draft to add the audio clip to (omit to only generate the file)"
          },
          "start_ms" => %{
            "type" => "integer",
            "description" => "Start time on timeline in ms (default: 0)"
          },
          "track_index" => %{
            "type" => "integer",
            "description" => "Track index (default: auto-select audio track)"
          },
          "duration_ms" => %{
            "type" => "integer",
            "description" => "Clip duration in ms (default: estimated from the generated audio)"
          },
          "output_path" => %{
            "type" => "string",
            "description" =>
              "Absolute path for the audio (default: <project>/voice/voiceover-<timestamp>.mp3)"
          },
          "model_id" => %{
            "type" => "string",
            "description" => "ElevenLabs model (default: eleven_multilingual_v2)"
          },
          "stability" => %{
            "type" => "number",
            "description" => "Voice stability 0.0-1.0 (default 0.5)"
          },
          "similarity_boost" => %{
            "type" => "number",
            "description" => "Similarity boost 0.0-1.0 (default 0.75)"
          },
          "style" => %{
            "type" => "number",
            "description" => "Style exaggeration 0.0-1.0 (default 0)"
          },
          "speed" => %{"type" => "number", "description" => "Speech speed (default 1.0)"}
        },
        "required" => ["text"]
      }
    }
  end

  @impl true
  def execute(%{"text" => text} = args) do
    with {:ok, speech} <- ElevenLabs.text_to_speech(text, elevenlabs_opts(args)),
         {:ok, output} <- resolve_output(args),
         {:ok, written_path} <- Output.write_file(output, speech.audio),
         {:ok, duration_ms} <- resolve_duration(args, speech.audio) do
      result_text = base_summary(written_path, speech, duration_ms)

      case maybe_add_to_timeline(args, written_path, duration_ms) do
        :skipped ->
          {:ok, result_text}

        {:ok, clip_text} ->
          {:ok, result_text <> "\n\n" <> clip_text}

        {:error, reason} ->
          {:ok, result_text <> "\n\nAudio generated but NOT added to the timeline: #{reason}"}
      end
    end
  end

  def execute(args), do: {:error, ToolArgs.missing_required_message(args, ["text"])}

  # ── Provider ────────────────────────────────────────────────────────────────

  defp elevenlabs_opts(args) do
    [:voice_id, :voice_name, :model_id, :stability, :similarity_boost, :style, :speed]
    |> collect(args)
  end

  defp collect(keys, args) do
    Enum.flat_map(keys, fn key ->
      case Map.get(args, Atom.to_string(key)) do
        nil -> []
        value -> [{key, value}]
      end
    end)
  end

  # ── Output ──────────────────────────────────────────────────────────────────

  defp resolve_output(args) do
    case Map.get(args, "project_id") do
      nil ->
        Output.resolve_path(
          Map.get(args, "output_path"),
          Output.default_dir(),
          "voiceover",
          ".mp3"
        )

      project_id ->
        with {:ok, %{meta: meta}} <- fetch_project(project_id) do
          Output.resolve_path(
            Map.get(args, "output_path"),
            Output.project_dir(meta, "voice"),
            "voiceover",
            ".mp3"
          )
        end
    end
  end

  defp fetch_project(id) do
    case ProjectStore.get_project_with_meta(id) do
      {:ok, _} = ok -> ok
      {:error, :not_found} -> {:error, "Project not found: #{id}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_duration(args, audio) do
    case Map.get(args, "duration_ms") do
      nil ->
        case Mp3Duration.estimate(audio) do
          {:ok, ms} -> {:ok, max(ms, 500)}
          :error -> {:ok, 5000}
        end

      n when is_integer(n) and n > 0 ->
        {:ok, n}

      other ->
        {:error, "Invalid duration_ms: #{inspect(other, limit: 20)}"}
    end
  end

  defp maybe_add_to_timeline(args, path, duration_ms) do
    case Map.get(args, "project_id") do
      nil ->
        :skipped

      project_id ->
        clip_args =
          %{
            "project_id" => project_id,
            "file_path" => path,
            "duration_ms" => duration_ms
          }
          |> put_optional(args, "start_ms")
          |> put_optional(args, "track_index")

        case AddClip.execute(clip_args) do
          {:ok, text} -> {:ok, text}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp put_optional(clip_args, args, key) do
    case Map.get(args, key) do
      nil -> clip_args
      value -> Map.put(clip_args, key, value)
    end
  end

  defp base_summary(path, speech, duration_ms) do
    """
    Speech generated.
    File: #{path}
    Voice: #{speech.voice_id} (model: #{speech.model_id})
    Format: #{speech.output_format}
    Estimated duration: #{duration_ms}ms
    Size: #{byte_size(speech.audio)} bytes
    """
    |> String.trim()
  end
end
