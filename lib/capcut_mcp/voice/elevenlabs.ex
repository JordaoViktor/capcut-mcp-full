defmodule CapcutMcp.Voice.ElevenLabs do
  @moduledoc """
  Client for the ElevenLabs API: text-to-speech and voice listing.

  - TTS: `POST /v1/text-to-speech/{voice_id}?output_format=...` returns raw
    MP3 bytes (this repo treats them as opaque binary and writes them out).
  - Voices: `GET /v1/voices` returns the account's voices (name, voice_id,
    category, labels) — used by `list_voices` and by voice-name resolution.

  Errors from the API are surfaced as human-readable strings; HTTP 401/422
  typically mean a missing/invalid `ELEVENLABS_API_KEY`.
  """

  alias CapcutMcp.Voice.{Config, HTTP}

  @tts_path "/v1/text-to-speech/"
  @voices_path "/v1/voices"

  @output_formats ~w(mp3_22050_32 mp3_44100_64 mp3_44100_128 mp3_44100_192)
  @default_output_format "mp3_44100_128"

  @type speech :: %{
          audio: binary(),
          output_format: String.t(),
          voice_id: String.t(),
          model_id: String.t()
        }
  @type voice :: %{
          voice_id: String.t(),
          name: String.t(),
          category: String.t() | nil,
          labels: map()
        }

  @doc """
  Converts text to speech. Options:

    * `:voice_id` — ElevenLabs voice id (preferred)
    * `:voice_name` — voice name (e.g. "Rachel"), resolved via `/v1/voices`
    * `:model_id` — TTS model (default: `eleven_multilingual_v2`)
    * `:output_format` — one of #{@output_formats} (default: mp3_44100_128)
    * `:stability`, `:similarity_boost`, `:style` — 0.0..1.0
    * `:speed` — 0.7..1.2
    * `:timeout_ms` — request timeout (default 60s)
  """
  @spec text_to_speech(String.t(), keyword()) :: {:ok, speech()} | {:error, String.t()}
  def text_to_speech(text, opts \\ []) when is_binary(text) do
    with :ok <- validate_text(text),
         {:ok, api_key} <- Config.require_elevenlabs_api_key(),
         {:ok, voice_id} <- resolve_voice_id(opts),
         {:ok, output_format} <- validate_output_format(Keyword.get(opts, :output_format)),
         {:ok, body} <- build_body(text, opts) do
      perform_tts(api_key, voice_id, output_format, body, opts)
    end
  end

  defp validate_text(text) do
    if String.trim(text) == "" do
      {:error, "Invalid text: text is empty"}
    else
      :ok
    end
  end

  defp perform_tts(api_key, voice_id, output_format, body, opts) do
    request = %{
      method: :post,
      url:
        "#{Config.elevenlabs_base_url()}#{@tts_path}#{voice_id}?output_format=#{output_format}",
      headers: [
        {"xi-api-key", api_key},
        {"accept", "audio/mpeg"},
        {"content-type", "application/json"}
      ],
      body: body,
      timeout_ms: Keyword.get(opts, :timeout_ms, 60_000)
    }

    case HTTP.request(request) do
      {:ok, %{status: 200, body: audio}} when is_binary(audio) and audio != "" ->
        {:ok,
         %{
           audio: audio,
           output_format: output_format,
           voice_id: voice_id,
           model_id: Keyword.get(opts, :model_id) || Config.elevenlabs_model_id()
         }}

      {:ok, %{status: status, body: error_body}} ->
        {:error, provider_error(status, error_body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Lists the account's ElevenLabs voices."
  @spec list_voices(keyword()) :: {:ok, [voice()]} | {:error, String.t()}
  def list_voices(opts \\ []) do
    with {:ok, api_key} <- Config.require_elevenlabs_api_key() do
      request = %{
        method: :get,
        url: "#{Config.elevenlabs_base_url()}#{@voices_path}",
        headers: [{"xi-api-key", api_key}, {"accept", "application/json"}],
        timeout_ms: Keyword.get(opts, :timeout_ms, 30_000)
      }

      case HTTP.request(request) do
        {:ok, %{status: 200, body: body}} -> parse_voices(body)
        {:ok, %{status: status, body: error_body}} -> {:error, provider_error(status, error_body)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Resolves the target voice id from options: explicit `:voice_id`, then
  `:voice_name` (looked up case-insensitively), then the configured default.
  """
  @spec resolve_voice_id(keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve_voice_id(opts) do
    cond do
      voice_id = Keyword.get(opts, :voice_id) ->
        validate_voice_id(voice_id)

      voice_name = Keyword.get(opts, :voice_name) ->
        resolve_voice_name(voice_name)

      true ->
        {:ok, Config.elevenlabs_voice_id()}
    end
  end

  # ── Internals ────────────────────────────────────────────────────────────────

  defp validate_voice_id(voice_id) when is_binary(voice_id) do
    if Regex.match?(~r/^[A-Za-z0-9]{10,60}$/, String.trim(voice_id)) do
      {:ok, String.trim(voice_id)}
    else
      {:error,
       "Invalid voice_id #{inspect(voice_id, limit: 20)}. Call list_voices to find valid voice ids."}
    end
  end

  defp validate_voice_id(other), do: {:error, "Invalid voice_id: #{inspect(other, limit: 20)}"}

  defp resolve_voice_name(voice_name) when is_binary(voice_name) do
    name = String.trim(voice_name)

    case list_voices([]) do
      {:ok, voices} ->
        exact = Enum.find(voices, &(String.downcase(&1.name) == String.downcase(name)))

        partial =
          exact ||
            Enum.find(voices, &String.contains?(String.downcase(&1.name), String.downcase(name)))

        case partial do
          %{} = voice -> {:ok, voice.voice_id}
          nil -> {:error, voice_not_found_message(name, voices)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_voice_name(other), do: {:error, "Invalid voice_name: #{inspect(other, limit: 20)}"}

  defp voice_not_found_message(name, voices) do
    available =
      voices
      |> Enum.take(10)
      |> Enum.map_join(", ", & &1.name)

    if available == "" do
      "Voice #{inspect(name)} not found and the account has no voices."
    else
      suffix = if length(voices) > 10, do: ", …", else: ""

      "Voice #{inspect(name)} not found. Available voices: #{available}#{suffix}. Use voice_id for exact match."
    end
  end

  defp validate_output_format(nil), do: {:ok, @default_output_format}

  defp validate_output_format(format) when format in @output_formats, do: {:ok, format}

  defp validate_output_format(other),
    do:
      {:error,
       "Invalid output_format: #{inspect(other, limit: 20)}. Supported: #{Enum.join(@output_formats, ", ")}"}

  defp build_body(text, opts) do
    model_id = Keyword.get(opts, :model_id) || Config.elevenlabs_model_id()

    body = %{
      "text" => text,
      "model_id" => model_id,
      "voice_settings" => %{
        "stability" => clamp01(Keyword.get(opts, :stability), 0.5),
        "similarity_boost" => clamp01(Keyword.get(opts, :similarity_boost), 0.75),
        "style" => clamp01(Keyword.get(opts, :style), 0.0),
        "use_speaker_boost" => true,
        "speed" => speed_value(Keyword.get(opts, :speed))
      }
    }

    {:ok, Jason.encode!(body)}
  rescue
    e in [Jason.EncodeError] -> {:error, "Failed to encode TTS request: #{Exception.message(e)}"}
  end

  defp clamp01(nil, default), do: default
  defp clamp01(v, _default) when is_number(v) and v >= 0 and v <= 1, do: v * 1.0
  defp clamp01(_, default), do: default

  defp speed_value(nil), do: 1.0
  defp speed_value(v) when is_number(v) and v >= 0.7 and v <= 1.2, do: v * 1.0
  defp speed_value(_), do: 1.0

  defp parse_voices(body) do
    case Jason.decode(body) do
      {:ok, %{"voices" => voices}} when is_list(voices) ->
        {:ok, Enum.map(voices, &parse_voice/1)}

      {:ok, _other} ->
        {:error, "Unexpected ElevenLabs voices response shape"}

      {:error, _} ->
        {:error, "ElevenLabs voices response is not valid JSON"}
    end
  end

  defp parse_voice(%{"voice_id" => id, "name" => name} = v) do
    %{
      voice_id: id,
      name: name,
      category: v["category"],
      labels: v["labels"] || %{}
    }
  end

  defp parse_voice(_other), do: %{voice_id: "", name: "(unknown)", category: nil, labels: %{}}

  @spec provider_error(pos_integer(), binary()) :: String.t()
  def provider_error(status, body) do
    "ElevenLabs request failed (HTTP #{status}). #{error_detail(body)}"
  end

  @doc false
  def error_detail(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"detail" => %{"message" => message}}} -> message
      {:ok, %{"detail" => detail}} when is_binary(detail) -> detail
      {:ok, other} -> truncated(Jason.encode!(other))
      {:error, _} -> truncated(body)
    end
  end

  defp truncated(body), do: String.slice(body, 0, 300)
end
