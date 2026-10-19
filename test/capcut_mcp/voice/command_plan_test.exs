defmodule CapcutMcp.Voice.CommandPlanTest do
  use ExUnit.Case, async: false

  alias CapcutMcp.CapCut.ProjectStore
  alias CapcutMcp.Voice.CommandPlan

  @valid_plan ~s({
    "transcript": "Silencia a música e adiciona um título",
    "language": "pt-BR",
    "actions": [
      {"tool": "set_clip_volume", "arguments": {"project_id": "P1", "clip_id": "seg-1", "volume": 0.0}},
      {"tool": "add_text", "arguments": {"project_id": "P1", "content": "Título", "start_ms": 0, "duration_ms": 2000}}
    ],
    "reply": "Feito!"
  })

  describe "parse/1" do
    test "parses a valid JSON string plan" do
      assert {:ok, %{plan: plan, skipped: []}} = CommandPlan.parse(@valid_plan)

      assert plan.transcript =~ "Silencia a música"
      assert plan.language == "pt-BR"
      assert plan.reply == "Feito!"
      assert [%{tool: "set_clip_volume"}, %{tool: "add_text"}] = plan.actions

      assert Enum.at(plan.actions, 1).arguments["content"] == "Título"
    end

    test "tolerates markdown fences around the JSON" do
      assert {:ok, %{plan: %{transcript: _}}} =
               CommandPlan.parse("```json\n" <> @valid_plan <> "\n```")
    end

    test "accepts already-decoded maps" do
      {:ok, decoded} = Jason.decode(@valid_plan)
      assert {:ok, %{plan: %{actions: [_, _]}}} = CommandPlan.parse(decoded)
    end

    test "rejects plans without a transcript" do
      assert {:error, message} = CommandPlan.parse(~s({"actions": []}))
      assert message =~ "transcript"
    end

    test "rejects non-JSON input" do
      assert {:error, "Command plan is not valid JSON"} = CommandPlan.parse("definitely not json")
      assert {:error, message} = CommandPlan.parse(42)
      assert message =~ "must be JSON"
    end

    test "drops actions for disallowed tools and reports them" do
      plan = ~s({
        "transcript": "apaga o projeto e cria outro",
        "actions": [
          {"tool": "remove_project", "arguments": {"project_id": "P1"}},
          {"tool": "create_project", "arguments": {"name": "Novo"}}
        ]
      })

      assert {:ok, %{plan: plan, skipped: skipped}} = CommandPlan.parse(plan)
      assert [%{tool: "create_project"}] = plan.actions
      assert [%{tool: "remove_project"}] = skipped
    end

    test "rejects plans with more than 10 actions" do
      actions =
        Enum.map_join(1..11, ",", fn _ -> ~s({"tool": "get_timeline", "arguments": {}}) end)

      assert {:error, message} =
               CommandPlan.parse(~s({"transcript": "x", "actions": [#{actions}]}))

      assert message =~ "more than 10 actions"
    end

    test "handles actions with missing arguments map" do
      assert {:ok, %{plan: %{actions: [%{tool: "list_projects", arguments: %{}}]}}} =
               CommandPlan.parse(
                 ~s({"transcript": "lista", "actions": [{"tool": "list_projects"}]})
               )
    end
  end

  describe "allowed_tools/0" do
    test "never includes destructive or meta tools" do
      tools = CommandPlan.allowed_tools()

      refute "remove_project" in tools
      refute "transcribe_audio" in tools
      refute "voice_command" in tools
      refute "list_voices" in tools
      assert "render_project" in tools
      assert "generate_speech" in tools
    end
  end

  describe "project_context/1" do
    setup %{tmp_dir: tmp} do
      project_path = Path.join(tmp, "voice_cmd_project")
      File.mkdir_p!(project_path)

      draft = %{
        "id" => "VOICE-CT-1",
        "name" => "Voice Test",
        "fps" => 30.0,
        "duration" => 10_000_000,
        "new_version" => "163.0.0",
        "canvas_config" => %{
          "width" => 1920,
          "height" => 1080,
          "ratio" => "original",
          "background" => nil
        },
        "tracks" => [
          %{
            "id" => "track-1",
            "type" => "video",
            "segments" => [
              %{
                "id" => "seg-video-1",
                "material_id" => "mat-video-1",
                "target_timerange" => %{"start" => 0, "duration" => 5_000_000}
              }
            ]
          }
        ],
        "materials" => %{
          "videos" => [
            %{
              "id" => "mat-video-1",
              "type" => "video",
              "path" => "/tmp/intro.mp4",
              "name" => "intro.mp4"
            }
          ]
        }
      }

      File.write!(Path.join(project_path, "draft_content.json"), Jason.encode!(draft))

      meta = %{
        "all_draft_store" => [
          %{
            "draft_id" => "VOICE-CT-1",
            "draft_name" => "Voice Test",
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

      %{project_id: "VOICE-CT-1", project_path: project_path}
    end

    @tag :tmp_dir
    test "returns nil when no project is bound" do
      assert CommandPlan.project_context(nil) == nil
    end

    @tag :tmp_dir
    test "summarizes the timeline with ids and material paths", %{project_id: id} do
      context = CommandPlan.project_context(id)
      assert is_binary(context)
      assert context =~ ~s("Voice Test")
      assert context =~ "seg-video-1"
      assert context =~ "intro.mp4"
      assert context =~ "0ms+5000ms"
    end

    @tag :tmp_dir
    test "errors for unknown projects" do
      assert {:error, "Project not found: NOPE"} = CommandPlan.project_context("NOPE")
    end
  end
end
