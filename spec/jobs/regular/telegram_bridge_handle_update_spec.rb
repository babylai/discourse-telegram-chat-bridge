# frozen_string_literal: true

describe Jobs::TelegramBridgeHandleUpdate do
  it "does nothing when the plugin is disabled" do
    SiteSetting.telegram_bridge_enabled = false

    expect(DiscourseTelegramChatBridge::WebhookHandler).not_to receive(:handle_update)

    described_class.new.execute(update: { "update_id" => 1 })
  end

  it "delegates to WebhookHandler when enabled" do
    SiteSetting.telegram_bridge_enabled = true
    update = { "update_id" => 1 }

    expect(DiscourseTelegramChatBridge::WebhookHandler).to receive(:handle_update).with(update)

    described_class.new.execute(update: update)
  end
end
