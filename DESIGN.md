# Discourse Chat ↔ Telegram bridge — design & plan

*Status: designfase, besluttet 2026-07-05. POC-mål: admin-grupperne.*

## 1. Formål og besluttede rammer

Realtids-tovejssynkronisering mellem Discourse Chat på ageplay.dk og Telegram.

Beslutninger truffet 2026-07-05:

| Emne | Beslutning |
|---|---|
| Topologi | **2 Telegram-supergrupper** (én SFW, én NSFW) med Topics slået til. Discourse-chatkanaler mappes manuelt til (gruppe, topic)-par via en konfigurationsliste. |
| Arkitektur | **Eget Discourse-plugin** — ingen ekstern service. |
| Identitet T→D | **Én bot-bruger** i Discourse; Telegram-beskeder postes som `**Maria:** tekst`. |
| Identitet D→T | Telegram-botten poster med `**nicolai:** tekst` (bots kan ikke udgive sig for brugere). |
| Omfang | Tekst begge veje, **redigeringer begge veje**, **sletninger kun D→T** (Bot API har ingen sletnings-event), **billeder/filer begge veje**, **replies/citater begge veje**. |
| Første leverance | POC der bridger admin-kanalerne til ét topic i hver supergruppe. |

Arbejdsnavn for pluginet: **`discourse-telegram-chat-bridge`** (bemærk:
`babylai/discourse-chat-bridge` er allerede optaget af en gammel, urørt fork
af Lhcfl's plugin fra jan. 2025 — bruges ikke som base, jf. §2). Deployes i
prod via `ageplay.yml` fra en fork under egen kontrol (babylai/DaVania-mønstret).

## 2. Research-resumé

### Discourse-siden (core, medio 2026)

- Chat-pluginet er bundlet i core og udsender `DiscourseEvent`-hooks, som et
  plugin kan abonnere på med `on(:event) { ... }` — **ingen monkey-patching**:
  - `:chat_message_created` (create_message.rb)
  - `:chat_message_edited` (update_message.rb)
  - `:chat_message_trashed` (trash_message.rb)
  - `:chat_message_restored` (restore_message.rb)
- **`ChatSDK::Message.create(raw:, channel_id:, guardian:, in_reply_to_id:, upload_ids:, enforce_membership:)`**
  er den semi-officielle API til at oprette chatbeskeder fra plugins (bruges af
  discourse-ai). Redigering/sletning findes ikke i SDK'en — dér kaldes
  service-objekterne direkte: `Chat::UpdateMessage.call(...)` /
  `Chat::TrashMessage.call(...)` (samme indgange som controllerne bruger).
- Core's *incoming chat webhooks* (`/chat/hooks/:key.json`) er for begrænsede
  (kun `text`, 2000 tegn, fast identitet) — bruges ikke.
- Det bundlede chat-integration-plugin sender kun *forumindlæg*, ikke chat —
  ikke relevant.

### Telegram-siden (Bot API)

- **Udgående:** `sendMessage`/`sendPhoto`/`sendDocument`/`sendMediaGroup`,
  `editMessageText`/`editMessageCaption`, `deleteMessage`. Formatering via
  `parse_mode: HTML` (lille tag-subset: b/i/u/s/a/code/pre/blockquote).
- **Indgående:** webhook (`setWebhook` → HTTPS-endpoint, valideret med
  `secret_token`, echoes i headeren `X-Telegram-Bot-Api-Secret-Token`) eller
  `getUpdates` long-polling. Botten skal have **privacy mode slået fra** (via
  BotFather) eller være gruppe-admin for at se alle beskeder.
- **Topics:** I en supergruppe med Topics har hver besked et
  `message_thread_id`; beskeder i "General" har intet. Man sender ind i et
  topic ved at sætte `message_thread_id` på sendMessage. Botten kan oprette
  topics (`createForumTopic`, kræver admin med `can_manage_topics`) — ikke
  nødvendigt i POC, hvor mapping er manuel.
- **Hårde begrænsninger:**
  - Bots kan ikke sætte navn/avatar pr. besked → navnepræfiks-konvention.
  - **Ingen event ved sletning** → sletninger kan ikke synkroniseres T→D.
  - Bots modtager aldrig andre bots' (eller egne) beskeder → gratis
    loop-beskyttelse på Telegram-siden.
  - Rate limits: ~30 beskeder/s globalt, **~20 beskeder/min pr. gruppe**.
  - Fil-download via `getFile` er begrænset til 20 MB.

### Eksisterende løsninger

- **[discourse-chat-bridge (Lhcfl)](https://meta.discourse.org/t/discourse-chat-bridge-telegram/284691)**
  ([GitHub](https://github.com/Lhcfl/discourse-chat-bridge), MIT): tovejs,
  billeder, replies, redigeringer — men sidste commit jan. 2025, bygger på
  monkey-patching fra før ChatSDK modnede, kræver nyeste `tests-passed`, og
  **ingen topics-support**. Bruges som kodereference (især
  markdown↔Telegram-konvertering), ikke som base.
- Kilder i øvrigt:
  [Telegram Bot API](https://core.telegram.org/bots/api),
  [create_message.rb](https://github.com/discourse/discourse/blob/main/plugins/chat/app/services/chat/create_message.rb),
  [ChatSDK](https://github.com/discourse/discourse/blob/main/plugins/chat/lib/chat_sdk/message.rb),
  [chat webhook-dokumentation](https://meta.discourse.org/t/discourse-chat-webhook-documentation/258667),
  [chat-integration-docs](https://github.com/discourse/discourse-developer-docs/blob/main/docs/04-plugins/09-chat-integration.md).

## 3. Arkitektur

```
Discourse (prod-container "ageplay")
┌─────────────────────────────────────────────┐
│ discourse-telegram-bridge (plugin)          │
│                                             │
│ UDGÅENDE                                    │
│  on(:chat_message_created/edited/trashed/   │
│     restored)                               │
│    └→ filtrér på mapping + skip bot-bruger  │
│    └→ Sidekiq-job ──HTTP──→ Telegram Bot API│
│                                             │
│ INDGÅENDE                                   │
│  POST /telegram-bridge/webhook  ←── Telegram│
│    └→ valider secret_token                  │
│    └→ slå (chat_id, thread_id) op i mapping │
│    └→ Sidekiq-job → ChatSDK::Message.create │
│                     / Chat::UpdateMessage   │
│                                             │
│ DB: telegram_bridged_messages (id-mapping)  │
└─────────────────────────────────────────────┘
```

Alt Telegram-I/O sker i Sidekiq-jobs (aldrig i request-cyklussen), med retry og
`retry_after`-respekt ved HTTP 429.

### Konfiguration (site settings, POC)

| Setting | Type | Indhold |
|---|---|---|
| `telegram_bridge_enabled` | bool | master-switch |
| `telegram_bridge_bot_token` | secret | én bot, medlem+admin i begge supergrupper |
| `telegram_bridge_webhook_secret` | secret | valideres mod Telegram-headeren |
| `telegram_bridge_mappings` | list | rækker af `chat_channel_id\|telegram_chat_id\|message_thread_id` — tom thread-id = General/almindelig gruppe |

SFW/NSFW-adskillelsen ligger alene i mapping-rækkerne (to forskellige
`telegram_chat_id`). Pluginet opretter ved boot en dedikeret Discourse-botbruger
(`@telegram_bridge`) og sikrer medlemskab af de mappede kanaler.

### Datamodel

Migration: tabel `telegram_bridged_messages`

| kolonne | type | note |
|---|---|---|
| `chat_message_id` | bigint, indexed | Discourse-besked |
| `telegram_chat_id` | bigint | supergruppe |
| `telegram_message_id` | bigint | unik sammen med chat_id |
| `direction` | smallint | 0 = D→T, 1 = T→D |
| `ordinal` | smallint | én D-besked kan blive flere T-beskeder (albums, >4096 tegn) |

Tabellen driver replies (slå modpartens id op), redigeringer og sletninger.

### Loop-beskyttelse

- T→D-beskeder oprettes af `@telegram_bridge`-brugeren → udgående hooks
  ignorerer alle beskeder fra den bruger i mappede kanaler.
- Telegram sender aldrig botten dens egne beskeder → ingen loop den vej.

## 4. Flows

### Discourse → Telegram

1. Hook affyres, kanal slås op i mapping (ellers ignorér), bot-bruger skippes.
2. Job renderer: `**{username}:** ` + `cooked`-HTML konverteret til
   Telegram-HTML-subset (mentions → `@navn` som tekst, uunderstøttede tags
   strippes, > 4096 tegn splittes i flere beskeder).
3. Uploads: billeder → `sendPhoto`/`sendMediaGroup`, andet → `sendDocument`.
   **Filerne uploades som bytes** (download fra Discourse-storen først) — URL'er
   duer ikke, da sitet er login-beskyttet.
4. Reply: `message.in_reply_to_id` → slå Telegram-id op → `reply_to_message_id`.
5. `message_thread_id` sættes fra mappingen. Resultatets id'er gemmes i
   mapping-tabellen.
6. Redigering → `editMessageText`/`editMessageCaption` på ordinal 0.
   Sletning → `deleteMessage` (alle ordinaler). Gendannelse → send på ny
   (Telegram kan ikke un-delete) og opdater mappingen.

### Telegram → Discourse

1. Webhook-request valideres (secret-header), svar 200 med det samme,
   payload lægges i Sidekiq-job.
2. `(chat.id, message_thread_id || nil)` slås op i mapping — ukendt topic
   logges og ignoreres. Service-beskeder (joins, topic-events) ignoreres.
3. Afsendernavn = `first_name last_name` (fallback `@username`). Telegram
   *entities* (bold/italic/link/code) konverteres til markdown.
4. `ChatSDK::Message.create(raw: "**Maria:** …", channel_id:, guardian: bot,
   in_reply_to_id: <mappet id>, upload_ids:, enforce_membership: true)`.
5. Medier: `getFile` → download (≤ 20 MB) → `UploadCreator` → `upload_ids`.
   Stickers: statisk webp sendes som billede; animeret `.tgs` → emoji-fallback.
   For store filer → besked med "[fil udeladt, {størrelse}]".
6. `edited_message`-update → slå op i mapping → `Chat::UpdateMessage`.
   (Sletning T→D er umulig — dokumenteret begrænsning.)

### Topics — sådan passer de ind

Telegram-topics er varige "rum" i én supergruppe og matcher derfor
**Discourse-chatkanaler 1:1** — det er den bærende idé i mappingen. De matcher
bevidst *ikke* Discourse-chattråde (som er flygtige og opstår pr. besked); i
POC'en bridges trådsvar fladt som reply på trådens rodbesked.

Praktisk POC-hjælper: botten svarer på kommandoen `/id` i et topic med
`chat_id` + `message_thread_id`, så mapping-rækker er lette at slå op.

## 5. Kanttilfælde og kendte begrænsninger

- **Sletning i Telegram** når ikke Discourse (ingen Bot API-event). Accepteret.
- **Redigeringsvindue:** Telegram tillader kun redigering af bot-beskeder i
  48 timer; ældre D-redigeringer får en "(redigeret: …)"-følgebesked eller
  ignoreres (POC: ignorér + log).
- **Reaktioner** er ude af scope (kan tilføjes senere; Bot API ≥ 7.0
  understøtter reaction-updates).
- **Rate limits:** burst i en travl kanal kan ramme 20/min pr. gruppe →
  jobs backer af på 429 og bevarer rækkefølge pr. kanal (Sidekiq-kø pr.
  mapping eller sekventiel genkørsel).
- **Formatteringstab** begge veje (tabeller, spoilers, onebox m.m.) — degradér
  pænt til tekst/link.
- **Webhook i dev:** dev-miljøet har ingen offentlig HTTPS → hidden setting
  skifter til `getUpdates`-polling (rake-task `telegram_bridge:poll`), så E2E
  kan testes lokalt i `discourse_dev`.

## 6. Sikkerhed og privatliv

- Webhook afviser requests uden korrekt `X-Telegram-Bot-Api-Secret-Token`.
- Bot-token ligger som secret site setting i DB — **ikke** i `ageplay.yml`.
- Kun eksplicit mappede kanaler bridges. Største reelle risiko er en
  **fejlkonfigureret mapping-række** (NSFW-kanal → SFW-gruppe); mitigering:
  få rækker, gennemgang ved ændring, og log-linje ved boot der opsummerer
  aktive mappings.
- Indholdet forlader det login-beskyttede forum og lagres hos Telegram —
  det er selve formålet, men bør nævnes for medlemmerne af de bridgede kanaler.
- Uploads bridges som bytes; der lækkes ingen interne URL'er der alligevel
  kræver login.

## 7. POC-plan (milepæle)

| # | Milepæl | Indhold | Acceptkriterium |
|---|---|---|---|
| M0 | Skelet | Plugin-skeleton, settings, mapping-parser, botbruger, migration | Plugin booter i dev uden fejl |
| M1 | D→T tekst | Event-hooks, Sidekiq-job, Telegram-klient (Faraday), mapping-skrivning | Besked i admin-kanal dukker op i rette topic |
| M2 | T→D tekst | Webhook-route + dev-polling, secret-validering, ChatSDK, entities→markdown | Telegram-besked lander i kanalen som `**Navn:** tekst` i realtid |
| M3 | Replies, redigeringer, sletning (D→T) | Fuld brug af mapping-tabellen | Redigér/slet/svar afspejles korrekt |
| M4 | Medier | Billeder/filer begge veje, albums, størrelsesgrænser | Foto begge veje; fil > 20 MB giver pæn fallback |
| M5 | Hærdning + prod-POC | 429-backoff, `/id`-kommando, boot-log af mappings, README; fork + `ageplay.yml`-linje; rebuild | Admin-kanaler kører mod begge supergrupper i prod |

Test: RSpec på renderer/mapping med WebMock mod Bot API; manuel E2E i dev via
polling-mode. Husk dev-gotcha: ændringer i `plugin.rb`/ruby kræver fuld
Rails-genstart.

## 8. Risici

| Risiko | Sandsynlighed | Mitigering |
|---|---|---|
| Core ændrer chat-events/SDK-signaturer | Middel | Lille kodeflade; kun officielle hooks; `.discourse-compatibility`; fork-mønstret gør hotfix let |
| Rate limits ved travle kanaler | Middel | Backoff + kø pr. kanal; POC er lavtrafik (admin) |
| Formatteringsfidelitet ædet af kanttilfælde | Høj (men lav skade) | Degradér til ren tekst; udbyg konverteren iterativt |
| Fejlmapping SFW/NSFW | Lav | Boot-log + manuel gennemgang |
