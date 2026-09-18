# yaply-ios — Codebase Reference

## What This Is

Native iOS app for yaply, built with SwiftUI (Swift 5.9+, iOS 17+). Shares the same Supabase backend as the web app at `../` — same database, same auth, same realtime channels. E2E encryption must produce byte-for-byte identical output to the web app or cross-platform messages break.

**`../CLAUDE.md` is always loaded alongside this file.** It holds the full database schema, every RPC, the encryption wire format, the pairing protocol, the friends/message-request semantics, and the push-notification server side. This file holds only what is iOS-specific: CryptoKit gotchas, file locations, and the "why" behind decisions that guard a real regression. Do not duplicate the backend contract here.

---

## Encryption Wire Format v2 (IMPLEMENTED)

Files: `Features/Encryption/EncryptionService.swift` (primitives, JWK↔x963),
`EnvelopeEncryption.swift` (seal/decrypt against `MessageRepository`),
`EncryptionRegistrar.swift` (device registration, orphan check), `KeyStore.swift`
(Keychain-backed identity + escrowed keys). The contract is in `../CLAUDE.md`;
these are the CryptoKit-specific rules that must not drift:

- **`AES.GCM.SealedBox` splits the parts** — `content = base64(sealedBox.ciphertext + sealedBox.tag)`,
  `iv = base64(sealedBox.nonce)`. Never `.combined`, which prepends the nonce.
- **Raw ECDH, no HKDF.** The shared secret bytes *are* the AES key:
  ```swift
  let secret = try ephPriv.sharedSecretFromKeyAgreement(with: devicePub)
  let kek = secret.withUnsafeBytes { SymmetricKey(data: Data($0)) }   // NOT hkdfDerivedSymmetricKey
  ```
- **Keys on the wire are JWK JSON.** `devices.identity_key` carries extra fields
  (`ext`, `key_ops`); decode with `struct JWKCoords: Decodable { let x: String; let y: String }`,
  not `[String: String]`. Fingerprint is `x + "." + y`.
- **One `devices` row per install.** Random `device_id` persisted in the Keychain
  with the keypair; upsert only that row (`onConflict: user_id,device_id`). Never
  `device_id = 1` — that was the single-slot bug that orphaned all history.
- **Recipients = every active device (90-day `last_active_at`) of every member,
  including the sender's own devices.** Omit your own and you can't read your sent
  messages after a reload. Groups and DMs are sealed identically.
- **Decrypt branches on `enc_v` first, then `iv`.** `enc_v == 2` → envelope for one
  of my candidate fingerprints, else permanent honest "couldn't decrypt";
  `enc_v == nil && iv == nil` → phase-1 plain base64 UTF-8; anything else → failed.
  Never fall back to decoding raw bytes.
- **Registration is single-flight.** `EncryptionRegistrar` shares one in-flight task
  per user; encrypt and decrypt **await** it so a send right after login is never
  downgraded to phase-1 or reported as a false failure.
- **In-memory key caches are keyed by userId** — never a single mutable slot with an
  owner check (see the web file for the sign-out/sign-in race that caused).
- **Editing (contract only, no UI):** re-seal with a new message key and replace all
  envelopes in one transaction. Never reuse the old key.

---

## Live Device Pairing (IMPLEMENTED)

Files: `Features/Devices/DevicePairingCrypto.swift` (code, SAS, transfer payload),
`DevicePairingViewModel.swift` (channel + handshake), `Views/DevicePairingView.swift`,
`Views/PairingQRView.swift` (CoreImage), `Views/QRScannerView.swift` (AVFoundation).
Escrow storage and `candidateFingerprints` live in `Features/Encryption/KeyStore.swift`.

A new install can't read history sealed before it existed, so an already-linked
device (*sender*) transfers its keys to the new one (*receiver*) over an
ephemeral **private** Realtime channel. Nothing is stored server-side. The full
protocol (code alphabet, channel topic, SAS formula, payload shape, handshake
events, 90s TTL) is in `../CLAUDE.md` and must stay byte-identical.

