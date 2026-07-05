# frozen_string_literal: true

module Jobs
  class TelegramBridgeRelayMessage < ::Jobs::Base
    def execute(args)
      return if !SiteSetting.telegram_bridge_enabled?

      message = ::Chat::Message.find_by(id: args[:chat_message_id])
      return if message.nil? || message.deleted_at.present?

      DiscourseTelegramChatBridge::Relay.relay_to_telegram(message)
    end
  end
end
