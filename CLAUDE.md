# yaply-ios — Codebase Reference

## What This Is

Native iOS app for yaply, built with SwiftUI (Swift 5.9+, iOS 17+). Shares the same Supabase backend as the web app at `../` — same database, same auth, same realtime channels. E2E encryption must produce byte-for-byte identical output to the web app or cross-platform messages break.

This is a monorepo sibling. The parent directory (`../`) contains the React web app. Read `../CLAUDE.md` for the full backend schema, encryption contract, and why certain platform choices were made.

---

## Critical: Encryption Wire Format v2 (envelope encryption)

> **⚠️ NOT YET IMPLEMENTED ON iOS.** The web app migrated to wire format v2 in
> `../supabase/migrations/00029_multi_device_envelopes.sql`. All pre-v2
> messages, conversations, and `devices` rows were **wiped** — there is no
> legacy pairwise data to stay compatible with. Until iOS implements v2 below,
> it cannot read or write messages the web app produces. This section is the
> contract to build against; the pairwise scheme it replaced is gone.

**Why v2:** the old scheme published one identity key per user (`device_id`
hard-coded to 1) and every login overwrote it, permanently orphaning every
message sealed under the replaced key — including the user's own sent history.
v2 gives each install its own `devices` row and seals every message to every
member device explicitly.

**Per message:**
1. Generate a random 256-bit AES **message key** (mk) and encrypt the plaintext
   once: `content = base64(ciphertext + tag[16])`, `iv = base64(nonce[12])`,
   `enc_v = 2`. CryptoKit's `AES.GCM.SealedBox` splits these — use
   `sealedBox.ciphertext + sealedBox.tag` for `content` and `sealedBox.nonce`
   for `iv` (do **not** use `.combined`, which prepends the nonce).
2. Generate **one ephemeral P-256 keypair for the message**.
3. For each recipient device (see recipient set below), wrap mk:
   `KEK = ECDH(ephemeral private, device public)`, then
   `wrapped_key = base64(AES-GCM(KEK, raw 32-byte mk) + tag)` with its own
   `key_iv = base64(nonce[12])`.
4. Insert via the **`send_message_with_envelopes` RPC** (message + all envelopes
   in one transaction). It rejects an empty envelope array or a NULL iv.

Key agreement is raw ECDH — **no HKDF** (unchanged from v1):
```swift
let sharedSecret = try ephemeralPrivKey.sharedSecretFromKeyAgreement(with: devicePubKey)
let kek = sharedSecret.withUnsafeBytes { SymmetricKey(data: Data($0)) }
// NOT hkdfDerivedSymmetricKey(...) — the raw shared secret bytes ARE the key
```

**Recipient set (critical):** every active device (`last_active_at` within 90
days) of every conversation member — **including all of the sender's own
devices**. Omitting your own devices means you cannot read your own sent
messages after a reload; that was the original bug. Groups and DMs are handled
identically — v2 is what finally makes group E2E possible.

**Device registration:** one `devices` row per install. Generate a random
`device_id`, persist it in the Keychain alongside the identity keypair, and
upsert **only that row** (`onConflict: user_id,device_id`). Never write
`device_id = 1` unconditionally — that reintroduces the single-slot bug. Publish
`key_fingerprint` (JWK `x` + `"."` + `y`) alongside `identity_key`.

**Decrypt:** fetch this device's envelope for the message
(`recipient_fp == my fingerprint`), unwrap mk with the identity private key +
the envelope's `eph_pub`, then decrypt `content`. Branch on **`enc_v` first**,
then `iv`:
- `enc_v == 2` → envelope path above; **no envelope ⇒ permanent, honest
  "couldn't decrypt"** (the message was sealed before this device existed).
  Never fall back to decoding raw bytes.
- `enc_v == nil && iv == nil` → phase-1: `content` is plain base64 UTF-8.
- anything else → `decryptFailed`.

**Message editing (contract only — no edit UI on any platform):** an edit is a
**re-seal** — new message key, new `content`/`iv`, and all envelope rows
replaced in one transaction. Never reuse the old message key.

**Registration must be single-flight:** if device registration can be triggered
from more than one place, concurrent calls on a fresh install would each
generate a different keypair and race to publish, desyncing the local private
key from the published public key. Share one in-flight registration task per
user, and **await it before encrypting or decrypting** so a message sent right
after login isn't silently downgraded to phase-1 or reported as a false
decrypt failure.

Keys in the `devices` table are stored as **JWK JSON** (matching the web app).
Conversion between CryptoKit x963 bytes and JWK x/y coordinates is in
`EncryptionService.swift`. Any in-memory key cache must be keyed by userId —
never a single mutable slot with an owner check (see web CLAUDE.md for the race
this caused).

