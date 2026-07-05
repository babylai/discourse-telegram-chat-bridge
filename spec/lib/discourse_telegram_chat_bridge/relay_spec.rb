# frozen_string_literal: true

describe DiscourseTelegramChatBridge::Relay do
  fab!(:channel) { Fabricate(:category_channel) }
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
  end
end
