defmodule CapcutMcp.Tools.AddText do
  @moduledoc """
  MCP tool: add a text overlay to a CapCut project timeline.

  Styling args write the same JSON content shape real CapCut drafts carry
  (ground truth from `video-obra-legendado`'s subtitle materials): the
  material's `content` is a JSON string `{"styles":[{...}],"text":"..."}` whose
  `styles[0].size` is the font size as a percentage of canvas height (8.0 =
  8%), and whose `fill.content.solid.color` holds 0..1 RGB floats. The
  material-level `text_size` stays at CapCut's constant 30 — it is a legacy
  scale, not the render size.
  """
  @behaviour CapcutMcp.Tool

  alias CapcutMcp.Brand.Store
  alias CapcutMcp.CapCut.ProjectStore
  alias CapcutMcp.Tools.{TimelineHelper, ToolArgs}

  @default_font_size 8.0

  @impl true
  def definition do
    %{
      "name" => "add_text",
      "description" => "Adds a text overlay element to a CapCut project timeline.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "project_id" => %{"type" => "string", "description" => "The draft_id of the project"},
          "content" => %{"type" => "string", "description" => "The text to display"},
          "start_ms" => %{"type" => "integer", "description" => "Start time in milliseconds"},
          "duration_ms" => %{"type" => "integer", "description" => "Duration in milliseconds"},
          "font_size" => %{
            "type" => "number",
            "description" =>
              "Font size as a percentage of canvas height (CapCut's own scale; real drafts use ~8.0; default 8)"
          },
          "color" => %{
            "type" => "string",
            "description" => "Fill color as #RRGGBB (default #FFFFFF)"
          },
          "stroke_color" => %{
            "type" => "string",
            "description" => "Outline color as #RRGGBB; when set, adds a stroke to the text"
          },
          "stroke_width" => %{
            "type" => "number",
            "description" => "Stroke width (default 0.08, CapCut's scale)"
          },
          "position_y" => %{
            "type" => "number",
            "description" =>
              "Vertical position in half-canvas units (CapCut convention): 0.0 centered, -1.0 top edge, 1.0 bottom edge; default 0"
          },
          "use_brand" => %{
            "type" => "boolean",
            "description" =>
              "Pull defaults from the brand memory (color from paleta.texto/primaria, font_size " <>
                "from tipografia.padrao); explicit color/font_size always win. Off-palette " <>
                "colors are recorded as pending — promote_style makes them global (default: false)"
          },
          "track_index" => %{
            "type" => "integer",
            "description" => "Track index (default: auto-select text track)"
          }
        },
        "required" => ["project_id", "content", "start_ms", "duration_ms"]
      }
    }
  end

  @impl true
  def execute(
        %{
          "project_id" => id,
          "content" => content,
          "start_ms" => start_ms,
          "duration_ms" => duration_ms
        } = args
      ) do
    track_index = Map.get(args, "track_index")
    use_brand? = Map.get(args, "use_brand", false) == true
    brand_defaults = if use_brand?, do: Store.defaults(id), else: %{}

    with {:ok, draft} <- ProjectStore.get_project(id),
         {:ok, {updated_draft, segment_id, track_idx, brand_applied}} <-
           apply_text_to_draft(
             draft,
             content,
             start_ms,
             duration_ms,
             args,
             track_index,
             brand_defaults
           ),
         :ok <- ProjectStore.update_project(id, updated_draft) do
      notice = brand_notice(brand_applied)
      palette = palette_notice(id, brand_applied.color)

      {:ok,
       "Text added.\nSegment ID: #{segment_id}\nTrack index: #{track_idx}\nContent: \"#{content}\"\nTime: #{start_ms}ms → #{start_ms + duration_ms}ms" <>
         notice <> palette}
    end
    |> ToolArgs.format_tool_result(id)
  end

  def execute(args),
    do:
      {:error,
       ToolArgs.missing_required_message(args, [
         "project_id",
         "content",
         "start_ms",
         "duration_ms"
       ])}

  defp apply_text_to_draft(
         draft,
         content,
         start_ms,
         duration_ms,
         args,
         track_index,
         brand_defaults
       ) do
    text_id = TimelineHelper.generate_uuid()
    segment_id = TimelineHelper.generate_uuid()
    tracks = draft["tracks"] || []

    with {:ok, validated_content} <- validate_content(content),
         {:ok, {validated_start_ms, validated_duration_ms}} <-
           TimelineHelper.validate_timing(start_ms, duration_ms),
         {:ok, validated_track_index} <- TimelineHelper.validate_track_index(tracks, track_index),
         {:ok, font_size, brand_font?} <-
           validate_font_size(Map.get(args, "font_size"), brand_defaults[:font_size]),
         {:ok, color, brand_color?} <-
           validate_color(Map.get(args, "color"), "color", brand_defaults[:color]),
         {:ok, stroke} <-
           validate_stroke(Map.get(args, "stroke_color"), Map.get(args, "stroke_width")),
         {:ok, position_y} <- validate_position_y(Map.get(args, "position_y")) do
      text_material = build_text_material(text_id, validated_content, font_size, color, stroke)

      segment =
        build_segment(segment_id, text_id, validated_start_ms, validated_duration_ms, position_y)

      {updated_tracks, track_idx} =
        TimelineHelper.insert_segment(tracks, segment, "text", validated_track_index)

      updated_draft =
        draft
        |> Map.put("tracks", updated_tracks)
        |> TimelineHelper.add_material("texts", text_material)

      brand_applied = %{
        color: color.hex,
        font_size: font_size,
        color_from_brand?: brand_color?,
        font_from_brand?: brand_font?
      }

      {:ok, {updated_draft, segment_id, track_idx, brand_applied}}
    end
  end

  # Brand-applied values are only mentioned when they actually came from the
  # brand memory, so responses stay honest about what was auto-styled.
  defp brand_notice(brand_applied) do
    from_brand =
      Enum.filter(
        [
          {"color", brand_applied.color, brand_applied.color_from_brand?},
          {"font_size", brand_applied.font_size, brand_applied.font_from_brand?}
        ],
        fn {_k, _v, from_brand?} -> from_brand? end
      )

    case from_brand do
      [] ->
        ""

      pairs ->
        "Estilo da marca aplicado: " <>
          Enum.map_join(pairs, ", ", fn {k, v, _} -> "#{k}=#{v}" end)
    end
  end

  # Off-palette colors are recorded in the project's pending queue — they
  # never reach the global brand without an explicit promote_style.
  defp palette_notice(id, hex) do
    if Store.off_palette?(hex, id) do
      Store.add_pending(id, "paleta", hex)
      "\nFora da paleta: #{hex} (registrado como pendente; promote_style torna global)"
    else
      ""
    end
  end

  # Ground truth shape (real draft `video-obra-legendado`): content is a JSON
  # string with a `styles` array (one entry per styled range, `range` in
  # codepoint offsets) plus the plain `text`.
  defp build_text_material(id, content, font_size, color, stroke) do
    style =
      %{
        "bold" => false,
        "fill" => %{
          "alpha" => 1.0,
          "content" => %{
            "render_type" => "solid",
            "solid" => %{"alpha" => 1.0, "color" => color.rgb}
          }
        },
        "italic" => false,
        "range" => [0, String.length(content)],
        "size" => font_size
      }
      |> maybe_put_stroke(stroke)

    %{
      "id" => id,
      "type" => "text",
      "content" => Jason.encode!(%{"styles" => [style], "text" => content}),
      "text_size" => 30,
      "font_size" => font_size,
      "font_color" => "rgba(#{Enum.map_join(color.rgb, ",", &format_channel/1)},1)",
      "text_color" => color.hex,
      "bold" => false,
      "italic" => false,
      "underline" => false,
      "alignment" => "center",
      "text_to_audio_ids" => [],
      "words" => %{"words" => []}
    }
  end

  defp maybe_put_stroke(style, nil), do: style

  defp maybe_put_stroke(style, %{color: stroke_rgb, width: width}) do
    Map.put(style, "strokes", [
      %{"content" => %{"solid" => %{"alpha" => 1.0, "color" => stroke_rgb}}, "width" => width}
    ])
  end

  defp build_segment(id, material_id, start_ms, duration_ms, position_y) do
    start_us = start_ms * 1000
    duration_us = duration_ms * 1000

    %{
      "id" => id,
      "material_id" => material_id,
      "target_timerange" => %{"start" => start_us, "duration" => duration_us},
      "source_timerange" => %{"start" => 0, "duration" => duration_us},
      "extra_material_refs" => [],
      "render_index" => 0,
      # Text segments are a "visual segment" in CapCut's schema (same family
      # as video/sticker), and always carry a `clip` object — confirmed
      # against pyCapCut's `TextSegment(VisualSegment)` inheritance. Without
      # this, `set_clip_transform` and `set_clip_keyframe`'s
      # position/scale/rotation properties silently reject every text
      # segment with "no clip object" — a real gap this tool had before
      # `set_clip_keyframe` existed to surface it via a live ground-truth
      # test.
      "clip" => %{
        "alpha" => 1.0,
        "flip" => %{"horizontal" => false, "vertical" => false},
        "rotation" => 0.0,
        "scale" => %{"x" => 1.0, "y" => 1.0},
        "transform" => %{"x" => 0.0, "y" => position_y}
      },
      "uniform_scale" => %{"on" => true, "value" => 1.0},
      "common_keyframes" => []
    }
  end

  defp validate_content(content) when is_binary(content) do
    if String.trim(content) != "" do
      {:ok, content}
    else
      {:error, "Invalid content: #{inspect(content)}"}
    end
  end

  defp validate_content(content), do: {:error, "Invalid content: #{inspect(content)}"}

  defp validate_font_size(nil, brand_default) when is_number(brand_default),
    do: {:ok, brand_default / 1, true}

  defp validate_font_size(nil, _), do: {:ok, @default_font_size, false}

  defp validate_font_size(n, _) when is_number(n) and n >= 0.5 and n <= 100,
    do: {:ok, n / 1, false}

  defp validate_font_size(other, _),
    do: {:error, "Invalid font_size: #{inspect(other)} (must be a number between 0.5 and 100)"}

  defp validate_color(nil, _kind, brand_default) when is_binary(brand_default) do
    case parse_hex_color(brand_default) do
      {r, g, b} -> {:ok, %{rgb: [r, g, b], hex: String.upcase(brand_default)}, true}
      nil -> {:ok, %{rgb: [1.0, 1.0, 1.0], hex: "#FFFFFF"}, false}
    end
  end

  defp validate_color(nil, _kind, _), do: {:ok, %{rgb: [1.0, 1.0, 1.0], hex: "#FFFFFF"}, false}

  defp validate_color(hex, kind, _) when is_binary(hex) do
    case parse_hex_color(hex) do
      {r, g, b} -> {:ok, %{rgb: [r, g, b], hex: String.upcase(hex)}, false}
      nil -> {:error, "Invalid #{kind}: #{inspect(hex)} (expected #RRGGBB)"}
    end
  end

  defp validate_color(other, kind, _),
    do: {:error, "Invalid #{kind}: #{inspect(other, limit: 20)}"}

  defp validate_stroke(nil, nil), do: {:ok, nil}

  defp validate_stroke(nil, width) do
    case validate_stroke_width(width) do
      {:ok, _} -> {:error, "stroke_color is required when stroke_width is set"}
      {:error, msg} -> {:error, msg}
    end
  end

  defp validate_stroke(hex, width) do
    with {:ok, stroke_rgb, _brand?} <- validate_color(hex, "stroke_color", nil),
         {:ok, stroke_width} <- validate_stroke_width(width) do
      {:ok, %{color: stroke_rgb.rgb, width: stroke_width}}
    end
  end

  # Real CapCut strokes carry 0..1 widths (a subtitle outline was 0.08).
  defp validate_stroke_width(nil), do: {:ok, 0.08}

  defp validate_stroke_width(w) when is_number(w) and w >= 0 and w <= 1, do: {:ok, w / 1}

  defp validate_stroke_width(other),
    do: {:error, "Invalid stroke_width: #{inspect(other)} (must be a number between 0 and 1)"}

  defp validate_position_y(nil), do: {:ok, 0.0}
  defp validate_position_y(y) when is_number(y) and y >= -1.0 and y <= 1.0, do: {:ok, y / 1}

  defp validate_position_y(other),
    do: {:error, "Invalid position_y: #{inspect(other)} (must be a number between -1.0 and 1.0)"}

  defp parse_hex_color("#" <> rest) when byte_size(rest) == 6 do
    with {:ok, r} <- hex_channel(binary_part(rest, 0, 2)),
         {:ok, g} <- hex_channel(binary_part(rest, 2, 2)),
         {:ok, b} <- hex_channel(binary_part(rest, 4, 2)) do
      {r, g, b}
    else
      _ -> nil
    end
  end

  defp parse_hex_color(_), do: nil

  # Real CapCut font_color strings use integer channels when whole
  # ("rgba(1,1,1,1)") — keep that convention for the common pure colors.
  defp format_channel(c) when is_float(c) and c == trunc(c), do: Integer.to_string(trunc(c))
  defp format_channel(c), do: Float.to_string(c)

  defp hex_channel(channel) do
    case Integer.parse(channel, 16) do
      {value, ""} when value in 0..255 -> {:ok, value / 255}
      _ -> :error
    end
  end
end
