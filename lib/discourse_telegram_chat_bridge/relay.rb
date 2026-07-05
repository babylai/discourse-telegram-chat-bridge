# frozen_string_literal: true

module DiscourseTelegramChatBridge
  # Relays a single Discourse chat message to its mapped Telegram
  # destination. M1 scope: plain text only - replies, edits, deletions and
  # media follow in later milestones (see DESIGN.md).
  class Relay
    def self.relay_to_telegram(message)
      new(message).relay_to_telegram
    end

    def initialize(message)
      @message = message
    end

    def relay_to_telegram
      return if bridge_bot_message?

      mapping = Mapping.for_channel(@message.chat_channel_id)
      return if mapping.nil?

      texts = TelegramFormatter.format(@message.cooked, prefix: @message.user.username)

      texts.each_with_index do |text, ordinal|
        result =
          TelegramClient.new.send_message(
            chat_id: mapping.telegram_chat_id,
            message_thread_id: mapping.telegram_thread_id,
            text: text,
          )

        TelegramBridgedMessage.create!(
          chat_message_id: @message.id,
          telegram_chat_id: mapping.telegram_chat_id,
          telegram_message_id: result["message_id"],
          direction: :discourse_to_telegram,
          ordinal: ordinal,
        )
      end
    end

    private

    # Messages posted by the bridge itself (once T->D exists, M2) must
    # never be relayed back out - avoids an infinite loop. Reads the bot
    # user id without creating it, since a bot that has never received a
    # Telegram-origin message yet simply can't be the author of anything.
    def bridge_bot_message?
      bot_user_id = SiteSetting.telegram_bridge_bot_user_id.presence&.to_i
      bot_user_id.present? && @message.user_id == bot_user_id
    end
  end
end
