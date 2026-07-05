# frozen_string_literal: true

module DiscourseTelegramChatBridge
  # Relays a single Discourse chat message to its mapped Telegram
  # destination: creation (with replies), edits, and deletion. Restoring a
  # trashed message is handled by re-running relay_to_telegram, since a
  # deleted Telegram message can't be un-deleted - it just sends fresh
  # (see DESIGN.md). Media follows in M4.
  class Relay
    def self.relay_to_telegram(message)
      new(message).relay_to_telegram
    end

    def self.relay_edit_to_telegram(message)
      new(message).relay_edit_to_telegram
    end

    def self.relay_deletion_to_telegram(message)
      new(message).relay_deletion_to_telegram
    end

    def initialize(message)
      @message = message
    end

    def relay_to_telegram
      return if bridge_bot_message?

      mapping = Mapping.for_channel(@message.chat_channel_id)
      return if mapping.nil?

      texts = TelegramFormatter.format(@message.cooked, prefix: @message.user.username)
      client = TelegramClient.new

      texts.each_with_index do |text, ordinal|
        result =
          client.send_message(
            chat_id: mapping.telegram_chat_id,
            message_thread_id: mapping.telegram_thread_id,
            text: text,
            reply_to_message_id: ordinal.zero? ? reply_target_message_id(mapping) : nil,
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

    def relay_edit_to_telegram
      return if bridge_bot_message?

      bridged =
        TelegramBridgedMessage
          .where(chat_message_id: @message.id, direction: :discourse_to_telegram)
          .order(:ordinal)
          .to_a
      return if bridged.empty?

      mapping = Mapping.for_channel(@message.chat_channel_id)
      return if mapping.nil?

      texts = TelegramFormatter.format(@message.cooked, prefix: @message.user.username)
      client = TelegramClient.new

      texts.each_with_index do |text, ordinal|
        existing = bridged[ordinal]

        if existing
          client.edit_message_text(
            chat_id: mapping.telegram_chat_id,
            message_id: existing.telegram_message_id,
            text: text,
          )
        else
          # The edit grew the message past its original number of Telegram
          # chunks - send the extra chunk(s) as new messages.
          result =
            client.send_message(
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

      # The edit shrank the message below its original number of Telegram
      # chunks - drop the now-unused trailing ones.
      bridged
        .select { |bridge_row| bridge_row.ordinal >= texts.size }
        .each do |stale|
          client.delete_message(chat_id: mapping.telegram_chat_id, message_id: stale.telegram_message_id)
          stale.destroy!
        end
    end

    def relay_deletion_to_telegram
      bridged = TelegramBridgedMessage.where(
        chat_message_id: @message.id,
        direction: :discourse_to_telegram,
      )
      return if bridged.empty?

      client = TelegramClient.new

      bridged.each do |bridge_row|
        client.delete_message(
          chat_id: bridge_row.telegram_chat_id,
          message_id: bridge_row.telegram_message_id,
        )
        bridge_row.destroy!
      end
    end

    private

    def reply_target_message_id(mapping)
      return nil if @message.in_reply_to_id.nil?

      TelegramBridgedMessage
        .where(chat_message_id: @message.in_reply_to_id, telegram_chat_id: mapping.telegram_chat_id)
        .order(:ordinal)
        .first
        &.telegram_message_id
    end

    # Messages posted by the bridge itself must never be relayed back out -
    # avoids an infinite loop. Reads the bot user id without creating it,
    # since a bot that has never received a Telegram-origin message yet
    # simply can't be the author of anything.
    def bridge_bot_message?
      bot_user_id = SiteSetting.telegram_bridge_bot_user_id.presence&.to_i
      bot_user_id.present? && @message.user_id == bot_user_id
    end
  end
end
