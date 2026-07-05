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
