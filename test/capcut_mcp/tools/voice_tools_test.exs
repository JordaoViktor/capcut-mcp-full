defmodule CapcutMcp.Tools.VoiceToolsTest do
  use ExUnit.Case, async: false

  import CapcutMcp.Voice.Stub

  alias CapcutMcp.CapCut.ProjectStore
  alias CapcutMcp.MCP.Dispatcher
  alias CapcutMcp.Tools.{GenerateSpeech, ListVoices, TranscribeAudio, VoiceCommand}

  @project_id "VOICE-TOOLS-1"
  @moduletag :tmp_dir

  # A minimal synthetic MP3: ID3v2 tag (10+10 bytes) + a CBR 128kbps frame
  # header + silence payload. 16 bytes of payload ≈ 1ms of audio.
  @fake_mp3 <<73, 68, 51, 3, 0, 0, 0, 0, 0, 10>> <>
              :binary.copy(<<0>>, 10) <>
              <<255, 251, 144>> <>
              :binary.copy(<<0>>, 16_000)

  setup %{tmp_dir: tmp} do
    project_path = Path.join(tmp, "voice_tools_project")
    File.mkdir_p!(project_path)

    draft = %{
      "id" => @project_id,
      "name" => "Voice Tools Test",
      "fps" => 30.0,
      "duration" => 30_000_000,
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
          "draft_name" => "Voice Tools Test",
          "draft_fold_path" => project_path,
          "draft_json_file" => Path.join(project_path, "draft_content.json"),
          "tm_draft_modified" => 1_750_000_000_000_000,
          "tm_duration" => 30_000_000
        }
      ],
      "draft_ids" => 1,
      "root_path" => tmp
    }

    File.write!(Path.join(tmp, "root_meta_info.json"), Jason.encode!(meta))

    start_supervised!({ProjectStore, [root_path: tmp]})

    Application.put_env(:capcut_mcp, :voice_output_dir, Path.join(tmp, "voice-out"))

    on_exit(fn ->
      Application.delete_env(:capcut_mcp, :elevenlabs_api_key)
      Application.delete_env(:capcut_mcp, :gemini_api_key)
      Application.delete_env(:capcut_mcp, :voice_http)
      Application.delete_env(:capcut_mcp, :voice_output_dir)
    end)

    %{project_id: @project_id, project_path: project_path, tmp: tmp}
  end

  describe "generate_speech" do
    test "errors when ELEVENLABS_API_KEY is missing", %{project_id: project_id} do
      assert {:error, message} =
               GenerateSpeech.execute(%{"text" => "olá", "project_id" => project_id})

      assert message =~ "ELEVENLABS_API_KEY"
    end

    test "generates the MP3 and adds it to the timeline", %{project_id: project_id, tmp: tmp} do
      put_key!(:elevenlabs, "key")

      stub!(fn req ->
        assert req[:method] == :post
        assert req[:url] =~ "/v1/text-to-speech/"
        ok(200, @fake_mp3)
      end)

      assert {:ok, text} =
               GenerateSpeech.execute(%{
                 "text" => "Bem-vindos ao lançamento",
                 "project_id" => project_id
               })

      assert text =~ "Speech generated."
      assert text =~ "voiceover-"

      voice_dir = Path.join(tmp, "voice_tools_project/voice")
      assert File.exists?(voice_dir)
      [mp3_path] = Path.wildcard(Path.join(voice_dir, "*.mp3"))
      assert byte_size(File.read!(mp3_path)) == byte_size(@fake_mp3)

      # The estimated duration comes from the synthetic CBR mp3 (16_000 payload bytes / 16).
      assert text =~ "Estimated duration: 1000ms"

      {:ok, draft} = ProjectStore.get_project(project_id)
      audio_tracks = Enum.filter(draft["tracks"], &(&1["type"] == "audio"))
      assert length(audio_tracks) == 1
      [segment] = hd(audio_tracks)["segments"]
      assert segment["target_timerange"]["duration"] == 1_000_000
    end

    test "generates without a project into the voice output dir", %{tmp: tmp} do
      put_key!(:elevenlabs, "key")
      stub!(ok(200, @fake_mp3))

      assert {:ok, text} = GenerateSpeech.execute(%{"text" => "sem projeto"})
      assert text =~ Path.join(tmp, "voice-out")
    end

    test "honours duration_ms overrides", %{project_id: project_id} do
      put_key!(:elevenlabs, "key")
      stub!(ok(200, @fake_mp3))

      assert {:ok, text} =
               GenerateSpeech.execute(%{
                 "text" => "x",
                 "project_id" => project_id,
                 "duration_ms" => 4_000
               })

      assert text =~ "Estimated duration: 4000ms"
    end
  end

  describe "list_voices" do
    test "errors without a key" do
      assert {:error, message} = ListVoices.execute(%{})
      assert message =~ "ELEVENLABS_API_KEY"
    end

    test "formats the voice list" do
      put_key!(:elevenlabs, "key")

      stub!(
        ok_json(200, %{
          "voices" => [
            %{
              "voice_id" => "abc123",
              "name" => "Rachel",
              "category" => "premade",
              "labels" => %{"accent" => "american"}
            }
          ]
        })
      )

      assert {:ok, text} = ListVoices.execute(%{})
      assert text =~ "Found 1 voice(s)"
      assert text =~ "Rachel"
      assert text =~ "abc123"
    end
  end

  describe "transcribe_audio" do
    test "errors when GEMINI_API_KEY is missing", %{tmp: tmp} do
      path = Path.join(tmp, "cmd.m4a")
      File.write!(path, "fake audio")

      assert {:error, message} = TranscribeAudio.execute(%{"file_path" => path})
      assert message =~ "GEMINI_API_KEY"
    end

    test "errors for missing files and unsupported types" do
      assert {:error, message} = TranscribeAudio.execute(%{"file_path" => "/nope/missing.mp3"})
      assert message =~ "not found"

      assert {:error, message} = TranscribeAudio.execute(%{"file_path" => "/nope/file.txt"})
      assert message =~ "Unsupported file type"
    end

    test "transcribes with the default prompt", %{tmp: tmp} do
      put_key!(:gemini, "g-key")
      path = Path.join(tmp, "command.m4a")
      File.write!(path, "fake audio bytes")

      stub!(fn req ->
        body = Jason.decode!(req[:body])
        [part_text, part_audio] = Enum.at(body["contents"], 0) |> Map.get("parts")

        assert part_text["text"] == "Transcribe the spoken content of this recording verbatim."
        assert part_audio["inlineData"]["mimeType"] == "audio/mp4"
        assert Base.decode64!(part_audio["inlineData"]["data"]) == "fake audio bytes"

        ok_json(200, %{
          "candidates" => [
            %{"content" => %{"parts" => [%{"text" => "Adiciona um título no início"}]}}
          ]
        })
      end)

      assert {:ok, "Adiciona um título no início"} =
               TranscribeAudio.execute(%{"file_path" => path})
    end

    test "honours prompt and include_timestamps", %{tmp: tmp} do
      put_key!(:gemini, "g-key")
      path = Path.join(tmp, "take.wav")
      File.write!(path, "audio")

      stub!(fn req ->
        body = Jason.decode!(req[:body])

        assert body
               |> then(
                 &(&1["contents"]
                   |> Enum.at(0)
                   |> Map.get("parts")
                   |> Enum.at(0)
                   |> Map.get("text"))
               ) =~ "timestamps"

        ok_json(200, %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "00:00 bla"}]}}]})
      end)

      assert {:ok, "00:00 bla"} =
               TranscribeAudio.execute(%{"file_path" => path, "include_timestamps" => true})
    end

    test "rejects files larger than 15MB", %{tmp: tmp} do
      put_key!(:gemini, "g-key")
      path = Path.join(tmp, "big.mp3")
      File.write!(path, :binary.copy(<<0>>, 16 * 1024 * 1024))

      assert {:error, message} = TranscribeAudio.execute(%{"file_path" => path})
      assert message =~ "too large"
    end
  end

  describe "voice_command" do
    @cmd_path Path.join(System.tmp_dir!(), "voice-command-test.m4a")

    setup do
      File.write!(@cmd_path, "fake voice bytes")
      on_exit(fn -> File.rm(@cmd_path) end)
      :ok
    end

    test "errors when the audio file is missing or has an unsupported type", %{tmp: tmp} do
      put_key!(:gemini, "g-key")

      assert {:error, message} = VoiceCommand.execute(%{"audio_path" => "/nope/missing.m4a"})
      assert message =~ "not found"

      flac = Path.join(tmp, "command.txt")
      File.write!(flac, "fake audio")

      assert {:error, message} = VoiceCommand.execute(%{"audio_path" => flac})
      assert message =~ "Unsupported audio type"
    end

    test "errors for unknown projects before calling the API" do
      put_key!(:gemini, "g-key")

      assert {:error, message} =
               VoiceCommand.execute(%{"audio_path" => @cmd_path, "project_id" => "NOPE"})

      assert message =~ "Project not found"
    end

    test "preview mode (execute: false) returns the plan without editing", %{
      project_id: project_id
    } do
      put_key!(:gemini, "g-key")

      stub!(fn req ->
        body = Jason.decode!(req[:body])
        parts = body["contents"] |> Enum.at(0) |> Map.get("parts")
        prompt_text = Enum.at(parts, 0) |> Map.get("text")

        # The project timeline must be part of the prompt context.
        assert prompt_text =~ "seg-"

        ok_json(200, %{
          "candidates" => [
            %{
              "content" => %{
                "parts" => [
                  %{
                    "text" =>
                      Jason.encode!(%{
                        "transcript" => "Adiciona um título dizendo Black Friday no início",
                        "language" => "pt-BR",
                        "actions" => [
                          %{
                            "tool" => "add_text",
                            "arguments" => %{
                              "content" => "Black Friday",
                              "start_ms" => 0,
                              "duration_ms" => 2000
                            }
                          }
                        ],
                        "reply" => "Título adicionado."
                      })
                  }
                ]
              }
            }
          ]
        })
      end)

      assert {:ok, text} =
               VoiceCommand.execute(%{
                 "audio_path" => @cmd_path,
                 "project_id" => project_id,
                 "execute" => false
               })

      assert text =~ "Transcript: Adiciona um título"
      assert text =~ "add_text"
      assert text =~ "Reply: Título adicionado."
      refute text =~ "[ok]"

      {:ok, draft} = ProjectStore.get_project(project_id)
      assert draft["tracks"] == []
    end

    test "executes the plan against the bound project", %{project_id: project_id} do
      put_key!(:gemini, "g-key")

      stub!(fn _req ->
        plan = %{
          "transcript" => "Silencia o clipe de vídeo",
          "language" => "pt-BR",
          "actions" => [
            %{
              "tool" => "add_clip",
              "arguments" => %{"file_path" => "/nonexistent/video.mp4", "start_ms" => 0}
            },
            %{
              "tool" => "add_text",
              "arguments" => %{"content" => "Oferta", "start_ms" => 0, "duration_ms" => 1500}
            }
          ],
          "reply" => "Texto adicionado."
        }

        ok_json(200, %{
          "candidates" => [%{"content" => %{"parts" => [%{"text" => Jason.encode!(plan)}]}}]
        })
      end)

      assert {:ok, text} =
               VoiceCommand.execute(%{"audio_path" => @cmd_path, "project_id" => project_id})

      # The project_id that Gemini left out is filled in from the bound
      # project before each action runs.
      assert text =~ "[ok] add_clip"
      assert text =~ "[ok] add_text"
      assert text =~ "Results:"

      {:ok, draft} = ProjectStore.get_project(project_id)
      text_tracks = Enum.filter(draft["tracks"], &(&1["type"] == "text"))
      assert length(text_tracks) == 1
    end

    test "filters disallowed tools and reports them", %{project_id: project_id} do
      put_key!(:gemini, "g-key")

      stub!(fn _req ->
        plan = %{
          "transcript" => "apaga tudo e cria outro",
          "actions" => [
            %{"tool" => "remove_project", "arguments" => %{"project_id" => project_id}},
            %{"tool" => "get_timeline", "arguments" => %{}}
          ],
          "reply" => nil
        }

        ok_json(200, %{
          "candidates" => [%{"content" => %{"parts" => [%{"text" => Jason.encode!(plan)}]}}]
        })
      end)

      assert {:ok, text} =
               VoiceCommand.execute(%{"audio_path" => @cmd_path, "project_id" => project_id})

      assert text =~ "Disallowed tools removed: remove_project"
      assert text =~ "[ok] get_timeline"
    end

    test "speaks the reply with ElevenLabs when speak_reply is set", %{tmp: tmp} do
      put_key!(:gemini, "g-key")
      put_key!(:elevenlabs, "key")

      stub!([
        {fn req -> String.contains?(req[:url], "generateContent") end,
         fn _req ->
           plan = %{
             "transcript" => "tudo certo?",
             "actions" => [],
             "reply" => "Tudo certo, chefe!"
           }

           ok_json(200, %{
             "candidates" => [%{"content" => %{"parts" => [%{"text" => Jason.encode!(plan)}]}}]
           })
         end},
        {fn req -> String.contains?(req[:url], "/v1/text-to-speech/") end, ok(200, @fake_mp3)}
      ])

      assert {:ok, text} =
               VoiceCommand.execute(%{"audio_path" => @cmd_path, "speak_reply" => true})

      assert text =~ "Spoken reply: "
      [path] = text |> String.split("Spoken reply: ") |> List.last() |> String.split("\n")
      assert File.exists?(String.trim(path))
      assert String.contains?(String.trim(path), tmp)
    end

    test "returns the interpreter error when Gemini fails" do
      put_key!(:gemini, "g-key")
      stub!(ok_json(500, %{"error" => %{"message" => "backend down"}}))

      assert {:error, message} = VoiceCommand.execute(%{"audio_path" => @cmd_path})
      assert message =~ "HTTP 500"
    end
  end

  describe "dispatcher integration" do
    test "call_tool/2 runs registered tools and validates required args" do
      assert {:error, :tool_not_found} = Dispatcher.call_tool("nope", %{})

      assert {:error, {:missing_required, message}} = Dispatcher.call_tool("generate_speech", %{})
      assert message =~ "Missing required arguments"
    end

    test "voice tools are registered in tools/list" do
      definitions = Dispatcher.dispatch(%{"method" => "tools/list", "id" => 1})
      {:ok, decoded} = Jason.decode(definitions)
      names = decoded["result"]["tools"] |> Enum.map(& &1["name"])

      for tool <- [
            "generate_speech",
            "list_voices",
            "transcribe_audio",
            "voice_command"
          ] do
        assert tool in names
      end
    end
  end
end
