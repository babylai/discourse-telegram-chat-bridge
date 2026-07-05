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
end
