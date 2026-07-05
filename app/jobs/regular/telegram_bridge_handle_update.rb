# frozen_string_literal: true

module Jobs
  class TelegramBridgeHandleUpdate < ::Jobs::Base
    prepend ::DiscourseTelegramChatBridge::RateLimitRetry

    def execute(args)
      return if !SiteSetting.telegram_bridge_enabled?

      DiscourseTelegramChatBridge::WebhookHandler.handle_update(args[:update])
    end
  end
end