---

## Tech Stack

| Layer | Technology | Why |
|-------|-----------|-----|
| UI | SwiftUI | Declarative, modern, iOS 17 features (NavigationStack, @Observable) |
| State | `@Observable` (Swift 5.9 Observation) | Replaces ObservableObject/Combine — less boilerplate, direct property access |
| Backend | supabase-swift v2 | Same Supabase project as the web app; covers auth, PostgREST, Realtime, Storage |
| Crypto | Apple CryptoKit | Built-in, secure, no bundle cost; P256.KeyAgreement + AES.GCM |
| Key storage | Keychain (via KeychainSwift) | iOS equivalent of IndexedDB; private keys get `afterFirstUnlockThisDeviceOnly` |
| Image loading | Kingfisher | Async image fetching + disk caching for avatars and media |
| Package manager | Swift Package Manager | Native Xcode integration; no CocoaPods/Carthage |

---

## Actual Database Schema

The migrations in `../supabase/migrations/` match the live database. Use the column names below.

**conversations:** `id, type ('direct'|'group'|'ai'), name, avatar_url, created_by, created_at, updated_at`

**conversation_members:** `conversation_id, user_id, role ('owner'|'admin'|'member'), joined_at, last_read_at, muted_until (timestamptz — null = not muted, future = muted until then, very far future = forever), request_state ('accepted'|'pending'|'declined', default 'accepted' — message requests, see Friends System below)`

**friendships:** `id, requester_id, recipient_id, status ('pending'|'accepted'), created_at, updated_at` — one row per pair, direction preserved. Unique in either direction via a functional index on `(least(requester_id, recipient_id), greatest(...))`. **No 'declined' status** — decline/cancel/unfriend all DELETE the row. RLS: participants SELECT + DELETE only; **no INSERT/UPDATE policy**, so writes must go through the RPCs. In the realtime publication.

**user_blocks:** `blocker_id, blocked_id, created_at` — PK (blocker_id, blocked_id), directed. RLS restricts everything to `blocker_id = auth.uid()`, so a blocked user can never see the row.

**messages:** `id, conversation_id, sender_id, type ('text'|'image'|'gif'|'sticker'|'system'|...), content (base64 ciphertext+tag or base64 UTF-8 plaintext), iv (base64 nonce[12]; nil = phase-1), enc_v (smallint — 2 = envelope-encrypted, nil = phase-1), media_url, media_mime, reply_to_id, thread_id, edited_at, deleted_at, created_at`
- Sort order: `created_at DESC`
- System messages: `type = 'system'`, `iv = nil`, `enc_v = nil`, `sender_id = creator`, `deleted_at = now + 7 days` (auto-destruct)
- Media/sticker/gif messages are **never** encrypted: `content = ''`, `iv = nil`, `enc_v = nil`

**message_envelopes:** `id, message_id (FK → messages ON DELETE CASCADE), recipient_user_id, recipient_fp (JWK x.y of the recipient device key), eph_pub (JSON-stringified JWK of the message's ephemeral public key), key_iv (base64 nonce[12]), wrapped_key (base64 AES-GCM(KEK, raw mk) + tag), created_at` — UNIQUE(message_id, recipient_user_id, recipient_fp). RLS: SELECT for recipient or the message's sender.

**Key RPCs:**
- `find_or_create_direct_conversation(target_user_id uuid)` — always use this for DMs (security definer, handles RLS). Raises `blocked` / `cannot message yourself`. On create, the recipient's `request_state` is `'accepted'` when the pair are friends, else `'pending'`.
- `send_message_with_envelopes(p_conversation_id, p_content, p_iv, p_envelopes jsonb, p_type, p_reply_to_id, p_thread_id, p_media_url, p_media_mime)` — the **only** way to send an encrypted message; writes the `enc_v = 2` row and all envelopes atomically. Raises `cannot send in this conversation` when the sender is a pending recipient, someone declined, or either party is blocked.
- `send_friend_request(p_recipient_id)` / `accept_friend_request(p_request_id)` / `block_user(p_user_id)` — the only write paths into `friendships`.
- `get_relationships(p_user_ids uuid[])` → `(user_id, status, request_id, mutual_friends)` — **batched**; never call per user.
- `search_users(p_query)` — people search; matches username or display_name and excludes blocked users in either direction.
- `get_friend_suggestions(p_limit)` — People You May Know (mutual friends + shared groups).
- `create_group_conversation(p_name, p_member_ids)` / `add_group_member(p_conversation_id, p_user_id)` — raise `can only add friends to groups`.