iOS-specific rules:
- **iOS is usually the sender to a desktop receiver**, so the show-an-8-char-code
  path is mandatory. Never gate pairing behind the camera.
- Ephemeral P-256 per side is **memory-only** — never Keychain, never the DB.
  `secret` = raw `sharedSecret.withUnsafeBytes { Data($0) }`, used directly as the
  AES-GCM key; **not** `hkdfDerivedSymmetricKey`.
- Channel opened with `$0.isPrivate = true` — RLS on `realtime.messages` scopes it.
- Escrowed `pub`/`priv` are JWKs, not x963/DER.

Invariants (each guards a real failure):
- **SAS confirmation is load-bearing.** It is what stops a second session on the
  *same account* (stolen JWT) from impersonating the receiver — that attacker
  passes RLS. Never ship a skip path.
- **Abort on a second joiner** (a different `ephPub` mid-session). Never pick a winner.
- **Adopted keys are decrypt-only:** never published to `devices`, never sealed to;
  **merge**, don't overwrite, on a second pairing.
- **Candidate fingerprints, not one:** envelope lookup filters
  `recipient_fp IN (own, ...escrowed)` and picks the matching private key — at
  every decrypt site.
- Accepted limitation: both devices online at once; no cold-start recovery.

---

## Device Management (IMPLEMENTED)

Settings → Devices: `Features/Devices/Views/DeviceSettingsView.swift`,
`DeviceRepository.swift`, `DeviceRevocationWatcher.swift`, `DeviceName.swift`.

- **Naming.** `DeviceName.generate()` (e.g. `iPhone (App)`) and `platform = 'ios'`
  are written **only at first registration**. A later login must never re-write
  `device_name` or a rename silently reverts.
- **Session capture.** `EncryptionRegistrar` records the access token's `session_id`
  claim on the row; without it `revoke_device` can drop the row but not the session.
- **Revoking** calls `revoke_device(p_device_id)` — never a direct DELETE, which
  leaves the auth session alive and lets the device re-register on next launch.
- **Orphan check — mandatory.** `EncryptionRegistrar.register` runs at startup: a
  local `device_id` with no matching row means this install was revoked offline →
  wipe **all** local keys (identity and escrowed) and register fresh. Skipping it
  lets a revoked device republish its old identity.
- **Never treat a failed lookup as "revoked".** Only a successful empty result
  counts; a network error must not sign the user out.
- `DeviceRevocationWatcher` (started from `ContentView`) subscribes to
  postgres_changes DELETE on `devices` filtered to this install's **own row id**
  (delete events carry only the PK and are not RLS-filtered), and re-checks on
  `willEnterForeground`.

---

## Push Notifications

Files: `Features/Notifications/PushNotificationService.swift` (registration +
token upload), `YaplyApp.swift` (`AppDelegate`, `UNUserNotificationCenterDelegate`),
`yaply/YaplyNotificationService/NotificationService.swift` (decrypting extension),
`yaply/yaply.entitlements` + `YaplyNotificationService.entitlements`. Server side
(trigger, edge function, payload, suppression rules) is in `../CLAUDE.md`.

**Previews decrypt on-device.** The payload carries ciphertext plus the one
envelope this device can open; the extension runs the same `unwrapKey` →
`decryptMessage` path as `EnvelopeEncryption.decryptV2`, minus the fetch. Branch on
`enc_v` first, then `iv`. Any failure delivers the server's placeholder untouched —
never ciphertext or a decode artifact.

**The shared Keychain group is what makes this work.** Both entitlements list
`$(AppIdentifierPrefix)wahid.yaply` as the **first and only** `keychain-access-groups`
entry. That is already where `KeychainService` items land implicitly (it passes no
`kSecAttrAccessGroup`), so existing installs needed no migration. **Reorder or
rename it and every signed-in device loses its identity key, fails the orphan
check, and re-registers as a new device**, orphaning all history. Identity keys use
`afterFirstUnlockThisDeviceOnly`; do not tighten to `whenUnlocked` or lock-screen
previews stop decrypting.

