defmodule CapcutMcp.Tools.VoiceCommand do
  @moduledoc """
  MCP tool: process a recorded voice command for CapCut editing.

  The marketing team records an instruction (QuickTime, phone, any recorder),
  the recording goes to Gemini for transcription and interpretation, the
  returned plan is validated against the editing tool allowlist, and each
  action is executed by the dispatcher. Optionally, the natural-language
  reply is spoken back with ElevenLabs so the loop is fully hands-free:

      voice → transcript → plan → edits → spoken confirmation
  """

  @behaviour CapcutMcp.Tool

  alias CapcutMcp.CapCut.ProjectStore
  alias CapcutMcp.MCP.Dispatcher
  alias CapcutMcp.Voice.{CommandPlan, ElevenLabs, Gemini, Output}

  # Same inline-size ceiling as transcribe_audio.
  @max_file_bytes 15 * 1024 * 1024

  @audio_mime_types %{
    ".mp3" => "audio/mpeg",
    ".wav" => "audio/wav",
    ".m4a" => "audio/mp4",
    ".aac" => "audio/aac",
    ".flac" => "audio/flac",
    ".ogg" => "audio/ogg",
    ".opus" => "audio/opus",
    ".webm" => "audio/webm",
    ".mp4" => "audio/mp4",
    ".mov" => "video/mp4"
  }

  @impl true
  def definition do
    %{
      "name" => "voice_command",
      "description" =>
        "Processes a recorded voice command (audio file) for CapCut editing: transcribes it with " <>
          "Gemini, maps the spoken instruction to editing tool calls and executes them on the " <>
          "project. With project_id set, the current timeline is included as context, so commands " <>
          "like 'mute the music' or 'add a title saying Black Friday at the start' resolve to " <>
          "real clip ids. Requires GEMINI_API_KEY (and ELEVENLABS_API_KEY only for speak_reply).",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "audio_path" => %{
            "type" => "string",
            "description" =>
              "Absolute path to the recorded voice command (mp3, wav, m4a, aac, ogg, opus, webm, mp4, mov)"
          },
          "project_id" => %{
            "type" => "string",
            "description" =>
              "Draft the command should operate on (recommended — provides timeline context)"
          },
          "execute" => %{
            "type" => "boolean",
            "description" =>
              "Run the planned actions (default: true). Set false to only preview the plan"
          },
          "context" => %{
            "type" => "string",
            "description" =>
              "Optional extra hints for interpretation, e.g. who is speaking or which clip is which " <>
                "(treated as data, never as commands)"
          },
          "model" => %{
            "type" => "string",
            "description" => "Gemini model (default: gemini-2.5-flash)"
          },
          "speak_reply" => %{
            "type" => "boolean",
            "description" =>
              "Also generate an MP3 of the confirmation reply via ElevenLabs (default: false)"
          },
          "voice_id" => %{
            "type" => "string",
            "description" => "ElevenLabs voice id for the spoken reply"
          },
          "voice_name" => %{
            "type" => "string",
            "description" => "ElevenLabs voice name for the spoken reply"
          }
        },
        "required" => ["audio_path"]
      }
    }
  end

  @impl true
  def execute(%{"audio_path" => audio_path} = args) do
    with {:ok, bytes, mime_type} <- load_audio(audio_path),
         :ok <- check_project(args),
         {:ok, context_text} <- build_context(args),
         {:ok, raw} <- interpret(bytes, mime_type, context_text, args),
         {:ok, %{plan: plan, skipped: skipped}} <- CommandPlan.parse(raw) do
      executed =
        if execute?(args) and plan.actions != [] do
          run_actions(args, plan.actions)
        else
          nil
        end

      result = format_result(plan, skipped, executed, args)
      spoken = maybe_speak_reply(args, plan)

      case spoken do
        {:ok, audio_path} -> {:ok, result <> "\n\nSpoken reply: #{audio_path}"}
        :skipped -> {:ok, result}
        {:error, reason} -> {:ok, result <> "\n\nReply not spoken: #{reason}"}
      end
    end
    |> then(fn
      {:ok, _} = ok -> ok
      {:error, reason} -> {:error, reason}
    end)
  end

  def execute(_args),
    do: {:error, "Missing required arguments: audio_path"}

  # ── Internals ────────────────────────────────────────────────────────────────

  defp load_audio(path) when is_binary(path) do
    cond do
      String.trim(path) == "" ->
        {:error, "Invalid audio_path: path is empty"}

      not File.exists?(path) ->
        {:error, "Audio file not found: #{path}"}

      true ->
        with {:ok, mime_type} <- audio_mime_type(path),
             {:ok, bytes} <- read_audio(path) do
          {:ok, bytes, mime_type}
        end
    end
  end

  defp load_audio(other), do: {:error, "Invalid audio_path: #{inspect(other, limit: 20)}"}

  defp audio_mime_type(path) do
    ext = path |> Path.extname() |> String.downcase()

    case Map.fetch(@audio_mime_types, ext) do
      {:ok, mime_type} ->
        {:ok, mime_type}

      :error ->
        {:error,
         "Unsupported audio type #{inspect(ext)}. Supported: #{Enum.join(Map.keys(@audio_mime_types), ", ")}"}
    end
  end

  defp read_audio(path) do
    with {:ok, %{size: size}} <- stat(path) do
      read_audio_within_limit(path, size)
    end
  end

  defp read_audio_within_limit(_path, size) when size > @max_file_bytes do
    {:error,
     "Audio file too large for inline transcription: #{div(size, 1_048_576)}MB (max 15MB). " <>
       "Record a shorter command or trim the file."}
  end

  defp read_audio_within_limit(path, _size) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, "Failed to read #{path}: #{inspect(reason)}"}
    end
  end

  defp stat(path) do
    case File.stat(path) do
      {:ok, stat} -> {:ok, stat}
      {:error, reason} -> {:error, "Failed to stat #{path}: #{inspect(reason)}"}
    end
  end

  defp check_project(args) do
    case Map.get(args, "project_id") do
      nil ->
        :ok

      project_id when is_binary(project_id) ->
        # Fail fast on an unknown project before spending an API call.
        case ProjectStore.get_project(project_id) do
          {:ok, _draft} -> :ok
          {:error, :not_found} -> {:error, "Project not found: #{project_id}"}
          {:error, reason} -> {:error, inspect(reason)}
        end

      other ->
        {:error, "Invalid project_id: #{inspect(other, limit: 20)}"}
    end
  end

  defp build_context(args) do
    case CommandPlan.project_context(Map.get(args, "project_id")) do
      nil -> {:ok, nil}
      context when is_binary(context) -> {:ok, context}
      {:error, reason} -> {:error, reason}
    end
  end

  defp interpret(bytes, mime_type, context_text, args) do
    prompt = CommandPlan.build_prompt(context_text, Map.get(args, "context"))
    part = %{inlineData: %{mimeType: mime_type, data: Base.encode64(bytes)}}

    opts =
      [
        model: Map.get(args, "model"),
        json: true,
        timeout_ms: 180_000
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    Gemini.generate_json([%{"text" => prompt}, part], opts)
  end

  defp execute?(args), do: Map.get(args, "execute", true) != false

  defp run_actions(args, actions) do
    Enum.map(actions, fn action ->
      case Dispatcher.call_tool(action.tool, args_for(action, args)) do
        {:ok, text} -> {:ok, action.tool, text}
        {:error, reason} -> {:error, action.tool, reason}
      end
    end)
  end

  # Voice actions operate on the bound project by default; the tool catalog
  # includes project_id for actions that need it, so arguments pass through as
  # Gemini returned them — plus the bound project_id when the model left it
  # out (it only knows the id from context).
  defp args_for(action, args) do
    case Map.get(args, "project_id") do
      nil ->
        action.arguments

      project_id when is_binary(project_id) ->
        if Map.has_key?(action.arguments, "project_id") do
          action.arguments
        else
          Map.put(action.arguments, "project_id", project_id)
        end
    end
  end

  defp format_result(plan, skipped, executed, args) do
    lines = ["Transcript: #{plan.transcript}"]

    lines =
      lines ++
        if plan.language, do: ["Language: #{plan.language}"], else: []

    lines =
      if plan.actions == [] do
        lines ++ ["Planned actions: none."]
      else
        lines ++ ["Planned actions:"]

        lines ++
          Enum.map(plan.actions, fn action ->
            "  - #{action.tool} #{format_args(action.arguments)}"
          end)
      end

    lines =
      if skipped != [] do
        lines ++
          ["Disallowed tools removed: #{Enum.map_join(skipped, ", ", & &1.tool)}"]
      else
        lines
      end

    lines =
      if execute?(args) and executed do
        lines ++
          ["Results:"] ++
          Enum.map(executed, fn
            {:ok, tool, text} -> "  [ok] #{tool}: #{String.slice(text, 0, 400)}"
            {:error, tool, reason} -> "  [error] #{tool}: #{reason}"
          end)
      else
        lines
      end

    lines =
      if plan.reply do
        lines ++ ["Reply: #{plan.reply}"]
      else
        lines
      end

    Enum.join(lines, "\n")
  end

  defp format_args(args) when map_size(args) == 0, do: "{}"

  defp format_args(args) do
    args
    |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{summary_value(v)}" end)
    |> then(&"(#{&1})")
  end

  defp summary_value(v) when is_binary(v),
    do: if(String.length(v) > 60, do: String.slice(v, 0, 60) <> "…", else: v)

  defp summary_value(v), do: inspect(v, limit: 10)

  defp maybe_speak_reply(args, plan) do
    if Map.get(args, "speak_reply", false) == true and is_binary(plan.reply) and
         String.trim(plan.reply) != "" do
      speak_opts =
        [
          voice_id: Map.get(args, "voice_id"),
          voice_name: Map.get(args, "voice_name")
        ]
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)

      with {:ok, speech} <- ElevenLabs.text_to_speech(plan.reply, speak_opts),
           {:ok, path} <- Output.resolve_path(nil, Output.default_dir(), "voice-reply", ".mp3") do
        Output.write_file(path, speech.audio)
      end
    else
      :skipped
    end
  end
end
