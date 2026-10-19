defmodule CapcutMcp.Tools.DownloadEpidemicSound do
  @moduledoc "Download a selected Epidemic Sound asset and optionally add it to CapCut."
  @behaviour CapcutMcp.Tool

  alias CapcutMcp.CapCut.ProjectStore
  alias CapcutMcp.EpidemicSound.Client
  alias CapcutMcp.Tools.{AddClip, TimelineHelper, ToolArgs}
  alias CapcutMcp.Voice.Output

  @impl true
  def definition do
    %{
      "name" => "download_epidemic_sound",
      "description" =>
        "Downloads a selected Epidemic Sound track or sound effect as MP3, " <>
          "optionally adding it to a project timeline. Use a track_id from search_epidemic_sound. " <>
          "Downloads count against the provider's API plan. Requires EPIDEMIC_SOUND_API_KEY (Partner API).",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "track_id" => %{
            "type" => "string",
            "description" => "Exact asset id returned by search_epidemic_sound"
          },
          "kind" => %{
            "type" => "string",
            "enum" => ["music", "sound_effect"],
            "default" => "music"
          },
          "quality" => %{
            "type" => "string",
            "enum" => ["normal", "high"],
            "default" => "normal",
            "description" => "MP3 bitrate: normal = 128 kbps, high = 320 kbps"
          },
          "project_id" => %{
            "type" => "string",
            "description" => "Omit to download without editing a project"
          },
          "start_ms" => %{"type" => "integer", "minimum" => 0, "default" => 0},
          "duration_ms" => %{
            "type" => "integer",
            "minimum" => 1,
            "description" =>
              "Timeline clip length; defaults to MP3 estimated duration, capped at the source length"
          },
          "track_index" => %{"type" => "integer", "minimum" => 0},
          "output_path" => %{
            "type" => "string",
            "description" =>
              "New absolute .mp3 path. Default: <project>/epidemic-sound/ or EPIDEMIC_SOUND_OUTPUT_DIR. Never overwrites a file."
          }
        },
        "required" => ["track_id"]
      }
    }
  end

  @impl true
  def execute(%{"track_id" => _} = args) do
    with :ok <- validate_args(args),
         {:ok, directory} <- output_directory(args),
         {:ok, path} <- resolve_path(args, directory),
         {:ok, download} <- Client.download(args),
         {:ok, ^path} <- write_new(path, download.audio) do
      duration = min(Map.get(args, "duration_ms", download.duration_ms), download.duration_ms)

      summary =
        "Epidemic Sound audio downloaded.\nFile: #{path}\nTrack ID: #{args["track_id"]}\n" <>
          "Kind: #{Map.get(args, "kind", "music")}\nEstimated source duration: #{download.duration_ms}ms"

      {:ok, summary <> add_to_timeline(args, path, duration)}
    end
  end

  def execute(args), do: {:error, ToolArgs.missing_required_message(args, ["track_id"])}

  defp validate_args(args) do
    with :ok <- Client.validate_id(args["track_id"]),
         {:ok, _} <- Client.kind_path(Map.get(args, "kind", "music")),
         :ok <- Client.member(Map.get(args, "quality", "normal"), ~w(normal high), "quality"),
         {:ok, _} <-
           TimelineHelper.validate_timing(
             Map.get(args, "start_ms", 0),
             Map.get(args, "duration_ms", 1)
           ),
         :ok <- optional_track_index(args) do
      optional_project_id(args)
    end
  end

  defp optional_track_index(%{"track_index" => index}),
    do: Client.integer_range(index, "track_index", 0, 1_000_000)

  defp optional_track_index(_), do: :ok

  defp optional_project_id(%{"project_id" => id}) when is_binary(id) and byte_size(id) > 0,
    do: :ok

  defp optional_project_id(%{"project_id" => _}),
    do: {:error, "Invalid project_id: expected a non-empty string"}

  defp optional_project_id(_), do: :ok

  defp output_directory(%{"project_id" => id} = args) do
    case ProjectStore.get_project_with_meta(id) do
      {:ok, %{meta: meta, draft: draft}} ->
        with {:ok, _} <-
               TimelineHelper.validate_track_index(draft["tracks"] || [], args["track_index"]) do
          {:ok, Path.join(meta.path, "epidemic-sound")}
        end

      {:error, :not_found} ->
        {:error, "Project not found: #{id}"}

      {:error, reason} ->
        {:error, "Could not read project: #{inspect(reason)}"}
    end
  end

  defp output_directory(_) do
    directory =
      Application.get_env(:capcut_mcp, :epidemic_sound_output_dir) ||
        System.get_env("EPIDEMIC_SOUND_OUTPUT_DIR") ||
        Path.join(File.cwd!(), "epidemic-sound-output")

    {:ok, Path.expand(directory)}
  end

  defp resolve_path(%{"output_path" => path}, _directory)
       when not is_nil(path) and not is_binary(path),
       do: {:error, "Invalid output_path: expected an absolute .mp3 path"}

  defp resolve_path(args, directory) do
    prefix = "#{args["track_id"]}-#{TimelineHelper.generate_uuid()}"

    with {:ok, resolved} <- Output.resolve_path(args["output_path"], directory, prefix, ".mp3") do
      cond do
        String.downcase(Path.extname(resolved)) != ".mp3" ->
          {:error, "output_path must end in .mp3"}

        File.exists?(resolved) ->
          {:error, "Output already exists: #{resolved}. Choose a new path."}

        true ->
          {:ok, resolved}
      end
    end
  end

  defp write_new(path, bytes) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, file} <- File.open(path, [:write, :binary, :exclusive]) do
      result = IO.binwrite(file, bytes)
      close_result = File.close(file)

      case {result, close_result} do
        {:ok, :ok} ->
          {:ok, path}

        _ ->
          File.rm(path)
          {:error, "Failed to write Epidemic Sound audio to #{path}"}
      end
    else
      {:error, reason} -> {:error, "Could not create audio file: #{inspect(reason)}"}
    end
  end

  defp add_to_timeline(%{"project_id" => _} = args, path, duration) do
    clip_args =
      args
      |> Map.take(["project_id", "start_ms", "track_index"])
      |> Map.put("file_path", path)
      |> Map.put("duration_ms", duration)

    case AddClip.execute(clip_args) do
      {:ok, result} -> "\n\n" <> result
      {:error, reason} -> "\n\nAudio saved but NOT added to the timeline: #{inspect(reason)}"
    end
  end

  defp add_to_timeline(_, _, _), do: ""
end
