# frozen_string_literal: true

class TelegramBridgedMessage < ActiveRecord::Base
  enum :direction, { discourse_to_telegram: 0, telegram_to_discourse: 1 }
end
