defmodule CapcutMcp.BrandTest do
  use ExUnit.Case, async: false

  alias CapcutMcp.Brand.Store
  alias CapcutMcp.CapCut.ProjectStore
  alias CapcutMcp.Tools.{AddClip, AddText, GetBrand, PromoteStyle, SetBrand}

  # Brand files are process-global config (System env + files on disk), so
  # this suite runs with async: false and per-test config dirs.
  setup do
    config_dir =
      Path.join(System.tmp_dir!(), "capcut-brand-#{System.unique_integer([:positive])}")

    File.mkdir_p!(config_dir)
    previous = System.get_env("CAPCUT_MCP_CONFIG_DIR")
    System.put_env("CAPCUT_MCP_CONFIG_DIR", config_dir)

    on_exit(fn ->
      File.rm_rf!(config_dir)

      case previous do
        nil -> System.delete_env("CAPCUT_MCP_CONFIG_DIR")
        value -> System.put_env("CAPCUT_MCP_CONFIG_DIR", value)
      end
    end)

    %{config_dir: config_dir}
  end

  # ── Store: global ────────────────────────────────────────────────────────────

  test "read_global returns empty map when brand file is missing" do
    assert %{} = Store.read_global()
  end

  test "write_global with merge preserves existing keys and validates palette colors" do
    assert :ok =
             Store.write_global(%{
               "empresa" => %{"nome" => "Orca"},
               "paleta" => %{"primaria" => "#FFB13D"}
             })

    assert :ok = Store.write_global(%{"paleta" => %{"texto" => "#FFFFFF"}})

    global = Store.read_global()
    assert global["empresa"]["nome"] == "Orca"
    assert global["paleta"]["primaria"] == "#FFB13D"
    assert global["paleta"]["texto"] == "#FFFFFF"
  end

  test "write_global with replace discards previous brand" do
    Store.write_global(%{"paleta" => %{"primaria" => "#FFB13D"}})
    assert :ok = Store.write_global(%{"paleta" => %{"texto" => "#FFFFFF"}}, :replace)

    assert Store.read_global()["paleta"] == %{"texto" => "#FFFFFF"}
  end

  test "write_global rejects invalid palette colors" do
    assert {:error, reason} = Store.write_global(%{"paleta" => %{"primaria" => "orange"}})
    assert reason =~ "paleta.primaria"
    assert %{} = Store.read_global()
  end

  test "write_global accepts numeric palette values (e.g. dim_brightness)" do
    assert :ok = Store.write_global(%{"paleta" => %{"dim_brightness" => -0.45}})
    assert Store.read_global()["paleta"]["dim_brightness"] == -0.45
  end

  # ── Store: project styles ────────────────────────────────────────────────────

  test "read_project returns normalized empty style for unknown projects" do
    assert %{"overrides" => %{}, "pendentes" => []} = Store.read_project("SOME-ID")
  end

  test "add_pending deduplicates identical entries" do
    :ok = Store.add_pending("proj-1", "paleta", "#1E88E5")
    :ok = Store.add_pending("proj-1", "paleta", "#1E88E5")

    assert [%{"campo" => "paleta", "valor" => "#1E88E5"}] =
             Store.read_project("proj-1")["pendentes"]
  end

  test "set_override writes project-local style without touching the global brand" do
    Store.write_global(%{"paleta" => %{"primaria" => "#FFB13D"}})
    :ok = Store.set_override("proj-2", "paleta.texto", "#00FF00")

    assert Store.read_global()["paleta"]["texto"] == nil
    assert Store.merged("proj-2")["paleta"]["texto"] == "#00FF00"
    assert Store.merged("proj-3")["paleta"]["texto"] == nil
  end

  test "merged deep-merges global with project overrides (project wins)" do
    Store.write_global(%{
      "paleta" => %{"primaria" => "#FFB13D", "texto" => "#FFFFFF"},
      "tipografia" => %{"titulo" => 16}
    })

    :ok = Store.set_override("proj-4", "paleta.primaria", "#112233")

    merged = Store.merged("proj-4")
    assert merged["paleta"]["primaria"] == "#112233"
    assert merged["paleta"]["texto"] == "#FFFFFF"
    assert merged["tipografia"]["titulo"] == 16
  end

  # ── Store: promotion (the opt-in gate) ───────────────────────────────────────

  test "promote/1 moves pending entries into the global brand with auto roles" do
    :ok = Store.add_pending("proj-5", "paleta", "#1E88E5")
    :ok = Store.add_pending("proj-5", "paleta", "#112244")

    assert {:ok, promoted} = Store.promote("proj-5")
    assert {"paleta.acento", "#1E88E5"} in promoted
    assert {"paleta.acento_2", "#112244"} in promoted

    assert Store.read_global()["paleta"]["acento"] == "#1E88E5"
    assert Store.read_global()["paleta"]["acento_2"] == "#112244"
    assert [] = Store.read_project("proj-5")["pendentes"]
  end

  test "promote/1 is a no-op on projects without pendentes" do
    assert {:ok, []} = Store.promote("proj-empty")
    assert %{} = Store.read_global()
  end

  test "promote/3 sets an explicit path and drops the matching pending" do
    :ok = Store.add_pending("proj-6", "paleta", "#1E88E5")

    assert {:ok, [{"paleta.acento", "#1E88E5"}]} =
             Store.promote("proj-6", "paleta.acento", "#1E88E5")

    assert Store.read_global()["paleta"]["acento"] == "#1E88E5"
    assert [] = Store.read_project("proj-6")["pendentes"]
  end

  test "promote/3 rejects invalid campos" do
    assert {:error, _} = Store.promote("proj-7", "", "#1E88E5")
    assert {:error, _} = Store.promote("proj-7", 123, "#1E88E5")
  end

  # ── Store: palette checks + defaults ─────────────────────────────────────────

  test "off_palette? is true for colors absent from global and project palettes" do
    Store.write_global(%{"paleta" => %{"primaria" => "#FFB13D"}})
    :ok = Store.set_override("proj-8", "paleta.texto", "#00FF00")

    assert Store.off_palette?("#1E88E5", "proj-8")
    refute Store.off_palette?("#FFB13D", "proj-8")
    refute Store.off_palette?("#00ff00", "proj-8")
    refute Store.off_palette?("#FFB13D", "proj-9")
  end

  test "defaults pull from paleta.texto, then paleta.primaria, then plain defaults" do
    assert %{color: "#FFFFFF", font_size: 8.0} = Store.defaults("no-brand")

    Store.write_global(%{
      "paleta" => %{"primaria" => "#FFB13D", "texto" => "#FFFFFF"},
      "tipografia" => %{"padrao" => 12.5}
    })

    assert %{color: "#FFFFFF", font_size: 12.5} = Store.defaults("with-brand")

    Store.write_global(%{"paleta" => %{"primaria" => "#FFB13D"}}, :replace)
    assert %{color: "#FFB13D", font_size: 8.0} = Store.defaults("primaria-only")
  end

  test "defaults fall back when brand values are malformed" do
    Store.write_global(%{
      "paleta" => %{"texto" => "#ZZZZZZ"},
      "tipografia" => %{"padrao" => 999}
    })

    assert %{color: "#FFFFFF", font_size: 8.0} = Store.defaults("broken")
  end

  # ── Tools ────────────────────────────────────────────────────────────────────

  test "GetBrand.definition has the right name" do
    assert %{"name" => "get_brand"} = GetBrand.definition()
  end

  test "GetBrand.execute returns global brand and project sections" do
    Store.write_global(%{"paleta" => %{"primaria" => "#FFB13D"}})
    Store.add_pending("proj-10", "paleta", "#1E88E5")

    assert {:ok, text} = GetBrand.execute(%{"project_id" => "proj-10"})
    assert text =~ "MARCA GLOBAL"
    assert text =~ "#FFB13D"
    assert text =~ "PENDENTES DO PROJETO (1)"
    assert text =~ "#1E88E5"
    assert text =~ "promote_style"
  end

  test "GetBrand.execute without project_id omits project sections" do
    assert {:ok, text} = GetBrand.execute(%{})
    assert text =~ "MARCA GLOBAL"
    refute text =~ "PENDENTES"
  end

  test "GetBrand.execute shows empty-brand hint" do
    assert {:ok, text} = GetBrand.execute(%{})
    assert text =~ "use set_brand"
  end

  test "SetBrand requires a brand object" do
    assert {:error, reason} = SetBrand.execute(%{})
    assert reason =~ "brand"
  end

  test "SetBrand executes merge by default" do
    assert {:ok, _} = SetBrand.execute(%{"brand" => %{"paleta" => %{"primaria" => "#FFB13D"}}})
    assert {:ok, _} = SetBrand.execute(%{"brand" => %{"paleta" => %{"texto" => "#FFFFFF"}}})

    assert Store.read_global()["paleta"]["primaria"] == "#FFB13D"
  end

  test "PromoteStyle requires project_id" do
    assert {:error, reason} = PromoteStyle.execute(%{})
    assert reason =~ "project_id"
  end

  test "PromoteStyle promotes all pendentes and reports auto roles" do
    Store.add_pending("proj-11", "paleta", "#1E88E5")

    assert {:ok, text} = PromoteStyle.execute(%{"project_id" => "proj-11"})
    assert text =~ "Promovido para a marca global"
    assert text =~ "paleta.acento"
  end

  test "PromoteStyle sets an explicit campo/valor directly" do
    assert {:ok, text} =
             PromoteStyle.execute(%{
               "project_id" => "proj-12",
               "campo" => "paleta.acento",
               "valor" => "#1E88E5"
             })

    assert text =~ "paleta.acento"
    assert Store.read_global()["paleta"]["acento"] == "#1E88E5"
  end

  # ── add_text integration ─────────────────────────────────────────────────────

  describe "AddText use_brand" do
    setup do
      tmp =
        Path.join(System.tmp_dir!(), "capcut-brand-text-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      project_id = "BRAND-TEXT-001"
      project_path = Path.join(tmp, "brand_text_project")
      File.mkdir_p!(project_path)

      draft = %{
        "id" => project_id,
        "name" => "Brand Text Test",
        "fps" => 30.0,
        "duration" => 10_000_000,
        "new_version" => "163.0.0",
        "canvas_config" => %{"width" => 1920, "height" => 1080, "ratio" => "original"},
        "tracks" => [
          %{"id" => "track-001", "type" => "video", "segments" => []}
        ],
        "materials" => %{"videos" => [], "texts" => [], "audios" => [], "images" => []}
      }

      File.write!(Path.join(project_path, "draft_content.json"), Jason.encode!(draft))

      meta = %{
        "all_draft_store" => [
          %{
            "draft_id" => project_id,
            "draft_name" => "Brand Text Test",
            "draft_fold_path" => project_path,
            "draft_json_file" => Path.join(project_path, "draft_content.json"),
            "tm_draft_modified" => 1_750_000_000_000_000,
            "tm_duration" => 10_000_000
          }
        ],
        "draft_ids" => 1,
        "root_path" => tmp
      }

      File.write!(Path.join(tmp, "root_meta_info.json"), Jason.encode!(meta))
      start_supervised!({ProjectStore, [root_path: tmp]})

      %{project_id: project_id}
    end

    test "use_brand pulls palette color and typography size", %{project_id: id} do
      Store.write_global(%{
        "paleta" => %{"primaria" => "#FFB13D", "texto" => "#FFFFFF"},
        "tipografia" => %{"padrao" => 12}
      })

      assert {:ok, text} =
               AddText.execute(%{
                 "project_id" => id,
                 "content" => "Brand applied",
                 "start_ms" => 0,
                 "duration_ms" => 1000,
                 "use_brand" => true
               })

      assert text =~ "Estilo da marca aplicado: color=#FFFFFF, font_size=12.0"
      refute text =~ "Fora da paleta"
      # The brand color itself is never "off palette".
      assert [] = Store.read_project(id)["pendentes"]
    end

    test "explicit color wins over brand and off-palette colors become pending", %{project_id: id} do
      Store.write_global(%{"paleta" => %{"texto" => "#FFFFFF"}})

      assert {:ok, text} =
               AddText.execute(%{
                 "project_id" => id,
                 "content" => "Custom",
                 "start_ms" => 0,
                 "duration_ms" => 1000,
                 "color" => "#1E88E5",
                 "use_brand" => true
               })

      assert text =~ "Fora da paleta: #1E88E5"
      assert text =~ "promote_style"
      refute text =~ "Estilo da marca aplicado: color"
      assert [%{"campo" => "paleta", "valor" => "#1E88E5"}] = Store.read_project(id)["pendentes"]
    end

    test "without use_brand explicit off-palette colors still become pending (review queue)", %{
      project_id: id
    } do
      Store.write_global(%{"paleta" => %{"texto" => "#FFFFFF"}})

      assert {:ok, text} =
               AddText.execute(%{
                 "project_id" => id,
                 "content" => "Plain",
                 "start_ms" => 0,
                 "duration_ms" => 1000,
                 "color" => "#1E88E5"
               })

      refute text =~ "Estilo da marca aplicado"
      assert text =~ "Fora da paleta: #1E88E5"
      assert [%{"campo" => "paleta", "valor" => "#1E88E5"}] = Store.read_project(id)["pendentes"]
    end
  end

  # ── add_clip images ──────────────────────────────────────────────────────────

  describe "AddClip image support" do
    setup do
      tmp =
        Path.join(System.tmp_dir!(), "capcut-brand-clip-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      project_id = "BRAND-CLIP-001"
      project_path = Path.join(tmp, "brand_clip_project")
      File.mkdir_p!(project_path)

      draft = %{
        "id" => project_id,
        "name" => "Brand Clip Test",
        "fps" => 30.0,
        "duration" => 10_000_000,
        "new_version" => "163.0.0",
        "canvas_config" => %{"width" => 1920, "height" => 1080, "ratio" => "original"},
        "tracks" => [
          %{"id" => "track-001", "type" => "video", "segments" => []}
        ],
        "materials" => %{"videos" => [], "texts" => [], "audios" => [], "images" => []}
      }

      File.write!(Path.join(project_path, "draft_content.json"), Jason.encode!(draft))

      meta = %{
        "all_draft_store" => [
          %{
            "draft_id" => project_id,
            "draft_name" => "Brand Clip Test",
            "draft_fold_path" => project_path,
            "draft_json_file" => Path.join(project_path, "draft_content.json"),
            "tm_draft_modified" => 1_750_000_000_000_000,
            "tm_duration" => 10_000_000
          }
        ],
        "draft_ids" => 1,
        "root_path" => tmp
      }

      File.write!(Path.join(tmp, "root_meta_info.json"), Jason.encode!(meta))
      start_supervised!({ProjectStore, [root_path: tmp]})

      # 1x1 transparent PNG.
      png = Path.join(tmp, "logo.png")

      File.write!(
        png,
        Base.decode64!(
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
        )
      )

      %{project_id: project_id, png: png}
    end

    test "add_clip accepts an image and writes a photo material on a video track", %{
      project_id: id,
      png: png
    } do
      assert {:ok, text} =
               AddClip.execute(%{"project_id" => id, "file_path" => png, "duration_ms" => 3000})

      assert text =~ "Type: image"
      assert text =~ "Track index: 0"

      {:ok, %{draft: draft}} = ProjectStore.get_project_with_meta(id)
      [material] = draft["materials"]["videos"]
      assert material["type"] == "photo"
      assert material["path"] == png

      [track] = draft["tracks"]
      assert track["type"] == "video"
      [segment] = track["segments"]
      assert segment["material_id"] == material["id"]
    end

    test "add_clip still rejects unsupported extensions", %{project_id: id} do
      bad = Path.join(System.tmp_dir!(), "capcut-brand-unsupported.xyz")
      File.write!(bad, "not media")
      on_exit(fn -> File.rm(bad) end)

      assert {:error, reason} = AddClip.execute(%{"project_id" => id, "file_path" => bad})
      assert reason =~ "Unsupported file extension"
    end
  end
end
