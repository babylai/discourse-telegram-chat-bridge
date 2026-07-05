# discourse-telegram-chat-bridge

Real-time, two-way bridge between [Discourse Chat](https://meta.discourse.org/t/discourse-chat/230881)
and Telegram, including Telegram forum topics.

See [DESIGN.md](DESIGN.md) for the full design, scope, and milestone plan.

## Status

Feature-complete for the POC (M0–M5): two-way text bridging with
replies, edits both ways, Discourse→Telegram deletion, media both ways
(photos, albums, documents, with graceful degradation for oversized
files), rate-limit backoff, an `/id` setup command, and a boot log of
active mappings.

## How it works

Each Discourse chat channel is mapped to a Telegram chat — either a plain
group, or a specific topic in a supergroup with Topics enabled
(`message_thread_id`). Outgoing messages are picked up via Discourse's chat
events and sent through the Telegram Bot API; incoming messages arrive on a
secret-validated webhook and are posted by a dedicated bot user as
`**Name:** text`.

Telegram deletions are **not** synced into Discourse: the Bot API provides
no deletion event. Deletions sync Discourse→Telegram only.

## Configuration

| Site setting | Purpose |
|---|---|
| `telegram_bridge_enabled` | Master on/off switch. |
| `telegram_bridge_bot_token` | Telegram Bot API token from [@BotFather](https://t.me/BotFather). |
| `telegram_bridge_webhook_secret` | Secret validated against Telegram's `X-Telegram-Bot-Api-Secret-Token` header. |
| `telegram_bridge_mappings` | One line per bridged channel: `chat_channel_id:telegram_chat_id:telegram_thread_id` (thread id optional). |

### Finding the ids: the `/id` command

Type `/id` in any group or topic the bot can see (mapped or not). The bot
replies with the `chat_id`, the `message_thread_id` (in a topic), and a
ready-to-paste mapping line — fill in the Discourse chat channel id.

### Rate limits

Telegram allows roughly 20 messages/minute per group. When the bridge is
told to slow down (HTTP 429), the job re-enqueues itself after the wait
Telegram asked for, up to 5 attempts per message. All bridge jobs are
idempotent, so retries never duplicate messages.

### Telegram bot setup

1. Create a bot via [@BotFather](https://t.me/BotFather) and copy the token.
2. **Disable privacy mode** (`/setprivacy` → Disable), or the bot only sees
   `/commands`. If the bot is already in the group, remove and re-add it —
   the change doesn't apply to existing memberships otherwise.
3. Add the bot to the group as an **admin** (it needs `can_delete_messages`
   for deletion sync, and admin also bypasses privacy mode).
4. Register the webhook:
   `POST https://api.telegram.org/bot<token>/setWebhook` with
   `url=https://<your-site>/telegram-bridge/webhook`,
   `secret_token=<telegram_bridge_webhook_secret>` and
   `allowed_updates=["message","edited_message"]`.

## Development

Clone into your Discourse checkout's `plugins/` directory. A full Rails
restart is required after any Ruby change — the dev file watcher only
covers JS/HBS/SCSS.

```
bin/rspec plugins/discourse-telegram-chat-bridge/spec
```

## License

MIT, see [LICENSE](LICENSE).
