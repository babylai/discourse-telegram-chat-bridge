# frozen_string_literal: true

class AddMediaAttachmentToTelegramBridgedMessages < ActiveRecord::Migration[8.0]
  def change
    add_column :telegram_bridged_messages, :media_attachment, :boolean, null: false, default: false
  end
end
