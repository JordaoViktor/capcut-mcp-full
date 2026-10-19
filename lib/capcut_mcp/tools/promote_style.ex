defmodule CapcutMcp.Tools.PromoteStyle do
  @moduledoc "MCP tool: explicitly promote project styles into the global brand."
  @behaviour CapcutMcp.Tool

  alias CapcutMcp.Brand.Store
  alias CapcutMcp.Tools.ToolArgs

  @impl true
  def definition do
    %{
      "name" => "promote_style",
      "description" =>
        "Promotes a project style into the global brand — the explicit opt-in. " <>
          "Without `campo`/`valor`: promotes every pending entry of the project " <>
          "(colors get roles like paleta.acento, paleta.acento_2...). With `campo`/`valor`: " <>
          "sets that exact path in the global brand (e.g. campo \"paleta.acento\", " <>
          "valor \"#1E88E5\").",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "project_id" => %{"type" => "string", "description" => "The draft_id of the project"},
          "campo" => %{
            "type" => "string",
            "description" =>
              "Dotted path in the brand, e.g. \"paleta.acento\" or \"tipografia.titulo\""
          },
          "valor" => %{
            "description" =>
              "Value for `campo` (colors as #RRGGBB; numbers or strings for other keys)"
          }
        },
        "required" => ["project_id"]
      }
    }
  end

  @impl true
  def execute(%{"project_id" => id} = args) when is_binary(id) do
    case Map.get(args, "campo") do
      nil -> promote_all(id)
      campo -> promote_one(id, campo, Map.get(args, "valor"))
    end
    |> summarize()
  end

  def execute(args),
    do: {:error, ToolArgs.missing_required_message(args, ["project_id"])}

  defp promote_all(id) do
    case Store.promote(id) do
      {:ok, []} -> {:ok, "Nada pendente para promover no projeto."}
      {:ok, promoted} -> {:ok, promoted}
      {:error, reason} -> {:error, reason}
    end
  end

  defp promote_one(id, campo, valor) do
    case Store.promote(id, campo, valor) do
      {:ok, promoted} -> {:ok, promoted}
      {:error, reason} -> {:error, reason}
    end
  end

  defp summarize({:ok, text}) when is_binary(text), do: {:ok, text}

  defp summarize({:ok, promoted}) do
    lines =
      Enum.map(promoted, fn {campo, valor} -> "- #{campo} = #{inspect(valor, limit: 20)}" end)

    {:ok, "Promovido para a marca global:\n#{Enum.join(lines, "\n")}"}
  end

  defp summarize({:error, reason}), do: {:error, reason}
end
