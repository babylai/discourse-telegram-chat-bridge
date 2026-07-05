# frozen_string_literal: true

class CreateTelegramBridgedMessages < ActiveRecord::Migration[8.0]
  def change
    create_table :telegram_bridged_messages do |t|
      t.bigint :chat_message_id, null: false
      t.bigint :telegram_chat_id, null: false
      t.bigint :telegram_message_id, null: false
      t.integer :direction, null: false
      t.integer :ordinal, null: false, default: 0
      t.timestamps null: false
    end

    add_index :telegram_bridged_messages, :chat_message_id

    add_index :telegram_bridged_messages,
              %i[telegram_chat_id telegram_message_id],
              unique: true,
              name: "idx_telegram_bridged_messages_on_telegram_ids"
  end
end
