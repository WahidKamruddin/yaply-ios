# yaply-ios — Codebase Reference

## What This Is

Native iOS app for yaply, built with SwiftUI (Swift 5.9+, iOS 17+). Shares the same Supabase backend as the web app at `../` — same database, same auth, same realtime channels. E2E encryption must produce byte-for-byte identical output to the web app or cross-platform messages break.

This is a monorepo sibling. The parent directory (`../`) contains the React web app. Read `../CLAUDE.md` for the full backend schema, encryption contract, and why certain platform choices were made.

---

## Critical: Encryption Wire Format

All platforms must produce identical encrypted output. The format is:

```
DB column: encrypted_content = base64( nonce[12 bytes] + AES-GCM-ciphertext + GCM-tag[16 bytes] )
```

The GCM tag is appended to the ciphertext (Web Crypto AES-GCM bundles them into one output). `CryptoKit`'s `AES.GCM.SealedBox.combined` produces exactly this layout: `nonce(12) + ciphertext + tag(16)`. Use `.combined!` directly.

Key derivation is raw ECDH — **no HKDF**:
```swift
let sharedSecret = try myPrivKey.sharedSecretFromKeyAgreement(with: theirPubKey)
let aesKey = sharedSecret.withUnsafeBytes { SymmetricKey(data: Data($0)) }
```

Keys in the `devices` table are stored as **JWK JSON** (matching the web app). Conversion between CryptoKit x963 bytes and JWK x/y coordinates is in `EncryptionService.swift`.

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

**conversation_members:** `conversation_id, user_id, role ('owner'|'admin'|'member'), joined_at, last_read_at, muted_until (timestamptz — null = not muted, future = muted until then, very far future = forever)`

**messages:** `id, conversation_id, sender_id, type ('text'|'image'|'gif'|'sticker'|'system'|...), content (base64 ciphertext+tag or base64 UTF-8 plaintext), iv (base64 nonce[12]; nil = phase-1), media_url, media_mime, reply_to_id, thread_id, edited_at, deleted_at, created_at`
- Sort order: `created_at DESC`
- System messages: `type = 'system'`, `iv = nil`, `sender_id = creator`, `deleted_at = now + 7 days` (auto-destruct)

**Key RPC:** `find_or_create_direct_conversation(target_user_id uuid)` — always use this for DMs (security definer, handles RLS).

**Encryption wire format:** `content = base64(ciphertext + GCM tag[16])`, `iv = base64(nonce[12])` as two separate columns. If `iv` is nil, content is plain base64 plaintext (phase-1 fallback).

**profiles:** `id, username, display_name, avatar_url, bio, public_key, is_online, last_seen_at, created_at, updated_at`

**devices:** `user_id, device_id (int), identity_key (JSON — JWK format public key)`

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
    │   ├── Repositories/EventRepository.swift   ← YaplyEvent, CRUD + delete
    │   └── Views/EventListView.swift             ← grouped list, create sheet, delete confirm
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

**Availability calendar (future):** The `event_availability` and `event_rsvp` tables exist in the DB. A full when2meet-style calendar view is not yet implemented in iOS.

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
