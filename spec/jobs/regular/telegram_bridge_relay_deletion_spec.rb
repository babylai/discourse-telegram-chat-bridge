# frozen_string_literal: true

describe Jobs::TelegramBridgeRelayDeletion do
  fab!(:message) { Fabricate(:chat_message) }

  it "does nothing when the plugin is disabled" do
    SiteSetting.telegram_bridge_enabled = false

    expect(DiscourseTelegramChatBridge::Relay).not_to receive(:relay_deletion_to_telegram)

    described_class.new.execute(chat_message_id: message.id)
  end

  it "still processes a deleted message (that's the whole point)" do
    SiteSetting.telegram_bridge_enabled = true
    message.update!(deleted_at: Time.zone.now)

    expect(DiscourseTelegramChatBridge::Relay).to receive(:relay_deletion_to_telegram).with(
      an_object_having_attributes(id: message.id),
    )

    described_class.new.execute(chat_message_id: message.id)
  end

  it "does nothing when the message no longer exists at all" do
    expect(DiscourseTelegramChatBridge::Relay).not_to receive(:relay_deletion_to_telegram)

    described_class.new.execute(chat_message_id: -1)
  end
end
