# frozen_string_literal: true

module DiscourseTelegramChatBridge
  # Parses and looks up the `telegram_bridge_mappings` site setting.
  #
  # Each line maps one Discourse chat channel to one Telegram destination:
  #
  #   chat_channel_id:telegram_chat_id:telegram_thread_id
  #
  # `telegram_thread_id` is optional (a plain group without Topics, or a
  # message posted to the General topic). Discourse's own `list` site
  # setting storage joins entries with "|", so ":" is used as the
  # field separator here to avoid colliding with that.
  class Mapping
    Entry =
      Struct.new(:chat_channel_id, :telegram_chat_id, :telegram_thread_id, keyword_init: true)

    class InvalidEntryError < StandardError
    end

    def self.entries
      SiteSetting
        .telegram_bridge_mappings
        .to_s
        .split("|")
        .filter_map do |line|
          line = line.strip
          next if line.empty?

          begin
            parse!(line)
          rescue InvalidEntryError => e
            Rails.logger.warn("[discourse-telegram-chat-bridge] #{e.message}")
            nil
          end
        end
    end

    def self.for_channel(chat_channel_id)
      entries.find { |e| e.chat_channel_id == chat_channel_id.to_i }
    end

    def self.for_telegram(telegram_chat_id, telegram_thread_id = nil)
      normalized_thread_id = telegram_thread_id.presence&.to_i

      entries.find do |e|
        e.telegram_chat_id == telegram_chat_id.to_i &&
          e.telegram_thread_id == normalized_thread_id
      end
    end

    def self.parse!(line)
      fields = line.split(":").map(&:strip)

      if fields.size < 2 || fields.size > 3
        raise InvalidEntryError, "malformed mapping line (expected 2-3 fields): #{line.inspect}"
      end

      chat_channel_id, telegram_chat_id, telegram_thread_id = fields

      if !integer_string?(chat_channel_id)
        raise InvalidEntryError, "invalid chat_channel_id in mapping line: #{line.inspect}"
      end

      if !integer_string?(telegram_chat_id)
        raise InvalidEntryError, "invalid telegram_chat_id in mapping line: #{line.inspect}"
      end

      if telegram_thread_id.present? && !integer_string?(telegram_thread_id)
        raise InvalidEntryError, "invalid telegram_thread_id in mapping line: #{line.inspect}"
      end

      Entry.new(
        chat_channel_id: chat_channel_id.to_i,
        telegram_chat_id: telegram_chat_id.to_i,
        telegram_thread_id: telegram_thread_id.presence&.to_i,
      )
    end

    def self.integer_string?(value)
      value.to_s.match?(/\A-?\d+\z/)
    end
    private_class_method :integer_string?
  end
end
