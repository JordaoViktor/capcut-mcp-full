defmodule CapcutMcp.Voice.Stub do
  @moduledoc """
  Test helper: replaces the voice HTTP transport with a canned response or
  an ordered sequence of responses. Each entry is either a bare
  `{:ok, %{...}} | {:error, ...}` response, a response function (`req -> result`),
  or a `{match_fn, response}` pair that only triggers when the request matches.
  """

  def stub!(responses) when is_list(responses) do
    {:ok, agent} = Agent.start_link(fn -> responses end)

    Application.put_env(:capcut_mcp, :voice_http, fn req ->
      next =
        Agent.get_and_update(agent, fn
          [] -> {:missing, []}
          [head | tail] -> {head, tail}
        end)

      case next do
        :missing ->
          {:error, "no stubbed response left (unexpected request: #{req[:method]} #{req[:url]})"}

        {match, response} when is_function(match, 1) ->
          respond(match.(req), response, req)

        response ->
          respond(true, response, req)
      end
    end)

    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:capcut_mcp, :voice_http) end)

    agent
  end

  def stub!(response), do: stub!([response])

  def ok(status, body), do: {:ok, %{status: status, headers: [], body: body}}

  def ok_json(status, term), do: ok(status, Jason.encode!(term))

  def put_key!(provider, key) do
    case provider do
      :elevenlabs -> Application.put_env(:capcut_mcp, :elevenlabs_api_key, key)
      :gemini -> Application.put_env(:capcut_mcp, :gemini_api_key, key)
    end

    ExUnit.Callbacks.on_exit(fn ->
      case provider do
        :elevenlabs -> Application.delete_env(:capcut_mcp, :elevenlabs_api_key)
        :gemini -> Application.delete_env(:capcut_mcp, :gemini_api_key)
      end
    end)
  end

  defp respond(true, response, req) when is_function(response, 1), do: response.(req)
  defp respond(true, response, _req), do: response

  defp respond(false, _response, req),
    do: {:error, "stubbed request did not match: #{req[:method]} #{req[:url]}"}
end
