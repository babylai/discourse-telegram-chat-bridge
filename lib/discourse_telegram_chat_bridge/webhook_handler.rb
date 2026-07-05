# frozen_string_literal: true

module DiscourseTelegramChatBridge
  # Handles a single Telegram Bot API update (webhook payload), relaying
  # plain-text messages into the mapped Discourse chat channel. M2 scope:
  # text only - edits, media and replies follow in later milestones.
  class WebhookHandler
    def self.handle_update(update)
      new(update).handle_update
    end

    def initialize(update)
      @update = update
    end

    def handle_update
      message = @update["message"]
      return if message.nil?
      return if message.dig("from", "is_bot")
      return if message["text"].blank?

      mapping = Mapping.for_telegram(message["chat"]["id"], message["message_thread_id"])
      return if mapping.nil?

      channel = Chat::Channel.find_by(id: mapping.chat_channel_id)
      return if channel.nil?

      chat_message =
        ChatSDK::Message.create(
          raw: build_raw(message),
          channel_id: channel.id,
          guardian: Guardian.new(BotUser.ensure!),
          enforce_membership: true,
        )

      TelegramBridgedMessage.create!(
        chat_message_id: chat_message.id,
        telegram_chat_id: message["chat"]["id"],
        telegram_message_id: message["message_id"],
        direction: :telegram_to_discourse,
        ordinal: 0,
      )
    end

    private

    def build_raw(message)
      first_name = message.dig("from", "first_name")
      last_name = message.dig("from", "last_name")
      name = [first_name, last_name].compact.join(" ")
      name = message.dig("from", "username").presence || "Telegram" if name.blank?

      "**#{name}:** #{MarkdownFormatter.format(message["text"], message["entities"])}"
    end
  end
end
