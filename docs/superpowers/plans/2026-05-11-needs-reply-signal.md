# Needs-Reply Signal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Vibez push title's suffix correctly distinguish "Claude asked you something" from "Claude wrapped a turn," and surface a yellow dot in the iOS Recent Triggers row for entries still awaiting reply.

**Architecture:** A bash heuristic in `notify.sh` inspects the last assistant text and decides whether the `Stop` hook emits `— needs you` or `— done`. A new `_vibez:waiting` marker tag travels alongside the existing `_vibez:block:<sid>` tag so the iOS app can persist a `needsReply` flag on each `TriggerEvent`. The flag drives a yellow dot in `TriggerRow` and is cleared when the matching `_vibez:unblock:<sid>` push arrives.

**Tech Stack:** Bash (plugin hook script), Swift / SwiftUI (iOS app), ntfy.sh (transport).

**Spec:** `docs/superpowers/specs/2026-05-11-needs-reply-signal-design.md`.

---

## File Structure

| File | Responsibility |
|---|---|
| `ClaudePlugin/scripts/notify.sh` | Adds `last_turn_is_asking()` heuristic and `_selftest` mode; updates `stop` and `notification` branches to emit the new tag. |
| `ClaudePlugin/.claude-plugin/plugin.json` | Version bump to `0.6.0`. |
| `Vibez/NotifyClient.swift` | Adds `NtfyMessage.needsReply`, parses `_vibez:waiting` in `handle()`, extends `injectFakeMessage`. |
| `Vibez/Components.swift` | Adds `TriggerEvent.sessionId` + `needsReply` with back-compat decode; renders yellow dot in `TriggerRow`. |
| `Vibez/TriggerStore.swift` | New `clearNeedsReply(forSession:)` mutator. |
| `Vibez/ContentView.swift` | Pipes `sessionId` + `needsReply` into `recordTrigger`; calls `clearNeedsReply` from the `.unblock` branch. |

---

### Task 1: Plugin — `last_turn_is_asking` helper + `_selftest`

**Files:**
- Modify: `ClaudePlugin/scripts/notify.sh`

- [ ] **Step 1: Add the helper near the other transcript helpers**

Insert the following block immediately before the `case "${EVENT}" in` line (around line 263):

```bash
# Returns 0 (true) when the assistant excerpt looks like Claude is waiting
# on the user (last sentence ends with "?", or matches a common asking
# phrase). 1 (false) otherwise. Operates on the already-extracted excerpt
# so we don't re-read the transcript.
last_turn_is_asking() {
    local text="$1"
    [ -z "${text}" ] && return 1

    # Strip triple-fenced code blocks so a "?" inside a code sample
    # doesn't false-positive.
    local cleaned
    cleaned="$(printf '%s' "${text}" \
        | awk 'BEGIN{infence=0}
               /^```/ { infence = 1 - infence; next }
               { if (!infence) print }')"

    # Last non-empty sentence. Split on terminators "."/"!"/"?" followed
    # by whitespace. The terminator is preserved on the segment it
    # belongs to so step "trailing ?" still works.
    local last
    last="$(printf '%s' "${cleaned}" \
        | tr '\n' ' ' \
        | sed -E 's/([.!?]+)[[:space:]]+/\1\n/g' \
        | grep -v '^[[:space:]]*$' \
        | tail -n 1 \
        | sed -E 's/^[[:space:]]+//')"

    [ -z "${last}" ] && return 1

    # Trailing "?"
    case "${last}" in
        *\?) return 0 ;;
    esac

    # Common interrogative openers, case-insensitive.
    local lower
    lower="$(printf '%s' "${last}" | tr '[:upper:]' '[:lower:]')"
    case "${lower}" in
        "should i "*|"do you want"*|"would you like"*|"would you prefer"*|\
        "want me to"*|"shall i"*|"ready to"*|"let me know"*|\
        "which one"*|"which of"*|"how would you"*|"do we"*)
            return 0 ;;
    esac

    return 1
}
```

- [ ] **Step 2: Add a `_selftest` case to the dispatch switch**

Inside the `case "${EVENT}" in ... esac` block, before the existing `*)` catch-all, add:

```bash
    _selftest)
        pass=0; fail=0
        check() {
            local name="$1" input="$2" expected="$3" got
            if last_turn_is_asking "$input"; then got=1; else got=0; fi
            if [ "$got" = "$expected" ]; then
                pass=$((pass+1))
                printf 'PASS %s\n' "$name"
            else
                fail=$((fail+1))
                printf 'FAIL %s (expected=%s got=%s)\n' "$name" "$expected" "$got"
            fi
        }
        check "trailing-q"       "Should I commit this?"          1
        check "mid-q"            "I changed X. Did that work?"     1
        check "no-q"             "I committed the change."         0
        check "code-fence"       "$(printf 'See:\n```bash\nrm -rf /?\n```\nDone.')" 0
        check "phrase-letmeknow" "Let me know if you want this."   1
        check "phrase-done"      "All done."                       0
        check "phrase-shouldi"   "Should I rebase before merging?" 1
        check "trailing-period"  "Looks good."                     0
        printf '%d passed, %d failed\n' "$pass" "$fail"
        if [ "$fail" = "0" ]; then exit 0; else exit 1; fi
        ;;
