# Needs-reply signal across plugin + iOS app

## Problem

The Vibez Claude Code plugin emits three push-title suffixes today:

- `notification` → `… — needs you`
- `stop` → `… — done`
- `user-prompt-submit` → `… — replied`

Claude Code's `Notification` hook only fires for tool-permission requests and idle timeouts. When the assistant writes a question in plain text and stops generating, only the `Stop` hook fires — so the push says `— done` even though the conversation is parked on the user's reply.

The desktop Claude app sidesteps this by showing a yellow dot in the sidebar next to any conversation awaiting user input. The dot is computed at runtime from message activity; there is no on-disk flag to mirror.

The persisted `Recent triggers` list in the iOS app strips the suffix entirely, so the in-app history carries no signal about which conversations are still waiting on the user.

## Goal

Two changes, kept narrow:

1. The push title's suffix correctly distinguishes "Claude asked you something" from "Claude wrapped a turn that doesn't appear to need a reply."
2. The iOS `Recent triggers` row shows a yellow dot next to entries still awaiting user reply, and clears that dot when the user replies in the matching conversation.

Non-goals: changing the blocking behavior (every `Stop` still triggers a block as today), restructuring the trigger list to group by conversation, or reverse-engineering the desktop app's exact dot semantics.

## Approach

### Plugin: heuristic detection in `notify.sh`

New helper `last_turn_is_asking()` invoked from the `stop` branch. It takes the assistant excerpt already produced by `last_assistant_excerpt` (no extra transcript reads) and returns true when:

1. Triple-fenced code blocks (` ``` … ``` `) are stripped first, so a `?` inside a snippet does not false-positive. Inline backticks are left alone.
2. The remaining text is split into sentences on the regex `[.!?]+\s+`, and the last non-empty segment is the "last sentence." The trailing terminator from the split is retained when checking step 3a.
3. Returns true if either:
   a. The last sentence ends with `?`, **or**
   b. The last sentence matches the case-insensitive regex
      `^(should i|do you want|would you (like|prefer)|want me to|shall i|ready to|let me know|which (one|of)|how would you|do we)\b`.

Outcomes for `stop`:

| Heuristic | Suffix | Priority | Tags |
|---|---|---|---|
| Asking | `— needs you` | `high` | `bell,_vibez:block:<sid>,_vibez:waiting` |
| Not asking | `— done` | `default` | `white_check_mark,_vibez:block:<sid>` |

The `notification` branch also adds the `_vibez:waiting` tag (it is always a waiting state).

### Wire format: `_vibez:waiting` marker tag

A second tag, not a parameterized one. The existing `_vibez:<kind>:<sid>` tag continues to carry the block/unblock kind and session id; `_vibez:waiting` is an orthogonal flag.

Chosen over string-matching the suffix because the suffix is human-facing and may be rephrased; the tag is a stable contract between the plugin and the app.

### iOS: parse and persist `needsReply`

`NotifyClient.handle()` already iterates the `tags` array. Add a second pass (or fold into the existing loop):

```swift
var needsReply = false
for tag in payload.tags ?? [] {
    if tag == "_vibez:waiting" { needsReply = true }
    // existing _vibez:<kind>:<sid> parsing unchanged
}
msg.needsReply = needsReply
```

`NtfyMessage` gains `var needsReply: Bool = false`.

`TriggerEvent` (Components.swift:325) gains two fields:

```swift
var sessionId: String?      // for matching unblock events
var needsReply: Bool = false
```

Both default-initialize, keeping existing persisted events readable through `Codable`.

`ContentView.recordTrigger` copies `message.sessionId` and `message.needsReply` onto the new `TriggerEvent`.

### iOS: clearing the dot on reply

Today the `.unblock` branch only updates the `ScreenTimeManager`. Extend it:

```swift
case .unblock:
    if let sid = message.sessionId {
        manager.resolveTrigger(sessionId: sid)
        triggerStore.clearNeedsReply(forSession: sid)
    }
```

New `TriggerStore.clearNeedsReply(forSession sid: String)`:

- Walks `events`.
- For each event whose `sessionId == sid`, flips `needsReply = false`.
- Saves.

There is no UI to manually clear the dot — it clears only when the matching `_vibez:unblock` push arrives.

### iOS: dot in `TriggerRow`

Render a 6pt `Color.yellow` circle inline at the start of the top-line `Text` when `event.needsReply`. Placement mirrors the desktop sidebar's leading-dot convention:

```
[cc] ● Plan plugin distribution
     Permission required to run npm install
     3m ago · blocked 1m
```

Implementation: replace the top-line `Text(topLine)` with an `HStack(spacing: 5)` containing the conditional circle and the text. Hardcoded `Color.yellow` for now; promote to a theme token only if a second consumer appears.

## File-by-file impact

| File | Change |
|---|---|
| `ClaudePlugin/scripts/notify.sh` | Add `last_turn_is_asking()` helper. Branch the `stop` case on it. Add `_vibez:waiting` to `notification` and asking-`stop` tags. |
| `ClaudePlugin/.claude-plugin/plugin.json` | Bump `version` to `0.6.0`. |
| `Vibez/NotifyClient.swift` | Add `needsReply: Bool` to `NtfyMessage`. Parse `_vibez:waiting` in `handle()`. |
| `Vibez/Components.swift` | Add `sessionId: String?` and `needsReply: Bool` to `TriggerEvent`. Update `TriggerRow` to render the dot. |
| `Vibez/TriggerStore.swift` | Add `clearNeedsReply(forSession:)`. |
| `Vibez/ContentView.swift` | Pass `sessionId` and `needsReply` into `recordTrigger`; call `triggerStore.clearNeedsReply(forSession:)` from the unblock branch. |

## Testing

- **Plugin heuristic**: unit-style test by piping a transcript fixture into a wrapped function — not strictly required for a bash script, but worth a manual matrix of 6–8 inputs covering: bare `?` at end, code-fence `?`, "Should I delete this?", "I committed the change.", "Let me know if you want X.", multi-sentence ending non-interrogatively.
- **iOS**: existing "Test push" button (`NotifyClient.injectFakeMessage`) gains a parameter (or a sibling injector) to flip `needsReply`, so the user can preview both states without a real Claude session.
- **End-to-end**: trigger a real Claude turn that ends with a question and confirm the iOS push reads `— needs you` and the trigger row shows the dot. Reply to Claude and confirm the dot disappears.

## Open questions

None blocking. Possible follow-ups, deliberately deferred:

- Splitting block-behavior from clarity: should "done" turns *not* block the phone? Out of scope until the user observes it as a pain point.
- Theme-aware dot color. Hardcoded yellow until there is a second consumer.
- Showing the dot on the home screen header (e.g. "1 conversation waiting"). Out of scope; the row-level signal is the request.
