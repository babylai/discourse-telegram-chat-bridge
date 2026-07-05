# frozen_string_literal: true

describe DiscourseTelegramChatBridge::RateLimitRetry do
  # Exercised through a real bridge job that has the module prepended.
  fab!(:message, :chat_message)

  let(:rate_limit_error) do
    DiscourseTelegramChatBridge::TelegramClient::RateLimitedError.new(
      description: "Too Many Requests: retry after 7",
      retry_after: 7,
    )
  end

  before do
    SiteSetting.telegram_bridge_enabled = true
    allow(DiscourseTelegramChatBridge::Relay).to receive(:relay_to_telegram).and_raise(
      rate_limit_error,
    )
    allow(Jobs).to receive(:enqueue_in)
  end

  it "re-enqueues the job with Telegram's retry_after and an attempt counter" do
    Jobs::TelegramBridgeRelayMessage.new.execute(chat_message_id: message.id)

    expect(Jobs).to have_received(:enqueue_in).with(
      7.seconds,
      :telegram_bridge_relay_message,
      a_hash_including(chat_message_id: message.id, rate_limited_attempts: 1),
    )
  end

  it "increments the attempt counter across retries" do
    Jobs::TelegramBridgeRelayMessage.new.execute(
      chat_message_id: message.id,
      rate_limited_attempts: 2,
    )

    expect(Jobs).to have_received(:enqueue_in).with(
      7.seconds,
      :telegram_bridge_relay_message,
      a_hash_including(rate_limited_attempts: 3),
    )
  end

  it "gives up (without raising) after the attempt cap" do
    expect {
      Jobs::TelegramBridgeRelayMessage.new.execute(
        chat_message_id: message.id,
        rate_limited_attempts: described_class::MAX_ATTEMPTS,
      )
    }.not_to raise_error

    expect(Jobs).not_to have_received(:enqueue_in)
  end

  it "does not intercept other Telegram errors" do
    allow(DiscourseTelegramChatBridge::Relay).to receive(:relay_to_telegram).and_raise(
      DiscourseTelegramChatBridge::TelegramClient::ApiError.new(
        error_code: 400,
        description: "Bad Request",
      ),
    )

    expect {
      Jobs::TelegramBridgeRelayMessage.new.execute(chat_message_id: message.id)
    }.to raise_error(DiscourseTelegramChatBridge::TelegramClient::ApiError)

    expect(Jobs).not_to have_received(:enqueue_in)
  end
end
