defmodule CapcutMcp.Voice.Output do
  @moduledoc """
  Shared path resolution and file writing for generated media (TTS audio,
  Veo video). With a project bound, files land inside the project folder
  (`<project>/voice`, `<project>/generated`); otherwise they go to
  `CapcutMcp.Voice.Config.voice_output_dir/0`.
  """

  alias CapcutMcp.Voice.Config

  @doc """
  Resolves the output file path: `output_path` (absolute, expanded) when
  given, otherwise `dir/prefix-<timestamp><ext>`.
  """
  @spec resolve_path(String.t() | nil, String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def resolve_path(output_path, dir, prefix, ext)

  def resolve_path(output_path, _dir, _prefix, _ext) when is_binary(output_path) do
    trimmed = String.trim(output_path)

    cond do
      trimmed == "" ->
        {:error, "Invalid output_path: path is empty"}

      Path.type(trimmed) != :absolute ->
        {:error, "Invalid output_path: expected absolute path, got #{inspect(trimmed)}"}

      true ->
        {:ok, Path.expand(trimmed)}
    end
  end

  def resolve_path(nil, dir, prefix, ext) do
    {:ok, Path.join(dir, "#{prefix}-#{System.system_time(:millisecond)}#{ext}")}
  end

  @doc "Output directory for generated media when a project is involved."
  @spec project_dir(map(), String.t()) :: String.t()
  def project_dir(meta, subdir) do
    Path.join(meta.path, subdir)
  end

  @doc "Output directory fallback when no project is involved."
  @spec default_dir() :: String.t()
  def default_dir, do: Config.voice_output_dir()

  @doc "Writes the bytes, creating parent directories. Returns the absolute path."
  @spec write_file(String.t(), binary()) :: {:ok, String.t()} | {:error, String.t()}
  def write_file(path, bytes) when is_binary(path) and is_binary(bytes) do
    dir = Path.dirname(path)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, bytes) do
      {:ok, path}
    else
      {:error, reason} -> {:error, "Failed to write #{path}: #{inspect(reason)}"}
    end
  end
end
