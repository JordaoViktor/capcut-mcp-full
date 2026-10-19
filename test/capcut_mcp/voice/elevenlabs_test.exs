defmodule CapcutMcp.Voice.ElevenLabsTest do
  use ExUnit.Case, async: false

  import CapcutMcp.Voice.Stub

  alias CapcutMcp.Voice.ElevenLabs

  @fake_mp3 <<73, 68, 51, 3, 0, 0, 0, 0, 0, 10>> <> :binary.copy(<<0>>, 100)

  describe "text_to_speech/2" do
    test "errors with a helpful message when the API key is missing" do
      assert {:error, message} = ElevenLabs.text_to_speech("hello")
      assert message =~ "ELEVENLABS_API_KEY"
    end

    test "rejects empty text" do
      put_key!(:elevenlabs, "key")
      assert {:error, message} = ElevenLabs.text_to_speech("   ")
      assert message =~ "text is empty"
    end

    test "rejects unknown output formats" do
      put_key!(:elevenlabs, "key")

      assert {:error, message} = ElevenLabs.text_to_speech("hello", output_format: "wav_999")
      assert message =~ "output_format"
    end

    test "posts the TTS request and returns audio bytes" do
      put_key!(:elevenlabs, "key-123")

      stub!(fn req ->
        assert req[:method] == :post

        assert req[:url] ==
                 "https://api.elevenlabs.io/v1/text-to-speech/21m00Tcm4TlvDq8ikWAM?output_format=mp3_44100_128"

        assert {"xi-api-key", "key-123"} in req[:headers]

        body = Jason.decode!(req[:body])
        assert body["text"] == "Olá time"
        assert body["model_id"] == "eleven_multilingual_v2"
        assert body["voice_settings"]["stability"] == 0.5

        ok(200, @fake_mp3)
      end)

      assert {:ok,
              %{
                audio: @fake_mp3,
                output_format: "mp3_44100_128",
                voice_id: "21m00Tcm4TlvDq8ikWAM"
              }} =
               ElevenLabs.text_to_speech("Olá time")
    end

    test "surfaces API errors as readable messages" do
      put_key!(:elevenlabs, "bad-key")
      stub!(ok_json(401, %{"detail" => %{"message" => "invalid api key"}}))

      assert {:error, message} = ElevenLabs.text_to_speech("hello")
      assert message =~ "HTTP 401"
      assert message =~ "invalid api key"
    end

    test "resolves voice_name via the voices endpoint" do
      put_key!(:elevenlabs, "key")

      stub!([
        {fn req -> String.contains?(req[:url], "/v1/voices") end,
         ok_json(200, %{
           "voices" => [
             %{"voice_id" => "voiceabc12345", "name" => "Rachel", "category" => "premade"}
           ]
         })},
        {fn req -> String.contains?(req[:url], "/v1/text-to-speech/voiceabc12345") end,
         ok(200, @fake_mp3)}
      ])

      assert {:ok, %{voice_id: "voiceabc12345"}} =
               ElevenLabs.text_to_speech("hello", voice_name: "rachel")
    end

    test "reports available voices when voice_name does not match" do
      put_key!(:elevenlabs, "key")

      stub!([
        {fn req -> String.contains?(req[:url], "/v1/voices") end,
         ok_json(200, %{
           "voices" => [
             %{"voice_id" => "voiceabc12345", "name" => "Rachel"},
             %{"voice_id" => "voicedef67890", "name" => "Adam"}
           ]
         })}
      ])

      assert {:error, message} = ElevenLabs.text_to_speech("hello", voice_name: " nonexistent ")
      assert message =~ "not found"
      assert message =~ "Rachel"
      assert message =~ "Adam"
    end
  end

  describe "list_voices/1" do
    test "returns parsed voices" do
      put_key!(:elevenlabs, "key")

      stub!(fn req ->
        assert req[:method] == :get
        assert String.ends_with?(req[:url], "/v1/voices")

        ok_json(200, %{
          "voices" => [
            %{
              "voice_id" => "abc123",
              "name" => "Rachel",
              "category" => "premade",
              "labels" => %{"accent" => "american"}
            }
          ]
        })
      end)

      assert {:ok,
              [
                %{
                  voice_id: "abc123",
                  name: "Rachel",
                  category: "premade",
                  labels: %{"accent" => "american"}
                }
              ]} =
               ElevenLabs.list_voices()
    end

    test "surfaces HTTP errors" do
      put_key!(:elevenlabs, "key")
      stub!(ok(500, "boom"))

      assert {:error, message} = ElevenLabs.list_voices()
      assert message =~ "HTTP 500"
    end
  end
end
