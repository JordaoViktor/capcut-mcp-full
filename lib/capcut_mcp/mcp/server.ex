defmodule CapcutMcp.MCP.Server do
  @moduledoc """
  GenServer that handles JSON-RPC messages forwarded from `CapcutMcp.MCP.StdinReader`.

  Decoding, dispatching, and stdout replies live here; stdin reading lives in a
  separate supervised `Task` so each concern has its own failure domain.
  """
  use GenServer
  require Logger
  alias CapcutMcp.MCP.{Dispatcher, Protocol, StdioEncoding}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    StdioEncoding.ensure_utf8()
    Logger.info("CapCut MCP Server started — waiting for messages on stdin")
    {:ok, %{}}
  end

  @impl true
  def handle_info({:line, line}, state) do
    with {:ok, msg} <- Protocol.decode_message(line),
         :ok <- set_request_metadata(msg),
         response when not is_nil(response) <- Dispatcher.dispatch(msg) do
      write_line(response)
    else
      {:error, _} -> write_line(Protocol.encode_error(nil, -32_700, "Parse error"))
      nil -> :ok
    end

    Logger.reset_metadata()
    {:noreply, state}
  end

  def handle_info(:eof, state) do
    Logger.info("stdin closed — shutting down")
    # The MCP client closed stdin, which is its signal to shut down. Stop
    # the whole runtime gracefully with exit status 0. Using `System.stop/1`
    # (rather than `{:stop, :normal, state}`) matters when running as a
    # release: a `:permanent` application terminating on its own brings the
    # node down abnormally ("Kernel pid terminated") and writes an
    # `erl_crash.dump`. `System.stop/0` runs every application's shutdown
    # callbacks in order and exits cleanly with no crash dump.
    System.stop(0)
    {:noreply, state}
  end

  def handle_info({:stdin_error, reason}, state) do
    Logger.error("stdin error: #{inspect(reason)}")
    {:stop, reason, state}
  end

  # Write the JSON-RPC response through encoding-aware `IO.write` with stdio
  # pinned to UTF-8 (`StdioEncoding.ensure_utf8/0`). The earlier `IO.binwrite`
  # asked the io server for latin1 semantics: on a unicode-mode device every
  # non-ASCII byte got re-encoded as its own codepoint (the "→" arrow in tool
  # results came out as the lone bytes of "â"). `IO.write` encodes the
  # codepoints to the device's UTF-8 encoding, so clients receive clean UTF-8.
  defp write_line(iodata) do
    StdioEncoding.ensure_utf8()
    IO.write(:stdio, [iodata, ?\n])
  end

  # Tag every log emitted downstream with the MCP request id + method so we can
  # `grep mcp_request_id=42` across the whole pipeline, including tool code.
  defp set_request_metadata(%{} = msg) do
    Logger.metadata(
      mcp_request_id: Map.get(msg, "id"),
      mcp_method: Map.get(msg, "method")
    )

    :ok
  end
end
