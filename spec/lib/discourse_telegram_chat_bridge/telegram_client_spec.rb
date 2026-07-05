# frozen_string_literal: true

describe DiscourseTelegramChatBridge::TelegramClient do
  let(:client) { described_class.new(bot_token: "test-token") }

  describe "#send_message" do
    it "posts to Telegram's sendMessage endpoint and returns the parsed result" do
      stub =
        stub_request(:post, "https://api.telegram.org/bottest-token/sendMessage").with(
          body:
            hash_including(
              "chat_id" => -1_001_111_111_111,
              "text" => "hello",
              "parse_mode" => "HTML",
            ),
        ).to_return(
          status: 200,
          body: { ok: true, result: { message_id: 42 } }.to_json,
          headers: {
            "Content-Type" => "application/json",
          },
        )

      result = client.send_message(chat_id: -1_001_111_111_111, text: "hello")

      expect(result["message_id"]).to eq(42)
      expect(stub).to have_been_requested
    end

    it "includes message_thread_id and reply_to_message_id when given" do
      stub =
        stub_request(:post, "https://api.telegram.org/bottest-token/sendMessage").with(
          body: hash_including("message_thread_id" => 42, "reply_to_message_id" => 7),
        ).to_return(status: 200, body: { ok: true, result: {} }.to_json)

      client.send_message(chat_id: -100, text: "hi", message_thread_id: 42, reply_to_message_id: 7)

      expect(stub).to have_been_requested
    end

    it "omits blank optional params instead of sending them as null" do
      stub =
        stub_request(:post, "https://api.telegram.org/bottest-token/sendMessage").with { |req|
          !JSON.parse(req.body).key?("message_thread_id")
        }.to_return(status: 200, body: { ok: true, result: {} }.to_json)

      client.send_message(chat_id: -100, text: "hi")

      expect(stub).to have_been_requested
    end

    it "raises RateLimitedError with Telegram's retry_after on HTTP 429" do
      stub_request(:post, "https://api.telegram.org/bottest-token/sendMessage").to_return(
        status: 429,
        body: {
          ok: false,
          error_code: 429,
          description: "Too Many Requests: retry after 7",
          parameters: {
            retry_after: 7,
          },
        }.to_json,
      )

      expect { client.send_message(chat_id: -100, text: "hi") }.to raise_error(
        DiscourseTelegramChatBridge::TelegramClient::RateLimitedError,
      ) { |error| expect(error.retry_after).to eq(7) }
    end

    it "raises ApiError when Telegram responds with ok: false" do
      stub_request(:post, "https://api.telegram.org/bottest-token/sendMessage").to_return(
        status: 400,
        body: {
          ok: false,
          error_code: 400,
          description: "Bad Request: TOPIC_DELETED",
        }.to_json,
      )

      expect { client.send_message(chat_id: -100, text: "hi") }.to raise_error(
        DiscourseTelegramChatBridge::TelegramClient::ApiError,
        /TOPIC_DELETED/,
      )
    end
  end

  describe "#edit_message_text" do
    it "posts to Telegram's editMessageText endpoint" do
      stub =
        stub_request(:post, "https://api.telegram.org/bottest-token/editMessageText").with(
          body:
            hash_including("chat_id" => -100, "message_id" => 42, "text" => "updated", "parse_mode" => "HTML"),
        ).to_return(status: 200, body: { ok: true, result: {} }.to_json)

      client.edit_message_text(chat_id: -100, message_id: 42, text: "updated")

      expect(stub).to have_been_requested
    end
  end

  describe "#delete_message" do
    it "posts to Telegram's deleteMessage endpoint" do
      stub =
        stub_request(:post, "https://api.telegram.org/bottest-token/deleteMessage").with(
          body: hash_including("chat_id" => -100, "message_id" => 42),
        ).to_return(status: 200, body: { ok: true, result: true }.to_json)

      client.delete_message(chat_id: -100, message_id: 42)

      expect(stub).to have_been_requested
    end
  end

  describe "#send_photo" do
    it "posts multipart form data to sendPhoto" do
      stub =
        stub_request(:post, "https://api.telegram.org/bottest-token/sendPhoto").with(
          headers: {
            "Content-Type" => %r{\Amultipart/form-data},
          },
        ).to_return(status: 200, body: { ok: true, result: { message_id: 42 } }.to_json)

      result =
        client.send_photo(chat_id: -100, io: StringIO.new("bytes"), filename: "pic.png")

      expect(result["message_id"]).to eq(42)
      expect(stub).to have_been_requested
    end
  end

  describe "#send_document" do
    it "posts multipart form data to sendDocument" do
      stub =
        stub_request(:post, "https://api.telegram.org/bottest-token/sendDocument").with(
          headers: {
            "Content-Type" => %r{\Amultipart/form-data},
          },
        ).to_return(status: 200, body: { ok: true, result: { message_id: 43 } }.to_json)

      client.send_document(chat_id: -100, io: StringIO.new("bytes"), filename: "doc.pdf")

      expect(stub).to have_been_requested
    end
  end

  describe "#send_media_group" do
    it "posts multipart form data and returns the message array" do
      # WebMock can't match multipart bodies, so this only asserts the call.
      stub =
        stub_request(:post, "https://api.telegram.org/bottest-token/sendMediaGroup").with(
          headers: {
            "Content-Type" => %r{\Amultipart/form-data},
          },
        ).to_return(
          status: 200,
          body: { ok: true, result: [{ message_id: 61 }, { message_id: 62 }] }.to_json,
        )

      result =
        client.send_media_group(
          chat_id: -100,
          entries: [
            { io: StringIO.new("a"), filename: "a.png", caption: "<b>maria:</b>" },
            { io: StringIO.new("b"), filename: "b.png" },
          ],
        )

      expect(result.map { |m| m["message_id"] }).to eq([61, 62])
      expect(stub).to have_been_requested
    end
  end

  describe "#get_file" do
    it "returns the file info" do
      stub_request(:post, "https://api.telegram.org/bottest-token/getFile").with(
        body: hash_including("file_id" => "abc"),
      ).to_return(status: 200, body: { ok: true, result: { file_path: "photos/f.jpg" } }.to_json)

      expect(client.get_file(file_id: "abc")["file_path"]).to eq("photos/f.jpg")
    end
  end

  describe "#download_file" do
    it "fetches the file bytes from the file endpoint" do
      stub_request(:get, "https://api.telegram.org/file/bottest-token/photos/f.jpg").to_return(
        status: 200,
        body: "bytes",
      )

      expect(client.download_file("photos/f.jpg")).to eq("bytes")
    end

    it "raises ApiError on a non-200 response" do
      stub_request(:get, "https://api.telegram.org/file/bottest-token/photos/f.jpg").to_return(
        status: 404,
        body: "not found",
      )

      expect { client.download_file("photos/f.jpg") }.to raise_error(
        DiscourseTelegramChatBridge::TelegramClient::ApiError,
      )
    end

    it "raises RateLimitedError when the file endpoint returns 429" do
      stub_request(:get, "https://api.telegram.org/file/bottest-token/photos/f.jpg").to_return(
        status: 429,
        body: {
          ok: false,
          error_code: 429,
          description: "Too Many Requests: retry after 3",
          parameters: {
            retry_after: 3,
          },
        }.to_json,
      )

      expect { client.download_file("photos/f.jpg") }.to raise_error(
        DiscourseTelegramChatBridge::TelegramClient::RateLimitedError,
      ) { |error| expect(error.retry_after).to eq(3) }
    end
  end

  describe "#set_webhook" do
    it "posts the url and secret_token to Telegram's setWebhook endpoint" do
      stub =
        stub_request(:post, "https://api.telegram.org/bottest-token/setWebhook").with(
          body:
            hash_including(
              "url" => "https://example.com/telegram-bridge/webhook",
              "secret_token" => "shh",
            ),
        ).to_return(status: 200, body: { ok: true, result: true }.to_json)

      client.set_webhook(url: "https://example.com/telegram-bridge/webhook", secret_token: "shh")

      expect(stub).to have_been_requested
    end
  end

  describe "#get_webhook_info" do
    it "returns the parsed webhook info" do
      stub_request(:post, "https://api.telegram.org/bottest-token/getWebhookInfo").to_return(
        status: 200,
        body: { ok: true, result: { url: "https://example.com/hook" } }.to_json,
      )

      expect(client.get_webhook_info["url"]).to eq("https://example.com/hook")
    end
  end
end
