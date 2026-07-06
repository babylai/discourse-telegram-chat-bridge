# discourse-telegram-chat-bridge

Real-time, two-way bridge between [Discourse Chat](https://meta.discourse.org/t/discourse-chat/230881)
and Telegram, with first-class support for Telegram forum topics.

Each Discourse chat channel is mapped to a Telegram chat — either a plain
group, or a specific topic in a supergroup with Topics enabled. A message
posted on one side shows up on the other within a second or two.

## Features

| | Discourse → Telegram | Telegram → Discourse |
|---|---|---|
| Text (with formatting) | ✅ real HTML formatting | ✅ entities → Markdown |
| Replies | ✅ | ✅ |
| Edits | ✅ | ✅ |
| Deletions | ✅ | ❌ not possible (see below) |
| Photos | ✅ `sendPhoto` / albums via `sendMediaGroup` | ✅ downloaded and re-uploaded |
| Other files | ✅ `sendDocument` | ✅ documents, video, audio, voice |
| Stickers | — | ✅ static as image; animated degrade to their emoji |

- **Author attribution:** bots can't impersonate users on either platform,
  so messages carry the author as a bold prefix — `**Maria:** hello` in
  Discourse, **maria:** in Telegram (real bold via HTML parse mode, not
  literal asterisks).
- **Loop-safe:** messages posted by the bridge itself are never relayed
  back.
- **Idempotent by design:** all bridge jobs can safely run twice (Sidekiq
  is at-least-once; Telegram redelivers unacknowledged webhooks) without
  producing duplicate messages.
- **Rate-limit aware:** Telegram allows ~20 messages/minute per group. On
  HTTP 429 the job re-enqueues itself after exactly the wait Telegram asks
  for (up to 5 attempts).
- **Graceful degradation:** files too big for the Bot API (20 MB download
  / 50 MB upload) become an `[file omitted: name (size)]` note instead of
  a silent failure; unsupported formatting degrades to plain text.

### Known limitations

- **Deletions in Telegram are not synced to Discourse.** The Telegram Bot
  API has no deletion event — this is a platform limitation, not a
  configuration issue.
- Telegram only lets bots edit their own messages for 48 hours; Discourse
  edits of older messages are not reflected on the Telegram side.
- Attachment changes in a Discourse edit are not synced (the text part
  is).
- Reactions are not bridged.
- One Discourse channel maps to one Telegram chat/topic (1:1). Discourse
  chat *threads* are not mapped to Telegram topics; thread replies are
  bridged flat.

## Installation

Add the repository to your container's `app.yml` like any other plugin:

```yaml
hooks:
  after_code:
    - exec:
        cd: $home/plugins
        cmd:
          - git clone https://github.com/discourse/docker_manager.git
          - git clone https://github.com/babylai/discourse-telegram-chat-bridge.git
```

Then rebuild:

```bash
cd /var/discourse
./launcher rebuild app
```

The plugin requires the Chat plugin (bundled with Discourse core) to be
enabled.

## Setup

### 1. Create the Telegram bot

1. Create a bot via [@BotFather](https://t.me/BotFather) and copy the
   token.
2. **Disable privacy mode** (`/setprivacy` → Disable), or the bot will
   only see `/commands`, not regular group messages. ⚠️ If the bot is
   already in a group when you change this, remove and re-add it — the
   change doesn't apply to existing memberships otherwise.
3. Add the bot to your group as an **admin**. It needs
   `can_delete_messages` for deletion sync, and admin status also
   bypasses privacy mode.
4. If you want to bridge into specific topics, enable **Topics** in the
   group settings (this converts the group to a supergroup).

### 2. Configure the site settings

In Admin → Plugins → **Telegram Bridge**:

| Setting | Purpose |
|---|---|
| `telegram_bridge_enabled` | Master on/off switch. |
| `telegram_bridge_bot_token` | The token from @BotFather. |
| `telegram_bridge_webhook_secret` | A random secret of your choosing (e.g. `openssl rand -hex 24`), validated on every incoming webhook request. |
| `telegram_bridge_mappings` | The channel mappings — see step 4. |

### 3. Register the webhook

The easiest way is through the plugin's own client, which sets the
correct `allowed_updates` for you:

```bash
cd /var/discourse
./launcher enter app
rails runner "puts DiscourseTelegramChatBridge::TelegramClient.new.set_webhook(
  url: 'https://YOUR-SITE/telegram-bridge/webhook',
  secret_token: SiteSetting.telegram_bridge_webhook_secret)"
```

Verify with:

```bash
rails runner "puts DiscourseTelegramChatBridge::TelegramClient.new.get_webhook_info.inspect"
```

`url` must match your site and `allowed_updates` must list **both**
`message` and `edited_message`.

> ⚠️ `allowed_updates` is a property of the webhook registration stored
> at Telegram, not of this plugin's code. If you register the webhook
> manually (e.g. with curl) and omit `edited_message`, Telegram will
> silently never deliver edits — no error is logged anywhere. Re-running
> `set_webhook` fixes it.

### 4. Map channels

Type `/id` in any group or topic the bot can see — mapped or not. The bot
replies with the `chat_id`, the `message_thread_id` (inside a topic), and
a ready-to-paste mapping line.

Each line of `telegram_bridge_mappings` bridges one channel:

```
chat_channel_id:telegram_chat_id:telegram_thread_id
```

- `chat_channel_id` — the Discourse chat channel id, i.e. the number at
  the end of the channel URL `/chat/c/<slug>/<id>`. Always positive.
- `telegram_chat_id` — the Telegram chat id from `/id`. Negative for
  groups/supergroups.
- `telegram_thread_id` — the topic id from `/id`. Leave blank for the
  General topic or a plain group without Topics.

Example — two channels into topics of one supergroup, one into a plain
group:

```
42:-1001111111111:7
43:-1001111111111:9
7:-1002222222222
```

Lines with swapped or invalid fields are rejected and logged, not
silently accepted. On every boot and mapping change the plugin logs one
summary line — grep your logs for `active mappings` to confirm what is
actually bridged:

```
[discourse-telegram-chat-bridge] active mappings: channel 42 <-> chat -1001111111111 thread 7; ...
```

### 5. Verify

Send a message in the Discourse channel and one in the Telegram chat.
Both should appear on the opposite side within a couple of seconds. If
nothing happens, check in order: the `active mappings` log line, the
webhook info from step 3, and privacy mode from step 1.

## How it works

- **Outgoing:** the plugin subscribes to Discourse's chat events
  (`:chat_message_created` / `edited` / `trashed` / `restored`). A Sidekiq
  job renders the message to Telegram's HTML subset and calls the Bot API.
  Long messages are split at the 4096-character limit; attachments are
  uploaded as bytes (so login-protected sites work).
- **Incoming:** Telegram POSTs to `/telegram-bridge/webhook`, validated
  via the `X-Telegram-Bot-Api-Secret-Token` header. The request is
  acknowledged immediately; a Sidekiq job posts the message via
  `ChatSDK::Message.create` as a dedicated bot user, downloading any media
  via `getFile` first.
- A small `telegram_bridged_messages` table maps message ids across the
  two platforms, which is what makes replies, edits, and deletions work.
- All Telegram I/O happens in background jobs — never in the request
  cycle.

See [DESIGN.md](DESIGN.md) for the full design notes and the reasoning
behind the trade-offs.

## Privacy considerations

Content from bridged channels leaves your Discourse instance and is
stored with Telegram (and vice versa). If your site or channels are
private, make sure the members of bridged channels know. Only channels
explicitly listed in the mappings are ever bridged.

## Development

Clone into your Discourse checkout's `plugins/` directory. A full Rails
restart is required after any Ruby change — the dev file watcher only
covers JS/HBS/SCSS.

```bash
bin/rspec plugins/discourse-telegram-chat-bridge/spec
bundle exec rubocop --force-exclusion plugins/discourse-telegram-chat-bridge/
```

Bug reports and pull requests are welcome.

## License

MIT, see [LICENSE](LICENSE).
