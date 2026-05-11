# Ignored Conversations

## Problem

Vibez blocks distracting apps on every `_vibez:block:<sessionId>` ping. Some
Claude/Codex conversations are background chores (long-running builds, scheduled
agents, low-stakes pings) where the block is more interruption than help. There
is no way today to mute a specific conversation without disabling Vibez
entirely.

## Goal

Let the user mark individual conversations as "ignored". Future block pings for
an ignored session never apply the shield, never show the in-app overlay, and
the trigger row is rendered as a passive log entry. The user can ignore a
conversation directly from a recent-trigger row, and manage the list (search by
name, toggle on/off) from Settings.

Internally everything is keyed by `sessionId`; the conversation *name* is only
the search/display affordance.

## Non-goals

- Name-pattern or wildcard ignore (always per-sessionId).
- Cross-device sync.
- Retroactive cleanup of an already-shielded block when its conversation is
  newly ignored — the user can use the big toggle for that.
- Suppressing the local UNUserNotification banner that fires upstream of the
  ignore gate.

## Behavior when an ignored conversation pings

The pinged conversation still shows up in **Recent triggers** dimmed with a
`bell.slash` badge, but:

- No `pendingTriggers` entry is added, so the shield does not engage.
- No `BlockedOverlay` is presented.
- The stored `IgnoredConversation.name` is refreshed to the latest title.
- The local notification (UNUserNotification) still fires; it's harmless in
  foreground and `NotifyClient` stays unaware of ignore state.

`_vibez:unblock:<sid>` pings are unchanged — `resolveTrigger` on a sid that was
never blocked is a harmless no-op.

## Data model

### New type

```swift
struct IgnoredConversation: Codable, Identifiable, Equatable {
    var id: String { sessionId }   // sessionId is the natural key
    let sessionId: String
    var name: String               // last-known title; refreshed on each ping
    let ignoredAt: Date
}
```

### New store

```swift
@MainActor
@Observable
final class IgnoreStore {
    private(set) var conversations: [IgnoredConversation]

    init(defaults: UserDefaults = .standard)

    func contains(_ sessionId: String) -> Bool
    func ignore(sessionId: String, name: String)   // upserts, refreshes name
    func unignore(sessionId: String)
    func refreshName(sessionId: String, name: String) // updates if present
}
```

- Persists to `UserDefaults` under key `vibez.ignored.v1` (JSON-encoded array).
- Same pattern as `TriggerStore`: `@Observable`, JSON-codable, `@MainActor`.
- Insertion order = ignore-time order (newest first), matching `TriggerStore`.
- Empty-string and `"nosid"` session IDs are rejected by `ignore(...)`.

### `TriggerEvent` change

Add an optional sessionId:

```swift
struct TriggerEvent: Identifiable, Codable, Equatable {
    var id: UUID
    var receivedAt: Date
    var source: Source
    var title: String?
    var label: String
    var blockSeconds: Int
    var sessionId: String?   // NEW — nil on rows persisted before this change
    // ...
}
```

Codable handles missing field as `nil` automatically. Legacy rows from before
the change can never be ignored (the long-press menu hides on rows where
`sessionId` is `nil` or empty); they rotate out of the 10-event cap quickly.

## Gate placement

Single check site: `ContentView.handleIncoming(_:)` in the `.block` arm.

```swift
case .block:
    recordTrigger(from: message)   // always record (with sessionId)

    if let sid = message.sessionId,
       !sid.isEmpty, sid != "nosid" {
        if ignoreStore.contains(sid) {
            // Refresh the stored name so Settings shows the latest title.
            ignoreStore.refreshName(
                sessionId: sid,
                name: TriggerEvent.cleanedTitle(from: message.title)
            )
            return
        }
        manager.addTrigger(sessionId: sid)
    }

    withAnimation(.easeOut(duration: 0.45)) {
        overlayMessage = message
    }
```

`recordTrigger(from:)` is updated to pass `sessionId` into the `TriggerEvent` it
records.

## UI

### Trigger row long-press

`TriggerRow` (in `Components.swift`) gains:

```swift
let event: TriggerEvent
let theme: Theme
let now: Date
let isIgnored: Bool
let onIgnore: () -> Void
let onUnignore: () -> Void
```

- Apply `.contextMenu { … }` only when `event.sessionId` is non-empty and not
  `"nosid"`. The menu has one item:
  - Not ignored → `Button { onIgnore() } label: { Label("Ignore this conversation", systemImage: "bell.slash") }`
  - Ignored → `Button { onUnignore() } label: { Label("Stop ignoring", systemImage: "bell") }`
- When `isIgnored`, render the row with `.opacity(0.55)` and append a small
  `bell.slash` glyph after the title text.

