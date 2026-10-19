defmodule CapcutMcp.Voice.GeminiTest do
  use ExUnit.Case, async: false

  import CapcutMcp.Voice.Stub

  alias CapcutMcp.Voice.Gemini

  @audio_b64 Base.encode64(<<1, 2, 3, 4>>)
  @candidates %{
    "candidates" => [
      %{
        "content" => %{"parts" => [%{"text" => "hello world"}], "role" => "model"},
        "finishReason" => "STOP"
      }
    ]
  }

  describe "generate_content/2" do
    test "errors when the API key is missing" do
      assert {:error, message} = Gemini.generate_content([%{"text" => "hi"}])
      assert message =~ "GEMINI_API_KEY"
    end

    test "posts parts and returns the candidate text" do
      put_key!(:gemini, "g-key")

      stub!(fn req ->
        assert req[:method] == :post
        assert String.contains?(req[:url], "/v1beta/models/gemini-2.5-flash:generateContent")
        assert {"x-goog-api-key", "g-key"} in req[:headers]

        body = Jason.decode!(req[:body])
        assert [%{"parts" => parts}] = body["contents"]

        assert [
                 %{"text" => "Listen:"},
                 %{"inlineData" => %{"mimeType" => "audio/mpeg", "data" => @audio_b64}}
               ] = parts

        assert body["generationConfig"] == %{}

        ok_json(200, @candidates)
      end)

      parts = [%{"text" => "Listen:"}, %{inlineData: %{mimeType: "audio/mpeg", data: @audio_b64}}]
      assert {:ok, "hello world"} = Gemini.generate_content(parts)
    end

    test "supports a custom model" do
      put_key!(:gemini, "g-key")

      stub!(fn req ->
        assert String.contains?(req[:url], "models/gemini-2.5-pro:generateContent")
        ok_json(200, @candidates)
      end)

      assert {:ok, "hello world"} =
               Gemini.generate_content([%{"text" => "hi"}], model: "gemini-2.5-pro")
    end

    test "rejects hostile model names" do
      put_key!(:gemini, "g-key")

      assert {:error, message} =
               Gemini.generate_content([%{"text" => "hi"}], model: "model/../secret")

      assert message =~ "Invalid model"
    end

    test "surfaces provider errors with the API message" do
      put_key!(:gemini, "key")
      stub!(ok_json(400, %{"error" => %{"message" => "model not found"}}))

      assert {:error, message} = Gemini.generate_content([%{"text" => "hi"}])
      assert message =~ "HTTP 400"
      assert message =~ "model not found"
    end

    test "reports blocked prompts" do
      put_key!(:gemini, "key")
      stub!(ok_json(200, %{"promptFeedback" => %{"blockReason" => "SAFETY"}}))

      assert {:error, message} = Gemini.generate_content([%{"text" => "hi"}])
      assert message =~ "SAFETY"
    end

    test "adds a rate-limit hint on 429" do
      put_key!(:gemini, "key")
      stub!(ok_json(429, %{"error" => %{"message" => "quota exceeded"}}))

      assert {:error, message} = Gemini.generate_content([%{"text" => "hi"}])
      assert message =~ "429"
    end
  end

  describe "generate_json/2" do
    test "requests JSON mime type and decodes the response" do
      put_key!(:gemini, "key")

      stub!(fn req ->
        body = Jason.decode!(req[:body])
        assert body["generationConfig"]["responseMimeType"] == "application/json"

        ok_json(200, %{
          "candidates" => [%{"content" => %{"parts" => [%{"text" => "{\"a\": 1}"}]}}]
        })
      end)

      assert {:ok, %{"a" => 1}} = Gemini.generate_json([%{"text" => "go"}])
    end

    test "tolerates markdown fences" do
      put_key!(:gemini, "key")

      fenced = "```json\n{\"transcript\": \"oi\"}\n```"

      stub!(
        ok_json(200, %{"candidates" => [%{"content" => %{"parts" => [%{"text" => fenced}]}}]})
      )

      assert {:ok, %{"transcript" => "oi"}} = Gemini.generate_json([%{"text" => "go"}])
    end

    test "reports invalid JSON" do
      put_key!(:gemini, "key")

      stub!(
        ok_json(200, %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "not json"}]}}]})
      )

      assert {:error, message} = Gemini.generate_json([%{"text" => "go"}])
      assert message =~ "invalid JSON"
    end
  end
end
