defmodule CapcutMcp.Tools.SetBrand do
  @moduledoc "MCP tool: write the global brand identity memory (the only explicit entry)."
  @behaviour CapcutMcp.Tool

  alias CapcutMcp.Brand.Store

  @impl true
  def definition do
    %{
      "name" => "set_brand",
      "description" =>
        "Writes the global brand identity (palette, typography, company info, signature " <>
          "style). This is the EXPLICIT entry into the brand memory — project edits never " <>
          "write here automatically. `mode: merge` deep-merges into the existing brand; " <>
          "`mode: replace` discards it first.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "brand" => %{
            "type" => "object",
            "description" =>
              ~s(Brand object, e.g. {"empresa":{"nome":"X"},"paleta":{"primaria":"#FFB13D","texto":"#FFFFFF"},"tipografia":{"display":"Poppins","titulo":16}})
          },
          "mode" => %{
            "type" => "string",
            "enum" => ["merge", "replace"],
            "description" => "How to combine with the existing brand (default: merge)"
          }
        },
        "required" => ["brand"]
      }
    }
  end

  @impl true
  def execute(%{"brand" => brand} = args) when is_map(brand) do
    mode =
      case Map.get(args, "mode", "merge") do
        "replace" -> :replace
        _ -> :merge
      end

    case Store.write_global(brand, mode) do
      :ok ->
        {:ok, "Marca global atualizada (#{mode}).\n#{Store.global_path()}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def execute(args) when not is_map_key(args, "brand"),
    do: {:error, "Missing required arguments: brand"}

  def execute(_), do: {:error, "Invalid arguments: brand must be an object"}
end
