# frozen_string_literal: true

describe Jobs::TelegramBridgeRelayDeletion do
  fab!(:message, :chat_message)

  before { allow(DiscourseTelegramChatBridge::Relay).to receive(:relay_deletion_to_telegram) }

  it "does nothing when the plugin is disabled" do
    SiteSetting.telegram_bridge_enabled = false

    described_class.new.execute(chat_message_id: message.id)

    expect(DiscourseTelegramChatBridge::Relay).not_to have_received(:relay_deletion_to_telegram)
  end

  it "still processes a deleted message (that's the whole point)" do
    SiteSetting.telegram_bridge_enabled = true
    message.update!(deleted_at: Time.zone.now)

    described_class.new.execute(chat_message_id: message.id)

    expect(DiscourseTelegramChatBridge::Relay).to have_received(:relay_deletion_to_telegram).with(
      an_object_having_attributes(id: message.id),
    )
  end

  it "does nothing when the message no longer exists at all" do
    SiteSetting.telegram_bridge_enabled = true

    described_class.new.execute(chat_message_id: -1)

    expect(DiscourseTelegramChatBridge::Relay).not_to have_received(:relay_deletion_to_telegram)
  end
end
