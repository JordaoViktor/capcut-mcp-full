defmodule CapcutMcp.Tools.SearchEpidemicSound do
  @moduledoc "Search the Epidemic Sound music and sound effects catalogs."
  @behaviour CapcutMcp.Tool
  alias CapcutMcp.EpidemicSound.Client
  alias CapcutMcp.Tools.ToolArgs

  @impl true
  def definition do
    %{
      "name" => "search_epidemic_sound",
      "description" =>
        "Searches Epidemic Sound music or sound effects. Returns track ids, metadata " <>
          "and pagination. Use a returned id with download_epidemic_sound. Requires EPIDEMIC_SOUND_API_KEY (Partner API).",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "query" => %{
            "type" => "string",
            "description" => "Keywords, mood or scene, e.g. upbeat corporate, cinematic impact"
          },
          "kind" => %{
            "type" => "string",
            "enum" => ["music", "sound_effect"],
            "default" => "music"
          },
          "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 60, "default" => 10},
          "offset" => %{"type" => "integer", "minimum" => 0, "default" => 0},
          "vocal_type" => %{
            "type" => "string",
            "enum" => ["LEAD", "PRESENCE", "NONE"],
            "description" =>
              "Music only. NONE selects instrumental music for use under narration."
          }
        },
        "required" => ["query"]
      }
    }
  end

  @impl true
  def execute(%{"query" => _} = args) do
    with {:ok, result} <- Client.search(args), do: {:ok, Jason.encode!(result)}
  end

  def execute(args), do: {:error, ToolArgs.missing_required_message(args, ["query"])}
end
