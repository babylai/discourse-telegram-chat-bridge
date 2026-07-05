# frozen_string_literal: true

module DiscourseTelegramChatBridge
  # Thin wrapper around the Telegram Bot API.
  class TelegramClient
    class ApiError < StandardError
      attr_reader :error_code, :description

      def initialize(error_code:, description:)
        @error_code = error_code
        @description = description
        super("Telegram API error #{error_code}: #{description}")
      end
    end

    BASE_URL = "https://api.telegram.org"

    def initialize(bot_token: SiteSetting.telegram_bridge_bot_token)
      @bot_token = bot_token
    end

    def send_message(chat_id:, text:, message_thread_id: nil, reply_to_message_id: nil)
      call(
        "sendMessage",
        chat_id: chat_id,
        text: text,
        parse_mode: "HTML",
        disable_web_page_preview: true,
        message_thread_id: message_thread_id,
        reply_to_message_id: reply_to_message_id,
      )
    end

    private

    def call(method, **params)
      connection = Faraday.new { |f| f.adapter FinalDestination::FaradayAdapter }

      response =
        connection.post(
          "#{BASE_URL}/bot#{@bot_token}/#{method}",
          params.compact.to_json,
          { "Content-Type" => "application/json" },
        )

      body = JSON.parse(response.body)

      if !body["ok"]
        raise ApiError.new(error_code: body["error_code"], description: body["description"])
      end

      body["result"]
    end
  end
end
