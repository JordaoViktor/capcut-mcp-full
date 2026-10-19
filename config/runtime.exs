import Config

# Only override the application env when the operator explicitly set
# CAPCUT_PATH. Without it, `CapcutMcp.CapCut.PathDiscovery.discover/0` falls
# back to `%LOCALAPPDATA%\CapCut\User Data\Projects\com.lveditor.draft`, which
# is the default install location on Windows.
if capcut_path = System.get_env("CAPCUT_PATH") do
  config :capcut_mcp, capcut_path: capcut_path
end

# Voice providers (ElevenLabs TTS + Gemini transcription/command interpretation).
# Each variable is optional: the voice tools report which one is missing when
# called, so the rest of the server works without any keys configured.
# Overridable equivalents live in `CapcutMcp.Voice.Config` (app env first,
# then environment), so tests and releases can pin values explicitly.
voice_env_keys = [
  {"ELEVENLABS_API_KEY", :elevenlabs_api_key},
  {"ELEVENLABS_VOICE_ID", :elevenlabs_voice_id},
  {"GEMINI_API_KEY", :gemini_api_key},
  {"GOOGLE_API_KEY", :gemini_api_key}
]

Enum.each(voice_env_keys, fn {var, key} ->
  value = System.get_env(var)

  if is_binary(value) and value != "" do
    config :capcut_mcp, key, value
  end
end)
