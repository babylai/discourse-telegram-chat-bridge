# frozen_string_literal: true

module DiscourseTelegramChatBridge
  # Handles a single Telegram Bot API update (webhook payload): new
  # messages (with replies) and edits. M3 scope - deleting a Telegram
  # message can't be relayed into Discourse at all, since the Bot API has
  # no delete event (see DESIGN.md); media follows in M4.
  class WebhookHandler
    def self.handle_update(update)
      new(update).handle_update
    end

    def initialize(update)
      @update = update
    end

    def handle_update
      if @update["edited_message"]
        handle_edited_message(@update["edited_message"])
      elsif @update["message"]
        handle_new_message(@update["message"])
      end
    end

    private

    def handle_new_message(message)
      return if message.dig("from", "is_bot")
      return if message["text"].blank?

      # Sidekiq is at-least-once and Telegram redelivers unacknowledged
      # updates - skip if this exact Telegram message was already bridged.
      return if TelegramBridgedMessage.exists?(
        telegram_chat_id: message["chat"]["id"],
        telegram_message_id: message["message_id"],
      )

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
          in_reply_to_id: reply_target_chat_message_id(message),
        )

      TelegramBridgedMessage.create!(
        chat_message_id: chat_message.id,
        telegram_chat_id: message["chat"]["id"],
        telegram_message_id: message["message_id"],
        direction: :telegram_to_discourse,
        ordinal: 0,
      )
    end

    def handle_edited_message(message)
      return if message.dig("from", "is_bot")
      return if message["text"].blank?

      bridged =
        TelegramBridgedMessage.find_by(
          telegram_chat_id: message["chat"]["id"],
          telegram_message_id: message["message_id"],
          direction: :telegram_to_discourse,
        )
      return if bridged.nil?

      chat_message = Chat::Message.find_by(id: bridged.chat_message_id)
      return if chat_message.nil?

      result =
        Chat::UpdateMessage.call(
          guardian: Guardian.new(BotUser.ensure!),
          params: {
            message_id: chat_message.id,
            channel_id: chat_message.chat_channel_id,
            message: build_raw(message),
          },
        )

      if result.failure?
        Rails.logger.warn(
          "[discourse-telegram-chat-bridge] failed to relay edit for telegram_message_id=#{message["message_id"]}: #{result.inspect_steps}",
        )
      end
    end

    def build_raw(message)
      first_name = message.dig("from", "first_name")
      last_name = message.dig("from", "last_name")
      name = [first_name, last_name].compact.join(" ")
      name = message.dig("from", "username").presence || "Telegram" if name.blank?

      "**#{name}:** #{MarkdownFormatter.format(message["text"], message["entities"])}"
    end

    # Every message inside a Telegram topic implicitly carries a
    # reply_to_message pointing at the topic's own root/creation message
    # (its message_id equals the topic's message_thread_id) - that's not a
    # real user reply and must not be treated as one.
    def reply_target_chat_message_id(message)
      reply_to = message["reply_to_message"]
      return nil if reply_to.nil?
      return nil if reply_to["message_id"] == message["message_thread_id"]

      TelegramBridgedMessage.find_by(
        telegram_chat_id: message["chat"]["id"],
        telegram_message_id: reply_to["message_id"],
      )&.chat_message_id
    end
  end
end
