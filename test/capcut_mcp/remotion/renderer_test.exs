defmodule CapcutMcp.Remotion.RendererTest do
  use ExUnit.Case

  alias CapcutMcp.Remotion.Renderer

  @node_path System.find_executable("node")

  setup do
    on_exit(fn ->
      Application.delete_env(:capcut_mcp, :remotion_renderer_path)
      Application.delete_env(:capcut_mcp, :remotion_node_path)
    end)

    :ok
  end

  test "supported_codecs and container_extensions agree" do
    assert "h264" in Renderer.supported_codecs()

    assert ".mp4" in Renderer.container_extensions("h264")
    assert ".webm" in Renderer.container_extensions("vp9")
    assert ".mov" in Renderer.container_extensions("prores")
    assert [] = Renderer.container_extensions("mpeg2")
  end

  describe "ensure_available/1" do
    @tag :tmp_dir
    test "errors when the renderer directory cannot be discovered" do
      Application.put_env(:capcut_mcp, :remotion_renderer_path, "/definitely/not/a/renderer/dir")

      assert {:error, msg} = Renderer.ensure_available(node_path: @node_path)
      assert msg =~ "Remotion renderer"
    end

    # The discovery path resolves `renderer/` from the working directory (or a
    # parent) — the exact bug class fixed here: a broken pipe precedence used
    # to append "renderer" twice and discovery always failed. In this repo the
    # cwd always contains renderer/, so a successful resolution proves the
    # precedence fix; in a checkout without `npm install` the validation step
    # still proves discovery worked (it names the discovered directory).
    @tag :tmp_dir
    test "discovers the renderer directory from the working directory" do
      Application.delete_env(:capcut_mcp, :remotion_renderer_path)

      assert {:ok, %{renderer_dir: renderer_dir}} =
               Renderer.ensure_available(node_path: @node_path)

      assert renderer_dir == Path.absname("renderer")
      assert File.dir?(renderer_dir)
    end

    @tag :tmp_dir
    test "resolves the renderer directory from the REMOTION_RENDERER_PATH env var", %{
      tmp_dir: tmp
    } do
      renderer_dir = install_complete_renderer(tmp)
      System.put_env("REMOTION_RENDERER_PATH", renderer_dir)
      on_exit(fn -> System.delete_env("REMOTION_RENDERER_PATH") end)

      assert {:ok, %{renderer_dir: ^renderer_dir}} =
               Renderer.ensure_available(node_path: @node_path)
    end

    @tag :tmp_dir
    test "accepts an explicit renderer_dir option", %{tmp_dir: tmp} do
      renderer_dir = install_complete_renderer(tmp)

      assert {:ok, %{renderer_dir: ^renderer_dir}} =
               Renderer.ensure_available(renderer_dir: renderer_dir, node_path: @node_path)
    end

    @tag :tmp_dir
    test "errors when the CLI script is missing", %{tmp_dir: tmp} do
      renderer_dir = Path.join(tmp, "renderer")
      File.mkdir_p!(renderer_dir)
      Application.put_env(:capcut_mcp, :remotion_renderer_path, renderer_dir)

      assert {:error, msg} = Renderer.ensure_available(node_path: @node_path)
      assert msg =~ "render.mjs"
    end

    @tag :tmp_dir
    test "errors when node_modules are not installed", %{tmp_dir: tmp} do
      renderer_dir = Path.join(tmp, "renderer")
      File.mkdir_p!(Path.join(renderer_dir, "src"))
      File.write!(Path.join(Path.join(renderer_dir, "src"), "render.mjs"), "// placeholder")
      Application.put_env(:capcut_mcp, :remotion_renderer_path, renderer_dir)

      assert {:error, msg} = Renderer.ensure_available(node_path: @node_path)
      assert msg =~ "npm install"
    end

    @tag :tmp_dir
    test "errors when node is not available", %{tmp_dir: tmp} do
      renderer_dir = install_complete_renderer(tmp)
      Application.put_env(:capcut_mcp, :remotion_renderer_path, renderer_dir)

      assert {:error, msg} = Renderer.ensure_available(node_path: "/definitely/not/node")
      assert msg =~ "Node.js"
    end

    @tag :tmp_dir
    test "succeeds with a complete renderer directory", %{tmp_dir: tmp} do
      renderer_dir = install_complete_renderer(tmp)
      Application.put_env(:capcut_mcp, :remotion_renderer_path, renderer_dir)

      assert {:ok, %{renderer_dir: ^renderer_dir, node_path: node_path}} =
               Renderer.ensure_available(node_path: @node_path)

      assert node_path == @node_path
    end
  end

  describe "render/3" do
    @tag :tmp_dir
    test "errors on unsupported codec", %{tmp_dir: tmp} do
      renderer_dir = install_complete_renderer(tmp)
      Application.put_env(:capcut_mcp, :remotion_renderer_path, renderer_dir)

      assert {:error, msg} =
               Renderer.render(
                 Path.join(tmp, "draft.json"),
                 Path.join(tmp, "out.mp4"),
                 node_path: @node_path,
                 codec: "mpeg2"
               )

      assert msg =~ "Unsupported codec"
    end

    @tag :tmp_dir
    test "errors on invalid concurrency", %{tmp_dir: tmp} do
      renderer_dir = install_complete_renderer(tmp)
      Application.put_env(:capcut_mcp, :remotion_renderer_path, renderer_dir)

      assert {:error, msg} =
               Renderer.render(
                 Path.join(tmp, "draft.json"),
                 Path.join(tmp, "out.mp4"),
                 node_path: @node_path,
                 concurrency: "lots"
               )

      assert msg =~ "concurrency"
    end

    @tag :tmp_dir
    test "errors on codec/extension mismatch", %{tmp_dir: tmp} do
      renderer_dir = install_complete_renderer(tmp)
      Application.put_env(:capcut_mcp, :remotion_renderer_path, renderer_dir)

      assert {:error, msg} =
               Renderer.render(
                 Path.join(tmp, "draft.json"),
                 Path.join(tmp, "out.webm"),
                 node_path: @node_path,
                 codec: "h264"
               )

      assert msg =~ "requires one of"
    end

    @tag :tmp_dir
    test "errors when the draft file is missing", %{tmp_dir: tmp} do
      renderer_dir = install_complete_renderer(tmp)
      Application.put_env(:capcut_mcp, :remotion_renderer_path, renderer_dir)

      assert {:error, msg} =
               Renderer.render(
                 Path.join(tmp, "missing.json"),
                 Path.join(tmp, "out.mp4"),
                 node_path: @node_path
               )

      assert msg =~ "Draft file not found"
    end
  end

  defp install_complete_renderer(tmp) do
    renderer_dir = Path.join(tmp, "renderer")
    File.mkdir_p!(Path.join(renderer_dir, "src"))
    File.mkdir_p!(Path.join(renderer_dir, "node_modules/@remotion/renderer"))

    File.write!(Path.join(Path.join(renderer_dir, "src"), "render.mjs"), "// placeholder")
    File.write!(Path.join(renderer_dir, "node_modules/@remotion/renderer/package.json"), "{}")

    renderer_dir
  end
end
