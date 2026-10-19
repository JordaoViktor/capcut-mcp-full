defmodule CapcutMcp.Tools.TranscribeAudio do
  @moduledoc """
  MCP tool: transcribe an audio or video file to text using Google Gemini
  (inline media). Useful for captioning clips, summarizing takes, or
  understanding what is inside a media file before editing.
  """

  @behaviour CapcutMcp.Tool

  alias CapcutMcp.Voice.Gemini

  # Request body must stay under ~20MB; 15MB of raw bytes (~20MB base64) is a
  # conservative ceiling.
  @max_file_bytes 15 * 1024 * 1024

  @mime_types %{
    ".mp3" => "audio/mpeg",
    ".wav" => "audio/wav",
    ".m4a" => "audio/mp4",
    ".aac" => "audio/aac",
    ".flac" => "audio/flac",
    ".ogg" => "audio/ogg",
    ".opus" => "audio/opus",
    ".webm" => "audio/webm",
    ".mp4" => "audio/mp4",
    ".mov" => "video/mp4",
    ".avi" => "video/x-msvideo",
    ".mkv" => "video/x-matroska",
    ".m4v" => "video/mp4"
  }

  @impl true
  def definition do
    %{
      "name" => "transcribe_audio",
      "description" =>
        "Transcribes an audio or video file to text using Google Gemini. Supports mp3, wav, m4a, " <>
          "aac, flac, ogg, opus, mp4, mov, webm, avi, mkv up to ~15MB. Requires the GEMINI_API_KEY " <>
          "environment variable.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "file_path" => %{
            "type" => "string",
            "description" => "Absolute path to the audio or video file"
          },
          "model" => %{
            "type" => "string",
            "description" => "Gemini model (default: gemini-2.5-flash)"
          },
          "prompt" => %{
            "type" => "string",
            "description" =>
              "Custom instruction. Default: transcribe verbatim. Examples: \"summarize in Portuguese\", " <>
                "\"list the spoken editing instructions\", \"transcribe with timestamps\""
          },
          "include_timestamps" => %{
            "type" => "boolean",
            "description" => "Ask Gemini to add timestamps to the transcript (default: false)"
          }
        },
        "required" => ["file_path"]
      }
    }
  end

  @impl true
  def execute(%{"file_path" => path} = args) do
    with {:ok, mime_type} <- mime_type_for(path),
         {:ok, bytes} <- read_file(path) do
      prompt = build_prompt(args)

      parts = [
        %{"text" => prompt},
        %{inlineData: %{mimeType: mime_type, data: Base.encode64(bytes)}}
      ]

      opts =
        [
          model: Map.get(args, "model"),
          timeout_ms: 180_000
        ]
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)

      Gemini.generate_content(parts, opts)
    end
  end

  def execute(_args),
    do: {:error, "Missing required arguments: file_path"}

  # ── Internals ────────────────────────────────────────────────────────────────

  defp build_prompt(args) do
    base = Map.get(args, "prompt") || "Transcribe the spoken content of this recording verbatim."

    base =
      if String.trim(base) == "",
        do: "Transcribe the spoken content of this recording verbatim.",
        else: String.trim(base)

    if Map.get(args, "include_timestamps") do
      base <>
        " Include timestamps in [mm:ss] format for each spoken segment."
    else
      base
    end
  end

  defp mime_type_for(path) when is_binary(path) do
    ext = path |> Path.extname() |> String.downcase()

    case Map.fetch(@mime_types, ext) do
      {:ok, mime_type} ->
        {:ok, mime_type}

      :error ->
        {:error,
         "Unsupported file type #{inspect(ext)}. Supported: #{Enum.join(Map.keys(@mime_types), ", ")}"}
    end
  end

  defp mime_type_for(other), do: {:error, "Invalid file_path: #{inspect(other, limit: 20)}"}

  defp read_file(path) when is_binary(path) do
    cond do
      String.trim(path) == "" ->
        {:error, "Invalid file_path: path is empty"}

      not File.exists?(path) ->
        {:error, "File not found: #{path}"}

      true ->
        stat_and_read(path)
    end
  end

  defp stat_and_read(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > @max_file_bytes ->
        {:error,
         "File too large for inline transcription: #{div(size, 1_048_576)}MB (max 15MB). " <>
           "Trim or compress the file first."}

      {:ok, _stat} ->
        read_bytes(path)

      {:error, reason} ->
        {:error, "Failed to stat #{path}: #{inspect(reason)}"}
    end
  end

  defp read_bytes(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, "Failed to read #{path}: #{inspect(reason)}"}
    end
  end
end
