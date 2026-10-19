defmodule CapcutMcp.Tools.EpidemicSoundTest do
  use ExUnit.Case, async: false

  alias CapcutMcp.CapCut.ProjectStore
  alias CapcutMcp.MCP.Dispatcher
  alias CapcutMcp.Tools.{DownloadEpidemicSound, ReportEpidemicSoundExport, SearchEpidemicSound}

  @moduletag :tmp_dir
  @audio <<255, 251, 144, 0>> <> :binary.copy(<<0>>, 16_000)
  @cdn "https://pdn.epidemicsound.com/audio/test.mp3?signature=private"

  setup %{tmp_dir: tmp} do
    keys = [
      :epidemic_sound_api_key,
      :epidemic_sound_http,
      :epidemic_sound_user_id,
      :epidemic_sound_output_dir
    ]

    previous = Map.new(keys, &{&1, Application.fetch_env(:capcut_mcp, &1)})
    Application.put_env(:capcut_mcp, :epidemic_sound_api_key, "test-secret")
    Application.put_env(:capcut_mcp, :epidemic_sound_user_id, "anonymous-editor-1")
    Application.put_env(:capcut_mcp, :epidemic_sound_output_dir, Path.join(tmp, "downloads"))
    stub(fn _ -> flunk("Unexpected HTTP request") end)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:capcut_mcp, key, value)
          :error -> Application.delete_env(:capcut_mcp, key)
        end
      end
    end)

    File.write!(
      Path.join(tmp, "root_meta_info.json"),
      Jason.encode!(%{
        "all_draft_store" => [],
        "draft_ids" => 0,
        "root_path" => tmp
      })
    )

    start_supervised!({ProjectStore, [root_path: tmp]})
    {:ok, project_id} = ProjectStore.create_project(%{"name" => "Sound Test"})
    %{project_id: project_id}
  end

  test "registered tools validate required arguments" do
    response = Dispatcher.dispatch(%{"method" => "tools/list", "id" => 1}) |> Jason.decode!()
    names = Enum.map(response["result"]["tools"], & &1["name"])

    for name <- ~w(search_epidemic_sound download_epidemic_sound report_epidemic_sound_export) do
      assert name in names
      assert {:error, {:missing_required, _}} = Dispatcher.call_tool(name, %{})
    end
  end

  test "missing key explains which key to configure" do
    Application.put_env(:capcut_mcp, :epidemic_sound_api_key, "")
    assert {:error, error} = SearchEpidemicSound.execute(%{"query" => "upbeat"})
    assert error =~ "EPIDEMIC_SOUND_API_KEY"
    assert error =~ "Partner API"
  end

  test "music search encodes text and preserves metadata, access flags and pagination" do
    stub(fn request ->
      uri = URI.parse(request.url)
      assert uri.path == "/v0/tracks/search"

      assert URI.decode_query(uri.query) == %{
               "term" => "ação & calm",
               "limit" => "5",
               "offset" => "10",
               "vocalType" => "NONE"
             }

      assert {"authorization", "Bearer test-secret"} in request.headers
      assert {"x-partner-user-id", "anonymous-editor-1"} in request.headers

      json(200, %{
        "tracks" => [%{"id" => "music-1", "isPreviewOnly" => true, "title" => "Calm"}],
        "pagination" => %{"offset" => 10},
        "links" => %{"next" => "/tracks/search?offset=15"}
      })
    end)

    assert {:ok, text} =
             Dispatcher.call_tool("search_epidemic_sound", %{
               "query" => "ação & calm",
               "limit" => 5,
               "offset" => 10,
               "vocal_type" => "NONE"
             })

    result = Jason.decode!(text)
    assert result["tracks"] == [%{"id" => "music-1", "isPreviewOnly" => true, "title" => "Calm"}]
    assert result["pagination"]["offset"] == 10
    assert result["kind"] == "music"
  end

  test "sound effects use their own endpoint and empty results are valid" do
    stub(fn request ->
      assert URI.parse(request.url).path == "/v0/sound-effects/search"
      json(200, %{"soundEffects" => []})
    end)

    assert {:ok, text} =
             SearchEpidemicSound.execute(%{"query" => "whoosh", "kind" => "sound_effect"})

    assert Jason.decode!(text)["soundEffects"] == []
  end

  test "invalid search arguments never call the provider" do
    for args <- [
          %{"query" => nil},
          %{"query" => " "},
          %{"query" => 12},
          %{"query" => "x", "kind" => "bad"},
          %{"query" => "x", "limit" => 61},
          %{"query" => "x", "offset" => -1},
          %{"query" => "x", "vocal_type" => false},
          %{"query" => "x", "kind" => "sound_effect", "vocal_type" => "NONE"}
        ] do
      assert {:error, _} = SearchEpidemicSound.execute(args)
    end
  end

  test "HTTP errors are useful without exposing secrets or response bodies" do
    for status <- [401, 403, 404, 429, 503] do
      stub(fn _ ->
        {:ok, %{status: status, headers: [{~c"retry-after", ~c"30"}], body: "test-secret"}}
      end)

      assert {:error, error} = SearchEpidemicSound.execute(%{"query" => "x"})
      assert error =~ "HTTP #{status}"
      assert error =~ "Retry-After: 30"
      refute error =~ "test-secret"
    end
  end

  test "invalid JSON and response shapes return errors" do
    for body <- ["<html>bad gateway</html>", "[]", "{}"] do
      stub(fn _ -> response(200, body) end)
      assert {:error, _} = SearchEpidemicSound.execute(%{"query" => "x"})
    end
  end

  test "downloads music into the project and adds a trimmed audio clip", %{project_id: id} do
    stub_download("music", "high")

    assert {:ok, result} =
             DownloadEpidemicSound.execute(%{
               "track_id" => "music-1",
               "project_id" => id,
               "quality" => "high",
               "start_ms" => 2000,
               "duration_ms" => 500
             })

    assert result =~ "Clip added."
    {:ok, draft} = ProjectStore.get_project(id)
    [%{"type" => "audio", "segments" => [segment]}] = draft["tracks"]
    assert segment["target_timerange"] == %{"start" => 2_000_000, "duration" => 500_000}
    [material] = draft["materials"]["audios"]
    assert File.read!(material["path"]) == @audio
    assert material["path"] =~ "/epidemic-sound/"
    refute result =~ "signature"
    refute result =~ "test-secret"
  end

  test "sound effect downloads without a project return a real local MP3", %{tmp_dir: tmp} do
    stub_download("sound_effect", "normal")

    assert {:ok, result} =
             DownloadEpidemicSound.execute(%{"track_id" => "effect-1", "kind" => "sound_effect"})

    [path] = Path.wildcard(Path.join(tmp, "downloads/*.mp3"))
    assert File.read!(path) == @audio
    assert result =~ path
    refute result =~ "Clip added"
  end

  test "source duration limits a longer requested clip", %{project_id: id} do
    stub_download("music", "normal")

    assert {:ok, _} =
             DownloadEpidemicSound.execute(%{
               "track_id" => "music-1",
               "project_id" => id,
               "duration_ms" => 5000
             })

    {:ok, draft} = ProjectStore.get_project(id)
    [track] = draft["tracks"]
    [segment] = track["segments"]
    assert segment["target_timerange"]["duration"] == 1_000_000
  end

  test "invalid download inputs and unknown projects fail before HTTP", %{project_id: id} do
    for extra <- [
          %{"track_id" => "../escape"},
          %{"track_id" => nil},
          %{"quality" => "wav"},
          %{"start_ms" => -1},
          %{"duration_ms" => nil},
          %{"duration_ms" => 0},
          %{"project_id" => "missing"},
          %{"project_id" => false},
          %{"project_id" => id, "track_index" => 20},
          %{"track_index" => -1},
          %{"output_path" => 42},
          %{"output_path" => "relative.mp3"},
          %{"output_path" => "/tmp/sound.wav"}
        ] do
      assert {:error, _} =
               DownloadEpidemicSound.execute(Map.merge(%{"track_id" => "valid-1"}, extra))
    end
  end

  test "existing output is preserved without consuming a download", %{tmp_dir: tmp} do
    path = Path.join(tmp, "keep.mp3")
    File.write!(path, "original")

    assert {:error, error} =
             DownloadEpidemicSound.execute(%{"track_id" => "music-1", "output_path" => path})

    assert error =~ "already exists"
    assert File.read!(path) == "original"
  end

  test "untrusted URLs never receive a second request" do
    for url <- [
          nil,
          "http://pdn.epidemicsound.com/a.mp3",
          "https://127.0.0.1/a.mp3",
          "https://pdn.epidemicsound.com.evil.test/a.mp3",
          "https://user@pdn.epidemicsound.com/a.mp3"
        ] do
      stub(fn request ->
        assert URI.parse(request.url).host == "api.epidemicsound.com"
        json(200, %{"url" => url})
      end)

      assert {:error, _} = DownloadEpidemicSound.execute(%{"track_id" => "music-1"})
    end
  end

  test "CDN failures and non-audio responses leave no files", %{tmp_dir: tmp} do
    for reply <- [
          response(200, ""),
          response(200, "<html>error</html>"),
          response(302, "redirect"),
          response(403, "expired"),
          {:error, "timed out"}
        ] do
      stub(fn request ->
        if URI.parse(request.url).host == "api.epidemicsound.com",
          do: json(200, %{"url" => @cdn}),
          else: reply
      end)

      assert {:error, _} = DownloadEpidemicSound.execute(%{"track_id" => "music-1"})
      assert Path.wildcard(Path.join(tmp, "downloads/*")) == []
    end
  end

  test "completed exports report deduplicated music ids and destination" do
    stub(fn request ->
      assert request.method == :post
      assert request.url == "https://api.epidemicsound.com/v0/usage"

      assert Jason.decode!(request.body) == %{
               "eventType" => "EXPORTED",
               "platform" => "LOCAL",
               "trackIds" => ["music-1"]
             }

      json(200, %{"message" => "Ok"})
    end)

    assert {:ok, _} = ReportEpidemicSoundExport.execute(%{"track_ids" => ["music-1", "music-1"]})
  end

  test "invalid export reports are rejected locally" do
    for args <- [
          %{"track_ids" => []},
          %{"track_ids" => "music-1"},
          %{"track_ids" => [nil]},
          %{"track_ids" => ["music-1"], "platform" => "invalid"}
        ] do
      assert {:error, _} = ReportEpidemicSoundExport.execute(args)
    end
  end

  defp stub(fun), do: Application.put_env(:capcut_mcp, :epidemic_sound_http, fun)
  defp response(status, body), do: {:ok, %{status: status, headers: [], body: body}}
  defp json(status, body), do: response(status, Jason.encode!(body))

  defp stub_download(kind, quality) do
    prefix = if kind == "music", do: "/v0/tracks/", else: "/v0/sound-effects/"

    stub(fn request ->
      if URI.parse(request.url).host == "api.epidemicsound.com" do
        assert String.starts_with?(URI.parse(request.url).path, prefix)

        assert URI.decode_query(URI.parse(request.url).query) == %{
                 "format" => "mp3",
                 "quality" => quality
               }

        json(200, %{"url" => @cdn, "expires" => "2026-10-20T00:00:00Z"})
      else
        assert request.url == @cdn
        refute List.keymember?(request.headers, "authorization", 0)
        response(200, @audio)
      end
    end)
  end
end
