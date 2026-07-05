# frozen_string_literal: true

describe DiscourseTelegramChatBridge::BotUser do
  describe ".ensure!" do
    it "creates the bot user once and reuses it on subsequent calls" do
      expect { described_class.ensure! }.to change { User.count }.by(1)

      user = described_class.ensure!
      expect(user.username).to start_with(DiscourseTelegramChatBridge::BotUser::USERNAME)
      expect(user.id).to be < 0
      expect(SiteSetting.telegram_bridge_bot_user_id.to_i).to eq(user.id)

      expect { described_class.ensure! }.not_to change { User.count }
      expect(described_class.ensure!.id).to eq(user.id)
    end
  end

  describe ".ensure_channel_membership!" do
    it "joins the bot user to the given chat channel" do
      channel = Fabricate(:category_channel)

      membership = described_class.ensure_channel_membership!(channel)

      expect(membership.following).to eq(true)
      expect(membership.user_id).to eq(described_class.ensure!.id)
    end
  end
end
