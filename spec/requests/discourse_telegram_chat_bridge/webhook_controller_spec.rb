# frozen_string_literal: true

describe DiscourseTelegramChatBridge::WebhookController do
  let(:webhook_secret) { "test-secret" }
  let(:payload) { { "update_id" => 1, "message" => { "text" => "hi" } } }

  before do
    SiteSetting.telegram_bridge_enabled = true
    SiteSetting.telegram_bridge_webhook_secret = webhook_secret
  end

  def post_update(secret_header:)
    headers = { "CONTENT_TYPE" => "application/json" }
    headers["X-Telegram-Bot-Api-Secret-Token"] = secret_header if secret_header
    post "/telegram-bridge/webhook", params: payload.to_json, headers: headers
  end

  context "when the plugin is disabled" do
    before { SiteSetting.telegram_bridge_enabled = false }

    it "returns 404" do
      post_update(secret_header: webhook_secret)
      expect(response.status).to eq(404)
    end
  end

  context "with a missing secret header" do
    it "returns 403 and does not enqueue a job" do
      expect { post_update(secret_header: nil) }.not_to change {
        Jobs::TelegramBridgeHandleUpdate.jobs.size
      }
      expect(response.status).to eq(403)
    end
  end

  context "with an incorrect secret header" do
    it "returns 403 and does not enqueue a job" do
      expect { post_update(secret_header: "wrong") }.not_to change {
        Jobs::TelegramBridgeHandleUpdate.jobs.size
      }
      expect(response.status).to eq(403)
    end
  end

  context "with malformed JSON" do
    it "returns 400 and does not enqueue a job" do
      expect {
        post "/telegram-bridge/webhook",
             params: "{not json",
             headers: {
               "CONTENT_TYPE" => "text/plain",
               "X-Telegram-Bot-Api-Secret-Token" => webhook_secret,
             }
      }.not_to change { Jobs::TelegramBridgeHandleUpdate.jobs.size }
      expect(response.status).to eq(400)
    end
  end

  context "with the correct secret header" do
    it "returns 200 and enqueues the update for processing" do
      expect { post_update(secret_header: webhook_secret) }.to change {
        Jobs::TelegramBridgeHandleUpdate.jobs.size
      }.by(1)
      expect(response.status).to eq(200)

      enqueued_update = Jobs::TelegramBridgeHandleUpdate.jobs.last["args"].first["update"]
      expect(enqueued_update).to eq(payload)
    end
  end
end
