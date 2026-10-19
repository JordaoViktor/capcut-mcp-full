defmodule CapcutMcp.Tools.RenderProjectTest do
  use ExUnit.Case

  alias CapcutMcp.CapCut.ProjectStore
  alias CapcutMcp.Tools.RenderProject

  @project_id "RENDER-TEST-001"

  setup %{tmp_dir: tmp} do
    project_path = Path.join(tmp, "render_project")
    File.mkdir_p!(project_path)

    draft = %{
      "id" => "timeline-id",
      "name" => "Render Test",
      "fps" => 30.0,
      "duration" => 3_000_000,
      "new_version" => "163.0.0",
      "canvas_config" => %{
        "width" => 1920,
        "height" => 1080,
        "ratio" => "original",
        "background" => nil
      },
      "tracks" => [],
      "materials" => %{}
    }

    File.write!(Path.join(project_path, "draft_content.json"), Jason.encode!(draft))

    meta = %{
      "all_draft_store" => [
        %{
          "draft_id" => @project_id,
          "draft_name" => "Render Test",
          "draft_fold_path" => project_path,
          "draft_json_file" => Path.join(project_path, "draft_content.json"),
          "tm_draft_modified" => 1_750_000_000_000_000,
          "tm_duration" => 3_000_000
        }
      ],
      "draft_ids" => 1,
      "root_path" => tmp
    }

    File.write!(Path.join(tmp, "root_meta_info.json"), Jason.encode!(meta))

    start_supervised!({ProjectStore, [root_path: tmp]})

    on_exit(fn ->
      Application.delete_env(:capcut_mcp, :remotion_renderer_path)
      Application.delete_env(:capcut_mcp, :remotion_render_timeout_ms)
      Application.delete_env(:capcut_mcp, :remotion_node_path)
    end)

    %{project_id: @project_id, project_path: project_path, tmp: tmp}
  end

  @tag :tmp_dir
  test "definition returns correct tool name and schema" do
    defn = RenderProject.definition()
    assert %{"name" => "render_project"} = defn
    assert %{"project_id" => _} = defn["inputSchema"]["properties"]
    assert defn["inputSchema"]["required"] == ["project_id"]
  end

  @tag :tmp_dir
  test "execute returns project-not-found error for unknown id" do
    assert {:error, "Project not found: NOPE"} = RenderProject.execute(%{"project_id" => "NOPE"})
  end

  @tag :tmp_dir
  test "execute returns missing-required error for invalid args" do
    assert {:error, msg} = RenderProject.execute(%{})
    assert msg =~ "project_id"
  end

  @tag :tmp_dir
  test "execute surfaces renderer-not-installed error", %{tmp: tmp} do
    renderer_dir = Path.join(tmp, "bare_renderer")
    File.mkdir_p!(Path.join(renderer_dir, "src"))
    File.write!(Path.join(Path.join(renderer_dir, "src"), "render.mjs"), "// no deps installed\n")
    Application.put_env(:capcut_mcp, :remotion_renderer_path, renderer_dir)

    assert {:error, msg} = RenderProject.execute(%{"project_id" => @project_id})
    assert msg =~ "npm install"
    assert msg =~ renderer_dir
  end

  @tag :tmp_dir
  test "execute renders via the node CLI and reports the summary", %{
    tmp: tmp,
    project_path: project_path
  } do
    renderer_dir = install_fake_renderer(tmp)
    Application.put_env(:capcut_mcp, :remotion_renderer_path, renderer_dir)

    output = Path.join(tmp, "out.mp4")

    assert {:ok, text} =
             RenderProject.execute(%{"project_id" => @project_id, "output_path" => output})

    assert text =~ "Render complete."
    assert text =~ "Output: #{output}"
    assert text =~ "Canvas: 1920x1080 @ 30fps"
    assert text =~ "Layers: 2 rendered"
    assert File.exists?(output)
    # Default codec h264 lands on .mp4 without an explicit output_path:
    default_dir = Path.join(project_path, "renders")

    assert {:ok, text2} = RenderProject.execute(%{"project_id" => @project_id})
    assert text2 =~ "Output: " <> Path.join(default_dir, "render-")
    assert File.exists?(default_dir)
  end

  @tag :tmp_dir
  test "execute validates codec and output extension", %{tmp: tmp} do
    renderer_dir = install_fake_renderer(tmp)
    Application.put_env(:capcut_mcp, :remotion_renderer_path, renderer_dir)

    assert {:error, msg} =
             RenderProject.execute(%{
               "project_id" => @project_id,
               "output_path" => Path.join(tmp, "out.mp4"),
               "codec" => "mpeg2"
             })

    assert msg =~ "Unsupported codec"

    assert {:error, msg} =
             RenderProject.execute(%{
               "project_id" => @project_id,
               "output_path" => Path.join(tmp, "out.webm"),
               "codec" => "h264"
             })

    assert msg =~ "requires one of"

    # vp9 + .webm is a valid pair and reaches the fake renderer.
    assert {:ok, _} =
             RenderProject.execute(%{
               "project_id" => @project_id,
               "output_path" => Path.join(tmp, "out.webm"),
               "codec" => "vp9"
             })
  end

  @tag :tmp_dir
  test "execute validates concurrency argument", %{tmp: tmp} do
    renderer_dir = install_fake_renderer(tmp)
    Application.put_env(:capcut_mcp, :remotion_renderer_path, renderer_dir)

    assert {:error, msg} =
             RenderProject.execute(%{
               "project_id" => @project_id,
               "output_path" => Path.join(tmp, "out.mp4"),
               "concurrency" => "four"
             })

    assert msg =~ "concurrency"
  end

  @tag :tmp_dir
  test "execute surfaces renderer failure summary", %{tmp: tmp} do
    renderer_dir = install_fake_renderer(tmp)
    Application.put_env(:capcut_mcp, :remotion_renderer_path, renderer_dir)

    assert {:error, msg} =
             RenderProject.execute(%{
               "project_id" => @project_id,
               "output_path" => Path.join(tmp, "out-fail.mp4")
             })

    assert msg =~ "render boom"
  end

  @tag :tmp_dir
  test "execute reports a timeout", %{tmp: tmp} do
    renderer_dir = install_fake_renderer(tmp)
    Application.put_env(:capcut_mcp, :remotion_renderer_path, renderer_dir)
    Application.put_env(:capcut_mcp, :remotion_render_timeout_ms, 200)

    assert {:error, msg} =
             RenderProject.execute(%{
               "project_id" => @project_id,
               "output_path" => Path.join(tmp, "out-sleep.mp4")
             })

    assert msg =~ "timed out"
  end

  @tag :tmp_dir
  test "execute renders a draft_info.json-only project (macOS layout)", %{tmp: tmp} do
    renderer_dir = install_fake_renderer(tmp)
    Application.put_env(:capcut_mcp, :remotion_renderer_path, renderer_dir)

    # A real macOS CapCut draft can ship only draft_info.json; the resolver
    # must fall back to it instead of failing on the missing draft_content.json.
    info_only = Path.join(tmp, "info_only")
    File.mkdir_p!(info_only)

    File.cp!(
      Path.join(tmp, "render_project/draft_content.json"),
      Path.join(info_only, "draft_info.json")
    )

    meta_file = Path.join(tmp, "root_meta_info.json")
    existing = Jason.decode!(File.read!(meta_file))

    File.write!(
      meta_file,
      Jason.encode!(%{
        existing
        | "all_draft_store" => [
            %{
              "draft_id" => "INFO-ONLY-001",
              "draft_name" => "Info Only",
              "draft_fold_path" => info_only,
              "draft_json_file" => Path.join(info_only, "draft_info.json"),
              "tm_draft_modified" => 1,
              "tm_duration" => 3_000_000
            }
            | existing["all_draft_store"]
          ],
          "draft_ids" => 2
      })
    )

    output = Path.join(tmp, "out-info.mp4")

    assert {:ok, text} =
             RenderProject.execute(%{"project_id" => "INFO-ONLY-001", "output_path" => output})

    assert text =~ "Render complete."
    assert File.exists?(output)
  end

  @tag :tmp_dir
  test "execute errors when the project folder has no draft file at all", %{tmp: tmp} do
    renderer_dir = install_fake_renderer(tmp)
    Application.put_env(:capcut_mcp, :remotion_renderer_path, renderer_dir)

    # The project cache is read-through: get_project_with_meta succeeds from a
    # warm entry even after the files vanish, so the tool's own draft-file
    # resolver is what reports the human-readable error.
    empty_project = Path.join(tmp, "empty_project")
    File.mkdir_p!(empty_project)
    File.write!(Path.join(empty_project, "draft_content.json"), "{}")

    meta_file = Path.join(tmp, "root_meta_info.json")
    existing = Jason.decode!(File.read!(meta_file))

    File.write!(
      meta_file,
      Jason.encode!(%{
        existing
        | "all_draft_store" => [
            %{
              "draft_id" => "EMPTY-001",
              "draft_name" => "Empty",
              "draft_fold_path" => empty_project,
              "draft_json_file" => Path.join(empty_project, "draft_content.json"),
              "tm_draft_modified" => 1,
              "tm_duration" => 0
            }
            | existing["all_draft_store"]
          ],
          "draft_ids" => 2
      })
    )

    # Warm the cache, then delete the file from disk.
    assert {:ok, _} = ProjectStore.get_project_with_meta("EMPTY-001")
    File.rm!(Path.join(empty_project, "draft_content.json"))

    assert {:error, msg} =
             RenderProject.execute(%{
               "project_id" => "EMPTY-001",
               "output_path" => Path.join(tmp, "out.mp4")
             })

    assert msg =~ "No draft_content.json or draft_info.json in"
  end

  @tag :tmp_dir
  test "execute rejects a non-string output_path", %{tmp: tmp} do
    renderer_dir = install_fake_renderer(tmp)
    Application.put_env(:capcut_mcp, :remotion_renderer_path, renderer_dir)

    assert {:error, msg} =
             RenderProject.execute(%{"project_id" => @project_id, "output_path" => 42})

    assert msg =~ "output_path"
  end

  @tag :tmp_dir
  test "execute defaults the output extension to the codec's container", %{
    tmp: tmp,
    project_path: project_path
  } do
    renderer_dir = install_fake_renderer(tmp)
    Application.put_env(:capcut_mcp, :remotion_renderer_path, renderer_dir)

    assert {:ok, text} =
             RenderProject.execute(%{"project_id" => @project_id, "codec" => "vp9"})

    assert text =~ "Codec: vp9"

    assert Path.join(project_path, "renders")
           |> File.ls!()
           |> Enum.any?(&String.ends_with?(&1, ".webm"))
  end

  @tag :tmp_dir
  test "execute reports a missing draft file", %{tmp: tmp} do
    renderer_dir = install_fake_renderer(tmp)
    Application.put_env(:capcut_mcp, :remotion_renderer_path, renderer_dir)

    empty_project = Path.join(tmp, "empty_project")
    File.mkdir_p!(empty_project)

    meta_file = Path.join(tmp, "root_meta_info.json")
    existing = Jason.decode!(File.read!(meta_file))

    File.write!(
      meta_file,
      Jason.encode!(%{
        existing
        | "all_draft_store" => [
            %{
              "draft_id" => "EMPTY-001",
              "draft_name" => "Empty",
              "draft_fold_path" => empty_project,
              "draft_json_file" => Path.join(empty_project, "draft_content.json"),
              "tm_draft_modified" => 1,
              "tm_duration" => 0
            }
            | existing["all_draft_store"]
          ],
          "draft_ids" => 2
      })
    )

    assert {:error, msg} =
             RenderProject.execute(%{
               "project_id" => "EMPTY-001",
               "output_path" => Path.join(tmp, "out.mp4")
             })

    assert msg =~ "Draft file not found"
  end

  # ── Fixtures ─────────────────────────────────────────────────────────────────

  # A node script that mimics renderer/src/render.mjs's stdout protocol
  # without running Remotion: writes the output file, emits the one-line JSON
  # summary, and exercises error paths when the output path contains a
  # marker (`out-fail` fails, `out-sleep` sleeps past the configured
  # timeout) — the tool cannot pass test-only flags, so behavior keys off the
  # argument it does control.
  defp install_fake_renderer(tmp) do
    renderer_dir = Path.join(tmp, "renderer")
    File.mkdir_p!(Path.join(renderer_dir, "src"))
    File.mkdir_p!(Path.join(renderer_dir, "node_modules/@remotion/renderer"))

    File.write!(
      Path.join(Path.join(renderer_dir, "node_modules/@remotion/renderer"), "package.json"),
      "{}"
    )

    script = """
    #!/usr/bin/env node
    import fs from 'node:fs';
    const args = process.argv.slice(2);
    const get = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : null; };
    const output = get('--output') || '';
    if (output.includes('out-fail')) {
      console.log(JSON.stringify({ ok: false, error: 'render boom' }));
      process.exit(1);
    }
    if (output.includes('out-sleep')) {
      await new Promise((r) => setTimeout(r, 2000));
    }
    fs.writeFileSync(output, 'fake-render-bytes');
    console.log(JSON.stringify({
      ok: true, output, codec: get('--codec'), width: 1920, height: 1080, fps: 30.0,
      durationMs: 3000, durationFrames: 90, layers: 2, skipped: [], sizeBytes: 17, elapsedMs: 5,
    }));
    """

    File.write!(Path.join(Path.join(renderer_dir, "src"), "render.mjs"), script)
    renderer_dir
  end
end