`RecentTriggersSection` gains `ignoreStore: IgnoreStore` and two closures, and
forwards them to each row's `TriggerRow(...)` call.

### Settings — new section

Inserted in `SettingsView.body` after `notificationsSection`. New state in the
view:

```swift
@State private var ignoreQuery: String = ""
```

The section:

```swift
Section {
    TextField("Search by name…", text: $ignoreQuery)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()

    ForEach(filteredIgnoreRows) { row in
        Toggle(row.name, isOn: ignoreBinding(for: row))
    }

    if filteredIgnoreRows.isEmpty {
        Text(ignoreQuery.isEmpty
             ? "No conversations yet — pings from Claude or Codex will appear here."
             : "No matches.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
} header: {
    Text("Conversations to ignore")
} footer: {
    Text("Ignored conversations still appear in Recent triggers but don't block apps.")
}
```

`filteredIgnoreRows` is the search-filtered union:

```swift
struct IgnoreRow: Identifiable, Hashable {
    let sessionId: String
    let name: String
    var id: String { sessionId }
}

private var filteredIgnoreRows: [IgnoreRow] {
    let q = ignoreQuery.trimmingCharacters(in: .whitespaces)
    // Currently ignored (always shown when matching the query).
    let ignored = ignoreStore.conversations.map {
        IgnoreRow(sessionId: $0.sessionId, name: $0.name)
    }
    // Recent triggers with a sessionId, de-duped against ignored set.
    let ignoredIds = Set(ignored.map(\.sessionId))
    let recent = triggerStore.events.compactMap { event -> IgnoreRow? in
        guard let sid = event.sessionId, !sid.isEmpty, sid != "nosid",
              !ignoredIds.contains(sid),
              let name = event.title, !name.isEmpty
        else { return nil }
        return IgnoreRow(sessionId: sid, name: name)
    }
    // De-dupe the recent list itself (same sid can appear twice).
    var seen = ignoredIds
    let dedupedRecent = recent.filter { seen.insert($0.sessionId).inserted }

    let all = ignored + dedupedRecent
    guard !q.isEmpty else { return all }
    return all.filter { $0.name.localizedCaseInsensitiveContains(q) }
}

private func ignoreBinding(for row: IgnoreRow) -> Binding<Bool> {
    Binding(
        get: { ignoreStore.contains(row.sessionId) },
        set: { newValue in
            if newValue {
                ignoreStore.ignore(sessionId: row.sessionId, name: row.name)
            } else {
                ignoreStore.unignore(sessionId: row.sessionId)
            }
        }
    )
}
```

### Wiring

- `ContentView` owns `@State private var ignoreStore = IgnoreStore()`.
- `ContentView.mainScreen` passes the store + callbacks into
  `RecentTriggersSection(...)`.
- `ContentView`'s `.sheet` passes `triggerStore` and `ignoreStore` into
  `SettingsView(...)`.
- `SettingsView` adds `@Bindable var triggerStore: TriggerStore` and
  `@Bindable var ignoreStore: IgnoreStore` parameters; updates `#Preview` to
  pass throwaway instances.

## Persistence & migration

- `IgnoreStore` writes to `vibez.ignored.v1` — new key, no migration.
- `TriggerEvent` decoding tolerates a missing `sessionId` field (Codable
  default). No version bump needed for `vibez.triggers.v1`.

## File touch list

- `Vibez/Components.swift` — add `sessionId` to `TriggerEvent`; update
  `TriggerRow` (props, context menu, ignored visuals); update
  `RecentTriggersSection` (pass-through props + callbacks).
- `Vibez/IgnoreStore.swift` — new file with `IgnoredConversation` and
  `IgnoreStore`.
- `Vibez/ContentView.swift` — own `ignoreStore`, gate the block path, pass new
  state to `RecentTriggersSection` and `SettingsView`, populate `sessionId` in
  `recordTrigger`.
- `Vibez/SettingsView.swift` — new section, new state, new init params, update
  preview.

## Testing notes

Manual smoke test using the in-app test path (`NotifyClient.injectFakeMessage`)
or by adding a one-off test button:

1. Inject a `_vibez:block:test-conv-A` ping → toggle engages, row appears, overlay shows.
2. Long-press the row → "Ignore this conversation" → row dims, badge appears.
3. Toggle big switch off, then inject the same sid again → row appears dimmed,
   no overlay, big toggle stays off.
4. Open Settings → "Conversations to ignore" → search for "test" → toggle off →
   inject the sid again → blocking resumes.
5. Reload app → ignore list survives.
6. Inject a ping with a different sid → behaves normally (not ignored).