```

- [ ] **Step 3: Run the selftest to verify it passes**

Run:
```bash
bash ClaudePlugin/scripts/notify.sh _selftest
```

Expected:
```
PASS trailing-q
PASS mid-q
PASS no-q
PASS code-fence
PASS phrase-letmeknow
PASS phrase-done
PASS phrase-shouldi
PASS trailing-period
8 passed, 0 failed
```
Exit code `0`.

If a case fails, do not paper over it. Most likely culprits: the `sed -E` sentence split (BSD vs GNU regex differences), the awk code-fence stripper, or a missing pattern in the `case` glob list. Fix in `last_turn_is_asking` and rerun.

- [ ] **Step 4: Commit**

```bash
git add ClaudePlugin/scripts/notify.sh
git commit -m "vibez plugin: add last_turn_is_asking heuristic + selftest"
```

---

### Task 2: Plugin — wire heuristic into `stop`, tag `notification`

**Files:**
- Modify: `ClaudePlugin/scripts/notify.sh` — `stop)` branch (currently lines 306–317)
- Modify: `ClaudePlugin/scripts/notify.sh` — `notification)` branch (currently line 303)

- [ ] **Step 1: Replace the `stop)` branch**

Find:

```bash
    stop)
        cwd="$(jq_get '.cwd')"
        sid="$(jq_get '.session_id' 'nosid')"
        proj="$(basename "${cwd:-unknown}")"
        transcript="$(jq_get '.transcript_path')"
        convo_title="$(read_conversation_title "${transcript}" "${proj}" "" "${sid}")"
        excerpt="$(last_assistant_excerpt)"
        if [ -z "${excerpt}" ]; then
            excerpt="Claude finished a turn."
        fi
        post_ntfy "${convo_title} — done" "${excerpt}" "default" "white_check_mark,_vibez:block:${sid}"
        ;;
```

Replace with:

```bash
    stop)
        cwd="$(jq_get '.cwd')"
        sid="$(jq_get '.session_id' 'nosid')"
        proj="$(basename "${cwd:-unknown}")"
        transcript="$(jq_get '.transcript_path')"
        convo_title="$(read_conversation_title "${transcript}" "${proj}" "" "${sid}")"
        excerpt="$(last_assistant_excerpt)"
        if [ -z "${excerpt}" ]; then
            excerpt="Claude finished a turn."
        fi
        if last_turn_is_asking "${excerpt}"; then
            post_ntfy "${convo_title} — needs you" "${excerpt}" "high" "bell,_vibez:block:${sid},_vibez:waiting"
        else
            post_ntfy "${convo_title} — done" "${excerpt}" "default" "white_check_mark,_vibez:block:${sid}"
        fi
        ;;
```

- [ ] **Step 2: Add `_vibez:waiting` to the `notification)` branch**

In the `notification)` branch, find:

```bash
        post_ntfy "${convo_title} — needs you" "${message}" "high" "bell,_vibez:block:${sid}"
```

Replace with:

```bash
        post_ntfy "${convo_title} — needs you" "${message}" "high" "bell,_vibez:block:${sid},_vibez:waiting"
