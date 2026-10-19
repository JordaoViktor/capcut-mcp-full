defmodule CapcutMcp.Voice.Gemini do
  @moduledoc """
  Client for the Google Gemini API (`generativelanguage.googleapis.com`).

  Covers the three things this server needs:

    * `generate_content/2` — plain text generation (transcription prompts are
      sent as parts: text + inline media).
    * `generate_json/2` — generation with `responseMimeType: application/json`
      for structured command plans (markdown fences stripped, decoded, and
      shape-validated by `CapcutMcp.Voice.CommandPlan`).

  Keys: `GEMINI_API_KEY` (or `GOOGLE_API_KEY`). Models are validated for safe
  URL interpolation.
  """

  alias CapcutMcp.Voice.{Config, HTTP}

  @generate_path "/models/"
  @generate_suffix ":generateContent"
  @type inline_part :: %{mimeType: String.t(), data: String.t()}

  @doc """
  Calls `generateContent` with the given parts (text and/or inline media) and
  returns the concatenated text of the first candidate.
  """
  @spec generate_content([map()], keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def generate_content(parts, opts \\ []) when is_list(parts) do
    request_generate(parts, opts, false)
  end

  @doc """
  Same as `generate_content/2` but requests `application/json` output and
  decodes the response (tolerating markdown fences). `schema` is optional
  (a plain `responseMimeType` is enough for most models).
  """
  @spec generate_json([map()], keyword()) :: {:ok, term()} | {:error, String.t()}
  def generate_json(parts, opts \\ []) when is_list(parts) do
    case request_generate(parts, Keyword.put(opts, :json, true), true) do
      {:ok, text} -> decode_json_text(text)
      error -> error
    end
  end

  # ── Internals ────────────────────────────────────────────────────────────────

  defp request_generate(parts, opts, expect_json) do
    with {:ok, api_key} <- Config.require_gemini_api_key(),
         {:ok, model} <- model(opts, Config.gemini_text_model()),
         {:ok, body} <- encode_body(parts, opts) do
      url = "#{Config.gemini_base_url()}#{@generate_path}#{model}#{@generate_suffix}"

      request = %{
        method: :post,
        url: url,
        headers: [
          {"x-goog-api-key", api_key},
          {"content-type", "application/json"},
          {"accept", "application/json"}
        ],
        body: body,
        timeout_ms: Keyword.get(opts, :timeout_ms, 120_000)
      }

      case HTTP.request(request) do
        {:ok, %{status: 200, body: response_body}} -> parse_candidates(response_body, expect_json)
        {:ok, %{status: status, body: error_body}} -> {:error, provider_error(status, error_body)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp model(opts, default) do
    Config.validate_model(Keyword.get(opts, :model) || default)
  end

  defp encode_body(parts, opts) do
    generation_config =
      if Keyword.get(opts, :json) do
        base = %{"responseMimeType" => "application/json", "temperature" => 0.2}

        case Keyword.fetch(opts, :schema) do
          {:ok, schema} -> Map.put(base, "responseSchema", schema)
          :error -> base
        end
      else
        %{}
      end

    body = %{
      "contents" => [%{"role" => "user", "parts" => parts}],
      "generationConfig" => generation_config
    }

    {:ok, Jason.encode!(body)}
  rescue
    e in [Jason.EncodeError] ->
      {:error, "Failed to encode Gemini request: #{Exception.message(e)}"}
  end

  defp parse_candidates(body, _expect_json) do
    case Jason.decode(body) do
      {:ok, decoded} ->
        case extract_text(decoded) do
          {:ok, text} -> {:ok, text}
          {:error, reason} -> {:error, reason}
        end

      {:error, _} ->
        {:error, "Gemini response is not valid JSON. #{String.slice(body, 0, 300)}"}
    end
  end

  defp extract_text(%{"candidates" => [%{"content" => %{"parts" => parts}} | _]} = decoded)
       when is_list(parts) do
    text =
      parts
      |> Enum.map_join("", fn
        %{"text" => t} when is_binary(t) -> t
        _ -> ""
      end)

    if String.trim(text) == "" do
      {:error, blocked_message(decoded)}
    else
      {:ok, text}
    end
  end

  defp extract_text(decoded), do: {:error, blocked_message(decoded)}

  defp blocked_message(decoded) do
    case decoded do
      %{"promptFeedback" => %{"blockReason" => reason}} ->
        "Gemini blocked the prompt (#{reason}). Try rephrasing or removing flagged content."

      _ ->
        "Gemini returned no text content (the response was empty or blocked)."
    end
  end

  defp decode_json_text(text) do
    json =
      text
      |> String.trim()
      |> strip_fences()

    case Jason.decode(json) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, reason} ->
        {:error,
         "Gemini returned invalid JSON (#{inspect(reason)}): #{String.slice(text, 0, 300)}"}
    end
  end

  defp strip_fences(text) do
    case Regex.run(~r/```(?:json)?\s*([\s\S]*?)\s*```/, text) do
      [_, inner] -> inner
      nil -> text
    end
  end

  defp provider_error(status, body) do
    detail =
      case Jason.decode(body) do
        {:ok, %{"error" => %{"message" => message}}} -> message
        {:ok, other} -> truncated(Jason.encode!(other))
        {:error, _} -> truncated(body)
      end

    hint = if status == 429, do: " (rate limit or quota exceeded)", else: ""

    "Gemini request failed (HTTP #{status})#{hint}. #{detail}"
  end

  defp truncated(term) when is_binary(term), do: String.slice(term, 0, 300)
  defp truncated(term), do: term |> Jason.encode!() |> String.slice(0, 300)
end