**Extension target membership.** The extension compiles four app files that import
only CryptoKit / Foundation / Security: `EncryptionService.swift`, `KeyStore.swift`,
`DevicePairingCrypto.swift`, `KeychainService.swift`. `EnvelopeEncryption.swift` is
deliberately **excluded** (it takes a `MessageRepository`); adding Supabase to the
extension would blow its memory budget.

**`environment` comes from the provisioning profile, not `#if DEBUG`.**
`ApnsEnvironment.current` parses `aps-environment` from `embedded.mobileprovision`.
The two diverge for ad-hoc and enterprise builds; a wrong value means every send
gets `400 BadDeviceToken`, the server prunes the token, and notifications silently
stop. Verified on TestFlight build 5 (2026-09-17): Xcode's App Store export
rewrites the hardcoded `development` entitlement to `production` and the row lands
as `production` — no per-configuration entitlements file needed. When pushes work
from Xcode but not TestFlight, check `send-push` logs before touching signing:
`403 BadEnvironmentKeyInToken` means the APNs `.p8` key was created Sandbox-only,
which is a portal fix plus new `APNS_KEY_ID` / `APNS_PRIVATE_KEY` secrets, not an
iOS change.

**Token upload races device registration.** `push_tokens` has a composite FK onto
`devices`, which `EncryptionRegistrar` writes — but APNs can deliver the token
first. `uploadToken` retries with backoff on Postgres `23503` and surfaces failure
on `lastUploadError` rather than swallowing it.

**Delegate wiring.** `UNUserNotificationCenter.current().delegate` is assigned in
`application(_:didFinishLaunchingWithOptions:)` — any later and iOS drops the
notification that launched the app. In the foreground a `kind == "message"` push
returns only `[.sound, .badge]` (the realtime subscription already shows the in-app
banner); everything else gets a full banner, which is also what makes local
`/remind` notifications present while the app is open. A tap writes
`AppRouter.pendingConversationId`, drained by `ContentView` on appear and on change —
buffered because a cold-launch tap arrives before the navigation stack exists.

**Long messages (> ~2,100 chars) deliberately show "Sent a message"** with the
sender's name as title. The 4096-byte APNs cap can't hold the ciphertext, AES-GCM
can't be truncated, and both alternatives (extension fetch; a second sealed blob)
were rejected — see `../CLAUDE.md` for the reasoning. `mutable-content` is dropped
for them so the extension isn't woken pointlessly.

**Badge count** = total unread across accepted, unmuted conversations.
`ConversationListViewModel.totalUnreadCount` and the server's `unread_count`
(migration `00044`) must agree or the badge flips between numbers; the client
re-applies it after every `refresh`.

**Permission denial is surfaced** by `NotificationsDisabledBanner.swift` at the top
of `ConversationListView` when `authorizationStatus == .denied`; re-read on
`scenePhase == .active` so it clears without a relaunch.

