# frozen_string_literal: true

module Jobs
  class TelegramBridgeRelayDeletion < ::Jobs::Base
    prepend ::DiscourseTelegramChatBridge::RateLimitRetry

    def execute(args)
      return if !SiteSetting.telegram_bridge_enabled?

      message = ::Chat::Message.with_deleted.find_by(id: args[:chat_message_id])
      return if message.nil?

      DiscourseTelegramChatBridge::Relay.relay_deletion_to_telegram(message)
    end
  end
end
