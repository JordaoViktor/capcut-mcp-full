defmodule CapcutMcp.Voice.Config do
  @moduledoc """
  Configuration for the voice providers (ElevenLabs and Gemini).

  Resolution order for every value: `Application.get_env(:capcut_mcp, key)`
  first, then the documented environment variable. Nothing is required at
  boot — each voice tool checks its own provider key and returns a
  human-readable error when it is missing, so the rest of the server keeps
  working with no keys configured.
  """

  @elevenlabs_base "https://api.elevenlabs.io"
  @gemini_base "https://generativelanguage.googleapis.com/v1beta"

  @default_elevenlabs_model "eleven_multilingual_v2"
  @default_elevenlabs_voice_id "21m00Tcm4TlvDq8ikWAM"
  @default_gemini_text_model "gemini-2.5-flash"

  # ── ElevenLabs ───────────────────────────────────────────────────────────────

  @spec elevenlabs_api_key() :: String.t()
  def elevenlabs_api_key,
    do:
      Application.get_env(:capcut_mcp, :elevenlabs_api_key) ||
        System.get_env("ELEVENLABS_API_KEY") || ""

  @spec require_elevenlabs_api_key() :: {:ok, String.t()} | {:error, String.t()}
  def require_elevenlabs_api_key do
    case elevenlabs_api_key() do
      "" ->
        {:error,
         "ElevenLabs API key not configured. Set the ELEVENLABS_API_KEY environment variable " <>
           "(from https://elevenlabs.io → Profile → API Keys) and restart the server."}

      key ->
        {:ok, key}
    end
  end

  @spec elevenlabs_base_url() :: String.t()
  def elevenlabs_base_url,
    do: Application.get_env(:capcut_mcp, :elevenlabs_base_url) || @elevenlabs_base

  @spec elevenlabs_model_id() :: String.t()
  def elevenlabs_model_id,
    do:
      Application.get_env(:capcut_mcp, :elevenlabs_model_id) ||
        System.get_env("ELEVENLABS_MODEL_ID") ||
        @default_elevenlabs_model

  @doc "Default ElevenLabs voice id (Rachel) used when no voice_id/voice_name is given."
  @spec elevenlabs_voice_id() :: String.t()
  def elevenlabs_voice_id,
    do:
      Application.get_env(:capcut_mcp, :elevenlabs_voice_id) ||
        System.get_env("ELEVENLABS_VOICE_ID") ||
        @default_elevenlabs_voice_id

  # ── Gemini ───────────────────────────────────────────────────────────────────

  @spec gemini_api_key() :: String.t()
  def gemini_api_key,
    do:
      Application.get_env(:capcut_mcp, :gemini_api_key) || System.get_env("GEMINI_API_KEY") ||
        System.get_env("GOOGLE_API_KEY") || ""

  @spec require_gemini_api_key() :: {:ok, String.t()} | {:error, String.t()}
  def require_gemini_api_key do
    case gemini_api_key() do
      "" ->
        {:error,
         "Gemini API key not configured. Set the GEMINI_API_KEY environment variable " <>
           "(from https://aistudio.google.com/apikey) and restart the server."}

      key ->
        {:ok, key}
    end
  end

  @spec gemini_base_url() :: String.t()
  def gemini_base_url, do: Application.get_env(:capcut_mcp, :gemini_base_url) || @gemini_base

  @spec gemini_text_model() :: String.t()
  def gemini_text_model,
    do:
      Application.get_env(:capcut_mcp, :gemini_text_model) || System.get_env("GEMINI_TEXT_MODEL") ||
        @default_gemini_text_model

  @doc "Validates a Gemini model name for safe URL interpolation."
  @spec validate_model(term()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_model(model) when is_binary(model) do
    if Regex.match?(~r/^[A-Za-z0-9._-]+$/, model) do
      {:ok, model}
    else
      {:error, "Invalid model name: #{inspect(model)}"}
    end
  end

  def validate_model(other), do: {:error, "Invalid model name: #{inspect(other, limit: 20)}"}

  @doc """
  Default directory for generated audio/video when no project is involved:
  the `:voice_output_dir` app env, `VOICE_OUTPUT_DIR` env var, or
  `./voice-output` under the current working directory.
  """
  @spec voice_output_dir() :: String.t()
  def voice_output_dir do
    Application.get_env(:capcut_mcp, :voice_output_dir) || System.get_env("VOICE_OUTPUT_DIR") ||
      Path.join(File.cwd!(), "voice-output")
  end

  @doc "Injectable HTTP client for tests: `Application.get_env(:capcut_mcp, :voice_http)`."
  @spec http_injector() :: (map() -> {:ok, map()} | {:error, String.t()}) | nil
  def http_injector, do: Application.get_env(:capcut_mcp, :voice_http)
end
