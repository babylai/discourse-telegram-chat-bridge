# frozen_string_literal: true

module DiscourseTelegramChatBridge
  # Prepended to the bridge's Sidekiq jobs: when Telegram answers HTTP 429,
  # the job is re-enqueued after the retry_after Telegram asked for,
  # instead of failing into Sidekiq's generic retry schedule. Safe because
  # every bridge job is idempotent (work already done is skipped on the
  # next run).
  module RateLimitRetry
    MAX_ATTEMPTS = 5

    def execute(args)
      super
    rescue TelegramClient::RateLimitedError => e
      attempts = args[:rate_limited_attempts].to_i + 1

      if attempts > MAX_ATTEMPTS
        Rails.logger.warn(
          "[discourse-telegram-chat-bridge] #{self.class.name} giving up after #{MAX_ATTEMPTS} rate-limited attempts",
        )
      else
        Jobs.enqueue_in(
          e.retry_after.seconds,
          self.class.name.demodulize.underscore.to_sym,
          args.to_h.symbolize_keys.merge(rate_limited_attempts: attempts),
        )
      end
    end
  end
end
