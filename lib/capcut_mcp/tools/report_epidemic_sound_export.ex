defmodule CapcutMcp.Tools.ReportEpidemicSoundExport do
  @moduledoc "Report a completed video export containing Epidemic Sound music."
  @behaviour CapcutMcp.Tool
  alias CapcutMcp.EpidemicSound.Client
  alias CapcutMcp.Tools.ToolArgs

  @impl true
  def definition do
    %{
      "name" => "report_epidemic_sound_export",
      "description" =>
        "Reports a completed export containing Epidemic Sound music to the provider. " <>
          "Call once after successfully exporting the finished video, including from CapCut or render_project. " <>
          "Use music track ids only; do not report downloads, previews or sound effects. Does not grant a license or publish the video.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "track_ids" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "minItems" => 1,
            "maxItems" => 50
          },
          "platform" => %{
            "type" => "string",
            "default" => "LOCAL",
            "enum" => ~w(YOUTUBE TWITTER TWITCH FACEBOOK INSTAGRAM TIKTOK OTHER LOCAL)
          }
        },
        "required" => ["track_ids"]
      }
    }
  end

  @impl true
  def execute(%{"track_ids" => _} = args) do
    with {:ok, _} <- Client.report_export(args), do: {:ok, "Epidemic Sound export reported."}
  end

  def execute(args), do: {:error, ToolArgs.missing_required_message(args, ["track_ids"])}
end
