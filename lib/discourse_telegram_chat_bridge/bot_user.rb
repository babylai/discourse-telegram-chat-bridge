# frozen_string_literal: true

module DiscourseTelegramChatBridge
  # The single Discourse user that Telegram-origin chat messages are
  # posted as (using the `**Name:** text` prefix convention, since bots
  # can't post messages as arbitrary Discourse users).
  class BotUser
    USERNAME = "telegram_bridge"

    def self.ensure!
      existing = User.find_by(id: SiteSetting.telegram_bridge_bot_user_id)
      return existing if existing

      User.transaction do
        user =
          User.create!(
            id: [User.minimum(:id) - 1, -2].min,
            username: UserNameSuggester.suggest(USERNAME),
            name: "Telegram Bridge",
            email: "#{SecureRandom.hex(10)}@telegram-bridge.invalid",
            active: true,
            approved: true,
            admin: true,
            trust_level: TrustLevel[4],
          )

        SiteSetting.telegram_bridge_bot_user_id = user.id
        user
      end
    end

    def self.ensure_channel_membership!(chat_channel)
      Chat::ChannelMembershipManager.new(chat_channel).follow(ensure!)
    end
  end
end
