defmodule CapcutMcp.Tools.ListVoices do
  @moduledoc """
  MCP tool: list the voices available on the ElevenLabs account.

  Requires `ELEVENLABS_API_KEY`.
  """

  @behaviour CapcutMcp.Tool

  alias CapcutMcp.Voice.ElevenLabs

  @impl true
  def definition do
    %{
      "name" => "list_voices",
      "description" =>
        "Lists the available ElevenLabs voices (voice_id + name). Requires ELEVENLABS_API_KEY.",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    }
  end

  @impl true
  def execute(_args) do
    case ElevenLabs.list_voices([]) do
      {:ok, voices} ->
        if Enum.empty?(voices) do
          {:ok, "No voices found on this ElevenLabs account."}
        else
          listing = Enum.map_join(voices, "\n", &format_voice/1)
          {:ok, "Found #{length(voices)} voice(s):\n#{listing}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp format_voice(voice) do
    labels =
      voice.labels
      |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{v}" end)

    detail =
      [voice.category, if(labels == "", do: nil, else: labels)]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" | ")

    detail =
      if detail == "", do: voice.voice_id, else: "#{detail} | id=#{voice.voice_id}"

    "- #{voice.name} (#{detail})"
  end
end
