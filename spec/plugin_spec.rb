# frozen_string_literal: true

describe "DiscourseTelegramChatBridge plugin hooks" do
  fab!(:channel) { Fabricate(:category_channel) }
  fab!(:user) { Fabricate(:user) }
  fab!(:admin)

  before { SiteSetting.telegram_bridge_mappings = "#{channel.id}:-1001111111111" }

  it "enqueues a relay job when a chat message is created in a mapped channel, if enabled" do
    SiteSetting.telegram_bridge_enabled = true

    expect {
      Fabricate(:chat_message, use_service: true, chat_channel: channel, user: user, message: "hi")
    }.to change { Jobs::TelegramBridgeRelayMessage.jobs.length }.by(1)
  end

  it "does not enqueue a relay job when the plugin is disabled" do
    SiteSetting.telegram_bridge_enabled = false

    expect {
      Fabricate(:chat_message, use_service: true, chat_channel: channel, user: user, message: "hi")
    }.not_to change { Jobs::TelegramBridgeRelayMessage.jobs.length }
  end

  it "enqueues a relay-edit job when a chat message is edited, if enabled" do
    SiteSetting.telegram_bridge_enabled = true
    message = Fabricate(:chat_message, chat_channel: channel, user: user, message: "hi")
    channel.add(admin)

    expect {
      Chat::UpdateMessage.call(
        guardian: admin.guardian,
        params: {
          message_id: message.id,
          channel_id: channel.id,
          message: "hi edited",
        },
      )
    }.to change { Jobs::TelegramBridgeRelayEdit.jobs.length }.by(1)
  end

  it "enqueues a relay-deletion job when a chat message is trashed, if enabled" do
    SiteSetting.telegram_bridge_enabled = true
    message = Fabricate(:chat_message, chat_channel: channel, user: user, message: "hi")

    expect {
      Chat::TrashMessage.call(
        guardian: admin.guardian,
        params: {
          message_id: message.id,
          channel_id: channel.id,
        },
      )
    }.to change { Jobs::TelegramBridgeRelayDeletion.jobs.length }.by(1)
  end

  it "enqueues a relay job when a chat message is restored, if enabled" do
    SiteSetting.telegram_bridge_enabled = true
    message = Fabricate(:chat_message, chat_channel: channel, user: user, message: "hi")
    Chat::TrashMessage.call(
      guardian: admin.guardian,
      params: {
        message_id: message.id,
        channel_id: channel.id,
      },
    )
    Jobs::TelegramBridgeRelayMessage.jobs.clear

    expect {
      Chat::RestoreMessage.call(
        guardian: admin.guardian,
        params: {
          message_id: message.id,
          channel_id: channel.id,
        },
      )
    }.to change { Jobs::TelegramBridgeRelayMessage.jobs.length }.by(1)
  end
end