```

- [ ] **Step 3: Rerun selftest — confirms the helper still parses**

```bash
bash ClaudePlugin/scripts/notify.sh _selftest
```

Expected: `8 passed, 0 failed`, exit `0`.

- [ ] **Step 4: Commit**

```bash
git add ClaudePlugin/scripts/notify.sh
git commit -m "vibez plugin: branch stop suffix on heuristic + tag _vibez:waiting"
```

---

### Task 3: Plugin — version bump

**Files:**
- Modify: `ClaudePlugin/.claude-plugin/plugin.json:4`

- [ ] **Step 1: Bump version `0.5.0` → `0.6.0`**

Find:
```json
  "version": "0.5.0",
```

Replace with:
```json
  "version": "0.6.0",
```

- [ ] **Step 2: Verify the bump**

```bash
jq -r .version ClaudePlugin/.claude-plugin/plugin.json
```

Expected: `0.6.0`.

- [ ] **Step 3: Commit**

```bash
git add ClaudePlugin/.claude-plugin/plugin.json
git commit -m "Bump vibez plugin to 0.6.0 for needs-reply signal"
```

---

### Task 4: iOS — `NtfyMessage.needsReply` + tag parsing

**Files:**
- Modify: `Vibez/NotifyClient.swift:24-33` (`NtfyMessage` struct)
- Modify: `Vibez/NotifyClient.swift:82-95` (`injectFakeMessage`)
- Modify: `Vibez/NotifyClient.swift:167-182` (tag loop inside `handle()`)

- [ ] **Step 1: Add `needsReply` to `NtfyMessage`**

Find:

```swift
struct NtfyMessage: Equatable {
    let id: String
    let title: String
    let body: String
    let receivedAt: Date
    /// Kind derived from a "_vibez:<kind>:<sid>" tag, if present.
    var kind: NtfyMessageKind = .unknown
    /// Claude Code session_id when the tag is present.
    var sessionId: String? = nil
}
```

Replace with:

```swift
struct NtfyMessage: Equatable {
    let id: String
    let title: String
    let body: String
    let receivedAt: Date
    /// Kind derived from a "_vibez:<kind>:<sid>" tag, if present.
    var kind: NtfyMessageKind = .unknown
    /// Claude Code session_id when the tag is present.
    var sessionId: String? = nil
    /// True when a "_vibez:waiting" tag is present — Claude is parked
    /// on a user reply (either a Notification event or a Stop that
    /// looked like a question).
    var needsReply: Bool = false
}
```

- [ ] **Step 2: Replace the tag loop in `handle()` so it scans for both control tags**

Find:

```swift
        // Look for our control tag "_vibez:<kind>:<sessionId>".
        for tag in payload.tags ?? [] {
            guard tag.hasPrefix("_vibez:") else { continue }
            let parts = tag.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            // ["_vibez", "<kind>", "<sessionId>"]
            guard parts.count == 3 else { continue }
            let kindRaw = String(parts[1])
            let sid = String(parts[2])
            switch kindRaw {
            case "block":   msg.kind = .block
            case "unblock": msg.kind = .unblock
            default:        continue
            }
            msg.sessionId = sid
            break
        }
```

Replace with:

```swift
        // Look for our control tags:
        //   "_vibez:<kind>:<sessionId>"  → block/unblock + session id
        //   "_vibez:waiting"             → orthogonal "awaiting user" flag
        // No early-out: both tags may be present on the same message.
        for tag in payload.tags ?? [] {
            guard tag.hasPrefix("_vibez:") else { continue }
            if tag == "_vibez:waiting" {
                msg.needsReply = true
                continue
            }
            let parts = tag.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            // ["_vibez", "<kind>", "<sessionId>"]
            guard parts.count == 3 else { continue }
            let kindRaw = String(parts[1])
            let sid = String(parts[2])
            switch kindRaw {
            case "block":   msg.kind = .block
            case "unblock": msg.kind = .unblock
            default:        continue
            }
            msg.sessionId = sid
        }
```

- [ ] **Step 3: Extend `injectFakeMessage` to support the new field**

Find:

```swift
    func injectFakeMessage(title: String = "Claude Code — needs you",
                           body: String = "Permission required to run a tool.",
                           kind: NtfyMessageKind = .block,
                           sessionId: String? = "test-session") {
        var msg = NtfyMessage(
            id: UUID().uuidString,
            title: title,
            body: body,
            receivedAt: Date()
        )
        msg.kind = kind
        msg.sessionId = sessionId
        deliver(msg)
    }
