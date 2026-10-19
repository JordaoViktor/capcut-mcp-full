defmodule CapcutMcp.Tools.GetBrand do
  @moduledoc "MCP tool: read the brand identity memory (global + project pendentes)."
  @behaviour CapcutMcp.Tool

  alias CapcutMcp.Brand.Store

  @impl true
  def definition do
    %{
      "name" => "get_brand",
      "description" =>
        "Returns the brand identity memory: the global brand profile (palette, typography, " <>
          "company info, signature style) plus any project-local pending styles awaiting " <>
          "promotion. Call before styling edits to keep the visual identity consistent.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "project_id" => %{
            "type" => "string",
            "description" =>
              "Optional draft_id: also lists that project's pending/off-palette styles"
          }
        }
      }
    }
  end

  @impl true
  def execute(args) do
    global = Store.read_global()
    lines = ["MARCA GLOBAL", pretty(global)]

    case args do
      %{"project_id" => id} when is_binary(id) and id != "" ->
        project = Store.read_project(id)
        lines = lines ++ project_section(project)
        {:ok, Enum.join(lines, "\n")}

      _ ->
        {:ok, Enum.join(lines, "\n")}
    end
  end

  defp pretty(map) when map == %{}, do: "(vazia — use set_brand para definir a identidade)"

  defp pretty(map) when is_map(map) do
    Jason.encode!(map, pretty: true)
  end

  defp project_section(%{"pendentes" => pendentes, "overrides" => overrides}) do
    pendentes_lines =
      case pendentes do
        [] ->
          ["PENDENTES DO PROJETO (0)"]

        list ->
          ["PENDENTES DO PROJETO (#{length(list)})"] ++ Enum.map(list, &format_pending/1)
      end

    overrides_lines =
      case overrides do
        m when m == %{} -> ["OVERRIDES DO PROJETO (0)"]
        m -> ["OVERRIDES DO PROJETO", Jason.encode!(m, pretty: true)]
      end

    pendentes_lines ++ overrides_lines
  end

  defp format_pending(%{"campo" => campo, "valor" => valor}),
    do: "- #{campo} = #{valor} (promote_style torna global)"

  defp format_pending(other), do: "- #{inspect(other, limit: 10)}"
end
