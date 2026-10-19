defmodule CapcutMcp.Brand.Store do
  @moduledoc """
  Brand identity memory: global defaults plus per-project pending styles.

  Files live OUTSIDE the CapCut drafts so CapCut itself can never rewrite them:

    * global:  `<config_dir>/brand.json`
    * project: `<config_dir>/projects/<sanitized draft_id>/style.json`

  `<config_dir>` is `System.get_env("CAPCUT_MCP_CONFIG_DIR")` when set (tests
  use this for isolation), otherwise `~/.config/capcut-mcp`.

  ## Design contract

    * The global brand is only ever written through `write_global/2` or
      `promote/1`/`promote/3` — an explicit opt-in. Nothing here promotes
      project styles into the global brand automatically.
    * `add_text` (and friends) consult `merged/1` only when the caller passes
      `use_brand: true`; explicit tool arguments always win over brand values.
    * Colors used in a project that are NOT in the brand palette are recorded
      as `pendentes` — a review queue the brand owner promotes (or drops).

  ## Shape

  Both files are free-form JSON objects; the palette subtree is special:

      {
        "empresa": {"nome": "...", "tagline": "..."},
        "paleta": {"primaria": "#FFB13D", "texto": "#FFFFFF"},
        "tipografia": {"display": "Poppins", "titulo": 16},
        "assinatura": {"posicao_y": 0.78}
      }

  Any value under `paleta` that is a string starting with `#` must be a valid
  `#RRGGBB` color; numbers (e.g. `dim_brightness`) and other keys pass through
  untouched so the brand file can grow with the team's needs.
  """

  @hex_regex ~r/^#[0-9A-Fa-f]{6}$/

  # ── Paths ────────────────────────────────────────────────────────────────────

  @spec config_dir() :: String.t()
  def config_dir do
    case System.get_env("CAPCUT_MCP_CONFIG_DIR") do
      dir when is_binary(dir) and dir != "" -> dir
      _ -> Path.expand("~/.config/capcut-mcp")
    end
  end

  @spec global_path() :: String.t()
  def global_path, do: Path.join(config_dir(), "brand.json")

  @spec project_path(String.t()) :: String.t()
  def project_path(draft_id) do
    Path.join([config_dir(), "projects", sanitize_id(draft_id), "style.json"])
  end

  # Draft ids are uuid-like; keep only safe path characters.
  defp sanitize_id(id) when is_binary(id) do
    safe = String.replace(id, ~r/[^A-Za-z0-9_-]/, "_")
    if safe == "", do: "unnamed", else: safe
  end

  defp sanitize_id(_other), do: "unnamed"

  # ── Global brand ─────────────────────────────────────────────────────────────

  @doc "Reads the global brand; missing or corrupt file yields an empty map."
  @spec read_global() :: map()
  def read_global do
    case safe_read_json(global_path()) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  @doc """
  Writes the global brand. `mode` is `:merge` (default, deep-merges into the
  existing brand) or `:replace`. Validates palette colors before writing.
  """
  @spec write_global(map(), :merge | :replace) :: :ok | {:error, String.t()}
  def write_global(brand, mode \\ :merge) when is_map(brand) do
    with :ok <- validate_brand(brand) do
      current = if mode == :replace, do: %{}, else: read_global()
      write_json(global_path(), deep_merge(current, brand))
    end
  end

  # ── Project styles ───────────────────────────────────────────────────────────

  @doc ~s(Reads a project's style file: %{"overrides" => map, "pendentes" => list}.)
  @spec read_project(String.t()) :: %{optional(String.t()) => term()}
  def read_project(draft_id) do
    case safe_read_json(project_path(draft_id)) do
      {:ok, map} when is_map(map) -> normalize_project(map)
      _ -> %{"overrides" => %{}, "pendentes" => []}
    end
  end

  @doc """
  Records a color/style used in a project that is not part of the brand
  palette. Deduplicates on (campo, valor). Never writes the global brand.
  """
  @spec add_pending(String.t(), String.t(), term()) :: :ok
  def add_pending(draft_id, campo, valor) do
    project = read_project(draft_id)
    entry = %{"campo" => campo, "valor" => valor}

    already? =
      Enum.any?(project["pendentes"], fn p ->
        Map.get(p, "campo") == campo and Map.get(p, "valor") == valor
      end)

    if already? do
      :ok
    else
      project
      |> Map.update!("pendentes", &(&1 ++ [entry]))
      |> then(&write_json(project_path(draft_id), &1))
    end
  end

  @doc "Drops every pending entry for a project (review decided against promotion)."
  @spec clear_pending(String.t()) :: :ok
  def clear_pending(draft_id) do
    read_project(draft_id)
    |> Map.put("pendentes", [])
    |> then(&write_json(project_path(draft_id), &1))
  end

  @doc "Writes a project-local override (never touches the global brand)."
  @spec set_override(String.t(), String.t(), term()) :: :ok | {:error, String.t()}
  def set_override(draft_id, campo, valor) do
    with :ok <- validate_path_value(campo, valor) do
      project = read_project(draft_id)

      project
      |> Map.update!("overrides", &put_path(&1, split_path(campo), valor))
      |> then(&write_json(project_path(draft_id), &1))
    end
  end

  @doc """
  Global brand deep-merged with the project's overrides (project wins).
  This is the view `add_text` consults when `use_brand: true`.
  """
  @spec merged(String.t()) :: map()
  def merged(draft_id) do
    deep_merge(read_global(), read_project(draft_id)["overrides"])
  end

  # ── Promotion (the opt-in gate) ──────────────────────────────────────────────

  @doc """
  Promotes project styles into the GLOBAL brand — the explicit opt-in path.

    * `promote(draft_id)` — promotes every pending entry. Entries whose `campo`
      has no dot (e.g. `"paleta"` with a hex value) get an automatic role
      suffix: `paleta.acento`, then `paleta.acento_2`, `paleta.acento_3`...
    * `promote(draft_id, campo, valor)` — sets `campo` directly in the global
      brand (e.g. `"paleta.acento" => "#1E88E5"`), dropping any matching pending.

  Returns `{:ok, [{campo, valor}]}` or `{:error, reason}`.
  """
  @spec promote(String.t()) :: {:ok, list({String.t(), term()})} | {:error, String.t()}
  def promote(draft_id) do
    pendentes = read_project(draft_id)["pendentes"]

    if pendentes == [] do
      {:ok, []}
    else
      global = read_global()

      {promoted, final_global} = Enum.reduce(pendentes, {[], global}, &promote_entry/2)

      case write_global(final_global) do
        :ok ->
          clear_pending(draft_id)
          {:ok, promoted}

        error ->
          error
      end
    end
  end

  @spec promote(String.t(), String.t(), term()) ::
          {:ok, list({String.t(), term()})} | {:error, String.t()}
  def promote(draft_id, campo, valor) when is_binary(campo) and campo != "" do
    with :ok <- validate_path_value(campo, valor),
         global = read_global(),
         :ok <- write_global(put_path(global, split_path(campo), valor)) do
      drop_pending(draft_id, valor)
      {:ok, [{campo, valor}]}
    end
  end

  def promote(_draft_id, campo, _valor),
    do: {
      :error,
      "Invalid campo: #{inspect(campo, limit: 20)} (expected dotted path like \"paleta.acento\")"
    }

  defp drop_pending(draft_id, valor) do
    read_project(draft_id)
    |> Map.update!("pendentes", fn list ->
      Enum.reject(list, &(Map.get(&1, "valor") == valor))
    end)
    |> then(&write_json(project_path(draft_id), &1))

    :ok
  end

  defp promote_entry(entry, {acc, g}) do
    campo = Map.get(entry, "campo", "")
    valor = Map.get(entry, "valor")

    case resolve_auto_campo(g, campo, valor) do
      {:ok, campo_path} ->
        {acc ++ [{campo_path, valor}], put_path(g, split_path(campo_path), valor)}

      :error ->
        # Invalid entries are dropped, not promoted.
        {acc, g}
    end
  end

  defp resolve_auto_campo(global, campo, valor) do
    cond do
      is_binary(campo) and String.contains?(campo, ".") ->
        {:ok, campo}

      color?(valor) ->
        # Dot-less pendentes (add_text records generic "paleta") get an
        # automatic accent role: paleta.acento, paleta.acento_2, ...
        {:ok, free_role(global, "paleta.acento")}

      true ->
        :error
    end
  end

  defp free_role(global, base) do
    Enum.reduce_while(1..101, base, fn k, _candidate ->
      candidate = if k == 1, do: base, else: "#{base}_#{k}"

      if get_in(global, split_path(candidate)) == nil,
        do: {:halt, candidate},
        else: {:cont, candidate}
    end)
  end

  @doc """
  Style defaults the brand supplies when `use_brand` is on: text color from
  `paleta.texto` (falling back to `paleta.primaria`) and font size from
  `tipografia.padrao`. Invalid values fall back to the plain defaults.
  """
  @spec defaults(String.t()) :: %{color: String.t(), font_size: float()}
  def defaults(draft_id) do
    brand = merged(draft_id)

    color =
      [get_in(brand, ["paleta", "texto"]), get_in(brand, ["paleta", "primaria"])]
      |> Enum.find("#FFFFFF", &color?/1)
      |> String.upcase()

    font_size =
      case get_in(brand, ["tipografia", "padrao"]) do
        n when is_number(n) and n >= 0.5 and n <= 100 -> n / 1
        _ -> 8.0
      end

    %{color: color, font_size: font_size}
  end

  # ── Palette checks ───────────────────────────────────────────────────────────

  @doc "True when `hex` is not a color of the brand palette (global + project overrides)."
  @spec off_palette?(String.t(), String.t()) :: boolean()
  def off_palette?(hex, draft_id) when is_binary(hex) do
    global_colors =
      read_global()
      |> Map.get("paleta", %{})
      |> palette_colors()

    project_colors =
      read_project(draft_id)
      |> Map.get("overrides", %{})
      |> Map.get("paleta", %{})
      |> palette_colors()

    normalized = String.upcase(hex)

    not Enum.member?(global_colors ++ project_colors, normalized)
  end

  def off_palette?(_other, _draft_id), do: false

  defp palette_colors(paleta) when is_map(paleta) do
    paleta
    |> Map.values()
    |> Enum.filter(&color?/1)
    |> Enum.map(&String.upcase/1)
  end

  defp palette_colors(_), do: []

  defp color?(v) when is_binary(v), do: Regex.match?(@hex_regex, v)
  defp color?(_), do: false

  # ── Validation ───────────────────────────────────────────────────────────────

  defp validate_brand(brand) do
    case brand do
      %{"paleta" => paleta} when is_map(paleta) ->
        validate_paleta(paleta)

      %{"paleta" => other} ->
        {:error, "Invalid paleta: expected object, got #{inspect(other, limit: 20)}"}

      _ ->
        :ok
    end
  end

  defp validate_paleta(paleta) do
    Enum.reduce_while(paleta, :ok, fn {k, v}, acc ->
      cond do
        color?(v) ->
          {:cont, acc}

        is_number(v) ->
          {:cont, acc}

        true ->
          {:halt,
           {:error,
            "Invalid paleta.#{k}: #{inspect(v, limit: 20)} (expected #RRGGBB color or number)"}}
      end
    end)
  end

  defp validate_path_value(campo, valor) do
    cond do
      not is_binary(campo) or String.trim(campo) == "" ->
        {:error, "Invalid campo: #{inspect(campo)} (expected dotted path like \"paleta.acento\")"}

      color?(valor) ->
        :ok

      true ->
        :ok
    end
  end

  # ── JSON + merge helpers ─────────────────────────────────────────────────────

  defp safe_read_json(path) do
    case File.read(path) do
      {:ok, body} -> Jason.decode(body)
      {:error, _} -> :error
    end
  end

  defp write_json(path, map) do
    dir = Path.dirname(path)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, Jason.encode!(map, pretty: true) <> "\n") do
      :ok
    else
      {:error, reason} -> {:error, "Failed to write #{path}: #{inspect(reason)}"}
    end
  end

  defp normalize_project(map) do
    %{
      "overrides" => map |> Map.get("overrides", %{}) |> normalize_map(),
      "pendentes" => Map.get(map, "pendentes", [])
    }
  end

  defp normalize_map(m) when is_map(m), do: m
  defp normalize_map(_), do: %{}

  @doc false
  def deep_merge(a, b) when is_map(a) and is_map(b) do
    Map.merge(a, b, fn
      _k, va, vb when is_map(va) and is_map(vb) -> deep_merge(va, vb)
      _k, _va, vb -> vb
    end)
  end

  def deep_merge(_a, b) when is_map(b), do: b
  def deep_merge(a, _), do: a

  defp put_path(map, [key], value) when is_map(map), do: Map.put(map, key, value)

  # Map.update/3 never calls its fun for MISSING keys, so build the path
  # explicitly with Map.get + Map.put.
  defp put_path(map, [key | rest], value) when is_map(map) do
    inner = Map.get(map, key, %{})
    inner = if is_map(inner), do: inner, else: %{}
    Map.put(map, key, put_path(inner, rest, value))
  end

  defp put_path(_map, _path, _value), do: nil

  defp split_path(campo), do: String.split(campo, ".", trim: true)
end