**Encryption wire format:** see the v2 section at the top of this file.

**profiles:** `id, username, display_name, avatar_url, bio, public_key, is_online, last_seen_at, created_at, updated_at`. `username` has a DB-level unique constraint — the actual source of truth. `Core/Supabase/UsernameAvailability.swift` (`UsernameAvailabilityChecker`, `UsernameAvailability` enum) provides a debounced (400ms) pre-save `select id from profiles where username = candidate` check — mirrors the web app's `useUsernameAvailability` hook — so the UI can block Save/Create Account before a write is attempted, not just react to a Postgres `23505` unique-violation after a failed one. Both call sites (`AuthViewModel.checkUsernameAvailability`, sign-up; `AccountSettingsViewModel.checkUsernameAvailability`, profile editing — passes `excluding: userId` so re-saving your own unchanged username doesn't read as taken) still catch `23505` on the actual write as a last-resort guard against a race between the check and the save.

**devices:** `user_id, device_id (int — random per install, NOT always 1), identity_key (JSON — JWK format public key), key_fingerprint (text — JWK x.y), signed_prekey, device_name, push_subscription, last_active_at, created_at` — UNIQUE(user_id, device_id)

**tasks:** `id, conversation_id, created_by, assigned_to, title, description, status ('todo'|'in_progress'|'done'), priority ('low'|'medium'|'high'), due_at, completed_at, created_at, updated_at` — RLS: conversation members SELECT; creator/assignee UPDATE; creator DELETE.

**notes:** `id, user_id, conversation_id, title, content, created_at, updated_at` — **`user_id`** (not `created_by`). RLS: owner only.

**reminders:** `id, user_id, conversation_id, message, remind_at, status ('pending'|'sent'|'dismissed'), created_at` — After migration 00022: all conversation members can view/update/delete. **No `target_type` column.**

**events:** `id, conversation_id, created_by, name, description, location, status ('planning'|'confirmed'), starts_at, ends_at, created_at, updated_at`

**event_availability:** `id, event_id, user_id, slots (jsonb — ISO datetime strings), updated_at` — UNIQUE(event_id, user_id)

**event_rsvp:** `id, event_id, user_id, response ('going'|'maybe'|'not_going'|'pending'), updated_at` — UNIQUE(event_id, user_id)

**albums:** `id, conversation_id, name, created_by, created_at, event_id (nullable FK → events ON DELETE SET NULL)`

**album_media:** `id, album_id, message_id, media_url, media_mime, created_at`

**budgets:** `id, conversation_id, name, total_amount, currency, created_by, created_at, event_id (nullable FK → events ON DELETE SET NULL)`

**expenses:** `id, budget_id, paid_by, description, amount, category (expense_category enum), split_between (uuid[]), created_at`

---

## Architecture

```
YaplyApp (@main)
  └── ContentView                  ← auth gate: AuthView vs MainView
        ├── AuthView               ← sign in / sign up toggle
        └── NavigationStack        ← main app, path managed by AppRouter
              └── ConversationListView (root)
                    └── ChatView (pushed on row tap)
```

**Pattern:** MVVM with `@Observable` ViewModels.
- Views own their ViewModel via `@State private var vm = MyViewModel()`
- Shared services (AuthService, AppRouter, PresenceService) live in `@Environment`
- Repositories are plain `final class` — no actor needed, all mutations go through Supabase

