# frozen_string_literal: true

describe DiscourseTelegramChatBridge::WebhookHandler do
  fab!(:channel, :category_channel)

  before { SiteSetting.telegram_bridge_mappings = "#{channel.id}:-1001111111111:42" }

  def build_update(
    message_id: 555,
    text: "hello world",
    thread_id: 42,
    entities: nil,
    from: nil,
    reply_to_message_id: nil
  )
    {
      "update_id" => 1,
      "message" => {
        "message_id" => message_id,
        "date" => Time.zone.now.to_i,
        "chat" => {
          "id" => -1_001_111_111_111,
        },
        "message_thread_id" => thread_id,
        "text" => text,
        "entities" => entities,
        "from" => from || { "id" => 999, "is_bot" => false, "first_name" => "Maria" },
        "reply_to_message" =>
          (
            if reply_to_message_id
              { "message_id" => reply_to_message_id, "message_thread_id" => thread_id }
            end
          ),
      }.compact,
    }
  end

  def build_edit_update(message_id: 555, text: "hello world edited", entities: nil, from: nil)
    {
      "update_id" => 2,
      "edited_message" => {
        "message_id" => message_id,
        "date" => Time.zone.now.to_i,
        "chat" => {
          "id" => -1_001_111_111_111,
        },
        "message_thread_id" => 42,
        "text" => text,
        "entities" => entities,
        "from" => from || { "id" => 999, "is_bot" => false, "first_name" => "Maria" },
      }.compact,
    }
  end

  describe ".handle_update" do
    it "creates a chat message in the mapped channel and records the mapping" do
      expect {
        described_class.handle_update(build_update)
      }.to change { Chat::Message.where(chat_channel_id: channel.id).count }.by(1).and change {
              TelegramBridgedMessage.count
            }.by(1)

      message = Chat::Message.where(chat_channel_id: channel.id).last
      expect(message.message).to eq("**Maria:** hello world")

      bridged = TelegramBridgedMessage.last
      expect(bridged.telegram_chat_id).to eq(-1_001_111_111_111)
      expect(bridged.telegram_message_id).to eq(555)
      expect(bridged.direction).to eq("telegram_to_discourse")
      expect(bridged.chat_message_id).to eq(message.id)
    end

    it "prefers the Telegram username when no name is set" do
      described_class.handle_update(
        build_update(from: { "id" => 999, "is_bot" => false, "username" => "mariaB" }),
      )

      expect(Chat::Message.where(chat_channel_id: channel.id).last.message).to eq(
        "**mariaB:** hello world",
      )
    end

    it "applies entities as Discourse markdown" do
      described_class.handle_update(
        build_update(entities: [{ "type" => "bold", "offset" => 0, "length" => 5 }]),
      )

      expect(Chat::Message.where(chat_channel_id: channel.id).last.message).to eq(
        "**Maria:** **hello** world",
      )
    end

    it "does nothing when there's no mapping for the chat/thread" do
      expect {
        described_class.handle_update(build_update(thread_id: 999))
      }.not_to change { Chat::Message.count }
    end

    it "does nothing for updates without a message (e.g. my_chat_member)" do
      expect { described_class.handle_update({ "update_id" => 1 }) }.not_to change {
        Chat::Message.count
      }
    end

    it "ignores messages without text (e.g. stickers, service messages)" do
      expect { described_class.handle_update(build_update(text: nil)) }.not_to change {
        Chat::Message.count
      }
    end

    it "ignores messages sent by other bots" do
      expect {
        described_class.handle_update(
          build_update(from: { "id" => 1, "is_bot" => true, "first_name" => "OtherBot" }),
        )
      }.not_to change { Chat::Message.count }
    end

    it "sets in_reply_to_id when replying to a previously bridged message" do
      original = Fabricate(:chat_message, chat_channel: channel, message: "original")
      TelegramBridgedMessage.create!(
        chat_message_id: original.id,
        telegram_chat_id: -1_001_111_111_111,
        telegram_message_id: 111,
        direction: :discourse_to_telegram,
        ordinal: 0,
      )

      described_class.handle_update(
        build_update(message_id: 556, text: "a reply", reply_to_message_id: 111),
      )

      reply = Chat::Message.where(chat_channel_id: channel.id).last
      expect(reply.in_reply_to_id).to eq(original.id)
    end

    it "does not treat the topic's own root message as a reply" do
      # Telegram sets reply_to_message to the topic's creation message on
      # every message in that topic - its message_id equals the thread id.
      described_class.handle_update(
        build_update(message_id: 556, text: "just a topic message", reply_to_message_id: 42),
      )

      reply = Chat::Message.where(chat_channel_id: channel.id).last
      expect(reply.in_reply_to_id).to be_nil
    end

    it "relays an edited Telegram message as a Discourse edit" do
      described_class.handle_update(build_update)
      original = Chat::Message.where(chat_channel_id: channel.id).last

      described_class.handle_update(build_edit_update(text: "hello world edited"))

      expect(original.reload.message).to eq("**Maria:** hello world edited")
    end

    it "ignores edits for messages that were never bridged" do
      expect { described_class.handle_update(build_edit_update) }.not_to change {
        Chat::Message.count
      }
    end

    it "does not create a duplicate when the same update is processed twice (redelivery)" do
      described_class.handle_update(build_update)

      expect { described_class.handle_update(build_update) }.not_to change { Chat::Message.count }
    end
  end

  describe ".handle_update with media" do
    def build_media_update(message_id: 700, caption: nil, **media_fields)
      {
        "update_id" => 3,
        "message" => {
          "message_id" => message_id,
          "date" => Time.zone.now.to_i,
          "chat" => {
            "id" => -1_001_111_111_111,
          },
          "message_thread_id" => 42,
          "caption" => caption,
          "from" => {
            "id" => 999,
            "is_bot" => false,
            "first_name" => "Maria",
          },
          **media_fields,
        }.compact,
      }
    end

    def stub_photo_download
      stub_request(:post, %r{\Ahttps://api\.telegram\.org/bot.*/getFile\z}).to_return(
        status: 200,
        body: { ok: true, result: { file_path: "photos/file_2.jpg" } }.to_json,
      )
      stub_request(:get, %r{\Ahttps://api\.telegram\.org/file/bot.*/photos/file_2\.jpg\z}).to_return(
        status: 200,
        body: file_from_fixtures("logo.png", "images").read,
      )
    end

    let(:photo_field) do
      {
        "photo" => [
          { "file_id" => "small", "file_unique_id" => "u1", "file_size" => 100 },
          { "file_id" => "large", "file_unique_id" => "u2", "file_size" => 5000 },
        ],
      }
    end

    it "downloads a photo and attaches it to the created chat message" do
      stub_photo_download

      expect { described_class.handle_update(build_media_update(**photo_field)) }.to change {
        Chat::Message.where(chat_channel_id: channel.id).count
      }.by(1)

      message = Chat::Message.where(chat_channel_id: channel.id).last
      expect(message.uploads.count).to eq(1)
      expect(message.message).to eq("**Maria:**")
    end

    it "uses the caption (with entities) as the message text" do
      stub_photo_download

      described_class.handle_update(
        build_media_update(
          caption: "nice pic",
          "caption_entities" => [{ "type" => "bold", "offset" => 0, "length" => 4 }],
          **photo_field,
        ),
      )

      message = Chat::Message.where(chat_channel_id: channel.id).last
      expect(message.message).to eq("**Maria:** **nice** pic")
      expect(message.uploads.count).to eq(1)
    end

    it "degrades animated stickers to their emoji" do
      described_class.handle_update(
        build_media_update(
          "sticker" => {
            "file_id" => "s1",
            "file_unique_id" => "su1",
            "is_animated" => true,
            "emoji" => "😀",
          },
        ),
      )

      message = Chat::Message.where(chat_channel_id: channel.id).last
      expect(message.message).to eq("**Maria:** 😀")
      expect(message.uploads.count).to eq(0)
    end

    it "degrades files over the download limit to an omission note without calling getFile" do
      get_file_stub = stub_request(:post, %r{\Ahttps://api\.telegram\.org/bot.*/getFile\z})

      described_class.handle_update(
        build_media_update(
          "document" => {
            "file_id" => "d1",
            "file_unique_id" => "du1",
            "file_name" => "big.bin",
            "file_size" => 25.megabytes,
          },
        ),
      )

      message = Chat::Message.where(chat_channel_id: channel.id).last
      expect(message.message).to include("[file omitted: big.bin")
      expect(get_file_stub).not_to have_been_requested
    end

    it "degrades to a note when Telegram refuses the download as too big" do
      stub_request(:post, %r{\Ahttps://api\.telegram\.org/bot.*/getFile\z}).to_return(
        status: 400,
        body: {
          ok: false,
          error_code: 400,
          description: "Bad Request: file is too big",
        }.to_json,
      )

      described_class.handle_update(
        build_media_update(
          "document" => {
            "file_id" => "d1",
            "file_unique_id" => "du1",
            "file_name" => "big.bin",
          },
        ),
      )

      message = Chat::Message.where(chat_channel_id: channel.id).last
      expect(message.message).to include("[file omitted: big.bin")
    end
  end
end
