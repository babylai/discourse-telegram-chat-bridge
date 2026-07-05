# frozen_string_literal: true

describe DiscourseTelegramChatBridge::Relay do
  fab!(:channel, :category_channel)
  fab!(:author) { Fabricate(:user, username: "maria") }
  fab!(:message) do
    Fabricate(:chat_message, chat_channel: channel, user: author, message: "hello world")
  end

  before do
    SiteSetting.telegram_bridge_mappings = "#{channel.id}:-1001111111111:42"
  end

  def stub_send_message(message_id: 999)
    stub_request(:post, %r{\Ahttps://api\.telegram\.org/bot.*/sendMessage\z}).to_return(
      status: 200,
      body: { ok: true, result: { message_id: message_id } }.to_json,
      headers: {
        "Content-Type" => "application/json",
      },
    )
  end

  describe ".relay_to_telegram" do
    it "does nothing when the channel isn't mapped" do
      SiteSetting.telegram_bridge_mappings = ""
      stub = stub_send_message

      described_class.relay_to_telegram(message)

      expect(stub).not_to have_been_requested
    end

    it "sends the message to the mapped Telegram chat + thread and records the mapping" do
      stub =
        stub_request(:post, %r{\Ahttps://api\.telegram\.org/bot.*/sendMessage\z}).with(
          body:
            hash_including(
              "chat_id" => -1_001_111_111_111,
              "message_thread_id" => 42,
              "text" => "<b>maria:</b> hello world",
            ),
        ).to_return(
          status: 200,
          body: { ok: true, result: { message_id: 555 } }.to_json,
          headers: {
            "Content-Type" => "application/json",
          },
        )

      expect { described_class.relay_to_telegram(message) }.to change {
        TelegramBridgedMessage.count
      }.by(1)

      expect(stub).to have_been_requested

      bridged = TelegramBridgedMessage.last
      expect(bridged.chat_message_id).to eq(message.id)
      expect(bridged.telegram_chat_id).to eq(-1_001_111_111_111)
      expect(bridged.telegram_message_id).to eq(555)
      expect(bridged.direction).to eq("discourse_to_telegram")
      expect(bridged.ordinal).to eq(0)
    end

    it "does not relay messages posted by the bridge bot user itself (loop prevention)" do
      bot = DiscourseTelegramChatBridge::BotUser.ensure!
      bot_message = Fabricate(:chat_message, chat_channel: channel, user: bot, message: "echo")
      stub = stub_send_message

      described_class.relay_to_telegram(bot_message)

      expect(stub).not_to have_been_requested
    end

    it "does not send again when the message was already bridged (job retry idempotency)" do
      TelegramBridgedMessage.create!(
        chat_message_id: message.id,
        telegram_chat_id: -1_001_111_111_111,
        telegram_message_id: 555,
        direction: :discourse_to_telegram,
        ordinal: 0,
      )
      stub = stub_send_message

      expect { described_class.relay_to_telegram(message) }.not_to change {
        TelegramBridgedMessage.count
      }

      expect(stub).not_to have_been_requested
    end

    it "includes reply_to_message_id when replying to a previously bridged message" do
      TelegramBridgedMessage.create!(
        chat_message_id: message.id,
        telegram_chat_id: -1_001_111_111_111,
        telegram_message_id: 111,
        direction: :discourse_to_telegram,
        ordinal: 0,
      )
      reply =
        Fabricate(
          :chat_message,
          chat_channel: channel,
          user: author,
          message: "a reply",
          in_reply_to: message,
        )

      stub =
        stub_request(:post, %r{\Ahttps://api\.telegram\.org/bot.*/sendMessage\z}).with(
          body: hash_including("reply_to_message_id" => 111),
        ).to_return(status: 200, body: { ok: true, result: { message_id: 222 } }.to_json)

      described_class.relay_to_telegram(reply)

      expect(stub).to have_been_requested
    end
  end

  describe ".relay_to_telegram with attachments" do
    def create_image_upload(fixture: "logo.png")
      UploadCreator.new(file_from_fixtures(fixture, "images"), fixture).create_for(author.id)
    end

    def stub_send_photo(message_id: 601)
      stub_request(:post, %r{\Ahttps://api\.telegram\.org/bot.*/sendPhoto\z}).to_return(
        status: 200,
        body: { ok: true, result: { message_id: message_id } }.to_json,
      )
    end

    it "sends a lone image as a captioned photo and records a media row" do
      upload = create_image_upload
      media_message =
        Fabricate(
          :chat_message,
          chat_channel: channel,
          user: author,
          message: "",
          upload_ids: [upload.id],
        )
      photo_stub = stub_send_photo
      text_stub = stub_send_message

      described_class.relay_to_telegram(media_message)

      expect(photo_stub).to have_been_requested
      expect(text_stub).not_to have_been_requested

      row = TelegramBridgedMessage.find_by(chat_message_id: media_message.id)
      expect(row.media_attachment).to eq(true)
      expect(row.ordinal).to eq(0)
    end

    it "sends text first, then the photo without a caption" do
      upload = create_image_upload
      media_message =
        Fabricate(
          :chat_message,
          chat_channel: channel,
          user: author,
          message: "look at this",
          upload_ids: [upload.id],
        )
      text_stub = stub_send_message(message_id: 600)
      photo_stub = stub_send_photo(message_id: 601)

      described_class.relay_to_telegram(media_message)

      expect(text_stub).to have_been_requested
      expect(photo_stub).to have_been_requested

      rows = TelegramBridgedMessage.where(chat_message_id: media_message.id).order(:ordinal)
      expect(rows.map(&:ordinal)).to eq([0, 1])
      expect(rows.map(&:media_attachment)).to eq([false, true])
    end

    it "sends multiple images as one media group" do
      # Two distinct fixtures - identical bytes would dedupe to one upload.
      uploads = [create_image_upload, create_image_upload(fixture: "downsized.png")]
      media_message =
        Fabricate(
          :chat_message,
          chat_channel: channel,
          user: author,
          message: "",
          upload_ids: uploads.map(&:id),
        )
      group_stub =
        stub_request(:post, %r{\Ahttps://api\.telegram\.org/bot.*/sendMediaGroup\z}).to_return(
          status: 200,
          body: { ok: true, result: [{ message_id: 61 }, { message_id: 62 }] }.to_json,
        )

      described_class.relay_to_telegram(media_message)

      expect(group_stub).to have_been_requested

      rows = TelegramBridgedMessage.where(chat_message_id: media_message.id).order(:ordinal)
      expect(rows.map(&:telegram_message_id)).to eq([61, 62])
      expect(rows.map(&:media_attachment)).to eq([true, true])
    end

    it "routes images over the photo size limit through sendDocument" do
      upload = create_image_upload
      upload.update_columns(filesize: 11.megabytes)
      media_message =
        Fabricate(
          :chat_message,
          chat_channel: channel,
          user: author,
          message: "",
          upload_ids: [upload.id],
        )
      document_stub =
        stub_request(:post, %r{\Ahttps://api\.telegram\.org/bot.*/sendDocument\z}).to_return(
          status: 200,
          body: { ok: true, result: { message_id: 71 } }.to_json,
        )

      described_class.relay_to_telegram(media_message)

      expect(document_stub).to have_been_requested
    end

    it "degrades files over the Bot API upload limit to an omission note" do
      upload = create_image_upload
      upload.update_columns(filesize: 60.megabytes)
      media_message =
        Fabricate(
          :chat_message,
          chat_channel: channel,
          user: author,
          message: "",
          upload_ids: [upload.id],
        )
      text_stub =
        stub_request(:post, %r{\Ahttps://api\.telegram\.org/bot.*/sendMessage\z}).with(
          body: %r{file omitted},
        ).to_return(status: 200, body: { ok: true, result: { message_id: 81 } }.to_json)

      described_class.relay_to_telegram(media_message)

      expect(text_stub).to have_been_requested
    end
  end

  describe ".relay_edit_to_telegram" do
    before do
      TelegramBridgedMessage.create!(
        chat_message_id: message.id,
        telegram_chat_id: -1_001_111_111_111,
        telegram_message_id: 555,
        direction: :discourse_to_telegram,
        ordinal: 0,
      )
    end

    it "edits the existing Telegram message with the new text" do
      message.update!(message: "hello world edited", cooked: "<p>hello world edited</p>")

      stub =
        stub_request(:post, %r{\Ahttps://api\.telegram\.org/bot.*/editMessageText\z}).with(
          body:
            hash_including(
              "chat_id" => -1_001_111_111_111,
              "message_id" => 555,
              "text" => "<b>maria:</b> hello world edited",
            ),
        ).to_return(status: 200, body: { ok: true, result: {} }.to_json)

      described_class.relay_edit_to_telegram(message)

      expect(stub).to have_been_requested
    end

    it "does nothing if the message was never bridged" do
      other_message =
        Fabricate(:chat_message, chat_channel: channel, user: author, message: "not bridged")
      stub = stub_request(:post, %r{\Ahttps://api\.telegram\.org/bot.*/editMessageText\z})

      described_class.relay_edit_to_telegram(other_message)

      expect(stub).not_to have_been_requested
    end

    it "swallows Telegram's 'message is not modified' error instead of failing the job" do
      stub_request(:post, %r{\Ahttps://api\.telegram\.org/bot.*/editMessageText\z}).to_return(
        status: 400,
        body: {
          ok: false,
          error_code: 400,
          description: "Bad Request: message is not modified",
        }.to_json,
      )

      expect { described_class.relay_edit_to_telegram(message) }.not_to raise_error
    end

    it "does not touch attachment rows when editing the text (regression)" do
      TelegramBridgedMessage.create!(
        chat_message_id: message.id,
        telegram_chat_id: -1_001_111_111_111,
        telegram_message_id: 556,
        direction: :discourse_to_telegram,
        ordinal: 1,
        media_attachment: true,
      )

      stub_request(:post, %r{\Ahttps://api\.telegram\.org/bot.*/editMessageText\z}).to_return(
        status: 200,
        body: { ok: true, result: {} }.to_json,
      )
      delete_stub = stub_request(:post, %r{\Ahttps://api\.telegram\.org/bot.*/deleteMessage\z})

      expect { described_class.relay_edit_to_telegram(message) }.not_to change {
        TelegramBridgedMessage.count
      }

      expect(delete_stub).not_to have_been_requested
    end

    it "deletes stale trailing chunks when the edit shrinks the message" do
      TelegramBridgedMessage.create!(
        chat_message_id: message.id,
        telegram_chat_id: -1_001_111_111_111,
        telegram_message_id: 556,
        direction: :discourse_to_telegram,
        ordinal: 1,
      )

      stub_request(:post, %r{\Ahttps://api\.telegram\.org/bot.*/editMessageText\z}).to_return(
        status: 200,
        body: {
          ok: true,
          result: {
          },
        }.to_json,
      )
      delete_stub =
        stub_request(:post, %r{\Ahttps://api\.telegram\.org/bot.*/deleteMessage\z}).with(
          body: hash_including("message_id" => 556),
        ).to_return(status: 200, body: { ok: true, result: true }.to_json)

      expect { described_class.relay_edit_to_telegram(message) }.to change {
        TelegramBridgedMessage.count
      }.by(-1)

      expect(delete_stub).to have_been_requested
    end
  end

  describe ".relay_deletion_to_telegram" do
    it "deletes all bridged Telegram messages and removes the mapping rows" do
      TelegramBridgedMessage.create!(
        chat_message_id: message.id,
        telegram_chat_id: -1_001_111_111_111,
        telegram_message_id: 555,
        direction: :discourse_to_telegram,
        ordinal: 0,
      )

      stub =
        stub_request(:post, %r{\Ahttps://api\.telegram\.org/bot.*/deleteMessage\z}).with(
          body: hash_including("message_id" => 555),
        ).to_return(status: 200, body: { ok: true, result: true }.to_json)

      expect { described_class.relay_deletion_to_telegram(message) }.to change {
        TelegramBridgedMessage.count
      }.by(-1)

      expect(stub).to have_been_requested
    end

    it "does nothing when the message was never bridged" do
      stub = stub_request(:post, %r{\Ahttps://api\.telegram\.org/bot.*/deleteMessage\z})

      described_class.relay_deletion_to_telegram(message)

      expect(stub).not_to have_been_requested
    end

    it "still cleans up the mapping row when the Telegram message is already gone" do
      TelegramBridgedMessage.create!(
        chat_message_id: message.id,
        telegram_chat_id: -1_001_111_111_111,
        telegram_message_id: 555,
        direction: :discourse_to_telegram,
        ordinal: 0,
      )

      stub_request(:post, %r{\Ahttps://api\.telegram\.org/bot.*/deleteMessage\z}).to_return(
        status: 400,
        body: {
          ok: false,
          error_code: 400,
          description: "Bad Request: message to delete not found",
        }.to_json,
      )

      expect { described_class.relay_deletion_to_telegram(message) }.to change {
        TelegramBridgedMessage.count
      }.by(-1)
    end
  end
end
