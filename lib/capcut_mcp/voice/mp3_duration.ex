defmodule CapcutMcp.Voice.Mp3Duration do
  @moduledoc """
  Estimates the playback duration (ms) of an MP3 file from its raw bytes,
  without any decoder dependency.

  Strategy:

    1. Skip an ID3v2 tag when present (syncsafe size at bytes 6..9).
    2. Find the first valid MPEG frame header and read its bitrate.
    3. If the first frame carries a Xing/Info header (VBR), use its frame
       count for an exact duration; otherwise treat the file as CBR and
       divide the remaining payload size by the bitrate.

  This is exact for CBR files (ElevenLabs MP3 output is CBR) and a good
  approximation for VBR files without a Xing header. When parsing fails,
  callers should fall back to a caller-provided duration.
  """

  import Bitwise

  # Bitrate kbps tables (index 0 = free, 15 = invalid): [MPEG1 L3, MPEG2/2.5 L3]
  @mpeg1_l3_bitrates [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
  @mpeg2_l3_bitrates [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]

  # Sample rate tables per MPEG version: {MPEG1, MPEG2, MPEG2.5} × index.
  @sample_rates %{
    0b11 => [44_100, 48_000, 32_000],
    0b10 => [22_050, 24_000, 16_000],
    0b00 => [11_025, 12_000, 8_000]
  }

  @spec estimate(binary()) :: {:ok, non_neg_integer()} | :error
  def estimate(bytes) when is_binary(bytes) and byte_size(bytes) > 4 do
    offset = id3v2_skip(bytes)

    case first_frame(offset, bytes) do
      {start, frame} ->
        duration =
          case xing_frames(bytes, start, frame) do
            {:ok, frames} -> frames_to_ms(frames, frame.sample_rate, frame.samples_per_frame)
            :error -> cbr_ms(bytes, offset, frame)
          end

        if duration > 0, do: {:ok, duration}, else: :error

      nil ->
        :error
    end
  end

  def estimate(_), do: :error

  defp id3v2_skip(
         <<"ID3", _major::8, _minor::8, flags::8, b1::8, b2::8, b3::8, b4::8, _rest::binary>>
       ) do
    size = (b1 &&& 0x7F) <<< 21 ||| (b2 &&& 0x7F) <<< 14 ||| (b3 &&& 0x7F) <<< 7 ||| (b4 &&& 0x7F)
    footer = if Bitwise.band(flags, 0x10) != 0, do: 10, else: 0
    10 + size + footer
  end

  defp id3v2_skip(_bytes), do: 0

  defp first_frame(from, bytes) do
    max_start = max(0, byte_size(bytes) - 3)
    scan_frame(max(from, 0), max_start, bytes)
  end

  defp scan_frame(start, max_start, _bytes) when start > max_start, do: nil

  defp scan_frame(start, max_start, bytes) do
    case parse_frame(bytes, start) do
      nil -> scan_frame(start + 1, max_start, bytes)
      frame -> {start, frame}
    end
  end

  defp parse_frame(bytes, start) do
    window = :binary.part(bytes, start, 3)

    case window do
      <<0xFF::8, second::8, third::8>> ->
        version_bits = Bitwise.band(second, 0x18) >>> 3
        bitrate_index = Bitwise.band(third, 0xF0) >>> 4
        samplerate_index = Bitwise.band(third, 0x0C) >>> 2

        with {:ok, samples_per_frame} <- samples_per_frame(version_bits),
             {:ok, bitrate} <- bitrate(version_bits, bitrate_index),
             {:ok, sample_rate} <- sample_rate(version_bits, samplerate_index) do
          %{bitrate: bitrate, sample_rate: sample_rate, samples_per_frame: samples_per_frame}
        else
          _error -> nil
        end

      _ ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  defp samples_per_frame(0b11), do: {:ok, 1152}
  defp samples_per_frame(_), do: {:ok, 576}

  defp bitrate(0b11, idx) when idx in 1..14, do: {:ok, Enum.at(@mpeg1_l3_bitrates, idx)}
  defp bitrate(_, idx) when idx in 1..14, do: {:ok, Enum.at(@mpeg2_l3_bitrates, idx)}
  defp bitrate(_, _), do: :error

  defp sample_rate(version, index) when is_map_key(@sample_rates, version) and index in 0..2,
    do: {:ok, @sample_rates |> Map.fetch!(version) |> Enum.at(index)}

  defp sample_rate(_, _), do: :error

  defp xing_frames(bytes, frame_start, _frame) do
    # The Xing/Info tag sits after the 4-byte frame header + Layer III side
    # info (17/32 bytes for MPEG1, 9/17 for MPEG2), followed by the 4-byte
    # flags and the 4-byte frame count — 64 bytes of window covers it all.
    case xing_tag_window(bytes, frame_start) do
      nil -> :error
      window -> xing_frame_count(window)
    end
  end

  defp xing_tag_window(bytes, frame_start) do
    from = frame_start + 4
    window_size = min(64, max(0, byte_size(bytes) - from))

    if window_size < 8 do
      nil
    else
      :binary.part(bytes, from, window_size)
    end
  end

  defp xing_frame_count(window) do
    case :binary.match(window, ["Xing", "Info"]) do
      {index, 4} when index >= 0 ->
        tag = :binary.part(window, index, byte_size(window) - index)
        count_from_xing_tag(tag)

      :nomatch ->
        :error
    end
  end

  defp count_from_xing_tag(<<_tag::binary-size(4), flags::32, rest::binary>>) do
    if Bitwise.band(flags, 0x1) != 0 and byte_size(rest) >= 4 do
      <<frames::32, _::binary>> = rest
      {:ok, frames}
    else
      :error
    end
  end

  defp count_from_xing_tag(_), do: :error

  defp frames_to_ms(frames, sample_rate, samples_per_frame)
       when is_integer(frames) and frames > 0 and is_integer(sample_rate) and sample_rate > 0 do
    round(frames * samples_per_frame / sample_rate * 1000)
  end

  defp frames_to_ms(_, _, _), do: :error

  defp cbr_ms(bytes, offset, frame) do
    payload = max(0, byte_size(bytes) - offset)

    if frame.bitrate > 0 do
      round(payload * 8 / (frame.bitrate * 1000) * 1000)
    else
      :error
    end
  end
end
