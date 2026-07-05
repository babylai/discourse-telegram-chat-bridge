# frozen_string_literal: true

module DiscourseTelegramChatBridge
  # Handles a single Telegram Bot API update (webhook payload): new
  # messages (text, replies, and media) and edits. Deleting a Telegram
  # message can't be relayed into Discourse at all, since the Bot API has
  # no delete event (see DESIGN.md).
  #
  # Media handling: photos/documents/videos/audio are downloaded via
  # getFile (Bot API limit: 20 MB) and re-uploaded to Discourse as the
  # bridge bot user. Files that can't be bridged (too big, or rejected by
  # the site's upload settings) degrade to an "[file omitted: ...]" note.
  # Static stickers are bridged as images; animated/video stickers degrade
  # to their emoji.
  class WebhookHandler
    # getFile refuses files over 20 MB.
    TELEGRAM_DOWNLOAD_LIMIT = 20.megabytes

    # `/id` (optionally `/id@BotName`) as its own first word.
    ID_COMMAND = %r{\A/id(?:@\w+)?(?:\s|\z)}

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

      body = message["text"].presence || message["caption"]

      # Setup helper: replies with the ids needed for a mapping row. Works
      # in unmapped chats/topics on purpose - that's when you need it.
      return handle_id_command(message) if body.present? && body.match?(ID_COMMAND)

      media = extract_media(message)
      return if body.blank? && media.nil?

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

      notes = []
      upload_ids = []

      if media
        if media[:fallback]
          notes << media[:fallback]
        else
          result = fetch_upload(media)
          result[:upload_id] ? upload_ids << result[:upload_id] : notes << result[:note]
        end
      end

      return if body.blank? && upload_ids.empty? && notes.empty?

      chat_message =
        ChatSDK::Message.create(
          raw: build_raw(message, body: body, notes: notes),
          channel_id: channel.id,
          guardian: Guardian.new(BotUser.ensure!),
          enforce_membership: true,
          in_reply_to_id: reply_target_chat_message_id(message),
          upload_ids: upload_ids.presence,
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

      body = message["text"].presence || message["caption"]
      return if body.blank?

      bridged =
        TelegramBridgedMessage.find_by(
          telegram_chat_id: message["chat"]["id"],
          telegram_message_id: message["message_id"],
          direction: :telegram_to_discourse,
        )
      return if bridged.nil?

      chat_message = Chat::Message.find_by(id: bridged.chat_message_id)
      return if chat_message.nil?

      # No upload_ids passed - Chat::UpdateMessage leaves existing
      # attachments untouched in that case, so a caption edit keeps the
      # bridged file.
      result =
        Chat::UpdateMessage.call(
          guardian: Guardian.new(BotUser.ensure!),
          params: {
            message_id: chat_message.id,
            channel_id: chat_message.chat_channel_id,
            message: build_raw(message, body: body),
          },
        )

      if result.failure?
        Rails.logger.warn(
          "[discourse-telegram-chat-bridge] failed to relay edit for telegram_message_id=#{message["message_id"]}: #{result.inspect_steps}",
        )
      end
    end

    def handle_id_command(message)
      chat_id = message["chat"]["id"]
      thread_id = message["message_thread_id"]

      lines = ["chat_id: <code>#{chat_id}</code>"]
      lines << "message_thread_id: <code>#{thread_id}</code>" if thread_id
      mapping_line = ["{discourse_chat_channel_id}", chat_id, thread_id].compact.join(":")
      lines << "Mapping line: <code>#{mapping_line}</code>"

      TelegramClient.new.send_message(
        chat_id: chat_id,
        message_thread_id: thread_id,
        text: lines.join("\n"),
      )
    end

    def build_raw(message, body:, notes: [])
      first_name = message.dig("from", "first_name")
      last_name = message.dig("from", "last_name")
      name = [first_name, last_name].compact.join(" ")
      name = message.dig("from", "username").presence || "Telegram" if name.blank?

      entities =
        message["text"].present? ? message["entities"] : message["caption_entities"]

      parts = []
      parts << MarkdownFormatter.format(body, entities) if body.present?
      parts.concat(notes)

      "**#{name}:** #{parts.join(" ")}".strip
    end

    # Returns nil (no media), { fallback: "..." } (bridge as text), or
    # { file_id:, filename:, size: } (downloadable file).
    def extract_media(message)
      if (sizes = message["photo"]).present?
        largest = sizes.max_by { |p| p["file_size"].to_i }
        media_file(largest, "photo_#{largest["file_unique_id"]}.jpg")
      elsif (document = message["document"])
        media_file(
          document,
          document["file_name"].presence || "document_#{document["file_unique_id"]}",
        )
      elsif (video = message["video"])
        media_file(video, video["file_name"].presence || "video_#{video["file_unique_id"]}.mp4")
      elsif (animation = message["animation"])
        media_file(
          animation,
          animation["file_name"].presence || "animation_#{animation["file_unique_id"]}.mp4",
        )
      elsif (audio = message["audio"])
        media_file(audio, audio["file_name"].presence || "audio_#{audio["file_unique_id"]}.mp3")
      elsif (voice = message["voice"])
        media_file(voice, "voice_#{voice["file_unique_id"]}.ogg")
      elsif (video_note = message["video_note"])
        media_file(video_note, "video_note_#{video_note["file_unique_id"]}.mp4")
      elsif (sticker = message["sticker"])
        if sticker["is_animated"] || sticker["is_video"]
          { fallback: sticker["emoji"].presence || "[sticker]" }
        else
          media_file(sticker, "sticker_#{sticker["file_unique_id"]}.webp")
        end
      end
    end

    def media_file(descriptor, filename)
      { file_id: descriptor["file_id"], filename: filename, size: descriptor["file_size"].to_i }
    end

    # Returns { upload_id: } on success or { note: } when the file can't be
    # bridged (too big for the Bot API, or rejected by upload settings).
    def fetch_upload(media)
      return { note: omitted_note(media) } if media[:size] > TELEGRAM_DOWNLOAD_LIMIT

      client = TelegramClient.new
      begin
        file_info = client.get_file(file_id: media[:file_id])
        data = client.download_file(file_info["file_path"])
      rescue TelegramClient::ApiError => e
        return { note: omitted_note(media) } if e.description.to_s.match?(/file is too big/i)
        raise
      end

      upload = nil
      Tempfile.create(["telegram-bridge", File.extname(media[:filename])]) do |file|
        file.binmode
        file.write(data)
        file.rewind
        upload = UploadCreator.new(file, media[:filename]).create_for(BotUser.ensure!.id)
      end

      if upload&.persisted?
        { upload_id: upload.id }
      else
        { note: omitted_note(media) }
      end
    end

    def omitted_note(media)
      size = ActiveSupport::NumberHelper.number_to_human_size(media[:size])
      "[file omitted: #{media[:filename]} (#{size})]"
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
