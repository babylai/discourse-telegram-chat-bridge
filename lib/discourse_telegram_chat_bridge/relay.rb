# frozen_string_literal: true

module DiscourseTelegramChatBridge
  # Relays a single Discourse chat message to its mapped Telegram
  # destination: creation (with replies and attachments), edits, and
  # deletion. Restoring a trashed message is handled by re-running
  # relay_to_telegram, since a deleted Telegram message can't be un-deleted
  # - it just sends fresh (see DESIGN.md).
  #
  # A message is relayed as a sequence of "units", each becoming one or
  # more Telegram messages with consecutive ordinals: text chunks first,
  # then attachments (photos, albums, documents), then omission notes for
  # files too big for the Bot API. Edits only touch the text units;
  # attachment changes in a Discourse edit are not synced (POC limitation).
  #
  # All entry points are idempotent: Sidekiq is at-least-once, so a job may
  # run twice after a mid-run crash, and must not produce duplicates.
  class Relay
    # Telegram error descriptions that mean "the work is already done" -
    # retrying can never succeed, so they are swallowed rather than raised.
    ALREADY_SATISFIED_ERRORS =
      /message is not modified|message to edit not found|message to delete not found/i

    # Bot API upload limits.
    MAX_PHOTO_BYTES = 10.megabytes
    MAX_UPLOAD_BYTES = 50.megabytes
    MEDIA_GROUP_LIMIT = 10

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

      units = build_units
      return if units.empty?

      client = TelegramClient.new
      already_sent_ordinals =
        TelegramBridgedMessage.where(
          chat_message_id: @message.id,
          direction: :discourse_to_telegram,
        ).pluck(:ordinal)
      reply_to = reply_target_message_id(mapping)

      next_ordinal = 0
      units.each_with_index do |unit, index|
        ordinals = (next_ordinal...(next_ordinal + unit[:count])).to_a
        next_ordinal += unit[:count]
        next if (ordinals - already_sent_ordinals).empty?

        results = send_unit(client, mapping, unit, reply_to: index.zero? ? reply_to : nil)

        TelegramBridgedMessage.transaction do
          results.each_with_index do |result, i|
            next if already_sent_ordinals.include?(ordinals[i])

            TelegramBridgedMessage.create!(
              chat_message_id: @message.id,
              telegram_chat_id: mapping.telegram_chat_id,
              telegram_message_id: result["message_id"],
              direction: :discourse_to_telegram,
              ordinal: ordinals[i],
              media_attachment: unit[:media],
            )
          end
        end
      end
    end

    def relay_edit_to_telegram
      return if bridge_bot_message?

      all_rows =
        TelegramBridgedMessage
          .where(chat_message_id: @message.id, direction: :discourse_to_telegram)
          .order(:ordinal)
          .to_a
      return if all_rows.empty?

      mapping = Mapping.for_channel(@message.chat_channel_id)
      return if mapping.nil?

      # Attachment changes are not synced - edits only maintain text rows.
      text_rows = all_rows.reject(&:media_attachment)
      texts =
        if @message.message.present?
          TelegramFormatter.format(@message.cooked, prefix: @message.user.username)
        else
          []
        end
      return if text_rows.empty? && texts.empty?

      client = TelegramClient.new
      next_free_ordinal = (all_rows.map(&:ordinal).max || -1) + 1

      texts.each_with_index do |text, index|
        existing = text_rows[index]

        if existing
          swallow_already_satisfied do
            client.edit_message_text(
              chat_id: mapping.telegram_chat_id,
              message_id: existing.telegram_message_id,
              text: text,
            )
          end
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
            ordinal: next_free_ordinal,
            media_attachment: false,
          )
          next_free_ordinal += 1
        end
      end

      # The edit shrank the message below its original number of Telegram
      # chunks - drop the now-unused trailing text messages.
      text_rows[texts.size..]&.each do |stale|
        swallow_already_satisfied do
          client.delete_message(
            chat_id: mapping.telegram_chat_id,
            message_id: stale.telegram_message_id,
          )
        end
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
        swallow_already_satisfied do
          client.delete_message(
            chat_id: bridge_row.telegram_chat_id,
            message_id: bridge_row.telegram_message_id,
          )
        end
        bridge_row.destroy!
      end
    end

    private

    # Plans the sequence of Telegram messages for this Discourse message.
    # Each unit: { kind:, count:, media:, ... } where count is how many
    # Telegram messages (and thus ordinals) the unit produces.
    def build_units
      units = []
      texts =
        if @message.message.present?
          TelegramFormatter.format(@message.cooked, prefix: @message.user.username)
        else
          []
        end
      texts.each { |text| units << { kind: :text, text: text, count: 1, media: false } }

      uploads = @message.uploads.order("uploads.id").to_a
      return units if uploads.empty?

      sendable, oversized = uploads.partition { |u| u.filesize.to_i <= MAX_UPLOAD_BYTES }
      photos, documents =
        sendable.partition do |u|
          FileHelper.is_supported_image?(u.original_filename.to_s) &&
            u.filesize.to_i <= MAX_PHOTO_BYTES
        end

      photos.each_slice(MEDIA_GROUP_LIMIT) do |slice|
        if slice.size == 1
          units << { kind: :photo, upload: slice.first, count: 1, media: true }
        else
          units << { kind: :media_group, uploads: slice, count: slice.size, media: true }
        end
      end

      documents.each { |u| units << { kind: :document, upload: u, count: 1, media: true } }

      oversized.each do |u|
        units << { kind: :text, text: omitted_note(u), count: 1, media: false }
      end

      # A message with no text still needs author attribution - caption the
      # first attachment with the bare prefix.
      if texts.empty? && (first_media = units.find { |u| u[:media] })
        first_media[:caption] = TelegramFormatter.prefix_html(@message.user.username)
      end

      units
    end

    # Returns an array of Telegram Message hashes, one per ordinal.
    def send_unit(client, mapping, unit, reply_to:)
      base = {
        chat_id: mapping.telegram_chat_id,
        message_thread_id: mapping.telegram_thread_id,
        reply_to_message_id: reply_to,
      }

      case unit[:kind]
      when :text
        [client.send_message(**base, text: unit[:text])]
      when :photo
        with_upload_io(unit[:upload]) do |io|
          [
            client.send_photo(
              **base,
              io: io,
              filename: unit[:upload].original_filename,
              caption: unit[:caption],
            ),
          ]
        end
      when :document
        with_upload_io(unit[:upload]) do |io|
          [
            client.send_document(
              **base,
              io: io,
              filename: unit[:upload].original_filename,
              caption: unit[:caption],
            ),
          ]
        end
      when :media_group
        ios = unit[:uploads].map { |u| open_upload(u) }
        begin
          entries =
            unit[:uploads].each_with_index.map do |upload, i|
              { io: ios[i], filename: upload.original_filename }
            end
          entries.first[:caption] = unit[:caption] if unit[:caption]

          client.send_media_group(
            chat_id: mapping.telegram_chat_id,
            message_thread_id: mapping.telegram_thread_id,
            reply_to_message_id: reply_to,
            entries: entries,
          )
        ensure
          ios.each(&:close)
        end
      end
    end

    def with_upload_io(upload)
      io = open_upload(upload)
      begin
        yield io
      ensure
        io.close
      end
    end

    # The site may be login-protected, so Telegram can't fetch upload URLs -
    # attachments are always sent as bytes.
    def open_upload(upload)
      if Discourse.store.external?
        Discourse.store.download!(upload)
      else
        File.open(Discourse.store.path_for(upload), "rb")
      end
    end

    def omitted_note(upload)
      size = ActiveSupport::NumberHelper.number_to_human_size(upload.filesize.to_i)
      name = CGI.escapeHTML(upload.original_filename.to_s)
      "#{TelegramFormatter.prefix_html(@message.user.username)} [file omitted: #{name} (#{size})]"
    end

    def reply_target_message_id(mapping)
      return nil if @message.in_reply_to_id.nil?

      TelegramBridgedMessage
        .where(chat_message_id: @message.in_reply_to_id, telegram_chat_id: mapping.telegram_chat_id)
        .order(:ordinal)
        .first
        &.telegram_message_id
    end

    def swallow_already_satisfied
      yield
    rescue TelegramClient::ApiError => e
      raise if !e.description.to_s.match?(ALREADY_SATISFIED_ERRORS)
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
