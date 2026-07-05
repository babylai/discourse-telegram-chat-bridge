# frozen_string_literal: true

describe DiscourseTelegramChatBridge::WebhookHandler do
  fab!(:channel) { Fabricate(:category_channel) }

  before { SiteSetting.telegram_bridge_mappings = "#{channel.id}:-1001111111111:42" }

  def build_update(text: "hello world", thread_id: 42, entities: nil, from: nil)
    {
      "update_id" => 1,
      "message" => {
        "message_id" => 555,
        "date" => Time.zone.now.to_i,
        "chat" => {
          "id" => -1_001_111_111_111,
        },
        "message_thread_id" => thread_id,
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
  end
end
