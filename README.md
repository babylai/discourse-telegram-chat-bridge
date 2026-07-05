# discourse-telegram-chat-bridge

Real-time, two-way bridge between [Discourse Chat](https://meta.discourse.org/t/discourse-chat/230881)
and Telegram, including Telegram forum topics.

See [DESIGN.md](DESIGN.md) for the full design, scope, and milestone plan.

## Status

M0 (skeleton) — plugin loads, site settings and channel-mapping storage
exist, and a dedicated Discourse bot user can be created and joined to
channels. No message bridging yet.

## Configuration

| Site setting | Purpose |
|---|---|
| `telegram_bridge_enabled` | Master on/off switch. |
| `telegram_bridge_bot_token` | Telegram Bot API token from [@BotFather](https://t.me/BotFather). |
| `telegram_bridge_webhook_secret` | Secret validated against Telegram's `X-Telegram-Bot-Api-Secret-Token` header. |
| `telegram_bridge_mappings` | One line per bridged channel: `chat_channel_id:telegram_chat_id:telegram_thread_id` (thread id optional). |

## Development

This plugin lives in its own repo and is loaded into a local Discourse
checkout via a symlink under `plugins/`, same as the other ageplay.dk
plugins. A full Rails restart (`bin/ember-cli -u`) is required after any
Ruby change — the dev file watcher only covers JS/HBS/SCSS.

```
bin/rspec plugins/discourse-telegram-chat-bridge/spec
```

## License

MIT, see [LICENSE](LICENSE).
