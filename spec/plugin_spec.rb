# frozen_string_literal: true

describe "DiscourseTelegramChatBridge plugin hooks" do
  fab!(:channel) { Fabricate(:category_channel) }
  fab!(:user) { Fabricate(:user) }

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
end
