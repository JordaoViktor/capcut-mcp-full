defmodule CapcutMcp.Voice.ConfigTest do
  use ExUnit.Case, async: false

  alias CapcutMcp.Voice.Config

  @keys [
    :elevenlabs_api_key,
    :elevenlabs_voice_id,
    :gemini_api_key,
    :gemini_text_model
  ]

  setup do
    on_exit(fn ->
      Enum.each(@keys, &Application.delete_env(:capcut_mcp, &1))
      System.delete_env("ELEVENLABS_API_KEY")
      System.delete_env("GEMINI_API_KEY")
      System.delete_env("GOOGLE_API_KEY")
      System.delete_env("ELEVENLABS_VOICE_ID")
      System.delete_env("GEMINI_TEXT_MODEL")
      System.delete_env("VOICE_OUTPUT_DIR")
    end)

    :ok
  end

  describe "elevenlabs key" do
    test "errors with a helpful message when nothing is set" do
      assert {:error, message} = Config.require_elevenlabs_api_key()
      assert message =~ "ELEVENLABS_API_KEY"
      assert message =~ "restart"
    end

    test "prefers app env over the environment variable" do
      Application.put_env(:capcut_mcp, :elevenlabs_api_key, "app-env-key")
      System.put_env("ELEVENLABS_API_KEY", "system-env-key")

      assert {:ok, "app-env-key"} = Config.require_elevenlabs_api_key()
    end

    test "falls back to ELEVENLABS_API_KEY" do
      System.put_env("ELEVENLABS_API_KEY", "env-key")

      assert {:ok, "env-key"} = Config.require_elevenlabs_api_key()
    end
  end

  describe "gemini key" do
    test "errors with a helpful message when nothing is set" do
      assert {:error, message} = Config.require_gemini_api_key()
      assert message =~ "GEMINI_API_KEY"
    end

    test "accepts GEMINI_API_KEY" do
      System.put_env("GEMINI_API_KEY", "g-key")

      assert {:ok, "g-key"} = Config.require_gemini_api_key()
    end

    test "accepts GOOGLE_API_KEY as a fallback" do
      System.put_env("GOOGLE_API_KEY", "google-key")

      assert {:ok, "google-key"} = Config.require_gemini_api_key()
    end
  end

  describe "model handling" do
    test "returns the default text model when unset" do
      assert Config.gemini_text_model() == "gemini-2.5-flash"
    end

    test "honours GEMINI_TEXT_MODEL env var" do
      System.put_env("GEMINI_TEXT_MODEL", "gemini-2.5-pro")

      assert Config.gemini_text_model() == "gemini-2.5-pro"
    end

    test "validate_model/1 rejects names with URL-hostile characters" do
      assert {:error, _} = Config.validate_model("veo-3/..%2F..")
      assert {:error, _} = Config.validate_model(123)

      assert {:ok, "veo-3.0-generate-001"} =
               Config.validate_model("veo-3.0-generate-001")
    end
  end

  describe "voice output dir" do
    test "uses VOICE_OUTPUT_DIR when set" do
      System.put_env("VOICE_OUTPUT_DIR", "/tmp/voice-out-test")

      assert Config.voice_output_dir() == "/tmp/voice-out-test"
    end

    test "defaults to ./voice-output" do
      assert String.ends_with?(Config.voice_output_dir(), "voice-output")
    end
  end
end
