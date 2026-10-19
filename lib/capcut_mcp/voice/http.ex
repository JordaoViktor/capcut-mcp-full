defmodule CapcutMcp.Voice.HTTP do
  @moduledoc """
  Minimal HTTPS client for the voice providers, backed by OTP's `:httpc`
  (no new dependencies — the release stays self-contained).

  Testable: when `Application.get_env(:capcut_mcp, :voice_http)` holds a
  1-arity function it replaces the real transport entirely (see
  `CapcutMcp.Voice.Config.http_injector/0`). The function receives the same
  request map and must return `{:ok, %{status: _, headers: _, body: _}}` or
  `{:error, reason}`.
  """

  alias CapcutMcp.Voice.Config

  @type request :: %{
          required(:method) => :get | :post,
          required(:url) => String.t(),
          optional(:headers) => [{String.t(), String.t()}],
          optional(:body) => binary() | nil,
          optional(:timeout_ms) => pos_integer()
        }

  @type response :: %{
          required(:status) => pos_integer(),
          required(:headers) => [{String.t(), String.t()}],
          required(:body) => binary()
        }

  @connect_timeout_ms 10_000
  @default_timeout_ms 30_000

  @doc """
  Performs the request. The default transport is `:httpc` with SSL
  verification left at OTP's safe defaults (verify_peer + OS trust store on
  Erlang/OTP 25+).
  """
  @spec request(request()) :: {:ok, response()} | {:error, String.t()}
  def request(%{method: method} = req) do
    case Config.http_injector() do
      nil -> transport(method, req)
      fun -> fun.(req)
    end
  end

  defp transport(method, %{url: url} = req) do
    timeout_ms = Map.get(req, :timeout_ms, @default_timeout_ms)

    headers =
      Enum.map(Map.get(req, :headers, []), fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    body = Map.get(req, :body)

    # `timeout`/`connect_timeout` are http_options; `body_format` belongs to
    # the request options (mixing them up makes :httpc reject the call).
    http_options = [connect_timeout: @connect_timeout_ms, timeout: timeout_ms]
    request_options = [body_format: :binary]

    result =
      case method do
        :get ->
          :httpc.request(:get, {to_charlist(url), headers}, http_options, request_options)

        :post ->
          :httpc.request(
            :post,
            {to_charlist(url), headers, ~c"application/json", body},
            http_options,
            request_options
          )
      end

    case result do
      {:ok, {{_http_version, status, _reason}, resp_headers, resp_body}} ->
        {:ok, %{status: status, headers: normalize_headers(resp_headers), body: resp_body}}

      {:error, reason} ->
        {:error, format_http_error(url, reason)}
    end
  end

  defp normalize_headers(headers) do
    Enum.map(headers, fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end)
  end

  defp format_http_error(url, reason) do
    host = URI.parse(url).host

    case reason do
      {:failed_connect, _details} ->
        "Request to #{host} failed (connection error). Check network access, DNS, and that " <>
          "no proxy/firewall is blocking HTTPS. Details: #{inspect(reason, limit: 5)}"

      other ->
        "Request to #{host} failed: #{inspect(other, limit: 5)}"
    end
  end
end
