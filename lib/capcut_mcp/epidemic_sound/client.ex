defmodule CapcutMcp.EpidemicSound.Client do
  @moduledoc "Server-side client for the official Epidemic Sound Partner API (v0)."

  alias CapcutMcp.Voice.Mp3Duration

  @base "https://api.epidemicsound.com/v0"
  @platforms ~w(YOUTUBE TWITTER TWITCH FACEBOOK INSTAGRAM TIKTOK OTHER LOCAL)

  def search(args) do
    with {:ok, path} <- kind_path(Map.get(args, "kind", "music")),
         :ok <- nonempty_string(args["query"], "query"),
         :ok <- integer_range(Map.get(args, "limit", 10), "limit", 1, 60),
         :ok <- integer_range(Map.get(args, "offset", 0), "offset", 0, 1_000_000),
         {:ok, filters} <- search_filters(args),
         {:ok, data} <-
           api(
             :get,
             path <> "/search",
             [
               {"term", String.trim(args["query"])},
               {"limit", Map.get(args, "limit", 10)},
               {"offset", Map.get(args, "offset", 0)}
             ] ++ filters
           ) do
      key = if path == "/tracks", do: "tracks", else: "soundEffects"

      case data[key] do
        items when is_list(items) ->
          {:ok,
           Map.put(Map.take(data, [key, "pagination", "links"]), "kind", args["kind"] || "music")}

        _ ->
          {:error, "Unexpected Epidemic Sound search response: missing #{key}"}
      end
    end
  end

  def download(args) do
    with {:ok, path} <- kind_path(Map.get(args, "kind", "music")),
         :ok <- validate_id(args["track_id"]),
         :ok <- member(Map.get(args, "quality", "normal"), ~w(normal high), "quality"),
         {:ok, data} <-
           api(:get, path <> "/#{args["track_id"]}/download",
             format: "mp3",
             quality: Map.get(args, "quality", "normal")
           ),
         {:ok, url} <- download_url(data["url"]),
         {:ok, audio} <- fetch_audio(url),
         {:ok, duration_ms} <- audio_duration(audio) do
      {:ok, %{audio: audio, duration_ms: duration_ms}}
    end
  end

  def report_export(args) do
    with :ok <- validate_ids(args["track_ids"]),
         :ok <- member(Map.get(args, "platform", "LOCAL"), @platforms, "platform") do
      api(:post, "/usage", [], %{
        "eventType" => "EXPORTED",
        "platform" => Map.get(args, "platform", "LOCAL"),
        "trackIds" => Enum.uniq(args["track_ids"])
      })
    end
  end

  def kind_path("music"), do: {:ok, "/tracks"}
  def kind_path("sound_effect"), do: {:ok, "/sound-effects"}
  def kind_path(_), do: {:error, "Invalid kind: use music or sound_effect"}

  def validate_id(id) when is_binary(id) do
    if Regex.match?(~r/\A[A-Za-z0-9_-]{1,128}\z/, id),
      do: :ok,
      else: {:error, "Invalid track_id: use the id returned by search_epidemic_sound"}
  end

  def validate_id(_), do: {:error, "Invalid track_id: expected a string"}

  def integer_range(value, _name, min, max)
      when is_integer(value) and value >= min and value <= max, do: :ok

  def integer_range(_value, name, min, max),
    do: {:error, "Invalid #{name}: expected an integer from #{min} to #{max}"}

  def member(value, values, name) do
    if value in values, do: :ok, else: {:error, "Invalid #{name}: use #{Enum.join(values, ", ")}"}
  end

  defp nonempty_string(value, name) do
    if is_binary(value) and String.trim(value) != "",
      do: :ok,
      else: {:error, "Invalid #{name}: expected a non-empty string"}
  end

  defp search_filters(%{"vocal_type" => value} = args) when not is_nil(value) do
    with :ok <- member(value, ~w(LEAD PRESENCE NONE), "vocal_type") do
      if Map.get(args, "kind", "music") == "music",
        do: {:ok, [{"vocalType", value}]},
        else: {:error, "vocal_type applies only to music searches"}
    end
  end

  defp search_filters(_), do: {:ok, []}

  defp validate_ids(ids) when is_list(ids) and length(ids) in 1..50 do
    Enum.reduce_while(ids, :ok, fn id, :ok ->
      case validate_id(id) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_ids(_), do: {:error, "Invalid track_ids: expected 1 to 50 music track ids"}

  defp api(method, path, query, body \\ nil) do
    with {:ok, key} <- api_key() do
      query_string = if query == [], do: "", else: "?" <> URI.encode_query(query)

      case request(%{
             method: method,
             url: @base <> path <> query_string,
             headers: api_headers(key),
             body: if(body, do: Jason.encode!(body), else: nil)
           }) do
        {:ok, %{status: status, body: response}} when status in 200..299 ->
          decode_response(response)

        {:ok, response} ->
          {:error, provider_error(response)}

        {:error, _} = error ->
          error
      end
    end
  end

  defp api_headers(key) do
    headers = [{"authorization", "Bearer " <> key}, {"accept", "application/json"}]

    user_id =
      Application.get_env(:capcut_mcp, :epidemic_sound_user_id) ||
        System.get_env("EPIDEMIC_SOUND_USER_ID")

    if is_binary(user_id) and user_id != "",
      do: [{"x-partner-user-id", user_id} | headers],
      else: headers
  end

  defp decode_response(response) do
    case Jason.decode(response) do
      {:ok, data} when is_map(data) -> {:ok, data}
      _ -> {:error, "Unexpected Epidemic Sound response: expected a JSON object"}
    end
  end

  defp api_key do
    key =
      Application.get_env(:capcut_mcp, :epidemic_sound_api_key) ||
        System.get_env("EPIDEMIC_SOUND_API_KEY") || ""

    if is_binary(key) and String.trim(key) != "" do
      {:ok, String.trim(key)}
    else
      {:error,
       "Epidemic Sound API key not configured. Set EPIDEMIC_SOUND_API_KEY from " <>
         "https://developers.epidemicsound.com/ (Partner API, not the account MCP key) " <>
         "and restart the server."}
    end
  end

  # Only download URLs issued by the provider; never forward the API key to the CDN.
  # Redirects are disabled so a remote response cannot redirect to the local network.
  defp download_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, port: 443, userinfo: nil} when is_binary(host) ->
        if String.ends_with?(String.downcase(host), ".epidemicsound.com"),
          do: {:ok, url},
          else: {:error, "Unexpected Epidemic Sound download host"}

      _ ->
        {:error, "Invalid Epidemic Sound download URL: expected HTTPS"}
    end
  end

  defp download_url(_), do: {:error, "Epidemic Sound response is missing the download URL"}

  defp fetch_audio(url) do
    case request(%{
           method: :get,
           url: url,
           headers: [{"accept", "audio/mpeg"}],
           timeout_ms: 120_000
         }) do
      {:ok, %{status: 200, body: audio}} when is_binary(audio) and byte_size(audio) > 4 ->
        case audio do
          <<"ID3", _::binary>> -> {:ok, audio}
          <<255, second, _::binary>> when second >= 224 -> {:ok, audio}
          _ -> {:error, "Epidemic Sound download did not contain MP3 audio"}
        end

      {:ok, %{status: 200}} ->
        {:error, "Epidemic Sound returned empty audio"}

      {:ok, response} ->
        {:error, provider_error(response)}

      {:error, _} = error ->
        error
    end
  end

  defp audio_duration(audio) do
    case Mp3Duration.estimate(audio) do
      {:ok, ms} when is_integer(ms) and ms > 0 -> {:ok, ms}
      _ -> {:error, "Cannot determine duration of the Epidemic Sound MP3"}
    end
  end

  defp provider_error(%{status: status} = response) do
    detail =
      case status do
        401 ->
          "Check EPIDEMIC_SOUND_API_KEY (Partner API key)."

        403 ->
          "Your API account does not have access to this asset or operation."

        404 ->
          "Asset not found. Search again for a current track id."

        429 ->
          "Rate limit reached. Retry later."

        503 ->
          "Service temporarily unavailable or reference track still being analysed. Retry later."

        _ ->
          "The provider could not complete the request."
      end

    retry_after =
      Enum.find_value(Map.get(response, :headers, []), fn {k, v} ->
        if String.downcase(to_string(k)) == "retry-after", do: to_string(v)
      end)

    suffix = if retry_after, do: " Retry-After: #{retry_after}", else: ""
    "Epidemic Sound request failed (HTTP #{status}). #{detail}#{suffix}"
  end

  defp request(req) do
    case Application.get_env(:capcut_mcp, :epidemic_sound_http) do
      nil -> transport(req)
      fun -> fun.(req)
    end
  end

  defp transport(req) do
    headers = Enum.map(req.headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    request =
      case req.method do
        :get -> {to_charlist(req.url), headers}
        :post -> {to_charlist(req.url), headers, ~c"application/json", req.body}
      end

    options = [
      connect_timeout: 10_000,
      timeout: Map.get(req, :timeout_ms, 30_000),
      autoredirect: false,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]

    case :httpc.request(req.method, request, options, body_format: :binary) do
      {:ok, {{_, status, _}, response_headers, body}} ->
        {:ok, %{status: status, headers: response_headers, body: body}}

      {:error, _} ->
        {:error, "Epidemic Sound connection failed or timed out. Check network access and retry."}
    end
  end
end
