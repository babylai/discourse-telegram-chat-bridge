# frozen_string_literal: true

require "faraday/multipart" # bundled by core with require: false

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

    # HTTP 429 - Telegram tells us exactly how long to wait (~20
    # messages/min per group). Jobs re-enqueue after retry_after instead
    # of failing into Sidekiq's generic retry schedule.
    class RateLimitedError < ApiError
      attr_reader :retry_after

      def initialize(description:, retry_after:)
        @retry_after = retry_after
        super(error_code: 429, description: description)
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

    def edit_message_text(chat_id:, message_id:, text:)
      call(
        "editMessageText",
        chat_id: chat_id,
        message_id: message_id,
        text: text,
        parse_mode: "HTML",
        disable_web_page_preview: true,
      )
    end

    def delete_message(chat_id:, message_id:)
      call("deleteMessage", chat_id: chat_id, message_id: message_id)
    end

    def send_photo(chat_id:, io:, filename:, caption: nil, message_thread_id: nil, reply_to_message_id: nil)
      call_multipart(
        "sendPhoto",
        chat_id: chat_id,
        message_thread_id: message_thread_id,
        reply_to_message_id: reply_to_message_id,
        caption: caption,
        parse_mode: caption ? "HTML" : nil,
        photo: file_part(io, filename),
      )
    end

    def send_document(chat_id:, io:, filename:, caption: nil, message_thread_id: nil, reply_to_message_id: nil)
      call_multipart(
        "sendDocument",
        chat_id: chat_id,
        message_thread_id: message_thread_id,
        reply_to_message_id: reply_to_message_id,
        caption: caption,
        parse_mode: caption ? "HTML" : nil,
        document: file_part(io, filename),
      )
    end

    # entries: array of { io:, filename:, caption: (optional) } - photos only.
    # Returns the array of sent Message objects.
    def send_media_group(chat_id:, entries:, message_thread_id: nil, reply_to_message_id: nil)
      media =
        entries.each_with_index.map do |entry, index|
          {
            type: "photo",
            media: "attach://file#{index}",
            caption: entry[:caption],
            parse_mode: entry[:caption] ? "HTML" : nil,
          }.compact
        end

      params = {
        chat_id: chat_id,
        message_thread_id: message_thread_id,
        reply_to_message_id: reply_to_message_id,
        media: media.to_json,
      }
      entries.each_with_index do |entry, index|
        params[:"file#{index}"] = file_part(entry[:io], entry[:filename])
      end

      call_multipart("sendMediaGroup", **params)
    end

    def get_file(file_id:)
      call("getFile", file_id: file_id)
    end

    def download_file(file_path)
      connection = Faraday.new { |f| f.adapter FinalDestination::FaradayAdapter }
      response = connection.get("#{BASE_URL}/file/bot#{@bot_token}/#{file_path}")

      return response.body if response.status == 200

      begin
        parse_response(response) # raises Rate/ApiError from the JSON error body
      rescue JSON::ParserError
        nil
      end

      raise ApiError.new(error_code: response.status, description: "file download failed")
    end

    def set_webhook(url:, secret_token:)
      call(
        "setWebhook",
        url: url,
        secret_token: secret_token,
        allowed_updates: %w[message edited_message],
      )
    end

    def delete_webhook
      call("deleteWebhook")
    end

    def get_webhook_info
      call("getWebhookInfo")
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

      parse_response(response)
    end

    def call_multipart(method, **params)
      connection =
        Faraday.new do |f|
          f.request :multipart
          f.adapter FinalDestination::FaradayAdapter
        end

      response = connection.post("#{BASE_URL}/bot#{@bot_token}/#{method}", params.compact)

      parse_response(response)
    end

    def parse_response(response)
      body = JSON.parse(response.body)

      return body["result"] if body["ok"]

      if body["error_code"] == 429
        raise RateLimitedError.new(
          description: body["description"],
          retry_after: (body.dig("parameters", "retry_after") || 30).to_i.clamp(1, 3600),
        )
      end

      raise ApiError.new(error_code: body["error_code"], description: body["description"])
    end

    def file_part(io, filename)
      content_type = MiniMime.lookup_by_filename(filename)&.content_type || "application/octet-stream"
      Faraday::Multipart::FilePart.new(io, content_type, filename)
    end
  end
end