```

Replace with:

```swift
    func injectFakeMessage(title: String = "Claude Code — needs you",
                           body: String = "Permission required to run a tool.",
                           kind: NtfyMessageKind = .block,
                           sessionId: String? = "test-session",
                           needsReply: Bool = true) {
        var msg = NtfyMessage(
            id: UUID().uuidString,
            title: title,
            body: body,
            receivedAt: Date()
        )
        msg.kind = kind
        msg.sessionId = sessionId
        msg.needsReply = needsReply
        deliver(msg)
    }
```

- [ ] **Step 4: Compile to verify**

Run:
```bash
xcodebuild -project Vibez.xcodeproj -scheme Vibez \
    -destination 'generic/platform=iOS Simulator' \
    -configuration Debug build 2>&1 | tail -10
```

Expected: output ends with `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Vibez/NotifyClient.swift
git commit -m "NtfyMessage carries needsReply + parses _vibez:waiting tag"
```

---

### Task 5: iOS — `TriggerEvent` gets `sessionId` + `needsReply`

**Files:**
- Modify: `Vibez/Components.swift:325-353` (`TriggerEvent` struct + initializer)

- [ ] **Step 1: Add the two stored fields and update the memberwise init**

Find:

```swift
struct TriggerEvent: Identifiable, Codable, Equatable {
    enum Source: String, Codable { case claude, codex }

    var id: UUID
    var receivedAt: Date
    var source: Source
    /// Conversation name (e.g. "Plan plugin distribution"). May be nil
    /// for older persisted events from before this field existed.
    var title: String?
    /// Body / description of the ping (e.g. "Permission required to
    /// run npm install").
    var label: String
    var blockSeconds: Int

    init(
        id: UUID = UUID(),
        receivedAt: Date = Date(),
        source: Source,
        title: String? = nil,
        label: String,
        blockSeconds: Int
    ) {
        self.id = id
        self.receivedAt = receivedAt
        self.source = source
        self.title = title
        self.label = label
        self.blockSeconds = blockSeconds
    }
```

Replace with:

```swift
struct TriggerEvent: Identifiable, Codable, Equatable {
    enum Source: String, Codable { case claude, codex }

    var id: UUID
    var receivedAt: Date
    var source: Source
    /// Conversation name (e.g. "Plan plugin distribution"). May be nil
    /// for older persisted events from before this field existed.
    var title: String?
    /// Body / description of the ping (e.g. "Permission required to
    /// run npm install").
    var label: String
    var blockSeconds: Int
    /// Claude Code session id, used to match an unblock against the
    /// matching block event. Optional for back-compat with older
    /// persisted events that didn't store it.
    var sessionId: String?
    /// True while this trigger is still parked on a user reply.
    /// Cleared by TriggerStore.clearNeedsReply when the matching
    /// _vibez:unblock arrives. Defaults to false so old persisted
    /// events render without a dot.
    var needsReply: Bool

    init(
        id: UUID = UUID(),
        receivedAt: Date = Date(),
        source: Source,
        title: String? = nil,
        label: String,
        blockSeconds: Int,
        sessionId: String? = nil,
        needsReply: Bool = false
    ) {
        self.id = id
        self.receivedAt = receivedAt
        self.source = source
        self.title = title
        self.label = label
        self.blockSeconds = blockSeconds
        self.sessionId = sessionId
        self.needsReply = needsReply
    }
```

- [ ] **Step 2: Add a custom `Decodable` init so older persisted events keep loading**

Add the following immediately after the memberwise `init(...)` (so it lives inside the `TriggerEvent` struct):

```swift
    private enum CodingKeys: String, CodingKey {
        case id, receivedAt, source, title, label, blockSeconds, sessionId, needsReply
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        receivedAt = try c.decode(Date.self, forKey: .receivedAt)
        source = try c.decode(Source.self, forKey: .source)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        label = try c.decode(String.self, forKey: .label)
        blockSeconds = try c.decode(Int.self, forKey: .blockSeconds)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        needsReply = try c.decodeIfPresent(Bool.self, forKey: .needsReply) ?? false
    }
```

- [ ] **Step 3: Compile**

Run:
```bash
xcodebuild -project Vibez.xcodeproj -scheme Vibez \
    -destination 'generic/platform=iOS Simulator' \
    -configuration Debug build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Vibez/Components.swift
git commit -m "TriggerEvent carries sessionId + needsReply with back-compat decode"
```

---

### Task 6: iOS — `TriggerStore.clearNeedsReply`

**Files:**
- Modify: `Vibez/TriggerStore.swift:13-49`

- [ ] **Step 1: Add the mutator after `clear()`**

Find:

```swift
    func clear() {
        events = []
        save()
    }

