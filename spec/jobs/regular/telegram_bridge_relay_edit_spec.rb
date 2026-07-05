# frozen_string_literal: true

describe Jobs::TelegramBridgeRelayEdit do
  fab!(:message, :chat_message)

  before { allow(DiscourseTelegramChatBridge::Relay).to receive(:relay_edit_to_telegram) }

  it "does nothing when the plugin is disabled" do
    SiteSetting.telegram_bridge_enabled = false

    described_class.new.execute(chat_message_id: message.id)

    expect(DiscourseTelegramChatBridge::Relay).not_to have_received(:relay_edit_to_telegram)
  end

  it "does nothing when the message has been deleted" do
    SiteSetting.telegram_bridge_enabled = true
    message.update!(deleted_at: Time.zone.now)

    described_class.new.execute(chat_message_id: message.id)

    expect(DiscourseTelegramChatBridge::Relay).not_to have_received(:relay_edit_to_telegram)
  end

  it "delegates to Relay when enabled and the message exists" do
    SiteSetting.telegram_bridge_enabled = true

    described_class.new.execute(chat_message_id: message.id)

    expect(DiscourseTelegramChatBridge::Relay).to have_received(:relay_edit_to_telegram).with(
      an_object_having_attributes(id: message.id),
    )
  end
end
