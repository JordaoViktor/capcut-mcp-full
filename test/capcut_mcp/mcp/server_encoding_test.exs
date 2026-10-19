defmodule CapcutMcp.MCP.ServerEncodingTest do
  @moduledoc """
  Regression tests for the stdio encoding of the JSON-RPC transport.

  Two bugs bit here, both from the stdio device's encoding mode:

  1. **Output escapes** — under `-noshell`, `IO.puts/2` on a latin1 device
     escapes any codepoint above 255 (the "•" bullet became the literal text
     `\\x{2022}`), which is not a valid JSON escape and makes clients reject
     the message. The intermediate `IO.binwrite/2` fix swapped the failure
     mode: on a *unicode*-mode device it re-encoded each byte as its own
     codepoint (the "→" arrow came out as "â"). The final fix pins the device
     to UTF-8 via `StdioEncoding.ensure_utf8/0` and writes with
     encoding-aware `IO.write/2`, which is byte-clean on either starting mode.

  2. **Input mangling** — on a *unicode*-mode device, `IO.binread/2` asks the
     io server for a latin1 reply: it decodes the incoming UTF-8 and re-encodes
     each codepoint as one latin1 byte (ç → 0xE7; "●" has no latin1 form at
     all), so `Jason.decode` rejected every request carrying non-ASCII with a
     bare "Parse error" — silently, since the parse-error response has
     `id: null` and clients keyed on request ids. Fixed by reading with
     encoding-aware `IO.read/2` after pinning the device to UTF-8.

  Both tests capture through ExUnit's io device: the output test runs under a
  UTF-8 capture — the state production reaches right after `ensure_utf8/0`
  pins the device — and the input test starts from a latin1 capture and
  asserts `StdinReader.loop/1` still hands back the "●" payload intact.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias CapcutMcp.CapCut.ProjectStore
  alias CapcutMcp.MCP.{Server, StdinReader}

  setup %{tmp_dir: tmp} do
    project_id = "ENC-TEST-1"
    # Name deliberately carries both an accented letter and a bullet so the
    # encoded response is guaranteed to contain codepoints > 255.
    name = "Café • Draft"
    project_path = Path.join(tmp, "encoding_test_project")
    File.mkdir_p!(project_path)

    draft = %{
      "id" => project_id,
      "name" => name,
      "fps" => 30.0,
      "duration" => 0,
      "new_version" => "163.0.0",
      "canvas_config" => %{"width" => 1920, "height" => 1080, "ratio" => "original"},
      "tracks" => [],
      "materials" => %{}
    }

    File.write!(Path.join(project_path, "draft_content.json"), Jason.encode!(draft))

    meta = %{
      "all_draft_store" => [
        %{
          "draft_id" => project_id,
          "draft_name" => name,
          "draft_fold_path" => project_path,
          "draft_json_file" => Path.join(project_path, "draft_content.json"),
          "tm_draft_modified" => 1_750_000_000_000_000,
          "tm_duration" => 0
        }
      ],
      "draft_ids" => 1,
      "root_path" => tmp
    }

    File.write!(Path.join(tmp, "root_meta_info.json"), Jason.encode!(meta))
    start_supervised!({ProjectStore, [root_path: tmp]})
    :ok
  end

  @tag :tmp_dir
  test "a non-ASCII tool response is valid JSON on the UTF-8-pinned stdio device" do
    request =
      ~s({"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"list_projects","arguments":{}}})

    output =
      capture_io([encoding: :utf8], fn ->
        assert {:noreply, _} = Server.handle_info({:line, request}, %{})
      end)

    # The literal broken-escape sequence must NOT appear...
    refute output =~ "\\x{",
           "response leaked an Elixir codepoint escape — encoding-aware write bypassed?"

    # ...and the emitted bytes must parse as JSON and round-trip the real chars.
    decoded = output |> String.trim() |> Jason.decode!()
    text = decoded["result"]["content"] |> hd() |> Map.get("text")

    assert text =~ "•"
    assert text =~ "Café"
  end

  @tag :tmp_dir
  test "StdinReader forwards a UTF-8 request line intact on a latin1 stdio device" do
    request =
      ~s({"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"add_text","arguments":{"content":"●"}}})

    output =
      capture_io([encoding: :latin1, input: request <> "\n"], fn ->
        parent = self()
        spawn(fn -> StdinReader.loop(parent) end)

        assert_receive {:line, trimmed}, 2_000
        assert trimmed == String.trim(request)
      end)

    # The loop must not have written anything to stdout while reading.
    assert output == ""
  end
end
