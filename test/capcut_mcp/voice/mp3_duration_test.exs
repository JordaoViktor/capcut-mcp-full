defmodule CapcutMcp.Voice.Mp3DurationTest do
  use ExUnit.Case, async: true

  alias CapcutMcp.Voice.Mp3Duration

  @frame_header_mpeg1_l3_128k_44100 <<0xFF, 0xFB, 0x90>>
  @frame_header_mpeg1_l3_320k_44100 <<0xFF, 0xFB, 0xE0>>

  defp cbr_mp3(payload_bytes, header \\ @frame_header_mpeg1_l3_128k_44100) do
    header <> :binary.copy(<<0>>, payload_bytes)
  end

  defp id3_mp3(payload_bytes) do
    # ID3v2 header with syncsafe size = 10 (so 10 bytes tag + 10 header + footer 0)
    <<73, 68, 51, 3, 0, 0, 0, 0, 0, 10>> <> :binary.copy(<<0>>, 10) <> cbr_mp3(payload_bytes)
  end

  test "estimates CBR duration from file size and bitrate" do
    # 128 kbps: duration_ms = payload_bytes * 1000 / 16000 = payload/16
    assert {:ok, 1_000} == Mp3Duration.estimate(cbr_mp3(16_000))
    assert {:ok, 5_000} == Mp3Duration.estimate(cbr_mp3(80_000))
  end

  test "skips an ID3v2 tag before measuring" do
    # 20 bytes of tag → duration is based on the remaining 16_000 bytes.
    assert {:ok, 1_000} == Mp3Duration.estimate(id3_mp3(16_000))
  end

  test "honours a different bitrate (320 kbps)" do
    # 320 kbps: duration_ms = payload * 1000 / 40000 = payload/40
    assert {:ok, 1_000} ==
             Mp3Duration.estimate(cbr_mp3(40_000, @frame_header_mpeg1_l3_320k_44100))
  end

  test "uses the Xing frame count when present" do
    # MPEG1 Layer III stereo: side info is 32 bytes; Xing tag follows.
    xing =
      :binary.copy(<<0>>, 32) <>
        "Xing" <>
        <<0, 0, 0, 1>> <>
        <<0, 0, 0, 10>> <>
        :binary.copy(<<0>>, 20)

    # 10 frames * 1152 samples / 44100 Hz = ~261.2ms
    assert {:ok, duration} = Mp3Duration.estimate(@frame_header_mpeg1_l3_128k_44100 <> xing)
    assert abs(duration - 261) <= 2
  end

  test "handles MPEG2 Layer III (576 samples per frame)" do
    # 0xFF 0xF3: version bits = 10 (MPEG2), layer = 01 (III); 0x80: 64kbps, 22050Hz
    mp3 = <<0xFF, 0xF3, 0x80>> <> :binary.copy(<<0>>, 16_000)

    # 64 kbps → duration_ms = payload * 1000 / 8000 = payload / 8
    assert {:ok, 2_000} == Mp3Duration.estimate(mp3)
  end

  test "returns :error for non-mp3 data" do
    assert :error == Mp3Duration.estimate("not an mp3 at all")
    assert :error == Mp3Duration.estimate("")
    assert :error == Mp3Duration.estimate(<<0xFF>>)
  end
end
