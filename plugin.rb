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
end