**Still missing:** notification-preferences UI (yaply-ios#25). Per-kind toggles
need a server-side prefs table — suppression happens in the fanout query and an
extension can only modify a notification, not suppress it.

---

## Realtime Connection Recovery

File: `Core/Realtime/RealtimeConnectionMonitor.swift` (+ `ReconnectingPillView.swift`).
Started from `ContentView.onAppear`, stopped in `.onDisappear`.

Realtime used to die permanently after any network interruption: retries gave up
after ~12s and nothing tried again. The WebSocket carries only change events (all
fetches are HTTPS, pushes are OS-level), so a dead socket looks like a *frozen* UI,
not an empty one — which is why recovery is a non-blocking pill, never a skeleton.
supabase-swift reconnects on foreground and retries **once** after a connection
error; it does not handle server-initiated closes or know about the network path.

**Four recovery signals**, all funnelled into one debounced, single-flight sweep
that runs every registered reconnect closure:
1. `NWPathMonitor` — back to `.satisfied`, or a WiFi↔cellular interface change.
2. `UIApplication.willEnterForegroundNotification`.
3. `supabase.realtimeV2.onStatusChange` — a connected→lost→connected cycle.
4. A 30s periodic re-sweep while unhealthy.

**Invariants:**
- **Refetch on reconnect, not just resubscribe.** Reattaching only delivers future
  events; without the refetch the UI reconnects and still shows stale data.
- **Subscribe first, then refetch** — the catch-up runs inside the realtime task
  right after `subscribe` returns, so an event landing during the refetch is either
  delivered live or included in the fetch.
- **Never give up.** `subscribe` retries forever with capped backoff (2/4/8/16/30s).
  Safe only because it runs inside a `realtimeTask` that every `startRealtime`
  cancels on teardown — keep that relationship.
- **`NWPathMonitor` and `onStatusChange` replay their current value on subscribe.**
  `hasSeenInitialPath` / `hasEverConnected` stop that first callback from tearing
  down a subscription still being set up.
- **Resubscribing tears down first:** cancel task, `removeChannel`, rebuild with a
  `UUID()`-salted topic. Re-invocation is safe and is what the reconnect closure does.
- **Register once (guarded on a nil token), unregister in `stopRealtime`.** Closures
  are `[weak self]`; the monitor outlives every view model.

**Per-subscriber catch-up:** `ConversationListViewModel` → `refresh` +
`refreshFriendRequestCount`; `ChatViewModel` → `mergeLatestMessages` + pins +
reactions + read status + request state; `ThreadViewModel` → `load()`;
`FriendsViewModel` → `loadAll(showSpinner: false)`; `PresenceService` → `goOnline`.

`ChatViewModel.mergeLatestMessages` **merges** the newest page by id rather than
replacing `messages`, leaving `nextCursor`/`hasMore` alone — that preserves pages
from `loadOlderMessages()` and the scroll position; in-flight optimistic sends keep
their temp id.

The pill appears only after ~4s of sustained failure and clears on first success.

---

## Tech Stack

| Layer | Technology | Why |
|-------|-----------|-----|
| UI | SwiftUI | iOS 17 features (NavigationStack, @Observable) |
| State | `@Observable` (Swift 5.9 Observation) | Less boilerplate than ObservableObject/Combine |
| Backend | supabase-swift v2 | Same Supabase project as web: auth, PostgREST, Realtime, Storage |
| Crypto | Apple CryptoKit | P256.KeyAgreement + AES.GCM, no bundle cost |
| Key storage | Keychain (KeychainSwift) | Private keys `afterFirstUnlockThisDeviceOnly` |
| Image loading | Kingfisher | Async fetch + disk cache; `KFAnimatedImage` for GIFs/stickers |
| Packages | Swift Package Manager | No CocoaPods/Carthage |

---

## Schema: iOS-specific notes

The schema, RPCs and their error strings are in `../CLAUDE.md`. iOS decoding
gotchas that are not visible from the schema:

- **`notes.user_id`** is the owner FK (not `created_by`). `NoteRepository` was once
  wrong about this and silently loaded nothing.
- **`reminders`** has no `target_type`; creator is `user_id`. Shared with all
  conversation members since migration 00022, so `ReminderRepository` queries
  without a `user_id` filter and lets RLS enforce membership.
- **`devices.identity_key`** JWK has extra fields — decode via `JWKCoords` (above).
- **`message_reactions`** PK is `(message_id, user_id, emoji)`, so the DB allows
  several per user. `ChatViewModel.setReaction` enforces **one per user**
  (Messenger style): `MessageRepository.removeAllReactions(messageId:userId:)` then
  insert. Web allows multiple; if they must match, add a DB constraint.
- **`pinned_messages`** — `MessageRepository.fetchPinnedMessageIds` / `pinMessage`
  / `unpinMessage`; `ChatViewModel.pinnedMessageIds` + `togglePin`; realtime on the
  table is a pure refetch trigger.
- **Username uniqueness** — `Core/Supabase/UsernameAvailability.swift`
  (`UsernameAvailabilityChecker`, 400ms debounce) mirrors the web hook so Save is
  blocked *before* a write. Call sites: `AuthViewModel.checkUsernameAvailability`
  (sign-up) and `AccountSettingsViewModel.checkUsernameAvailability` (passes
  `excluding: userId`). Both still catch `23505` on the write as the last-resort guard.
- **Phase-1 text** — `Data(plaintext.utf8).base64EncodedString()` / `String(data:encoding: .utf8)`.
  Never Latin-1 byte-by-byte; it breaks emoji.

---

## Architecture

```
YaplyApp (@main)
  └── ContentView                  ← auth gate: AuthView vs MainView
        ├── AuthView               ← sign in / sign up toggle
        └── NavigationStack        ← path managed by AppRouter
              └── ConversationListView (root)
                    └── ChatView (pushed on row tap)
```

**Pattern:** MVVM with `@Observable` ViewModels. Views own their VM via
`@State private var vm = MyViewModel()`. Shared services (AuthService, AppRouter,
PresenceService) live in `@Environment`. Repositories are plain `final class`.

**Real-time house style:** every subscription treats the payload as an invalidation
trigger and re-fetches — never parse the row (matches web). `ChatViewModel`
subscribes to `messages` insert **and** update (remote deletes arrive as an
`UpdateAction` setting `deleted_at`; own-message updates are skipped to avoid
double-processing optimistic state).

---

## Project Structure

The active project is `yaply/yaply/` (Xcode project) plus the
`yaply/YaplyNotificationService/` extension target. **`Sources/yaply/` is a stale
SPM layout — never edit or add files there.**

Convention: `Features/<Name>/{Repositories,ViewModels,Views}` (smaller features
are flat). Cross-cutting code: `Core/` (Supabase client, Keychain, Realtime
monitor, shared UI, extensions), `Models/` (Codable structs mirroring the DB),
`Navigation/` (`AppRoute`, `AppRouter`). Current feature folders: Auth, Chat,
Friends, Devices, Encryption, Events, Albums, Budgets, Home, Media, Notifications,
Presence, Commands, Productivity (Tasks/Notes/Reminders), Settings.

---

## Configuration

Keys are read from `Bundle.main.infoDictionary` (via `Config.xcconfig` → `Info.plist`),
falling back to `ProcessInfo.processInfo.environment`. Copy
`Config.xcconfig.example` → `Config.xcconfig` (gitignored):
```
SUPABASE_URL = https://your-project.supabase.co
SUPABASE_ANON_KEY = your-anon-key
GIPHY_API_KEY = your-giphy-key
```

---

## Development Notes

- **`@Observable` requires iOS 17+** — do not lower the deployment target.
- **`YaplyTask`** (not `Task`) — avoids collision with Swift concurrency.
- **Encryption init** runs on `AuthService` login via `EncryptionRegistrar`.
- **Message decryption** happens in `ChatViewModel` after fetching — never store or
  render raw ciphertext.
- **Conversation delete = membership delete only.** `ConversationRepository.deleteConversation`
  removes the user's own `conversation_members` row; the DB trigger
  `trg_delete_empty_conversation` removes the conversation when nobody is left.
- **System messages:** `type == "system"`, `iv = nil`, `deleted_at = now + 7d` (set
  at insert). `MessageBubbleView` returns `EmptyView` when `deletedAt <= Date()` —
  never "Message deleted". Active ones render as a centered pill with an
  "Open {tab} →" button; `systemMessageTabMap` maps content prefixes
  ("Task created" → tasks, "Plan created" → events, …) to `ConversationDetailView` tabs.
- **Sidebar refetch after slash commands:** after a `/task` `/note` `/remind`
  `/album` `/budget` `/event` `/plan` insert, `ChatView` posts
  `Notification.Name.yaplyItemCreated` (defined in `Core/Extensions/String+Utils.swift`)
  with `userInfo["type"]`; each list view `.onReceive`s it and reloads on match.
- **Events availability slot keys** are UTC ISO strings (`"2025-06-10T13:00:00.000Z"`)
  built from local-time `Date`s via `ISO8601DateFormatter` with `timeZone = UTC` and
  `.withFractionalSeconds`, 8am–10pm local in 30-min rows — must match web or the
  heatmap breaks. Every formatter that parses a slot key back must also set UTC.
- **`RemindHandler`** always schedules a local `UNNotificationRequest` for the creator.
- **`ConversationDetailView`** is the iOS equivalent of the web's right-hand
  `ConversationPanel` (tabs: Tasks | Notes | Reminders | Events | Albums | Budgets),
  opened from the `list.bullet.rectangle.portrait` toolbar button or a system-message
  link (`initialTab`).
- **Destructive confirmations** everywhere use native `.alert` with
  `Button(role: .destructive)` + `Button(role: .cancel)`; list rows use
  `.swipeActions` gated on creator/admin where RLS would reject the write.
- **SourceKit cross-file diagnostics** are spurious for new files ("Cannot find
  type") — verify in Xcode, not the SourceKit panel.

---

## Friends System (migration 00033)

Files: `Features/Friends/Repositories/FriendsRepository.swift` (all RPC/table
calls), `FriendsRepository+Errors.swift` (`friendlyFriendsError`, RPC error string →
human text), `ViewModels/FriendsViewModel.swift` (one VM for every tab),
`ViewModels/ProfileCardViewModel.swift`, `Views/FriendsView.swift` (pushed via
`AppRoute.friends`; hand-rolled pill tabs Friends/Requests/Sent/Discover/Blocked, no
`TabView`), `Views/ProfileView.swift` (the one shared profile card, always a
`.sheet`), `Views/UserRowView.swift`, `Views/MessageRequestBarView.swift` (replaces
`MessageInputView` while `ChatViewModel.myRequestState == "pending"`),
`Views/MessageRequestsView.swift`. `ConversationListItem.requestState` drives the
"Message requests" split in `ConversationListView`;
`ConversationListViewModel.pendingFriendRequestCount` (refreshed off a
`friendships` realtime subscription) drives the badge on the `person.2` header icon.

Semantics (friend requests vs message requests, `request_state`, blocks) are in
`../CLAUDE.md`. The iOS contract:
- Create/accept/block only via `send_friend_request` / `accept_friend_request` /
  `block_user`; `friendships` has no INSERT/UPDATE policy so a direct write fails
  silently. Decline, cancel and unfriend are all `FriendsRepository.removeFriendship(friendshipId:)`.
- Relationship state via **batched** `get_relationships([uuid])`
  (`FriendsRepository.fetchRelationships(userIds:)`), always the full array in one
  round trip. Render `blocked_by` identically to `none`.
- People search uses `search_users` (`FriendsRepository.searchUsers`) — this
  replaced the raw `profiles` ilike search in `ConversationRepository` and
  `GroupInfoView`'s add-member search.
- `'pending'` conversations: separate section, composer replaced by the
  Accept/Decline/Block bar, excluded from unread counts and banners. Accept/decline
  is an UPDATE of your **own** member row — **never a DELETE** (the empty-conversation
  trigger would take the whole thread).
- Map RPC errors through `friendlyFriendsError(_:)`: `blocked`,
  `cannot send in this conversation`, `can only add friends to groups`,
  `friend request already exists`, `cannot friend yourself`, `cannot message yourself`.
- All gating is server-side; a Swift-side check is decorative.

**Not yet built:** unfriend/block shortcut from a group member row (only via
`ProfileView`); friend-request push notifications are in-app badge/realtime only.

---

## Message long-press actions (Messenger / Instagram style)

Long-pressing a bubble (`MessageBubbleView.onLongPress`, 0.3s + haptic) opens
`MessageActionsOverlay` — a full-screen `.ultraThinMaterial` scrim. The tapped bubble
**stays exactly in place**: `BubbleAnchorKey` records each bubble's global `CGRect`
(measured on `bubbleContent`, not the row), the original is `.opacity(0)`'d, and the
overlay renders a pixel-aligned `BubbleContentView` copy at that rect. The reaction
rail floats above and the action card below; the group only shifts vertically
(`verticalShift`) if either would clip (card visibility wins).

- **Reaction rail:** the user's 6 personalized emoji + `+`. Tap applies via
  `ChatViewModel.setReaction` (single-reaction). `+` opens `EmojiPickerSheet`; the
  pick is applied and `CustomReactionStore.promote` swaps it into the last rail
  slot. The rail set is `UserDefaults` (`yaply.customReactions.v1`) — **device-local**.
- **Action card:** Reply · Copy · More; More → Pin/Unpin · Delete (own only) · More
  (back). Translate is deliberately absent. Delete routes to `ChatView`'s
  `yaplyConfirm`; Copy puts `message.content` (or media URL) on `UIPasteboard`.

`MessageBubbleView` no longer uses `.contextMenu` at all. Other gestures: swipe
right on a bubble = reply; swipe left on own bubble reveals the timestamp
(`ChatView` owns a single `swipeOffset` so only one shows).

---

## Composer attachment menu & expression picker

`MessageInputView` follows the Messenger composer model: a leading **`+`** toggles to
`chevron.right` and reveals **File · Camera · Voice message · Image**; the text
field narrows; the menu auto-collapses on focus or first keystroke. `ChatView` owns
presentation: `photosPicker` (Image), `fullScreenCover` → `CameraPicker`
(`UIImagePickerController(.camera)`), `fileImporter` →
`ChatViewModel.sendFileMessage` (`type:"file"`), and Voice swaps the whole composer
for `VoiceRecorderBar` (like the `MessageRequestBarView` swap). `ThreadView` passes
`showAttachments: false`.

A `face.smiling` button inside the field opens `ExpressionPickerSheet` (tabs: GIFs —
reuses `GifPickerView`; Stickers / Voice notes — "coming soon" reusable-clip features).

**Voice messages** (`type:"voice"`): `AudioRecorderService` records AAC `.m4a`
(`AVAudioRecorder`); `ChatViewModel.sendVoiceMessage` uploads via
`MediaUploadService.uploadFile` to `media` and sends `type:"voice"`,
`media_mime:"audio/mp4"`, `content:""`, `iv:nil` — **not** the envelope RPC (media
is never E2E). `VoiceMessageBubble` (AVPlayer) plays back. Needs
`NSMicrophoneUsageDescription`. Web renders `<audio>`; any container/mime change
must land on both platforms.

**File attachments** (`type:"file"`): `FileAttachmentBubble` — icon + filename pill
opening the public media URL. Web renders a download link.

---

## Media: GIFs & Stickers

GIFs send `type:"gif"` with the Giphy URL (hot-linked); photos compress to JPEG as
`type:"image"`. All media is a plain `MessageRepository.sendMessage` insert —
`content:""`, `iv:nil`, `enc_v` NULL — **never** the envelope RPC.

**Animated playback:** `gif`/`sticker` via Kingfisher `KFAnimatedImage`; stills via
`KFImage`. `GifPickerView` needs `GIPHY_API_KEY`.

**Stickers — no yaply sticker library** (no `stickers` table, no picker tab on iOS).
The user inserts a sticker the device already has (Stickers drawer, Memoji, Markup,
Genmoji):
- **Drag & drop** onto the conversation — `ChatView.onDrop(of: [.image])` →
  `handleDroppedProviders`, with a "Drop to send" overlay.
- **Paste** — `MessageInputView` shows a `PasteButton` when
  `UIPasteboard.general.hasImages`, wired to `onPasteImage`.
- **Sticker vs photo:** `UIImage.hasAlpha` → transparent = sticker
  (`sendStickerMessage`, PNG, `type:"sticker"`, `media_mime:"image/png"`, capped
  512px; `MediaUploadService.uploadImage` takes an `ext` so it keeps `.png`);
  opaque = photo (`sendImageMessage`).
- **Rendering:** `type:"sticker"` is bubble-free — no background/border, ~150pt,
  drop shadow, `StickerPopIn` spring. Reply previews show "Sticker" / "GIF" / "📷 Photo".

**Not built:** iOS 18 inline keyboard sticker/Genmoji insertion (needs a `UITextView`
representable with `supportsAdaptiveImageGlyph` and walking `NSAdaptiveImageGlyph`
runs on send). Drop + paste cover iOS 17.

---

## Known issues

Tracked on GitHub (`WahidKamruddin/yaply-ios`), not here. Check open issues before
touching Events/Albums/Budgets — the linking and confirm flows have several small
open bugs filed from a code review.
