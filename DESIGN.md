# Discourse Chat ↔ Telegram bridge — design & plan

*Status: in development. POC target: staff/admin channels.*

## 1. Purpose and decisions

Real-time, two-way synchronization between Discourse Chat and Telegram.

Decisions made 2026-07-05:

| Topic | Decision |
|---|---|
| Topology | **2 Telegram supergroups** (one SFW, one NSFW) with Topics enabled. Discourse chat channels are mapped manually to (group, topic) pairs via a configuration list. |
| Architecture | **A dedicated Discourse plugin** — no external service. |
| Identity T→D | **A single bot user** in Discourse; Telegram messages are posted as `**Maria:** text`. |
| Identity D→T | The Telegram bot posts the author as **real bold text** via Telegram's `parse_mode: HTML` (`<b>nicolai:</b> text`), not literal markdown asterisks (bots cannot impersonate users). |
| Scope | Text both ways, **edits both ways**, **deletions D→T only** (the Bot API has no deletion event), **images/files both ways**, **replies/quotes both ways**. |
| First deliverable | A POC bridging the staff channels to one topic in each supergroup. |

Plugin name: **`discourse-telegram-chat-bridge`**. Deployed to production
via a `git clone` line in the site's container config (`app.yml`), like any
other Discourse plugin.

## 2. Research summary

### The Discourse side (core, mid-2026)

- The chat plugin is bundled into core and fires `DiscourseEvent` hooks that
  a plugin can subscribe to with `on(:event) { ... }` — **no monkey-patching**:
  - `:chat_message_created` (create_message.rb)
  - `:chat_message_edited` (update_message.rb)
  - `:chat_message_trashed` (trash_message.rb)
  - `:chat_message_restored` (restore_message.rb)
- **`ChatSDK::Message.create(raw:, channel_id:, guardian:, in_reply_to_id:, upload_ids:, enforce_membership:)`**
  is the semi-official API for creating chat messages from plugins (used by
  discourse-ai). Editing/deletion don't exist in the SDK — for those the
  service objects are called directly: `Chat::UpdateMessage.call(...)` /
  `Chat::TrashMessage.call(...)` (the same entry points the controllers use).
- Core's *incoming chat webhooks* (`/chat/hooks/:key.json`) are too limited
  (only `text`, 2000 chars, fixed identity) — not used.
- The bundled chat-integration plugin only relays *forum posts*, not chat —
  not relevant.

### The Telegram side (Bot API)

- **Outgoing:** `sendMessage`/`sendPhoto`/`sendDocument`/`sendMediaGroup`,
  `editMessageText`/`editMessageCaption`, `deleteMessage`. Formatting via
  `parse_mode: HTML` (small tag subset: b/i/u/s/a/code/pre/blockquote).
- **Incoming:** webhook (`setWebhook` → HTTPS endpoint, validated via
  `secret_token`, echoed in the `X-Telegram-Bot-Api-Secret-Token` header) or
  `getUpdates` long-polling. The bot must have **privacy mode disabled** (via
  BotFather) or be a group admin to see all messages. Note: a privacy-mode
  change only takes effect for groups the bot is already in after the bot is
  removed and re-added.
- **Topics:** In a supergroup with Topics, every message carries a
  `message_thread_id`; messages in "General" have none. Sending into a topic
  means setting `message_thread_id` on sendMessage. The bot can create topics
  (`createForumTopic`, requires admin with `can_manage_topics`) — not needed
  in the POC, where the mapping is manual.
- **Hard limitations:**
  - Bots cannot set a per-message name/avatar → the name-prefix convention.
  - **No deletion event** → deletions cannot be synced T→D.
  - Bots never receive other bots' (or their own) messages → free loop
    protection on the Telegram side.
  - Rate limits: ~30 messages/s globally, **~20 messages/min per group**.
  - File downloads via `getFile` are limited to 20 MB.

### Existing solutions

