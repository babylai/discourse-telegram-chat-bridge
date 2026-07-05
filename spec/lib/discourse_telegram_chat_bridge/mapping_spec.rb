# frozen_string_literal: true

describe DiscourseTelegramChatBridge::Mapping do
  describe ".entries" do
    it "returns an empty array when unset" do
      SiteSetting.telegram_bridge_mappings = ""
      expect(described_class.entries).to eq([])
    end

    it "parses multiple lines, joined the way the list site setting stores them" do
      SiteSetting.telegram_bridge_mappings = "5:-1001111111111:42|7:-1002222222222"

      expect(described_class.entries).to contain_exactly(
        an_object_having_attributes(
          chat_channel_id: 5,
          telegram_chat_id: -1_001_111_111_111,
          telegram_thread_id: 42,
        ),
        an_object_having_attributes(
          chat_channel_id: 7,
          telegram_chat_id: -1_002_222_222_222,
          telegram_thread_id: nil,
        ),
      )
    end

    it "skips malformed lines instead of raising" do
      SiteSetting.telegram_bridge_mappings = "not-a-number:-100|5:-1001111111111:42"

      expect(described_class.entries).to contain_exactly(
        an_object_having_attributes(chat_channel_id: 5, telegram_thread_id: 42),
      )
    end

    it "ignores blank lines" do
      SiteSetting.telegram_bridge_mappings = "5:-1001111111111:42| |"

      expect(described_class.entries.size).to eq(1)
    end
  end

  describe ".parse!" do
    it "raises for too few or too many fields" do
      expect { described_class.parse!("5") }.to raise_error(
        DiscourseTelegramChatBridge::Mapping::InvalidEntryError,
      )
      expect { described_class.parse!("5:6:7:8") }.to raise_error(
        DiscourseTelegramChatBridge::Mapping::InvalidEntryError,
      )
    end

    it "raises for non-integer fields" do
      expect { described_class.parse!("abc:-100") }.to raise_error(
        DiscourseTelegramChatBridge::Mapping::InvalidEntryError,
      )
      expect { described_class.parse!("5:abc") }.to raise_error(
        DiscourseTelegramChatBridge::Mapping::InvalidEntryError,
      )
      expect { described_class.parse!("5:-100:abc") }.to raise_error(
        DiscourseTelegramChatBridge::Mapping::InvalidEntryError,
      )
    end
  end

  describe ".for_channel" do
    it "finds the entry for a given chat channel id" do
      SiteSetting.telegram_bridge_mappings = "5:-1001111111111:42|7:-1002222222222"

      expect(described_class.for_channel(5).telegram_thread_id).to eq(42)
      expect(described_class.for_channel(99)).to be_nil
    end
  end

  describe ".for_telegram" do
    it "finds the entry for a given telegram chat + thread id" do
      SiteSetting.telegram_bridge_mappings = "5:-1001111111111:42|7:-1002222222222"

      expect(described_class.for_telegram(-1_001_111_111_111, 42).chat_channel_id).to eq(5)
      expect(described_class.for_telegram(-1_002_222_222_222).chat_channel_id).to eq(7)
      expect(described_class.for_telegram(-1_002_222_222_222, 42)).to be_nil
    end
  end
end