    private func load() {
```

Replace with:

```swift
    func clear() {
        events = []
        save()
    }

    /// Marks any TriggerEvent for the given session id as no-longer-
    /// awaiting-reply. Called when a `_vibez:unblock:<sid>` arrives
    /// because the user just replied in that conversation.
    func clearNeedsReply(forSession sid: String) {
        var changed = false
        for i in events.indices where events[i].sessionId == sid && events[i].needsReply {
            events[i].needsReply = false
            changed = true
        }
        if changed {
            save()
        }
    }

    private func load() {
```

- [ ] **Step 2: Compile**

Run:
```bash
xcodebuild -project Vibez.xcodeproj -scheme Vibez \
    -destination 'generic/platform=iOS Simulator' \
    -configuration Debug build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Vibez/TriggerStore.swift
git commit -m "TriggerStore can clear needsReply for a given session id"
```

---

### Task 7: iOS — `ContentView` pipes the new fields + clears on unblock

**Files:**
- Modify: `Vibez/ContentView.swift:122-139` (`recordTrigger`)
- Modify: `Vibez/ContentView.swift:141-148` (`.unblock` branch of `handleIncoming`)

- [ ] **Step 1: Pass `sessionId` and `needsReply` into the TriggerEvent**

Find:

```swift
    private func recordTrigger(from message: NtfyMessage) {
        let conversationName = TriggerEvent.cleanedTitle(from: message.title)
        let description = message.body
        let source = TriggerEvent.detectSource(
            title: message.title,
            body: message.body,
            fallback: agent
        )
        triggerStore.record(
            TriggerEvent(
                receivedAt: message.receivedAt,
                source: source,
                title: conversationName,
                label: description,
                blockSeconds: blockSeconds
            )
        )
    }
```

Replace with:

```swift
    private func recordTrigger(from message: NtfyMessage) {
        let conversationName = TriggerEvent.cleanedTitle(from: message.title)
        let description = message.body
        let source = TriggerEvent.detectSource(
            title: message.title,
            body: message.body,
            fallback: agent
        )
        triggerStore.record(
            TriggerEvent(
                receivedAt: message.receivedAt,
                source: source,
                title: conversationName,
                label: description,
                blockSeconds: blockSeconds,
                sessionId: message.sessionId,
                needsReply: message.needsReply
            )
        )
    }
```

- [ ] **Step 2: Clear the dot from the `.unblock` branch**

Find:

```swift
        case .unblock:
            // Match against pendingTriggers — the user just replied in
            // this conversation, so release the auto-block for it.
            if let sid = message.sessionId {
                manager.resolveTrigger(sessionId: sid)
            }
```

Replace with:

```swift
        case .unblock:
            // Match against pendingTriggers — the user just replied in
            // this conversation, so release the auto-block for it.
            if let sid = message.sessionId {
                manager.resolveTrigger(sessionId: sid)
                triggerStore.clearNeedsReply(forSession: sid)
            }
```

- [ ] **Step 3: Compile**

Run:
```bash
xcodebuild -project Vibez.xcodeproj -scheme Vibez \
    -destination 'generic/platform=iOS Simulator' \
    -configuration Debug build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Vibez/ContentView.swift
git commit -m "ContentView pipes needsReply + clears it on unblock"
```

---

### Task 8: iOS — yellow dot in `TriggerRow`

**Files:**
- Modify: `Vibez/Components.swift:391-451` (`TriggerRow`)

- [ ] **Step 1: Wrap the top-line `Text` in an `HStack` that conditionally prepends a yellow dot**

Find the inner `VStack(alignment: .leading, spacing: 3)` inside `TriggerRow.body`:

```swift
            VStack(alignment: .leading, spacing: 3) {
                Text(topLine)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.fg)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let description = descriptionLine {
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.fgMute)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                Text("\(event.relativeTime(from: now)) · blocked \(event.formattedDuration)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(theme.fgFaint)
            }
```

Replace with:

```swift
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if event.needsReply {
                        Circle()
                            .fill(Color.yellow)
                            .frame(width: 6, height: 6)
                            .accessibilityLabel("Waiting for reply")
                    }
                    Text(topLine)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(theme.fg)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let description = descriptionLine {
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.fgMute)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                Text("\(event.relativeTime(from: now)) · blocked \(event.formattedDuration)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(theme.fgFaint)
            }
```

- [ ] **Step 2: Compile**

Run:
```bash
xcodebuild -project Vibez.xcodeproj -scheme Vibez \
    -destination 'generic/platform=iOS Simulator' \
    -configuration Debug build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Vibez/Components.swift
git commit -m "TriggerRow shows a yellow dot when needsReply is set"
```

---

### Task 9: End-to-end verification on device

**Files:** None — this is a manual smoke test on the physical iPhone (the only place the Vibez app actually runs, per `CLAUDE.md`).

- [ ] **Step 1: Install the latest Vibez build on the device via Xcode**

Run the app from Xcode on the connected iPhone. Confirm the existing trigger list still renders (no decoder regression on old persisted events).

- [ ] **Step 2: Confirm the plugin version is `0.6.0`**

```bash
jq -r .version ClaudePlugin/.claude-plugin/plugin.json
```
Expected: `0.6.0`. If a stale older copy is loaded into Claude Code, reload the plugin (or restart `claude`).

- [ ] **Step 3: Fire a "needs you" Stop**

Open any Claude Code session and send:
```
Respond with exactly: "Done. Should I commit this?"
```
Expected on the iPhone:
- Push title: `<conversation_name> — needs you`
- A new row appears in `Recent triggers` with a **yellow dot** to the left of the conversation name.

- [ ] **Step 4: Fire a "done" Stop**

Send:
```
Respond with exactly: "I committed the change."
```
Expected on the iPhone:
- Push title: `<conversation_name> — done`
- The new row has **no** yellow dot.

- [ ] **Step 5: Reply and confirm the dot clears**

Type any prompt into the same Claude Code session (this fires UserPromptSubmit and sends `_vibez:unblock:<sid>`).

Expected on the iPhone:
- Push title: `<conversation_name> — replied`
- The previously-dotted row for this conversation now has **no** yellow dot.

- [ ] **Step 6: No commit — verification only.**

If anything in steps 3–5 fails: capture the failing case, identify the responsible task (heuristic → Task 1; tag emission → Task 2; tag parsing → Task 4; persistence → Task 5; clearing → Tasks 6/7; UI → Task 8) and fix it there before reverifying.

---

## Self-review (writer-side, not user-facing)

**Spec coverage**
- Plugin heuristic + regex + code-fence stripping: Task 1.
- `stop` branch wiring: Task 2.
- `_vibez:waiting` added to `notification`: Task 2.
- Plugin version bump: Task 3.
- `NtfyMessage.needsReply` + tag parsing: Task 4.
- `TriggerEvent.sessionId` + `needsReply` + Codable back-compat: Task 5.
- `TriggerStore.clearNeedsReply`: Task 6.
- `ContentView` wiring (record + unblock-clear): Task 7.
- Yellow dot in `TriggerRow`: Task 8.
- End-to-end manual verification: Task 9.

All spec sections covered.

**Placeholder scan:** every step contains the actual code or command. No "TODO", "TBD", or "implement later".

**Type / name consistency**
- `last_turn_is_asking` referenced identically in Tasks 1 and 2.
- Tag literal `_vibez:waiting` identical in Tasks 2 and 4.
- Field name `needsReply` identical across `NtfyMessage`, `TriggerEvent`, `injectFakeMessage`, and `clearNeedsReply`.
- Method signature `clearNeedsReply(forSession sid: String)` identical in Tasks 6 and 7.
- Initializer parameter order in `TriggerEvent.init` matches the call site in Task 7.
