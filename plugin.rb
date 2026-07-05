# frozen_string_literal: true

# name: discourse-telegram-chat-bridge
# about: Real-time two-way bridge between Discourse Chat and Telegram, including Telegram forum topics
# version: 0.0.1
# authors: babylai
# url: https://github.com/babylai/discourse-telegram-chat-bridge

enabled_site_setting :telegram_bridge_enabled

module ::DiscourseTelegramChatBridge
  PLUGIN_NAME = "discourse-telegram-chat-bridge"
end

require_relative "lib/discourse_telegram_chat_bridge/engine"

after_initialize do
  require_relative "lib/discourse_telegram_chat_bridge/mapping"
  require_relative "lib/discourse_telegram_chat_bridge/bot_user"
  require_relative "lib/discourse_telegram_chat_bridge/telegram_client"
  require_relative "lib/discourse_telegram_chat_bridge/telegram_formatter"
  require_relative "lib/discourse_telegram_chat_bridge/relay"
  require_relative "lib/discourse_telegram_chat_bridge/markdown_formatter"
  require_relative "lib/discourse_telegram_chat_bridge/webhook_handler"

  on(:chat_message_created) do |message, _channel, _user|
    next if !SiteSetting.telegram_bridge_enabled?

    Jobs.enqueue(:telegram_bridge_relay_message, chat_message_id: message.id)
  end

  Discourse::Application.routes.append do
    post "/telegram-bridge/webhook" => "discourse_telegram_chat_bridge/webhook#create"
  end
end
