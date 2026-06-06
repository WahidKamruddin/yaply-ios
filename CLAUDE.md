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

**conversation_members:** `conversation_id, user_id, role ('owner'|'admin'|'member'), joined_at, last_read_at`

**messages:** `id, conversation_id, sender_id, type ('text'|'image'|'gif'|...), content (base64 ciphertext+tag), iv (base64 nonce[12]; nil = phase-1), media_url, media_mime, reply_to_id, thread_id, edited_at, deleted_at, created_at`
- Joined via: `profiles!messages_sender_id_fkey`
- Sort order: `created_at DESC`
- `type = 'text'` for text messages

**Key RPC:** `find_or_create_direct_conversation(target_user_id uuid)` — always use this for DMs (security definer, handles RLS).

**Encryption wire format:** `content = base64(ciphertext + GCM tag[16])`, `iv = base64(nonce[12])` as two separate columns. If `iv` is nil, content is plain base64 plaintext (phase-1 fallback).

**profiles:** `id, username, display_name, avatar_url, bio, public_key, is_online, last_seen_at, created_at, updated_at`

**devices:** `user_id, device_id (int), identity_key (JSON — JWK format public key)`

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

```
Sources/yaply/
├── YaplyApp.swift                     ← @main entry, environment injection
├── ContentView.swift                  ← auth gate
├── Core/
│   ├── Supabase/SupabaseClient.swift  ← singleton, reads keys from Bundle/env
│   ├── Keychain/KeychainService.swift ← SecItem wrappers
│   └── Extensions/
│       ├── Date+ISO8601.swift
│       ├── Data+Base64URL.swift        ← base64url for JWK fields
│       └── String+Utils.swift
├── Models/                            ← Codable structs mirroring actual DB columns
│   ├── Profile.swift
│   ├── Conversation.swift
│   ├── Message.swift
│   └── Device.swift
├── Navigation/
│   ├── AppRoute.swift                 ← Hashable route enum
│   └── AppRouter.swift                ← @Observable NavigationPath manager
└── Features/
    ├── Auth/
    │   ├── Services/AuthService.swift  ← @Observable, wraps supabase.auth.*
    │   ├── ViewModels/AuthViewModel.swift
    │   └── Views/AuthView.swift
    ├── Chat/
    │   ├── Repositories/ConversationRepository.swift
    │   ├── Repositories/MessageRepository.swift
    │   ├── ViewModels/ConversationListViewModel.swift
    │   ├── ViewModels/ChatViewModel.swift
    │   └── Views/  (ConversationListView, ChatView, MessageBubbleView, etc.)
    ├── Encryption/
    │   ├── EncryptionService.swift     ← CryptoKit ECDH + AES-GCM, JWK-compatible
    │   └── KeyStore.swift              ← Keychain-backed key storage
    ├── Presence/PresenceService.swift
    ├── Media/
    │   ├── Services/  (GiphyService, MediaUploadService)
    │   └── Views/     (MediaPickerView, GifPickerView)
    └── Commands/
        ├── CommandParser.swift
        ├── CommandRegistry.swift
        ├── Views/CommandPaletteView.swift
        └── Handlers/  (RemindHandler, MuteHandler)
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
