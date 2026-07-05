# frozen_string_literal: true

describe Jobs::TelegramBridgeHandleUpdate do
  before { allow(DiscourseTelegramChatBridge::WebhookHandler).to receive(:handle_update) }

  it "does nothing when the plugin is disabled" do
    SiteSetting.telegram_bridge_enabled = false

    described_class.new.execute(update: { "update_id" => 1 })

    expect(DiscourseTelegramChatBridge::WebhookHandler).not_to have_received(:handle_update)
  end

  it "delegates to WebhookHandler when enabled" do
    SiteSetting.telegram_bridge_enabled = true
    update = { "update_id" => 1 }

    described_class.new.execute(update: update)

    expect(DiscourseTelegramChatBridge::WebhookHandler).to have_received(:handle_update).with(
      update,
    )
  end
end
