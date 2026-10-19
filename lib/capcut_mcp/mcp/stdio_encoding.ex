defmodule CapcutMcp.MCP.StdioEncoding do
  @moduledoc """
  Pins the stdio device to UTF-8 for the JSON-RPC transport.

  `mix run` boots stdio in unicode mode; the release (`-noshell`) may start in
  latin1. On a latin1 device, `IO.write/2` escapes any codepoint above 255
  (the "•" bullet becomes the literal text `\\x{2022}`) and `IO.read/2`
  latin1-decodes incoming UTF-8 (ç arrives as two lone bytes) — both corrupt
  the JSON-RPC stream. On a *unicode* device the reverse bite: `IO.binwrite/2`
  asks for latin1 semantics and re-encodes each byte as a separate codepoint
  (the "→" arrow came out as "â"), and `IO.binread/2` decode-then-reencode
  mangles input the same way.

  Calling `ensure_utf8/0` before each read/write makes the encoding explicit
  regardless of how the VM was booted, so `IO.read` and `IO.write` carry
  byte-clean UTF-8 end to end.
  """

  @spec ensure_utf8() :: :ok
  def ensure_utf8 do
    :io.setopts(:stdio, encoding: :utf8)
  end
end
