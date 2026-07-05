# frozen_string_literal: true

module DiscourseTelegramChatBridge
  class WebhookController < ::ApplicationController
    requires_plugin PLUGIN_NAME

    skip_before_action :check_xhr
    skip_before_action :verify_authenticity_token
    skip_before_action :redirect_to_login_if_required

    def create
      return head :forbidden if !valid_secret?

      request.body.rewind
      update = JSON.parse(request.body.read)
      Jobs.enqueue(:telegram_bridge_handle_update, update: update)

      head :ok
    end

    private

    def valid_secret?
      secret = SiteSetting.telegram_bridge_webhook_secret
      return false if secret.blank?

      header = request.headers["X-Telegram-Bot-Api-Secret-Token"]
      return false if header.blank?

      ActiveSupport::SecurityUtils.secure_compare(header, secret)
    end
  end
end