**Real-time:** Each `ChatViewModel` opens a Supabase Realtime channel on `.task {}` and cancels it on disappear. On insert event, re-fetches the latest page rather than parsing the payload (matches the web app's pattern).

---

## Project Structure

The active project is `yaply/yaply/` (Xcode project). The `Sources/yaply/` path is an older SPM layout — new files go in `yaply/yaply/`.

```
yaply/yaply/
├── YaplyApp.swift
├── ContentView.swift                  ← auth gate
├── Core/
│   ├── Supabase/SupabaseClient.swift
│   ├── Keychain/KeychainService.swift
│   └── Extensions/  (Color+Yaply, Date+ISO8601, Data+Base64URL, String+Utils, UIImage+Resize)
├── Models/                            ← Codable structs mirroring DB
│   ├── Profile.swift, Conversation.swift, Message.swift, Device.swift
├── Navigation/  (AppRoute, AppRouter)
└── Features/
    ├── Auth/  (AuthService, AuthViewModel, AuthView, SettingsView, ProfileView)
    ├── Chat/
    │   ├── Repositories/  (ConversationRepository, MessageRepository, PresenceService)
    │   ├── ViewModels/    (ConversationListViewModel, ChatViewModel, ThreadViewModel)
    │   └── Views/         (ConversationListView, ChatView, MessageBubbleView,
    │                        MessageInputView, ReplyStripView, DateSeparatorView,
    │                        ConversationRowView, GroupInfoView, NewConversationView,
    │                        ThreadView, ConversationDetailView)
    ├── Events/
    │   ├── Repositories/EventRepository.swift   ← YaplyEvent, YaplyEventAvailability, AvailMember, YaplyEventRsvp; CRUD + availability + RSVP
    │   └── Views/
    │       ├── EventListView.swift              ← grouped list (Confirmed / Planning), create sheet, delete confirm
    │       ├── EventDetailSheet.swift           ← planning mode (header + AvailabilityCalendarView) vs confirmed mode (header + RSVP)
    │       └── AvailabilityCalendarView.swift   ← when2meet grid: heatmap, tap-toggle, member chips, creator long-press confirm
    ├── Albums/
    │   ├── AlbumRepository.swift                ← YaplyAlbum, YaplyAlbumMedia, CRUD
    │   └── AlbumListView.swift                  ← list + gallery sheet (3-col grid)
    ├── Budgets/
    │   ├── BudgetRepository.swift               ← YaplyBudget, YaplyExpense, CRUD
    │   └── BudgetListView.swift                 ← list, create sheet, delete confirm
    ├── Encryption/  (EncryptionService, KeyStore)
    ├── Presence/PresenceService.swift
    ├── Media/  (GiphyService, MediaUploadService, GifPickerView, MediaPickerView)
    ├── Notifications/  (NotificationManager, PushNotificationService, InAppBannerView)
    ├── Commands/
    │   ├── CommandParser.swift
    │   ├── Views/CommandPaletteView.swift
    │   └── Handlers/  (RemindHandler, MuteHandler)
    └── Productivity/
        ├── Tasks/
        │   ├── Repositories/TaskRepository.swift   ← YaplyTask, CRUD + deleteTask
        │   └── Views/TaskListView.swift             ← list, add sheet, swipe-to-delete confirm
        ├── Notes/
        │   ├── Repositories/NoteRepository.swift   ← YaplyNote (user_id field), CRUD + deleteNote
        │   └── Views/NoteListView.swift             ← expandable cards, add sheet, swipe-to-delete
        └── Reminders/
            ├── ReminderRepository.swift             ← YaplyReminder, fetch/dismiss/delete
            └── ReminderListView.swift               ← list, dismiss confirm alert
```

---

## Configuration

Keys are read from `Bundle.main.infoDictionary` (set via `Config.xcconfig` → `Info.plist`), falling back to `ProcessInfo.processInfo.environment` for testing.

Copy `Config.xcconfig.example` → `Config.xcconfig` (gitignored) and fill in:
```
SUPABASE_URL = https://your-project.supabase.co
SUPABASE_ANON_KEY = your-anon-key
GIPHY_API_KEY = your-giphy-key
```

---

## Development Notes

- **`@Observable` requires iOS 17+** — do not lower the deployment target
- **`NavigationStack` path** is managed by `AppRouter` injected via `@Environment`
- **Encryption init** runs on `AuthService` login — generates keypair if none exists, upserts public key to `devices` table
- **Message decryption** happens in `ChatViewModel` after fetching — never store or render raw ciphertext
- **`YaplyTask`** (not `Task`) — named to avoid collision with Swift's concurrency `Task` type
- **JWK decoding:** The `devices.identity_key` JSON includes extra fields (`ext: Bool`, `key_ops: [String]`) beyond x/y. Decode with a dedicated struct `struct JWKCoords: Decodable { let x: String; let y: String }` — not `[String: String]`, which will fail to decode.
- **Phase-1 multi-byte encoding:** Use `Data(plaintext.utf8).base64EncodedString()` for encoding and `String(data: decodedData, encoding: .utf8)` for decoding. Never use Latin-1 byte-by-byte methods — they break on emoji and non-ASCII characters.
- **Conversation delete = membership delete only:** `ConversationRepository.deleteConversation` deletes the user's own row from `conversation_members`. A Postgres trigger (`trg_delete_empty_conversation`) cascades to deleting the conversation record if no members remain.
- **`NoteRepository` uses `user_id`** (not `created_by`) — the `notes` table has `user_id` as the owner FK. The web schema uses `user_id` throughout.
- **`RemindHandler` uses `user_id`** (not `created_by`), and there is no `target_type` column. Reminders are now shared (migration 00022): all conversation members can see/dismiss reminders in their conversations.
- **System message expiry:** System messages have `deleted_at` set to `now + 7 days` at insert. `MessageBubbleView` checks `deletedAt <= Date()` and returns `EmptyView` if expired — never shows "Message deleted" for expired system messages.
- **SourceKit cross-file diagnostics:** The Xcode project compiles fine; SourceKit shows spurious "Cannot find type" errors in new files because it doesn't index across all targets during standalone file edits. Always verify in Xcode, not the SourceKit error panel.
- **`ConversationDetailView`** is the iOS equivalent of the web's `ConversationPanel` sidebar. Opened from the toolbar `list.bullet.rectangle.portrait` button in `ChatView`, or by tapping an "Open →" link in a system message.
- **Sidebar refetch after slash command creation:** When any item is created via a slash command (`/task`, `/note`, `/remind`, `/album`, `/budget`, `/event`, `/plan`), `ChatView` posts `NotificationCenter.default.post(name: .yaplyItemCreated, object: nil, userInfo: ["type": "<type>"])` after the insert succeeds. Each list view listens with `.onReceive(NotificationCenter.default.publisher(for: .yaplyItemCreated))` and calls its `load()` function when the type string matches. `Notification.Name.yaplyItemCreated` is defined in `Core/Extensions/String+Utils.swift`.

---

## Tier 2 Implemented Features

### Realtime Message Deletion Propagation

`ChatViewModel.startRealtime()` subscribes to both `InsertAction` and `UpdateAction` on the `messages` table filtered by `conversation_id`. When a remote user deletes a message (which sets `deleted_at`), the `UpdateAction` fires. `handleMessageUpdate(_:)` finds the message by ID and rebuilds the `DecryptedMessage` with the new `deletedAt` value — no re-fetch needed.

Own-message updates are skipped (`sender_id == currentUserId`) to avoid double-processing local optimistic updates.

### Message Bubble Actions

- **Delete (own messages only):** Long-press context menu shows "Delete" option. Tapping shows a native `.alert("Delete Message", ...)` with a destructive "Delete" button. Confirmed deletes call `onDelete(message.id)`.
- **Reply (other users' messages):** Swipe right on the message bubble only (not the full row). Implemented as a `simultaneousGesture(DragGesture)` scoped to the bubble `VStack`. The gesture reveals a reply icon via `ZStack(alignment: .leading)` — icon sits behind the VStack at x=0; as the bubble slides right the icon is exposed. Triggers `onReply(message)` at 55pt drag distance; springs back to 0 on gesture end.
- **Timestamp:** Swipe left on own message bubbles reveals the timestamp. `ChatView` manages a single `swipeOffset: CGFloat` state passed as binding; only one timestamp shows at a time.

### Reply Quotation Bubble

The reply block appears above the message content inside the bubble. It uses a compact `HStack` with:
- A 2×22pt `RoundedRectangle` accent bar (sender's color)
- Sender name in small semibold
- Preview text: `"📷 Photo"` for media, italic `"Message deleted"` in `yaplySecondary.opacity(0.7)` if `reply.isDeleted`, otherwise first 60 chars of content
- Fixed `frame(height: 36)` on the HStack — **critical**: without an explicit height, `Rectangle()` in a ScrollView context expands to fill infinite proposed height
- `frame(maxWidth: 180)` on the `Button` to prevent it from stretching full width

### Conversation Swipe-to-Delete

`SwipeToDeleteConversationRow` (private struct in `ConversationListView.swift`) wraps each row with:
- A `ZStack(alignment: .trailing)` — red trash `Button` behind, content in front
- `simultaneousGesture(DragGesture(minimumDistance: 10))` on the content — left-swipe only; threshold 36pt, reveal width 68pt; springs back on gesture end
- `.alert("Delete Conversation", ...)` with a destructive "Delete" button that calls `onDelete()` and springs the offset back to 0

`ConversationListViewModel.deleteConversation(id:userId:)` removes the conversation optimistically from the local array, then calls `ConversationRepository.deleteConversation` (deletes own `conversation_members` row). On error it refreshes from the server to revert.

---

## Tier 4 Implemented Features

### ConversationDetailView (iOS equivalent of web sidebar panel)

`ConversationDetailView` is a sheet opened from a `list.bullet.rectangle.portrait` toolbar button in `ChatView`. It mirrors the web app's `ConversationPanel` right-sidebar with tabbed navigation:

**Tabs:** Tasks | Notes | Reminders | Events | Albums | Budgets

Each tab navigates to the matching list view. The sheet can be opened at a specific tab by setting `initialTab` — used when a system message "Open →" link is tapped.

**System message links:** `MessageBubbleView` has an `onOpenDetail: ((String) -> Void)?` callback. When a system message like "Task created: ..." is shown, a `tabMap` array matches the content pattern to a tab ID. Tapping "Open Tasks →" calls the callback, which sets `detailTab` and `showDetail = true` in `ChatView`.

---

### Delete Confirmations

All list views use `.alert(...)` for destructive confirmation before deleting:

- **TaskListView:** `.swipeActions(edge: .trailing)` reveals a red trash button → sets `taskToDelete` → alert with "Delete" (destructive) + "Cancel".
- **NoteListView:** Same swipe pattern → `noteToDelete` → alert.
- **EventListView:** Swipe only visible for `event.createdBy == currentUserId` → `eventToDelete` → alert.
- **BudgetListView:** Same creator-only swipe → `budgetToDelete` → alert.
- **AlbumListView:** Same creator-only swipe → `albumToDelete` → alert.
- **ReminderListView:** Dismiss button in each row → `reminderToDismiss` → alert (sets status = 'dismissed', not a hard delete).

All confirmations use native `Button(role: .destructive)` for the destructive action and `Button(role: .cancel)` for cancel.

---

### System Message Rendering + Auto-Expiry

System messages (`type == "system"`) render differently from regular messages in `MessageBubbleView`:

- **Expired** (when `deletedAt != nil && deletedAt <= Date()`): returns `EmptyView` — row disappears silently, no "Message deleted" text.
- **Active**: centered `HStack` pill (white background + `yaplyBorder` stroke) showing the decoded message text + optional "Open {tab} →" `Button`.

The `systemMessageTabMap` array maps content patterns (case-insensitive) to tab IDs:
```swift
("Task created", "tasks"), ("Note created", "notes"), ("Event created", "events"),
("Plan created", "events"), ("Album created", "albums"), ("Budget created", "budgets"),
("Reminder set", "reminders")
```

**Expiry is set on the web** at insert time (`deleted_at = now + 7 days`). iOS reads this value from the DB row — no iOS-side scheduling needed.

---

### Events (YaplyEvent)

`EventRepository` in `Features/Events/Repositories/`. `YaplyEvent` model maps to the `events` table (migration 00020).

`EventListView` shows two sections — "Confirmed" (status='confirmed') and "Planning" (status='planning'). Swipe-to-delete only shows for `event.createdBy == currentUserId`. Create sheet has a segmented picker for Planning vs Event type; confirmed events require a `DatePicker` for `starts_at`.

**Availability calendar:** Fully implemented as `AvailabilityCalendarView` in `Features/Events/Views/`. `EventDetailSheet` drives the split:

- **Planning mode** (`status='planning'`): compact header (badge + name + description + location) → `AvailabilityCalendarView` fills the remaining sheet space. No RSVP section.
- **Confirmed mode** (`status='confirmed'`): full header card → RSVP buttons (Going / Maybe / Can't Go) + member tally + response list.

**`AvailabilityCalendarView` key details:**
- Week navigator at top, advances/retreats 7 days at a time (Sunday-anchored `startOfWeek`)
- 7-column × 28-row grid (8am–10pm, 30-min slots)
- Slot keys are ISO8601 UTC strings matching the web format (e.g. `"2025-06-10T13:00:00.000Z"`) — built with `Calendar.current` local-time dates then formatted via `ISO8601DateFormatter` with `.timeZone = UTC` and `.withFractionalSeconds`
- Heatmap: transparent (0 others), light blue (≤33%), mid blue (≤66%), accent blue (>66%) — your own slots render dark navy
- Tap to toggle your slot; long-press (0.45s) on a cell where `isCreator && count > 0 && !isMine` fires the confirm-time alert
- "Save" button upserts `event_availability` with `onConflict: "event_id,user_id"`
- Creator confirm: parses slot key back to `Date`, adds 1h for `ends_at`, calls `repo.confirmEvent`, posts `.yaplyItemCreated` notification, dismisses the sheet
- Member chips: horizontal scroll showing initials avatar + name ("You" for current user) + slot count
- `EventRepository` gained: `fetchAvailability(eventId:)`, `setAvailability(eventId:userId:slots:)`, `fetchEventMembers(conversationId:)`

---

### Reminders (Shared Model)

After migration `00022_reminders_shared_access.sql`, reminders are visible to all conversation members (not just the creator). `ReminderRepository` queries without a `user_id` filter — Supabase RLS enforces membership.

`RemindHandler` updated: uses `user_id` (not `created_by`), no `target_type` field. Always schedules a local `UNNotificationRequest` for the creator.

`ReminderListView` shows pending/sent reminders ordered by `remind_at`. Past-due reminders highlight with an orange bell icon. Dismiss button triggers a confirmation alert → `UPDATE status = 'dismissed'`.

---

### Notes Field Name Fix

`NoteRepository` was incorrectly using `created_by` (no such column). Fixed to use `user_id` to match the actual `notes` table schema (`user_id uuid not null references profiles`). This is a **breaking fix** — any previously inserted notes with `created_by` would not have loaded.

---

### Albums (YaplyAlbum + YaplyAlbumMedia)

`AlbumRepository` in `Features/Albums/`. `AlbumListView` shows albums with a chevron to open `AlbumGallerySheet` — a 3-column `LazyVGrid` of `AsyncImage` thumbnails. Albums without photos show an empty state. Delete confirmation uses the same `.alert` pattern (creator-only).

---

### Budgets (YaplyBudget + YaplyExpense)

`BudgetRepository` in `Features/Budgets/`. `BudgetListView` shows budgets with a green dollar icon. Create sheet has name, total amount (decimal keyboard), and currency picker (USD/EUR/GBP/CAD). Delete confirmation is creator-only. Expense management (add expense, split) is stubbed via `addExpense` in the repository but no UI yet.

---

## Friends System — NOT YET IMPLEMENTED ON iOS (web shipped it; migration 00033)

The schema and every gate are already live in the shared Supabase project, so **iOS is currently out of sync**: group creation with a non-friend now fails, and a DM from a non-friend silently becomes a message request the iOS client does not render as one. Implementing this is the next cross-platform task.

**Two distinct consent mechanisms — do not conflate them:**
- **Friend requests** (`friendships`) — the social relationship. Required to add someone to a group; drives the friends list, suggestions, mutual counts.
- **Message requests** (`conversation_members.request_state`) — permission to talk. A DM from a **non-friend** arrives with the recipient's own member row `'pending'`: readable, but **not repliable until accepted**. Accepting does **not** create a friendship. Friends skip this and chat immediately.

`request_state` rules:
- `'accepted'` — normal (the default, so nothing pre-existing changed).
- `'pending'` — read-only for that member. Show in a separate "Message requests" section, disable the composer (Accept / Decline / Block bar instead), and **exclude from unread counts and notification banners**.
- `'declined'` — hide the conversation, and note that `can_send_in_conversation` then returns false for **both** parties so the sender cannot keep messaging into a wall.

**Never delete a membership row to decline** — `trg_delete_empty_conversation` would delete the whole conversation and its messages. Accepting/declining is an UPDATE of your **own** `conversation_members` row (covered by the existing "self can update" policy; no RPC needed).

**Implementation contract:**
- Create/accept/block only via the RPCs; `friendships` has no INSERT/UPDATE policy so a direct write fails silently. Decline, cancel and unfriend are all a plain DELETE of the `friendships` row.
- Relationship state comes from batched `get_relationships([uuid])` — six states, `none | pending_out | pending_in | friends | blocked | blocked_by`. Render `blocked_by` **identically to `none`**; revealing a block is itself information.
- People search must use `search_users`, not a direct `profiles` query (which skips the block filter). Note `profiles` SELECT is intentionally still `using (true)`, so a blocked user can technically still read the blocker's profile row — a documented, accepted limitation.
- Block = sends blocked both directions, new DM raises `blocked`, friendship deleted, hidden from search/suggestions. History is not deleted and the blocked party gets no signal.
- Map RPC errors to human text: `blocked`, `cannot send in this conversation`, `can only add friends to groups`, `friend request already exists`, `cannot friend yourself`.
- `friendships` is in the realtime publication — subscribe for request badges, and follow the house rule of treating the payload as an invalidation trigger.

**All gating is server-side and must stay that way.** The conversation RPCs are `SECURITY DEFINER` and bypass RLS, so a Swift-side check is decorative.

---

## Known Issues to Fix

Issues identified from code review (most severe first):

1. **`unlinkFromEvent` is a silent no-op** — `AlbumRepository.unlinkFromEvent` and `BudgetRepository.unlinkFromEvent` both encode `event_id: nil` via an `Encodable` struct. Swift's `JSONEncoder` omits `nil` Optional keys by default, so the PATCH body is `{}` and Supabase never clears `event_id`. Fix: use `AnyJSON` or pass `["event_id": AnyJSON.null]` directly instead of an Encodable struct.

2. **Lock-time confirm alert silently dropped** — `EventDetailSheet` sets `activeSheet = nil` and `showLockConfirm = true` in the same synchronous button handler. iOS cannot attach an alert while a sheet dismissal animation is in flight — the alert is swallowed. Fix: set `showLockConfirm = true` inside an `onDismiss` closure on the sheet instead.

3. **`doConfirm` timezone bug in `AvailabilityCalendarView`** — The `ISO8601DateFormatter` in `doConfirm` does not set `timeZone = UTC`, so UTC slot keys (e.g. `"2025-06-10T14:00:00.000Z"`) are parsed in the device's local time zone, writing a wrong `starts_at` to the DB. Fix: add `f.timeZone = TimeZone(identifier: "UTC")` matching `slotKey()` at line 73 of the same file.

4. **`AlbumGallerySheet` unlink doesn't dismiss** — The Unlink alert calls `repo.unlinkFromEvent` and `onDeleted()` but never `dismiss()`. The sheet stays open with a stale link button. Fix: call `dismiss()` after `onDeleted()` in the Unlink alert action, matching the Delete alert directly above it.

5. **`fetchLinkedAlbums` fetches all `album_media` rows** — `EventRepository.fetchLinkedAlbums` and `AlbumRepository.fetchAlbums` both join `album_media` with no LIMIT, downloading the full photo library just to get a cover thumbnail. Fix: add `.limit(1, referencedTable: "album_media")` to each join — only `albumMedia?.first` is ever used.

6. **Link/Unlink swipe shown to non-creators in `BudgetListView`** — The Link Event and Unlink swipe actions have no `isCreator` guard. Non-creator taps silently fail (RLS rejects the UPDATE) with no user feedback because the error is `try?`-discarded. Fix: wrap Link/Unlink swipe actions in `if budget.createdBy == currentUserId`, matching the Delete action above them.

7. **Double-tap race on 'Link' opens picker before data loads** — Tapping the 'Link' button fires `Task { await loadAllAlbums(); activeSheet = .linkAlbum }` with no guard. A second tap while the first is in-flight opens the sheet with `allAlbums == []`. Fix: add an `isLoadingAlbums: Bool` guard or cancel the prior Task before starting a new one.

8. **`doLockTime` hardcodes `endsAt = startsAt + 1h`** — No user input for event duration. A 30-min or 3-hour event gets an incorrect `ends_at` written to the DB. Fix: either add an end-time picker to `lockTimeSheet`, or pass `endsAt: nil` to `confirmEvent` until the user sets it explicitly.

9. **`linkedSection` empty-state uses stringly-typed title check** — `if (title == "Albums" && linkedAlbums.isEmpty) || (title == "Budgets" && linkedBudgets.isEmpty)` breaks silently if the title string ever changes. Fix: pass an explicit `isEmpty: Bool` parameter — the call sites already have `linkedAlbums.isEmpty` and `linkedBudgets.isEmpty` in scope.

10. **`load()` called during sheet dismiss animation in `BudgetListView`** — After `budgetToLink = nil` triggers the dismiss animation, `await load()` immediately writes `@State` mid-animation, causing a layout warning and visible list flash. Fix: add a short delay after setting `budgetToLink = nil` before calling `load()`.

11. **`doLockTime` doesn't update local sheet state** — After `confirmEvent` succeeds, the open `EventDetailSheet`'s local `event.isPlanning` is still `true` (it's an immutable `let`). The sheet continues showing the availability calendar UI. Same gap in `AvailabilityCalendarView.doConfirm`. Fix: dismiss the sheet after confirming, or pass a binding that allows the parent to update the event model.

12. **Concurrent RSVP taps bypass `isSaving` guard** — `RsvpButton` creates a new `Task` on each tap. `.disabled(isSaving)` only blocks re-render taps, not in-flight Tasks. Two rapid taps before the first `await` suspends fire duplicate `setRsvp` upserts. Fix: add `guard !isSaving else { return }` at the top of `tap()`.

13. **`canConfirm` blocks creator from confirming their own slots** — `canConfirm = isCreator && count > 0 && !isMine`. When the creator has also selected the overlapping slot (the normal case), `isMine` is `true` and the long-press does nothing. Fix: change the condition to `isCreator && count > 0` (or `count > 1` if you want to require at least one other attendee).

14. **`BudgetRowView.linkedEventName` O(n×m) per body eval** — `events.first { $0.id == eid }` runs on every SwiftUI body evaluation for every budget row. Fix: pre-compute a `[UUID: String]` dictionary in `load()` and pass it down, reducing each lookup to O(1).

15. **`fetchAlbums` unbounded `album_media` join** — Same as finding #5 but on the album list itself: every `AlbumListView.load()` call downloads all media rows for all albums just for cover thumbnails. Fix: add `.limit(1, referencedTable: "album_media")` to `AlbumRepository.fetchAlbums`.