- **[discourse-chat-bridge (Lhcfl)](https://meta.discourse.org/t/discourse-chat-bridge-telegram/284691)**
  ([GitHub](https://github.com/Lhcfl/discourse-chat-bridge), MIT): two-way,
  images, replies, edits — but last commit Jan 2025, built on monkey-patching
  from before ChatSDK matured, requires the very latest `tests-passed`, and
  **no topics support**. Used as a code reference (especially
  markdown↔Telegram conversion), not as a base.
- Other sources:
  [Telegram Bot API](https://core.telegram.org/bots/api),
  [create_message.rb](https://github.com/discourse/discourse/blob/main/plugins/chat/app/services/chat/create_message.rb),
  [ChatSDK](https://github.com/discourse/discourse/blob/main/plugins/chat/lib/chat_sdk/message.rb),
  [chat webhook documentation](https://meta.discourse.org/t/discourse-chat-webhook-documentation/258667),
  [chat-integration docs](https://github.com/discourse/discourse-developer-docs/blob/main/docs/04-plugins/09-chat-integration.md).

## 3. Architecture

```
Discourse (production container)
┌─────────────────────────────────────────────┐
│ discourse-telegram-chat-bridge (plugin)     │
│                                             │
│ OUTGOING                                    │
│  on(:chat_message_created/edited/trashed/   │
│     restored)                               │
│    └→ filter on mapping + skip bot user     │
│    └→ Sidekiq job ──HTTP──→ Telegram Bot API│
│                                             │
│ INCOMING                                    │
│  POST /telegram-bridge/webhook  ←── Telegram│
│    └→ validate secret_token                 │
│    └→ look up (chat_id, thread_id) mapping  │
│    └→ Sidekiq job → ChatSDK::Message.create │
│                     / Chat::UpdateMessage   │
│                                             │
│ DB: telegram_bridged_messages (id mapping)  │
└─────────────────────────────────────────────┘
```

All Telegram I/O happens in Sidekiq jobs (never in the request cycle), with
retries and respect for `retry_after` on HTTP 429.

### Configuration (site settings, POC)

| Setting | Type | Contents |
|---|---|---|
| `telegram_bridge_enabled` | bool | master switch |
| `telegram_bridge_bot_token` | secret | one bot, member + admin in both supergroups |
| `telegram_bridge_webhook_secret` | secret | validated against the Telegram header |
| `telegram_bridge_mappings` | list | rows of `chat_channel_id:telegram_chat_id:telegram_thread_id` — empty thread id = General/plain group |

**Correction from the M0 implementation:** the field separator within each
mapping row is `:`, not `\|`. Discourse's own `type: list` storage joins the
rows themselves with `\|` (confirmed in
`site_setting_extension.rb`/`type_supervisor.rb`), so a `\|` inside a row
would collide with it.

The SFW/NSFW separation lives entirely in the mapping rows (two different
`telegram_chat_id`s). The plugin creates a dedicated Discourse bot user
(`telegram_bridge_bot_user_id`, username `telegram_bridge*`) on demand —
not on every boot, mirroring discourse-ai's pattern for its spam-scanner
user — and ensures membership of the mapped channels via
`Chat::ChannelMembershipManager`.

### Data model

Migration: table `telegram_bridged_messages`

| column | type | note |
|---|---|---|
| `chat_message_id` | bigint, indexed | Discourse message |
| `telegram_chat_id` | bigint | supergroup |
| `telegram_message_id` | bigint | unique together with chat_id |
| `direction` | smallint | 0 = D→T, 1 = T→D |
| `ordinal` | smallint | one Discourse message can become several Telegram messages (albums, >4096 chars) |

This table drives replies (look up the counterpart id), edits and deletions.

### Loop protection

- T→D messages are created by the `telegram_bridge` user → outgoing hooks
  ignore all messages from that user in mapped channels.
- Telegram never delivers the bot its own messages → no loop that way.

## 4. Flows

### Discourse → Telegram

1. Hook fires, channel is looked up in the mapping (otherwise ignore), the
   bot user is skipped.
2. The job renders: `**{username}:** ` + `cooked` HTML converted to the
   Telegram HTML subset (mentions → `@name` as plain text, unsupported tags
   stripped, > 4096 chars split into multiple messages).
3. Uploads: images → `sendPhoto`/`sendMediaGroup`, everything else →
   `sendDocument`. **Files are uploaded as bytes** (downloaded from the
   Discourse store first) — URLs won't do, since the site may be
   login-protected.
4. Reply: `message.in_reply_to_id` → look up the Telegram id →
   `reply_to_message_id`.
5. `message_thread_id` comes from the mapping. The resulting ids are stored
   in the mapping table.
6. Edit → `editMessageText`/`editMessageCaption` on ordinal 0. Deletion →
   `deleteMessage` (all ordinals). Restore → send anew (Telegram cannot
   un-delete) and update the mapping.

### Telegram → Discourse

1. The webhook request is validated (secret header), 200 is returned
   immediately, the payload is put on a Sidekiq job.
2. `(chat.id, message_thread_id || nil)` is looked up in the mapping — an
   unknown topic is logged and ignored. Service messages (joins, topic
   events) are ignored.
3. Sender name = `first_name last_name` (fallback `@username`). Telegram
   *entities* (bold/italic/link/code) are converted to markdown.
4. `ChatSDK::Message.create(raw: "**Maria:** …", channel_id:, guardian: bot,
   in_reply_to_id: <mapped id>, upload_ids:, enforce_membership: true)`.
5. Media: `getFile` → download (≤ 20 MB) → `UploadCreator` → `upload_ids`.
   Stickers: static webp is sent as an image; animated `.tgs` → emoji
   fallback. Oversized files → a message with "[file omitted, {size}]".
6. An `edited_message` update → look up the mapping → `Chat::UpdateMessage`.
   (Deletion T→D is impossible — documented limitation.)

### Topics — how they fit

Telegram topics are long-lived "rooms" inside one supergroup and therefore
map to **Discourse chat channels 1:1** — that's the core idea of the
mapping. They deliberately do *not* map to Discourse chat threads (which are
ephemeral and created per message); in the POC, thread replies are bridged
flat as a reply to the thread's root message.

Practical POC helper: the bot replies to the `/id` command in a topic with
the `chat_id` + `message_thread_id`, making mapping rows easy to look up.

## 5. Edge cases and known limitations

- **Deletion in Telegram** never reaches Discourse (no Bot API event).
  Accepted.
- **Edit window:** Telegram only allows editing bot messages for 48 hours;
  older Discourse edits get an "(edited: …)" follow-up message or are
  ignored (POC: ignore + log).
- **Reactions** are out of scope (can be added later; Bot API ≥ 7.0 supports
  reaction updates).
- **Rate limits:** a burst in a busy channel can hit 20/min per group → jobs
  back off on 429 and preserve per-channel ordering (a Sidekiq queue per
  mapping, or sequential retry).
- **Formatting loss** both ways (tables, spoilers, oneboxes etc.) — degrade
  gracefully to text/links.
- **Webhook in dev:** the dev environment has no public HTTPS → a hidden
  setting switches to `getUpdates` polling (rake task
  `telegram_bridge:poll`) so E2E can be tested locally.

## 6. Security and privacy

- The webhook rejects requests without the correct
  `X-Telegram-Bot-Api-Secret-Token`.
- The bot token lives as a secret site setting in the DB — **not** in the
  container config.
- Only explicitly mapped channels are bridged. The biggest real risk is a
  **misconfigured mapping row** (NSFW channel → SFW group); mitigation: few
  rows, review on change, and a boot log line summarizing active mappings.
- Content leaves the login-protected forum and is stored with Telegram —
  that is the whole point, but members of bridged channels should be told.
- Uploads are bridged as bytes; no internal URLs (which would require login
  anyway) are leaked.

## 7. POC plan (milestones)

| # | Milestone | Contents | Acceptance criterion |
|---|---|---|---|
| M0 ✅ | Skeleton | Plugin skeleton, settings, mapping parser, bot user, migration | Plugin boots in dev without errors — verified 2026-07-05 on the test site |
| M1 ✅ | D→T text | Event hooks, Sidekiq job, Telegram client (Faraday), mapping writes | A message in a mapped channel shows up in the right topic — **live-verified 2026-07-05** against a real supergroup topic |
| M2 ✅ | T→D text | Webhook route, secret validation, ChatSDK, entities→markdown | A Telegram message lands in the channel as `**Name:** text` in real time — **live-verified 2026-07-05** with a real `setWebhook` against the test site |
| M3 ✅ | Replies, edits, deletion (D→T) | Full use of the mapping table | Edit/delete/reply reflected correctly — 77 specs green; D→T reply/edit/delete **live-verified 2026-07-05**; T→D reply/edit live check pending |
| M4 ✅ | Media | Images/files both ways, albums, size limits | Photos both ways; oversized files degrade gracefully — 99 specs green; live smoke test pending |
| M5 | Hardening + production POC | 429 backoff, `/id` command, boot log of mappings, README; production deploy | Staff channels running against both supergroups in production |

Testing: RSpec on renderer/mapping with WebMock against the Bot API; manual
E2E in dev via polling mode. Dev gotcha: changes to `plugin.rb`/Ruby require
a full Rails restart.

## 8. Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Core changes chat events/SDK signatures | Medium | Small code surface; only official hooks; `.discourse-compatibility`; plugin lives in its own repo so hotfixes are easy |
| Rate limits in busy channels | Medium | Backoff + per-channel queue; the POC is low-traffic (staff) |
| Formatting fidelity eaten by edge cases | High (but low harm) | Degrade to plain text; grow the converter iteratively |
| SFW/NSFW mapping mistake | Low | Boot log + manual review |
