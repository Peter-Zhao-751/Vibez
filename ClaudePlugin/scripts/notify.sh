#!/usr/bin/env bash
#
# vibez hook script.
#
# Dispatches Claude Code lifecycle events to the Vibez Firebase backend
# as push notifications. The user's Vibez ID is generated on first
# SessionStart (or via /vibez:setup) and persisted at
# ~/.config/vibez/vibez-id. VIBEZ_ID env var overrides if set.
#
# Hooks must never block Claude — this script always exits 0, network
# failures are swallowed.

set -uo pipefail

EVENT="${1:-}"

CONFIG_DIR="${HOME}/.config/vibez"
ID_FILE="${CONFIG_DIR}/vibez-id"
LEGACY_TOPIC_FILE="${CONFIG_DIR}/topic"
LOG_FILE="${CONFIG_DIR}/log"
BACKEND_URL="${VIBEZ_BACKEND_URL:-https://us-central1-vibez-backend.cloudfunctions.net}"

# Where setup.sh lives. CLAUDE_PLUGIN_ROOT is set by Claude Code when
# invoking the hook; we fall back to BASH_SOURCE-relative for direct
# `bash notify.sh` runs (mostly _selftest).
SCRIPT_DIR="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/scripts"

# One-shot migration from the old claude-ntfy-named directory used by the
# pre-0.9 Claude Code plugin. Same machine, same ID, same pairing.
OLD_CONFIG_DIR="${HOME}/.config/claude-ntfy"
if [ -d "${OLD_CONFIG_DIR}" ] && [ ! -d "${CONFIG_DIR}" ]; then
    mv "${OLD_CONFIG_DIR}" "${CONFIG_DIR}" 2>/dev/null || true
fi

mkdir -p "${CONFIG_DIR}" 2>/dev/null || true
chmod 700 "${CONFIG_DIR}" 2>/dev/null || true

log() {
    printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >>"${LOG_FILE}" 2>/dev/null || true
}

# --- HUD sidecar log -------------------------------------------------------
# The notch app tails this. Deliberately SEPARATE from post_vibez: the push
# path suppresses events on purpose (block debounce, stop_pending_work gate,
# Stop grace) to protect the phone from spam, and the HUD needs every
# transition. hud_record is therefore called at the EVENT SITE, never from
# inside post_vibez. Never call curl from here — SessionEnd hooks get killed
# fast.
HUD_DIR="${CONFIG_DIR}/hud"
HUD_LOG="${HUD_DIR}/events.jsonl"
HUD_LOG_MAX_BYTES="${VIBEZ_HUD_LOG_MAX_BYTES:-2097152}"
# A junk override would otherwise make the -lt below error out and rotate on
# every single write.
case "${HUD_LOG_MAX_BYTES}" in
    ''|*[!0-9]*) HUD_LOG_MAX_BYTES=2097152 ;;
esac

# BSD date has no %N, and jq is already a hard dependency of this script.
hud_now_ms() { jq -n '(now * 1000) | floor'; }

hud_rotate_if_needed() {
    [ -f "${HUD_LOG}" ] || return 0
    local size
    size="$(wc -c < "${HUD_LOG}" 2>/dev/null | tr -d ' ')"
    case "${size}" in ''|*[!0-9]*) return 0 ;; esac
    [ "${size}" -lt "${HUD_LOG_MAX_BYTES}" ] && return 0
    mv -f "${HUD_LOG}" "${HUD_LOG}.1" 2>/dev/null || true
}

# Walk up the process tree from this hook. Records TWO things:
#   agentPid  the claude/codex/cursor process, for liveness
#   appPid    the OUTERMOST .app ancestor, for click-to-jump
# Outermost matters: taking the first .app lands on "Cursor Helper.app" for
# integrated terminals; continuing to the root correctly yields "Cursor.app".
# Echoes: "<agentPid>|<agentStart>|<appPid>|<appName>"
hud_process_chain() {
    local pid="${PPID}" agent_pid="" app_pid="" app_name="" comm ppid guard=0
    while [ -n "${pid}" ] && [ "${pid}" -gt 1 ] 2>/dev/null && [ "${guard}" -lt 24 ]; do
        guard=$((guard + 1))
        comm="$(ps -o comm= -p "${pid}" 2>/dev/null)"
        [ -z "${comm}" ] && break
        case "${comm}" in
            */claude|*/codex|*/cursor-agent|claude|codex|cursor-agent)
                [ -z "${agent_pid}" ] && agent_pid="${pid}" ;;
        esac
        case "${comm}" in
            *.app/Contents/MacOS/*)
                app_pid="${pid}"
                app_name="$(printf '%s' "${comm}" | sed -E 's|.*/([^/]+)\.app/Contents/MacOS/.*|\1|')" ;;
        esac
        ppid="$(ps -o ppid= -p "${pid}" 2>/dev/null | tr -d ' ')"
        [ -z "${ppid}" ] && break
        pid="${ppid}"
    done
    [ -z "${agent_pid}" ] && agent_pid="${PPID}"
    local agent_start
    agent_start="$(ps -o lstart= -p "${agent_pid}" 2>/dev/null | sed -e 's/^ *//' -e 's/ *$//')"
    printf '%s|%s|%s|%s' "${agent_pid}" "${agent_start}" "${app_pid}" "${app_name}"
}

# hud_record <kind> <sid> <proj> <cwd> <title> [body] [tool]
# A single O_APPEND printf: atomic against the parallel hooks Claude Code fires,
# which is why this is an append-only log and not per-session state files.
hud_record() {
    local kind="$1" sid="$2" proj="$3" cwd="$4" title="$5" body="${6:-}" tool="${7:-}"
    [ -z "${sid}" ] && return 0
    [ "${sid}" = "nosid" ] && return 0
    command -v jq >/dev/null 2>&1 || return 0

    mkdir -p "${HUD_DIR}" 2>/dev/null || return 0
    chmod 700 "${HUD_DIR}" 2>/dev/null || true
    hud_rotate_if_needed

    local ts extra="{}" line
    ts="$(hud_now_ms)" || return 0
    if [ "${kind}" = "start" ]; then
        local chain agent_pid agent_start app_pid app_name
        chain="$(hud_process_chain)"
        agent_pid="${chain%%|*}"; chain="${chain#*|}"
        agent_start="${chain%%|*}"; chain="${chain#*|}"
        app_pid="${chain%%|*}"; app_name="${chain#*|}"
        extra="$(jq -nc \
            --argjson agentPid "${agent_pid:-0}" \
            --arg agentStart "${agent_start}" \
            --argjson appPid "${app_pid:-0}" \
            --arg app "${app_name}" \
            '{agentPid:$agentPid, agentStart:$agentStart}
             + (if $appPid > 0 then {appPid:$appPid, app:$app} else {} end)')"
    fi

    line="$(jq -nc \
        --argjson v 1 --argjson ts "${ts}" \
        --arg sid "${sid}" --arg agent "cc" --arg kind "${kind}" \
        --arg proj "${proj}" --arg cwd "${cwd}" \
        --arg title "$(clamp_field "${title}" 100)" \
        --arg body "$(clamp_field "${body}" 200)" \
        --arg tool "${tool}" \
        --argjson extra "${extra}" \
        '{v:$v, ts:$ts, sid:$sid, agent:$agent, kind:$kind, proj:$proj, cwd:$cwd, title:$title}
         + (if $body != "" then {body:$body} else {} end)
         + (if $tool != "" then {tool:$tool} else {} end)
         + $extra')" || return 0

    printf '%s\n' "${line}" >> "${HUD_LOG}" 2>/dev/null || true
    chmod 600 "${HUD_LOG}" 2>/dev/null || true
}

# Cap on the append-only log. Without one it grows forever (one line
# per hook event). Checked once per session (session-start), not per
# event; an oversized log is trimmed to its newest half.
LOG_MAX_BYTES="${VIBEZ_LOG_MAX_BYTES:-1048576}"
case "${LOG_MAX_BYTES}" in
    ''|*[!0-9]*) LOG_MAX_BYTES=1048576 ;;
esac

rotate_log_if_needed() {
    local size
    [ -f "${LOG_FILE}" ] || return 0
    size="$(wc -c <"${LOG_FILE}" 2>/dev/null | tr -d '[:space:]')"
    case "${size}" in
        ''|*[!0-9]*) return 0 ;;
    esac
    [ "${size}" -gt "${LOG_MAX_BYTES}" ] || return 0
    if tail -c "$((LOG_MAX_BYTES / 2))" "${LOG_FILE}" >"${LOG_FILE}.tmp" 2>/dev/null; then
        mv -f "${LOG_FILE}.tmp" "${LOG_FILE}" 2>/dev/null || rm -f "${LOG_FILE}.tmp" 2>/dev/null || true
    fi
    return 0
}

# Read stdin once if present, into INPUT.
INPUT=""
if [ ! -t 0 ]; then
    INPUT="$(cat 2>/dev/null || true)"
fi

# Resolve the Vibez ID: env wins, else file.
VIBEZ_ID="${VIBEZ_ID:-}"
if [ -z "${VIBEZ_ID}" ] && [ -f "${ID_FILE}" ]; then
    VIBEZ_ID="$(cat "${ID_FILE}" 2>/dev/null | tr -d '[:space:]')"
fi

# Lazy bridge to setup.sh for first-run ID generation. Keeps the
# wordlist in one place (setup.sh) instead of duplicating it here.
ensure_vibez_id() {
    if [ -n "${VIBEZ_ID}" ]; then
        return 0
    fi
    local setup="${SCRIPT_DIR}/setup.sh"
    if [ -x "${setup}" ] || [ -f "${setup}" ]; then
        # Discard human-readable output; we only care about the side
        # effect of writing the ID file.
        bash "${setup}" show >/dev/null 2>&1 || true
        if [ -f "${ID_FILE}" ]; then
            VIBEZ_ID="$(cat "${ID_FILE}" 2>/dev/null | tr -d '[:space:]')"
        fi
    fi
}

# Hard-cap a payload field at N chars with a trailing ellipsis. Call
# sites already clip for display (72/160); this is the defensive floor
# inside post_vibez itself so no future call site can bypass clipping.
# Server mirrors these caps (title 100 / body 200) and clamps too.
# Note: ${#raw} counts bytes under a C locale (chars under UTF-8) — a
# multibyte cut is possible there; the server's surrogate-safe clamp
# is the authoritative bound either way.
clamp_field() {
    local raw="$1" max="$2"
    if [ "${#raw}" -gt "${max}" ]; then
        printf '%s…' "${raw:0:$((max - 1))}"
    else
        printf '%s' "${raw}"
    fi
}

# Per-session block debounce. An agent can fire several block-type
# events for one conversation within seconds — sequential question
# asks before the user answers the first, or paired hooks double-
# firing the same ask. The first shield:on of a burst blocks +
# banners the phone; followers inside the window are pure noise
# (the phone is already blocked). A shield:on send is therefore
# SKIPPED when an AGENT event (shield:on, sent or suppressed) for
# the same session landed within the last
# VIBEZ_BLOCK_DEBOUNCE_SECONDS. shield:off (replies) is invisible
# to the debounce in BOTH directions: it always sends (it's what
# unblocks the phone) and it never touches the stamp — a reply must
# not silence the ask/done that lands seconds later; that's real
# agent activity, not a duplicate. Stamp files hold an epoch
# second; 0 disables the debounce.
DEBOUNCE_SECONDS="${VIBEZ_BLOCK_DEBOUNCE_SECONDS:-5}"
case "${DEBOUNCE_SECONDS}" in
    ''|*[!0-9]*) DEBOUNCE_SECONDS=5 ;;
esac

# Grace window for the Stop push (the completion-boundary flap fix).
# Claude Code re-injects a completed background task's result as a
# synthetic user prompt to auto-resume an idle session; that injection
# fires UserPromptSubmit ~1s after the Stop hook ran. The Stop gate
# (stop_pending_work) only suppresses while a task is STILL in flight —
# but a task that finished a beat before Stop has already left
# background_tasks[], so the gate passes and a false done/shield:on ships,
# only for the auto-resume's shield:off to unblock ~1s later: the phone
# blocks then unblocks (a visible flash). Fix: the Stop push is DEFERRED
# by this many seconds and CANCELLED if any session activity
# (UserPromptSubmit / PostToolUse / a fresh ask) lands first — a genuine
# stop (nothing resumes within the window) still fires, just this many
# seconds later. 0 disables the deferral (send immediately, pre-fix
# behavior). Only the Stop handler defers; explicit asks (AskUserQuestion
# / Notification / permission-request) still block immediately.
STOP_GRACE_SECONDS="${VIBEZ_STOP_GRACE_SECONDS:-3}"
case "${STOP_GRACE_SECONDS}" in
    ''|*[!0-9]*) STOP_GRACE_SECONDS=3 ;;
esac

lastevent_path() {
    local sid="$1"
    [ -z "${sid}" ] || [ "${sid}" = "nosid" ] && return 1
    printf '%s/lastevent.%s' "${CONFIG_DIR}" "${sid}"
}

mark_event() {
    local sid="$1" path
    path="$(lastevent_path "${sid}")" || return 0
    date +%s >"${path}" 2>/dev/null || true
}

clear_event() {
    local sid="$1" path
    path="$(lastevent_path "${sid}")" || return 0
    rm -f "${path}" 2>/dev/null || true
}

within_debounce_window() {
    local sid="$1" path ts now delta
    [ "${DEBOUNCE_SECONDS}" -gt 0 ] || return 1
    path="$(lastevent_path "${sid}")" || return 1
    [ -f "${path}" ] || return 1
    ts="$(tr -cd '0-9' <"${path}" 2>/dev/null)"
    [ -n "${ts}" ] || return 1
    now="$(date +%s)"
    delta="$((now - ts))"
    # A future-dated stamp (clock stepped backward mid-session) must
    # not debounce — a negative delta would pass -lt until wall-clock
    # catches up, eating every block for the session in the meantime.
    # Check-then-stamp is also not atomic across hook processes: two
    # near-simultaneous events can both pass and both send. Accepted —
    # worst case is the pre-debounce behavior, one extra banner.
    [ "${delta}" -ge 0 ] && [ "${delta}" -lt "${DEBOUNCE_SECONDS}" ]
}

# POST a Vibez payload to the backend's /notify endpoint. Title and
# body are required; the four trailing args become the event / shield /
# session / agent fields of the JSON payload (omitted when empty).
post_vibez() {
    local title="$1"
    local body="$2"
    local event="${3:-}"
    local shield="${4:-}"
    local session="${5:-}"
    local agent="${6:-}"
    title="$(clamp_field "${title}" 100)"
    body="$(clamp_field "${body}" 200)"
    session="${session:0:128}"

    if [ -z "${VIBEZ_ID}" ]; then
        log "skip: no Vibez ID configured (event=${EVENT})"
        return 0
    fi
    if ! command -v jq >/dev/null 2>&1; then
        log "skip: jq not installed (event=${EVENT})"
        return 0
    fi

    # Same-conversation debounce: skip block-type sends fired within
    # the window of this session's last AGENT event. Suppressed sends
    # still refresh the stamp (rolling window), so a machine-gun burst
    # stays silent for its whole run, not just its first few seconds.
    if [ "${shield}" = "on" ] && within_debounce_window "${session}"; then
        mark_event "${session}"
        log "debounced: ${title} (event=${event} session=${session})"
        return 0
    fi

    # Claim the stamp BEFORE the network call, not after — shield:on
    # only, since the stamp tracks agent block events exclusively.
    # Hooks run in parallel (Codex fires paired events in the same
    # second); a stamp written only on curl success leaves a 0.5-5s
    # hole during which a concurrent shield:on sees "no stamp" and
    # double-sends. Claiming here narrows the race to the one-liner
    # above. A failed send rolls the claim back (below) so a network
    # blip can't leave a phantom stamp that silences the burst's next
    # event.
    [ "${shield}" = "on" ] && mark_event "${session}" || true

    local payload
    payload=$(jq -nc \
        --arg vibezId "${VIBEZ_ID}" \
        --arg title "${title}" \
        --arg body "${body}" \
        --arg event "${event}" \
        --arg shield "${shield}" \
        --arg session "${session}" \
        --arg agent "${agent}" \
        '{vibezId:$vibezId,title:$title,body:$body}
         + (if $event   != "" then {event:$event}     else {} end)
         + (if $shield  != "" then {shield:$shield}   else {} end)
         + (if $session != "" then {session:$session} else {} end)
         + (if $agent   != "" then {agent:$agent}     else {} end)')

    if curl -fsS --max-time 5 \
        -H "content-type: application/json" \
        -X POST -d "${payload}" \
        "${BACKEND_URL}/notify" >/dev/null 2>&1; then
        log "sent: ${title} (event=${event})"
        # A DELIVERED reply (shield:off) just unblocked the phone, so the
        # next agent block for this session must re-block — not get
        # debounced against the pre-reply stamp. Clear the stamp here so a
        # follow-up permission/ask within the window still banners+blocks.
        # (Fixes the burst under-block: approve → reply unblocks → the next
        # permission prompt was being silently swallowed.) Success only — a
        # failed off unblocked nothing, so leave the stamp for the real
        # block to ride.
        [ "${shield}" = "off" ] && clear_event "${session}" || true
    else
        log "send failed: ${title} (event=${event})"
        # Roll the claim back — shield:on only (off never claimed, and
        # clearing here would erase a legitimate agent stamp): the
        # phone never got this push, so the next agent event for the
        # session must not be debounced against it.
        [ "${shield}" = "on" ] && clear_event "${session}" || true
        # Callers that branch on delivery (the approval watcher's
        # keep-the-fallback path) need the failure surfaced. Matches the
        # Codex plugin's post_vibez. The script never runs under -e and
        # ends in `exit 0`, so unchecked call sites are unaffected.
        return 1
    fi
}

# --- Deferred Stop push (completion-boundary flap fix) ---------------------
# The Stop handler doesn't send done/needs-input directly; it stashes the
# push in a per-session state file and arms a detached child that waits
# STOP_GRACE_SECONDS and only then delivers it — UNLESS a resume/activity
# hook deleted the state file first (clear_stop_pending). That cancellation
# is what swallows the false done at a background-task completion boundary:
# the harness's auto-resume fires UserPromptSubmit ~1s after Stop, well
# inside the grace window, and cancels the pending push before it ships.
# Mirrors the approval watcher's detached-process pattern.

clear_stop_pending() {
    local sid="$1"
    [ -z "${sid}" ] && return 0
    [ "${sid}" = "nosid" ] && return 0
    rm -f "${CONFIG_DIR}/stop-pending.${sid}."*.json 2>/dev/null || true
}

# Arm a deferred Stop push. With the grace window disabled (0), send inline
# — exact pre-fix behavior, so VIBEZ_STOP_GRACE_SECONDS=0 is a clean rollback.
defer_stop_push() {
    local sid="$1" title="$2" body="$3" event="$4"
    if [ "${STOP_GRACE_SECONDS}" -le 0 ] 2>/dev/null; then
        post_vibez "${title}" "${body}" "${event}" "on" "${sid}" "cc"
        return 0
    fi
    local nonce state
    nonce="$(date +%s).$$"
    state="${CONFIG_DIR}/stop-pending.${sid}.${nonce}.json"
    jq -nc \
        --arg sid "${sid}" \
        --arg title "${title}" \
        --arg body "${body}" \
        --arg event "${event}" \
        '{sid:$sid,title:$title,body:$body,event:$event}' >"${state}" 2>/dev/null || {
            # State write failed — fall back to an immediate send so the
            # push isn't lost entirely.
            post_vibez "${title}" "${body}" "${event}" "on" "${sid}" "cc"
            return 0
        }
    chmod 600 "${state}" 2>/dev/null || true
    log "stop: deferred ${event} push armed (grace=${STOP_GRACE_SECONDS}s sid=${sid})"
    # Detach so Claude Code doesn't wait on the grace sleep; redirect every
    # descriptor so the hook process pipes can close.
    nohup bash "${BASH_SOURCE[0]}" _deferred-stop "${state}" \
        </dev/null >/dev/null 2>&1 &
}

# Detached worker: wait out the grace window, then deliver the stashed push
# only if it wasn't cancelled (state file still present). Called via the
# _deferred-stop event so it re-enters with a freshly resolved environment.
run_deferred_stop() {
    local state="$1" sid title body event grace
    [ -f "${state}" ] || return 0
    # Read the stashed push up front so the cancel log can name the session
    # (the marker may be gone by the time we re-check after the sleep).
    sid="$(jq -r '.sid // empty' "${state}" 2>/dev/null)"
    title="$(jq -r '.title // empty' "${state}" 2>/dev/null)"
    body="$(jq -r '.body // empty' "${state}" 2>/dev/null)"
    event="$(jq -r '.event // "done"' "${state}" 2>/dev/null)"
    grace="${STOP_GRACE_SECONDS}"
    case "${grace}" in ''|*[!0-9]*) grace=3 ;; esac
    [ "${grace}" -gt 0 ] && sleep "${grace}"
    # Cancelled in-flight: a resume/activity hook removed the marker.
    if [ ! -f "${state}" ]; then
        log "stop: deferred push cancelled — session resumed before grace elapsed (sid=${sid})"
        return 0
    fi
    # Consume the marker before sending so a late resume can't double-fire it.
    rm -f "${state}" 2>/dev/null || true
    post_vibez "${title}" "${body}" "${event}" "on" "${sid}" "cc"
}

# Per-session pending marker — set by whichever hook just pushed a
# needs-input shield:on (PreToolUse:AskUserQuestion, or Notification for
# a tool-permission prompt) so the Notification hook can skip its
# near-duplicate push (~5-7s after the picker appears). PostToolUse and
# PostToolUseFailure clear it (the gated tool ran = the user answered);
# Stop and UserPromptSubmit clear defensively. Marker file holds an epoch-second
# timestamp and auto-expires after PENDING_TTL_SECONDS, so a missed
# PostToolUse (Claude Code crash, chat closed mid-question, etc.) can't
# silently silence every later Notification for the rest of the session.
PENDING_TTL_SECONDS=30

pending_marker_path() {
    local sid="$1"
    [ -z "${sid}" ] || [ "${sid}" = "nosid" ] && return 1
    printf '%s/pending.%s' "${CONFIG_DIR}" "${sid}"
}

mark_pending() {
    local sid="$1" path
    path="$(pending_marker_path "${sid}")" || return 0
    date +%s >"${path}" 2>/dev/null || true
}

clear_pending() {
    local sid="$1" path
    path="$(pending_marker_path "${sid}")" || return 0
    rm -f "${path}" 2>/dev/null || true
}

has_pending() {
    local sid="$1" path ts now
    path="$(pending_marker_path "${sid}")" || return 1
    [ -f "${path}" ] || return 1
    ts="$(cat "${path}" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    if [ "$((now - ts))" -gt "${PENDING_TTL_SECONDS}" ]; then
        rm -f "${path}" 2>/dev/null || true
        return 1
    fi
    return 0
}

# Claude Code has no hook that fires on the user's response to a permission
# dialog (PermissionRequest fires when the dialog APPEARS; PostToolUse /
# PostToolUseFailure fire when the granted tool FINISHES). For long-running
# shell commands that left the shield up for the whole run after the user
# had already pressed Enter. For Bash approvals, permission-request therefore
# starts a detached watcher that snapshots matching Claude child processes
# before the prompt is answered and sends shield:off as soon as a new
# matching command process starts — approval is the only thing that starts
# it. A denial never starts the command, so the shield stays. PostToolUse /
# PostToolUseFailure remain the fallback for fast commands, edits, MCP calls,
# and picker responses. Mirrored from the Codex plugin's approval watcher —
# keep the two in sync (divergences flagged inline).

# Find the Claude Code process that launched this hook. The approval watcher
# uses that process as its tree root so an unrelated command elsewhere on
# the Mac cannot be mistaken for this approval.
find_claude_ancestor() {
    local pid="${PPID}" comm base lower next
    while [ -n "${pid}" ] && [ "${pid}" -gt 1 ] 2>/dev/null; do
        comm="$(ps -p "${pid}" -o comm= 2>/dev/null | sed -E 's/^[[:space:]]+//')"
        base="${comm##*/}"
        lower="$(printf '%s' "${base}" | tr '[:upper:]' '[:lower:]')"
        case "${lower}" in
            claude|claude-*) printf '%s' "${pid}"; return 0 ;;
        esac
        next="$(ps -p "${pid}" -o ppid= 2>/dev/null | tr -d '[:space:]')"
        case "${next}" in
            ''|*[!0-9]*) return 1 ;;
        esac
        pid="${next}"
    done
    return 1
}

# Print descendant PIDs whose process command contains the approved shell
# command. Both strings are whitespace-normalized because ps flattens newlines
# from multi-line shell commands.
matching_approval_processes() {
    local root_pid="$1" command="$2"
    ps -axo pid=,ppid=,command= 2>/dev/null |
        VIBEZ_ROOT_PID="${root_pid}" VIBEZ_COMMAND="${command}" awk '
            {
                pid = $1
                parent[pid] = $2
                $1 = ""
                $2 = ""
                sub(/^[[:space:]]+/, "")
                text[pid] = $0
                ids[++count] = pid
            }
            END {
                root = ENVIRON["VIBEZ_ROOT_PID"]
                needle = ENVIRON["VIBEZ_COMMAND"]
                gsub(/[[:space:]]+/, " ", needle)
                # ps prints post-spawn argv: the quoting the shell consumed
                # when launching the command never appears there. Strip
                # quotes from both sides so an approved `rg -i "a|b"`
                # matches the spawned `rg -i a|b`. (\047 = single quote.)
                gsub(/["\047]/, "", needle)
                # Wrapped needles arrive as a spawn vector ("zsh -lc <cmd>");
                # sessions that exec the command directly never spawn that
                # wrapper process — only the command itself shows up in ps.
                # Try the prefix-stripped needle too.
                bare = needle
                sub(/^[A-Za-z0-9_.\/-]*sh -l?c /, "", bare)
                descendant[root] = 1

                # Process trees are shallow, but iterate to a fixed point so
                # wrappers such as sandbox-exec -> zsh -> command are covered.
                for (pass = 1; pass <= count; pass++) {
                    changed = 0
                    for (i = 1; i <= count; i++) {
                        pid = ids[i]
                        if (!descendant[pid] && descendant[parent[pid]]) {
                            descendant[pid] = 1
                            changed = 1
                        }
                    }
                    if (!changed) break
                }

                for (i = 1; i <= count; i++) {
                    pid = ids[i]
                    candidate = text[pid]
                    gsub(/[[:space:]]+/, " ", candidate)
                    gsub(/["\047]/, "", candidate)
                    if (pid != root && descendant[pid] &&
                        (index(candidate, needle) > 0 || index(candidate, bare) > 0)) {
                        print pid
                    }
                }
            }
        '
}

start_approval_watcher() {
    local sid="$1" title="$2" tool_name="$3" command="$4"
    local root_pid baseline state nonce

    [ -n "${command}" ] || {
        log "approval-watch: no command in payload (tool=${tool_name} session=${sid})"
        return 0
    }
    # VIBEZ_APPROVAL_ROOT_PID is a test seam — the e2e suite has no claude
    # ancestor, so it pins the tree root to the test shell instead.
    root_pid="${VIBEZ_APPROVAL_ROOT_PID:-}"
    case "${root_pid}" in
        ''|*[!0-9]*)
            root_pid="$(find_claude_ancestor)" || {
                log "approval-watch: no Claude ancestor (session=${sid})"
                return 0
            }
            ;;
    esac
    baseline="$(matching_approval_processes "${root_pid}" "${command}" | tr '\n' ' ')"
    nonce="$(date +%s).$$"
    state="${CONFIG_DIR}/approval-watch.${sid}.${nonce}.json"

    jq -nc \
        --arg sid "${sid}" \
        --arg title "${title}" \
        --arg toolName "${tool_name}" \
        --arg command "${command}" \
        --arg rootPid "${root_pid}" \
        --arg baseline "${baseline}" \
        '{sid:$sid,title:$title,toolName:$toolName,command:$command,
          rootPid:$rootPid,baseline:$baseline}' >"${state}" 2>/dev/null || return 0
    chmod 600 "${state}" 2>/dev/null || true

    log "approval-watch: started (tool=${tool_name} session=${sid})"
    # Redirect every descriptor so Claude Code does not wait for the detached
    # watcher to close the hook process pipes.
    nohup bash "${BASH_SOURCE[0]}" _watch-approval "${state}" \
        </dev/null >/dev/null 2>&1 &
}

watch_approval_start() {
    local state="$1" sid title tool_name command root_pid baseline timeout deadline
    local pid marker

    [ -f "${state}" ] || return 0
    sid="$(jq -r '.sid // empty' "${state}" 2>/dev/null)"
    title="$(jq -r '.title // empty' "${state}" 2>/dev/null)"
    tool_name="$(jq -r '.toolName // "tool"' "${state}" 2>/dev/null)"
    command="$(jq -r '.command // empty' "${state}" 2>/dev/null)"
    root_pid="$(jq -r '.rootPid // empty' "${state}" 2>/dev/null)"
    baseline="$(jq -r '.baseline // empty' "${state}" 2>/dev/null)"
    case "${root_pid}" in
        ''|*[!0-9]*) rm -f "${state}" 2>/dev/null || true; return 0 ;;
    esac
    marker="$(pending_marker_path "${sid}")" || { rm -f "${state}" 2>/dev/null || true; return 0; }

    timeout="${VIBEZ_APPROVAL_WATCH_SECONDS:-600}"
    case "${timeout}" in
        ''|*[!0-9]*) timeout=600 ;;
    esac
    local started
    started="$(date +%s)"
    deadline="$(( started + timeout ))"

    local end_reason="timeout"
    while [ "$(date +%s)" -lt "${deadline}" ]; do
        # DIVERGENCE from the Codex plugin: check the marker file's raw
        # existence, NOT has_pending — this plugin's has_pending applies a
        # 30s TTL and DELETES the marker on expiry (it exists to dedup the
        # Notification near-duplicate). A user can take minutes to answer a
        # permission prompt; expiring here would kill the watcher AND disarm
        # the post-tool-use fallback in one stroke. Raw existence mirrors
        # post-tool-use's deliberate no-TTL check.
        if [ ! -f "${marker}" ]; then end_reason="pending-cleared"; break; fi
        if ! kill -0 "${root_pid}" 2>/dev/null; then end_reason="claude-exited"; break; fi

        for pid in $(matching_approval_processes "${root_pid}" "${command}"); do
            case " ${baseline} " in
                *" ${pid} "*) continue ;;
            esac
            if post_vibez "${title}" "(approved: ${tool_name})" \
                "replied" "off" "${sid}" "cc"; then
                clear_pending "${sid}"
                log "approval-watch: command started (tool=${tool_name} session=${sid})"
            else
                # Keep pending so PostToolUse can retry after a transient
                # network failure.
                log "approval-watch: send failed; keeping fallback (session=${sid})"
            fi
            rm -f "${state}" 2>/dev/null || true
            return 0
        done
        # Each pass is a full `ps -axo` scan. Stay snappy while the user
        # is likely still looking at the prompt, then back off — 10 Hz
        # for the full 10-minute window is real CPU for no benefit.
        if [ "$(( $(date +%s) - started ))" -lt 30 ]; then
            sleep 0.15
        else
            sleep 0.75
        fi
    done

    # Every non-match exit logs its reason — a watcher that never fires must
    # be visible in the log, not indistinguishable from one that never ran.
    log "approval-watch: ended without match (${end_reason}, tool=${tool_name} session=${sid})"
    rm -f "${state}" 2>/dev/null || true
}

# True when the argument is a slash-command invocation — either the bare
# "/foo" form (.prompt of a UserPromptSubmit) or the
# "<command-name>...</command-name>" wrapper Claude Code stores in the
# transcript. Used to suppress phone pushes for scheduled cron-style
# commands that would otherwise spam the phone with bot-driven traffic.
is_slash_command() {
    case "$1" in
        "<command-name>"*|"<command-message>"*|"/"[a-zA-Z]*) return 0 ;;
    esac
    return 1
}

# Pull a JSON field with a default, swallowing jq errors. The default
# applies whenever the result is EMPTY — field absent, explicitly "",
# jq failure, or no stdin — not just when jq exits nonzero (jq exits 0
# for a missing field and even for empty input, which left defaults
# like 'nosid' dead and "" flowing through instead).
jq_get() {
    local query="$1"
    local default="${2:-}"
    local out=""
    if command -v jq >/dev/null 2>&1; then
        out="$(printf '%s' "${INPUT}" | jq -r "${query} // empty" 2>/dev/null)" || out=""
    fi
    if [ -n "${out}" ]; then
        printf '%s' "${out}"
    else
        printf '%s' "${default}"
    fi
}

# Harness-managed pending work advertised in the Stop hook payload
# (Claude Code ≥ 2.1.145): in-flight background tasks (workflows,
# background shells, subagents) and session-scoped scheduled wakeups
# (/loop, ScheduleWakeup, CronCreate). Either one non-empty means the
# turn ended as a pause — the harness will re-invoke the session by
# itself — not as the agent being done. Prints "<tasks> <crons>".
# Absent fields (older Claude Code, task registry unreachable) and
# non-array junk read as 0, failing open to the pre-gate behavior.
stop_pending_work() {
    local bg cron
    bg="$(jq_get '(.background_tasks // []) | if type == "array" then length else 0 end' '0')"
    cron="$(jq_get '(.session_crons // []) | if type == "array" then length else 0 end' '0')"
    case "${bg}" in ''|*[!0-9]*) bg=0 ;; esac
    case "${cron}" in ''|*[!0-9]*) cron=0 ;; esac
    printf '%s %s' "${bg}" "${cron}"
}

# Look up the desktop Claude app's own conversation title. The desktop
# app stores per-session metadata under
#   ~/Library/Application Support/Claude/claude-code-sessions/<workspace>/<some>/local_<uuid>.json
# with a .title field ("auto"-generated like "Fix plugin showing environment name…")
# and a .cliSessionId that matches the hook's session_id. This is the
# title the user actually sees in the desktop app's sidebar.
read_desktop_app_title() {
    local sid="$1"
    [ -z "${sid}" ] && return 0
    [ "${sid}" = "nosid" ] && return 0
    command -v jq >/dev/null 2>&1 || return 0

    local base="${HOME}/Library/Application Support/Claude/claude-code-sessions"
    [ -d "${base}" ] || return 0

    # Fast pre-filter via grep — the bare UUID is unique enough to land
    # on the right file with no false positives. Then validate via jq
    # so we don't accidentally pick a file that mentions the UUID for
    # some other reason.
    local match
    match=$(grep -rl --include='local_*.json' -F "${sid}" "${base}" 2>/dev/null | head -n 1)
    [ -z "${match}" ] && return 0

    jq -r --arg sid "${sid}" '
        select(.cliSessionId == $sid)
        | .title // empty
    ' "${match}" 2>/dev/null
}

# Best identifier we can give the user for "which conversation this is".
# Tries, in order:
#   1. The desktop Claude app's own .title for this session (lookup
#      by cliSessionId in ~/Library/Application Support/Claude/...).
#      This is the title the user actually sees in the app.
#   2. ai-title in the transcript (CLI auto-generated label).
#   3. lastPrompt in the transcript (CLI writes this synchronously;
#      desktop app writes it AFTER hooks fire, so often empty).
#   4. The latest "user" record's string content (desktop app's
#      synchronously-written prompt text, used while the app hasn't
#      generated its real title yet).
#   5. The $hint argument, used by user-prompt-submit which has the
#      typed prompt directly even when the transcript doesn't exist.
#   6. The $fallback argument (usually the project basename).
# Caps at 60 chars with a trailing ellipsis if longer.
read_conversation_title() {
    local transcript="$1"
    local fallback="${2:-Claude Code}"
    local hint="${3:-}"
    local sid="${4:-}"

    local title=""

    # Desktop app's own title takes priority — it's what the user sees
    # in their app sidebar, so the iPhone matching it is least surprising.
    title=$(read_desktop_app_title "${sid}")

    if [ -z "${title}" ] && [ -n "${transcript}" ] && [ -f "${transcript}" ] && command -v jq >/dev/null 2>&1; then
        title=$(jq -r '
            select(.type == "ai-title")
            | .aiTitle // empty
        ' "${transcript}" 2>/dev/null \
            | grep -v '^[[:space:]]*$' \
            | tail -n 1)

        if [ -z "${title}" ]; then
            title=$(jq -r '
                select(.type == "last-prompt")
                | .lastPrompt // empty
            ' "${transcript}" 2>/dev/null \
                | grep -v '^[[:space:]]*$' \
                | tail -n 1 \
                | tr '\n' ' ')
        fi

        # Desktop fallback while the app hasn't generated its title yet:
        # pull the latest user record whose content is a plain string
        # (CLI user records are arrays — last-prompt covers the CLI case).
        if [ -z "${title}" ]; then
            title=$(jq -r '
                select(.type == "user" and (.message.content | type == "string"))
                | .message.content
            ' "${transcript}" 2>/dev/null \
                | grep -v '^[[:space:]]*$' \
                | tail -n 1 \
                | tr '\n' ' ')
        fi
    fi

    # Hint path: typically .prompt from a user-prompt-submit hook,
    # used when the transcript file doesn't exist yet (desktop app
    # creates the file lazily on first user message).
    if [ -z "${title}" ] && [ -n "${hint}" ]; then
        title="${hint}"
    fi

    if [ -z "${title}" ]; then
        printf '%s' "${fallback}"
        return
    fi

    # Cap at 72 chars — the title is the conversation name on its own;
    # status (done / needs-input / replied) lives in the event field.
    if [ "${#title}" -gt 72 ]; then
        printf '%s…' "${title:0:71}"
    else
        printf '%s' "${title}"
    fi
}

# Read the current "last assistant text" from the transcript file, in
# full. No truncation here: last_turn_is_asking must see the entire
# message (the question that flips done→needs-input is often past the
# 160-char display cut), so clipping happens at the call site via
# clip_body — mirroring the Codex plugin's stop handler.
read_last_text() {
    local transcript="$1"
    local raw
    raw=$(jq -r '
        select(.type == "assistant")
        | .message.content[]?
        | select(.type == "text")
        | .text
    ' "${transcript}" 2>/dev/null \
        | grep -v '^[[:space:]]*$' \
        | tail -n 1 \
        | tr '\n' ' ')
    # Drop trailing space from the tr above.
    printf '%s' "${raw% }"
}

# Cap a string at 160 chars for the push body, with a trailing ellipsis
# so consumers can tell the body was clipped instead of just stopping
# mid-sentence. Same implementation as the Codex plugin's clip_body.
clip_body() {
    local raw="$1"
    raw="$(printf '%s' "${raw}" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g;s/^[[:space:]]+//;s/[[:space:]]+$//')"
    if [ "${#raw}" -gt 160 ]; then
        printf '%s…' "${raw:0:159}"
    else
        printf '%s' "${raw}"
    fi
}

last_assistant_excerpt() {
    local transcript
    transcript="$(jq_get '.transcript_path')"
    [ -z "${transcript}" ] && return 0
    [ ! -f "${transcript}" ] && return 0
    command -v jq >/dev/null 2>&1 || return 0

    # Per-transcript cache: stores the last excerpt we've already sent
    # for this session. Stop fires before Claude flushes the
    # just-finished assistant.text — a naive read returns the prior
    # turn's text. Polling + dedupe against this cache fixes the
    # off-by-one.
    local hash cache_file previous=""
    hash="$(printf '%s' "${transcript}" | shasum 2>/dev/null | cut -c 1-12)"
    cache_file="${CONFIG_DIR}/last_excerpt.${hash}"
    [ -f "${cache_file}" ] && previous="$(cat "${cache_file}" 2>/dev/null)"

    # Brief initial pause so an in-flight write has a chance to land.
    sleep 0.4

    local excerpt="" attempt
    for attempt in 1 2 3 4 5 6; do
        excerpt="$(read_last_text "${transcript}")"
        if [ -n "${excerpt}" ] && [ "${excerpt}" != "${previous}" ]; then
            break
        fi
        sleep 0.35
    done

    # If after ~2.5s of polling the excerpt is still empty or identical
    # to what we sent last turn, the just-finished response hasn't been
    # flushed yet. Return empty so the caller skips the push entirely —
    # a generic "Claude finished a turn." is just noise.
    if [ -z "${excerpt}" ] || [ "${excerpt}" = "${previous}" ]; then
        log "stop: no fresh excerpt after polling (transcript=${transcript})"
        return 0
    fi

    printf '%s' "${excerpt}" >"${cache_file}"
    printf '%s' "${excerpt}"
}

# Returns 0 (true) when the assistant excerpt looks like Claude is waiting
# on the user (a "?" anywhere outside code fences, or last sentence
# matches a common asking phrase). 1 (false) otherwise. Operates on the
# already-extracted excerpt so we don't re-read the transcript.
last_turn_is_asking() {
    local text="$1"
    [ -z "${text}" ] && return 1

    # Strip anything that displays as code or as a literal quoted span,
    # so a "?" inside a code sample or quoted phrase doesn't false-positive.
    # Order matters: fenced blocks first (multi-line), then inline spans
    # (paired single-line). Apostrophes are too noisy to handle safely
    # (don't / can't / it's), so single quotes are left alone.
    local cleaned
    cleaned="$(printf '%s' "${text}" \
        | awk 'BEGIN{infence=0}
               /^```/ { infence = 1 - infence; next }
               { if (!infence) print }' \
        | sed -E 's/`[^`]*`//g' \
        | sed -E 's/"[^"]*"//g' \
        | sed -E 's/“[^”]*”//g')"

    # A "?" anywhere in the cleaned text → asking. Catches mid-paragraph
    # questions that a last-sentence-only check would miss (e.g.
    # "Want me to retry? Anyway, moving on.").
    case "${cleaned}" in
        *\?*) return 0 ;;
    esac

    # No "?". Fall back to phrase matching on the last sentence so
    # directive asks ("Let me know what you want.") still register.
    local last
    last="$(printf '%s' "${cleaned}" \
        | tr '\n' ' ' \
        | sed -E 's/([.!?]+)[[:space:]]+/\1\n/g' \
        | grep -v '^[[:space:]]*$' \
        | tail -n 1 \
        | sed -E 's/^[[:space:]]+//')"

    [ -z "${last}" ] && return 1

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

case "${EVENT}" in

    session-start)
        # HUD first: it must land even if ID generation below fails, and it
        # writes to a file, never to stdout (the systemMessage JSON below is
        # a hook output contract).
        sid="$(jq_get '.session_id' 'nosid')"
        cwd="$(jq_get '.cwd')"
        proj="$(basename "${cwd:-unknown}")"
        # No conversation title exists yet at session start; the project name
        # is the honest label, and the first prompt/tool record supersedes it.
        hud_record "start" "${sid}" "${proj}" "${cwd}" "${proj}"
        if [ -z "${VIBEZ_ID}" ]; then
            ensure_vibez_id
            if [ -n "${VIBEZ_ID}" ]; then
                log "generated Vibez ID ${VIBEZ_ID}"
                msg="vibez plugin: your Vibez ID is ${VIBEZ_ID}. Type it into the Vibez iPhone app (Set up notifications widget) to pair this Mac with your phone. Run /vibez:setup to surface it again."
                # systemMessage = visible banner shown to the user.
                # additionalContext = injected so Claude can answer follow-ups.
                printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"vibez plugin first-run setup complete. Vibez ID: %s. The iOS app pairs with this ID via the registerPushToken Cloud Function."}}\n' \
                    "${msg}" "${VIBEZ_ID}"
            else
                log "vibez ID generation failed"
            fi
        else
            log "session-start (Vibez ID exists)"
        fi
        # Clean up the legacy ntfy topic file if it's still around.
        [ -f "${LEGACY_TOPIC_FILE}" ] && rm -f "${LEGACY_TOPIC_FILE}" 2>/dev/null || true
        rotate_log_if_needed
        # Sweep stale debounce stamps so dead sessions don't pile up.
        # (BSD find: -mtime +1 deletes after ~2 days. Stamps go inert
        # seconds after the window closes anyway — this is hygiene.)
        find "${CONFIG_DIR}" -maxdepth 1 -name 'lastevent.*' -mtime +1 -delete 2>/dev/null || true
        # pending.* markers from killed sessions otherwise live forever
        # (post-tool-use deliberately checks raw existence, no TTL), and
        # a resumed session id would treat its first autonomous
        # PostToolUse as a reply (spurious shield:off) — same sweep the
        # Codex plugin runs. last_excerpt.* are per-transcript dedupe
        # caches that go stale once the session ends.
        find "${CONFIG_DIR}" -maxdepth 1 -name 'pending.*' -mtime +1 -delete 2>/dev/null || true
        find "${CONFIG_DIR}" -maxdepth 1 -name 'last_excerpt.*' -mtime +1 -delete 2>/dev/null || true
        # Approval-watcher state files from crashed/killed watchers.
        find "${CONFIG_DIR}" -maxdepth 1 -name 'approval-watch.*.json' -mtime +1 -delete 2>/dev/null || true
        # Deferred-stop markers orphaned by a killed detached worker (they
        # normally live only STOP_GRACE_SECONDS).
        find "${CONFIG_DIR}" -maxdepth 1 -name 'stop-pending.*.json' -mtime +1 -delete 2>/dev/null || true
        ;;

    stop)
        cwd="$(jq_get '.cwd')"
        sid="$(jq_get '.session_id' 'nosid')"
        # Stop fires at every turn boundary, including one the session
        # ends while a background workflow/task is still running or a
        # /loop-style wakeup is scheduled ("Waiting for N dynamic
        # workflows to finish"). The harness resumes the session by
        # itself then — pushing done/shield:on there blocks the phone
        # mid-task and tells the user the agent finished when it
        # didn't. Skip; the eventual real stop (both arrays empty)
        # still pushes.
        pending="$(stop_pending_work)"
        pending_tasks="${pending%% *}"
        pending_crons="${pending##* }"
        if [ "$((pending_tasks + pending_crons))" -gt 0 ]; then
            log "stop: skip — session resumes itself (background_tasks=${pending_tasks} session_crons=${pending_crons} sid=${sid})"
            clear_pending "${sid}"
            exit 0
        fi
        proj="$(basename "${cwd:-unknown}")"
        transcript="$(jq_get '.transcript_path')"
        convo_title="$(read_conversation_title "${transcript}" "${proj}" "" "${sid}")"
        is_slash_command "${convo_title}" && exit 0
        excerpt="$(last_assistant_excerpt)"
        # Skip when polling didn't surface a fresh excerpt — sending a
        # generic "Claude finished a turn." is just noise on the phone.
        if [ -z "${excerpt}" ]; then
            exit 0
        fi
        # Classify on the full excerpt, clip only the push body — the
        # question that flips done→needs-input is often past the
        # 160-char display cut.
        body="$(clip_body "${excerpt}")"
        if last_turn_is_asking "${excerpt}"; then
            stop_kind="needs-input"
        else
            stop_kind="done"
        fi
        # HUD before defer_stop_push: the notch panel must see the turn end
        # now, not STOP_GRACE_SECONDS later, and it must still see it when the
        # deferred push is cancelled by an auto-resume.
        hud_record "${stop_kind}" "${sid}" "${proj}" "${cwd}" "${convo_title}" "${body}"
        # Supersede any still-armed deferred stop for this session (a newer
        # stop replaces the older one), then DEFER this push so an imminent
        # background-task auto-resume can cancel it before it reaches the
        # phone — the completion-boundary flap fix. defer_stop_push sends
        # inline when the grace window is disabled (pre-fix behavior).
        clear_stop_pending "${sid}"
        defer_stop_push "${sid}" "${convo_title}" "${body}" "${stop_kind}"
        clear_pending "${sid}"
        ;;

    pre-tool-use)
        # AskUserQuestion blocks Claude mid-turn waiting for the user's
        # pick. Stop doesn't fire here (stop_reason is tool_use, not
        # end_turn), so this PreToolUse hook is what pings the phone
        # while the picker is pending. The Notification hook fires a
        # second needs-input ~5-7s after the picker appears; the pending
        # marker set below is what makes it skip that near-duplicate.
        tool_name="$(jq_get '.tool_name')"
        [ "${tool_name}" = "AskUserQuestion" ] || exit 0

        sid="$(jq_get '.session_id' 'nosid')"
        # Session is active again — cancel any armed deferred stop; this
        # explicit ask supersedes a stale done/needs-input from the turn
        # boundary just before it.
        clear_stop_pending "${sid}"
        cwd="$(jq_get '.cwd')"
        transcript="$(jq_get '.transcript_path')"
        proj="$(basename "${cwd:-unknown}")"
        convo_title="$(read_conversation_title "${transcript}" "${proj}" "" "${sid}")"
        is_slash_command "${convo_title}" && exit 0

        question="$(jq_get '.tool_input.questions[0].question')"
        [ -z "${question}" ] && question="Claude is asking a question."
        if [ "${#question}" -gt 160 ]; then
            question="${question:0:159}…"
        fi
        hud_record "needs-input" "${sid}" "${proj}" "${cwd}" "${convo_title}" "${question}" "AskUserQuestion"
        post_vibez "${convo_title}" "${question}" "needs-input" "on" "${sid}" "cc"
        mark_pending "${sid}"
        ;;

    post-tool-use|post-tool-use-failure)
        # Serves BOTH PostToolUse and PostToolUseFailure. Claude Code
        # fires PostToolUse only when a tool SUCCEEDS; an errored tool
        # fires PostToolUseFailure instead. Either way the gated tool
        # RAN, which is the only post-approval signal Claude Code gives
        # us — there is no hook at Enter-press time. Without the failure
        # leg, granting a command that then errored stranded the shield
        # until the next successful tool or the 15-min timeout (the
        # 2026-06-11 stuck-shield bug).
        #
        # Two paths land here:
        #
        # 1. AskUserQuestion just returned — the user picked an option
        #    (or clicked Clarify). Picker answers arrive as tool_result
        #    on the next user record, NOT as a typed prompt, so
        #    UserPromptSubmit doesn't fire. This is the only hook that
        #    can lift the shield the PreToolUse push raised. Always
        #    push shield:off.
        #
        # 2. Any other tool — this fires whenever Claude runs a tool
        #    (Bash, Edit, Write, …). When Claude needed permission, the
        #    Notification hook fired earlier and set the pending marker;
        #    the tool only ran because the user pressed 1/2 to grant it.
        #    Push shield:off in that case and clear pending. When no
        #    marker is set, Claude is just autonomously running tools
        #    (accept-edits / bypass / pre-approved) — exit silently so
        #    we don't drown the phone with one shield:off per tool call
        #    (or per failed tool call, on the failure leg).
        #
        #    File existence is checked directly instead of has_pending
        #    so the TTL doesn't apply: the marker's 30s window exists
        #    only to dedup Notification's near-duplicate push, but the
        #    user's permission response itself can take longer than
        #    that. PostToolUse firing for the gated tool is itself
        #    proof the user responded, no matter how long they took.
        tool_name="$(jq_get '.tool_name')"
        sid="$(jq_get '.session_id' 'nosid')"
        # A tool ran = the session is active again. Cancel any armed
        # deferred stop BEFORE the autonomous-tool early-exit below — an
        # auto-resumed session running pre-approved tools (no pending
        # marker) is exactly the completion-boundary case, and it must
        # still cancel the false done even though it exits without sending.
        clear_stop_pending "${sid}"

        cwd="$(jq_get '.cwd')"
        proj="$(basename "${cwd:-unknown}")"
        # HUD ABOVE the autonomous-tool early-exit below. That exit is a push
        # suppression (one shield:off per tool call would drown the phone);
        # for the notch panel every tool call is exactly the "still working"
        # heartbeat it needs. Title is deliberately empty — the reducer keeps
        # the session's known title, and read_conversation_title (a recursive
        # grep of the desktop app's session store) is far too expensive to run
        # on every PostToolUse.
        hud_record "tool" "${sid}" "${proj}" "${cwd}" "" "" "${tool_name}"

        case "${tool_name}" in
            "AskUserQuestion")
                ;;
            *)
                marker="$(pending_marker_path "${sid}")" || exit 0
                [ -f "${marker}" ] || exit 0
                ;;
        esac

        transcript="$(jq_get '.transcript_path')"
        convo_title="$(read_conversation_title "${transcript}" "${proj}" "" "${sid}")"
        is_slash_command "${convo_title}" && exit 0

        # AskUserQuestion's tool_response is the user's actual answer,
        # which is meaningful body content. For shell/edit/etc. the
        # response is command output that may be huge or contain
        # secrets — keep it generic, mirroring the Codex side.
        case "${tool_name}" in
            "AskUserQuestion")
                body="$(jq_get '.tool_response.content')"
                [ -z "${body}" ] && body="(answered)"
                ;;
            *)
                # On the failure leg the user still answered the prompt,
                # but the tool didn't succeed (errored, or the grant was
                # denied) — "approved" would overclaim there.
                if [ "${EVENT}" = "post-tool-use-failure" ]; then
                    body="(answered: ${tool_name})"
                else
                    body="(approved: ${tool_name})"
                fi
                ;;
        esac
        if [ "${#body}" -gt 160 ]; then
            body="${body:0:159}…"
        fi
        post_vibez "${convo_title}" "${body}" "replied" "off" "${sid}" "cc"
        clear_pending "${sid}"
        ;;

    user-prompt-submit)
        # User replied in Claude — fire a push with shield:off so the
        # iOS app lifts the shield for this session. Body is mostly
        # informational; the Vibez app routes on the event + shield axes.
        sid="$(jq_get '.session_id' 'nosid')"
        # THE primary cancel point: the harness re-injects a completed
        # background task as a synthetic user prompt to auto-resume an idle
        # session, which fires THIS hook ~1s after Stop. Cancelling here —
        # first thing, before the slow title lookup — is what swallows the
        # false done within the grace window. A real human reply cancels it
        # too (and the user clearly doesn't need a stale block then).
        clear_stop_pending "${sid}"
        cwd="$(jq_get '.cwd')"
        transcript="$(jq_get '.transcript_path')"
        proj="$(basename "${cwd:-unknown}")"
        prompt="$(jq_get '.prompt')"
        is_slash_command "${prompt}" && exit 0
        # Pass the current prompt as a hint — for desktop sessions the
        # transcript file frequently doesn't exist yet at this point,
        # so falling back to .prompt beats falling back to basename.
        convo_title="$(read_conversation_title "${transcript}" "${proj}" "${prompt}" "${sid}")"
        # Truncate prompt to a short excerpt for the body
        if [ "${#prompt}" -gt 80 ]; then
            prompt="${prompt:0:79}…"
        fi
        [ -z "${prompt}" ] && prompt="(replied)"
        hud_record "prompt" "${sid}" "${proj}" "${cwd}" "${convo_title}" "${prompt}"
        post_vibez "${convo_title}" "${prompt}" "replied" "off" "${sid}" "cc"
        clear_pending "${sid}"
        ;;

    notification)
        # Claude Code fires Notification when Claude needs the user — either
        # asking permission to run a tool (Bash, Edit, Write, etc.) or after
        # ~60s of idle awaiting a response. This hook is the only signal for
        # permission prompts because the plugin's PreToolUse matcher is
        # AskUserQuestion-only.
        #
        # Skip when an AskUserQuestion PreToolUse just pushed for this
        # session — Claude Code fires Notification ~5-7s after the picker
        # appears, which would otherwise look like a duplicate. The marker
        # is cleared by PostToolUse:AskUserQuestion (or Stop /
        # UserPromptSubmit as a safety net).
        sid="$(jq_get '.session_id' 'nosid')"
        message="$(jq_get '.message')"
        log "notification: received (sid=${sid}, message=${message})"
        # A real permission/needs-you notification means the session
        # resumed and is now explicitly asking — supersede any armed
        # deferred stop. (An idle reminder lands ~60s out, long after the
        # grace window, so this is a no-op there.)
        clear_stop_pending "${sid}"

        if has_pending "${sid}"; then
            log "notification: skip — needs-input push still pending for ${sid}"
            exit 0
        fi

        # Filter out the 60s-idle reminder. Anchored prefix match against
        # Claude Code's default idle text — won't accidentally catch a
        # permission message that happens to contain the substring later.
        case "${message}" in
            "Claude is waiting"*)
                log "notification: skip — idle reminder"
                exit 0 ;;
        esac

        cwd="$(jq_get '.cwd')"
        transcript="$(jq_get '.transcript_path')"
        proj="$(basename "${cwd:-unknown}")"
        convo_title="$(read_conversation_title "${transcript}" "${proj}" "" "${sid}")"
        is_slash_command "${convo_title}" && { log "notification: skip — slash command title"; exit 0; }

        [ -z "${message}" ] && message="Claude needs your input."
        if [ "${#message}" -gt 160 ]; then
            message="${message:0:159}…"
        fi
        # Deliberately BELOW the idle-reminder skip and the has_pending skip:
        # both mean "this isn't a new transition" (a 60s nag; a near-duplicate
        # of the ask PreToolUse already recorded), not "don't spam the phone".
        hud_record "needs-input" "${sid}" "${proj}" "${cwd}" "${convo_title}" "${message}"
        post_vibez "${convo_title}" "${message}" "needs-input" "on" "${sid}" "cc"
        # Mark pending so the next PostToolUse can detect the user's
        # response to this permission prompt and push shield:off. The
        # AskUserQuestion path marks pending via PreToolUse; this is
        # the equivalent for tool-permission prompts that arrive via
        # Notification instead.
        mark_pending "${sid}"
        ;;

    permission-request)
        # Claude Code fires PermissionRequest when a permission dialog
        # appears. Unlike the generic Notification message ("Claude needs
        # your permission"), its payload carries tool_name + tool_input,
        # so the banner can show WHAT wants to run — and for shell
        # commands the approval watcher can unshield at process START
        # (the moment the user grants) instead of command completion.
        #
        # Ordering vs the Notification hook, which fires for the same
        # dialog: whichever lands first wins the banner. When this handler
        # is first, the pending marker makes Notification skip its
        # near-duplicate; when Notification is first, the 5s same-session
        # debounce eats this push. The marker and the watcher are set up
        # either way.
        sid="$(jq_get '.session_id' 'nosid')"
        # Explicit permission ask = session resumed and is waiting on the
        # user — supersede any armed deferred stop from the prior turn.
        clear_stop_pending "${sid}"
        cwd="$(jq_get '.cwd')"
        transcript="$(jq_get '.transcript_path')"
        tool_name="$(jq_get '.tool_name' 'tool')"
        proj="$(basename "${cwd:-unknown}")"
        convo_title="$(read_conversation_title "${transcript}" "${proj}" "" "${sid}")"
        is_slash_command "${convo_title}" && exit 0

        # Body: "<tool>: <command>" for shell tools, compact tool_input
        # JSON otherwise — mirrors the Codex permission-request body.
        command="$(jq_get '.tool_input.command')"
        body_detail="${command}"
        if [ -z "${body_detail}" ]; then
            body_detail="$(printf '%s' "${INPUT}" | jq -rc \
                '.tool_input // empty | if type == "string" then . else tostring end' \
                2>/dev/null || true)"
        fi
        if [ -n "${body_detail}" ]; then
            body="${tool_name}: ${body_detail}"
        else
            body="Permission required to run ${tool_name}"
        fi
        if [ "${#body}" -gt 160 ]; then
            body="${body:0:159}…"
        fi

        # Before post_vibez, so the 5s same-session debounce (which exists to
        # spare the phone a second banner) can't hide the ask from the HUD.
        hud_record "needs-input" "${sid}" "${proj}" "${cwd}" "${convo_title}" "${body}" "${tool_name}"
        post_vibez "${convo_title}" "${body}" "needs-input" "on" "${sid}" "cc"
        mark_pending "${sid}"
        case "${tool_name}" in
            Bash|bash)
                start_approval_watcher "${sid}" "${convo_title}" "${tool_name}" "${command}"
                ;;
        esac
        ;;

    session-end)
        sid="$(jq_get '.session_id' 'nosid')"
        cwd="$(jq_get '.cwd')"
        proj="$(basename "${cwd:-unknown}")"
        # Record only — never push, never curl. Claude Code kills SessionEnd
        # hooks quickly during exit (see CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS),
        # and a session that just ended has nothing to tell the phone anyway.
        hud_record "end" "${sid}" "${proj}" "${cwd}" "${proj}"
        ;;

    _watch-approval)
        watch_approval_start "${2:-}"
        ;;

    _deferred-stop)
        run_deferred_stop "${2:-}"
        ;;

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
        check "mid-q-not-trailing" "Want me to retry? Anyway, moving on." 1
        check "mid-q-multi-sentence" "Implemented X. Curious about that bug? Done for now." 1
        check "inline-backtick-q"  "Method \`isReady?\` returns bool. Done."         0
        check "quoted-q-only"      "Set placeholder to \"Should I commit?\" — done." 0
        check "quoted-plus-real-q" "Renamed \`foo?\`. Anything else?"                1
        check "smart-quoted-q"     "Updated to “Should I commit?” — done."           0

        # Stop-path regression: classification must see the FULL assistant
        # text. A question past the 160-char display clip was previously
        # cut off before last_turn_is_asking ran and misread as done.
        check_eq() {
            local name="$1" got="$2" expected="$3"
            if [ "${got}" = "${expected}" ]; then
                pass=$((pass+1))
                printf 'PASS %s\n' "$name"
            else
                fail=$((fail+1))
                printf 'FAIL %s (expected=[%s] got=[%s])\n' "$name" "$expected" "$got"
            fi
        }
        long_q="Some of what we're working on might be easier to explain if I can show it to you in a web browser. I can put together mockups, diagrams, comparisons, and other visuals as we go, especially for the permission screens and onboarding flow. This feature is still new and can be token-intensive. Want to try it?"
        tmp_transcript="$(mktemp)"
        jq -nc --arg t "${long_q}" '{type:"assistant",message:{content:[{type:"text",text:$t}]}}' >"${tmp_transcript}"
        check_eq "read-full-text"          "$(read_last_text "${tmp_transcript}")" "${long_q}"
        check    "late-question-after-160" "$(read_last_text "${tmp_transcript}")" 1
        check_eq "clip-body-caps-at-160"   "$(clip_body "${long_q}" 2>/dev/null)" "${long_q:0:159}…"
        rm -f "${tmp_transcript}"

        long_field="$(printf 'a%.0s' $(seq 1 150))"
        check_eq "clamp-field-caps"   "$(clamp_field "${long_field}" 100)" "${long_field:0:99}…"
        check_eq "clamp-field-passes" "$(clamp_field "short" 100)" "short"

        # Approval process matching — mirrored from the Codex plugin's
        # selftest. A newly spawned descendant containing the exact
        # requested command must be observable, while the current selftest
        # process must not match before that child exists.
        approval_marker="vibez-approval-selftest-$$"
        approval_probe="sleep 2 & wait"
        check_eq "approval-watch-no-process" \
            "$(matching_approval_processes "$$" "${approval_marker}")" ""
        bash -c "${approval_probe}" "${approval_marker}" &
        approval_probe_pid=$!
        sleep 0.1
        approval_matches="$(matching_approval_processes "$$" "${approval_marker}")"
        case " ${approval_matches} " in
            *" ${approval_probe_pid} "*) approval_found="found" ;;
            *) approval_found="missing" ;;
        esac
        check_eq "approval-watch-finds-child" "${approval_found}" "found"
        kill "${approval_probe_pid}" 2>/dev/null || true
        wait "${approval_probe_pid}" 2>/dev/null || true

        # Quoted-command matching. The hook receives the command as the user
        # approved it — quotes intact — but the spawned process's argv has had
        # that quoting consumed by the shell, and ps prints bare argv. The
        # matcher must align the two or any quoted command (most of them)
        # never matches.
        quoted_dir="$(mktemp -d)"
        quoted_script="${quoted_dir}/rgmark"
        printf '#!/bin/bash\nsleep 2 & wait\n' >"${quoted_script}"
        chmod +x "${quoted_script}"
        "${quoted_script}" -n -i "bigg|toggle" /tmp &
        quoted_pid=$!
        sleep 0.1
        quoted_needle="${quoted_script} -n -i \"bigg|toggle\" /tmp"
        quoted_matches="$(matching_approval_processes "$$" "${quoted_needle}")"
        case " ${quoted_matches} " in
            *" ${quoted_pid} "*) quoted_found="found" ;;
            *) quoted_found="missing" ;;
        esac
        check_eq "approval-watch-quoted-cmd" "${quoted_found}" "found"
        kill "${quoted_pid}" 2>/dev/null || true
        wait "${quoted_pid}" 2>/dev/null || true

        # Wrapped needles ("<shell> -lc '<cmd>'") may never appear in ps when
        # the host execs the command directly — the matcher must also try the
        # prefix-stripped needle.
        "${quoted_script}" -q /tmp &
        prefix_pid=$!
        sleep 0.1
        prefix_needle="bash -lc '${quoted_script} -q /tmp'"
        prefix_matches="$(matching_approval_processes "$$" "${prefix_needle}")"
        case " ${prefix_matches} " in
            *" ${prefix_pid} "*) prefix_found="found" ;;
            *) prefix_found="missing" ;;
        esac
        check_eq "approval-watch-shell-prefix" "${prefix_found}" "found"
        kill "${prefix_pid}" 2>/dev/null || true
        wait "${prefix_pid}" 2>/dev/null || true
        rm -rf "${quoted_dir}"

        # Debounce predicate — exercised against a throwaway CONFIG_DIR
        # so a selftest never touches real ~/.config/vibez state, and a
        # pinned window so an env override can't skew the stale test.
        # (LOG_FILE was resolved at startup, so logging is unaffected.)
        dbprobe() {
            if within_debounce_window "$1"; then printf 'debounced'; else printf 'send'; fi
        }
        saved_debounce="${DEBOUNCE_SECONDS}"
        DEBOUNCE_SECONDS=5
        CONFIG_DIR="$(mktemp -d)"
        check_eq "debounce-no-stamp"    "$(dbprobe sess1)" "send"
        mark_event "sess1"
        check_eq "debounce-fresh-stamp" "$(dbprobe sess1)" "debounced"
        printf '%s' "$(( $(date +%s) - 60 ))" >"${CONFIG_DIR}/lastevent.sess2"
        check_eq "debounce-stale-stamp" "$(dbprobe sess2)" "send"
        printf 'junk' >"${CONFIG_DIR}/lastevent.sess3"
        check_eq "debounce-junk-stamp"  "$(dbprobe sess3)" "send"
        printf '%s' "$(( $(date +%s) + 60 ))" >"${CONFIG_DIR}/lastevent.sess4"
        check_eq "debounce-future-stamp" "$(dbprobe sess4)" "send"
        check_eq "debounce-nosid"       "$(dbprobe nosid)" "send"
        DEBOUNCE_SECONDS=0
        check_eq "debounce-disabled"    "$(dbprobe sess1)" "send"

        # post_vibez stamp policy — only agent block events (shield:on)
        # may touch the stamp: claim on send, refresh on suppress, roll
        # back on failure. A user reply (shield:off) must do NONE of
        # those — the debounce dedupes what the AGENT fires; a reply
        # must never silence the ask/done that lands seconds later.
        # curl is shadowed (no network), VIBEZ_ID is forced non-empty,
        # and LOG_FILE points into the throwaway CONFIG_DIR.
        stampprobe() {
            if [ -f "${CONFIG_DIR}/lastevent.$1" ]; then
                printf 'stamped'
            else
                printf 'clean'
            fi
        }
        saved_log="${LOG_FILE}"
        saved_id="${VIBEZ_ID}"
        DEBOUNCE_SECONDS=5
        LOG_FILE="${CONFIG_DIR}/testlog"
        VIBEZ_ID="self-test-self-test"
        curl() { return 0; }
        post_vibez "t" "b" "replied" "off" "pvA" "cc"
        check_eq "stamp-off-send-no-claim"     "$(stampprobe pvA)" "clean"
        post_vibez "t" "b" "needs-input" "on" "pvA" "cc"
        check_eq "stamp-reply-then-ask-sends"  "$(grep -c 'debounced:' "${LOG_FILE}")" "0"
        check_eq "stamp-on-send-claims"        "$(stampprobe pvA)" "stamped"
        post_vibez "t" "b" "done" "on" "pvA" "cc"
        check_eq "stamp-burst-still-debounced" "$(grep -c 'debounced:' "${LOG_FILE}")" "1"
        curl() { return 22; }
        post_vibez "t" "b" "replied" "off" "pvA" "cc"
        check_eq "stamp-off-fail-preserves"    "$(stampprobe pvA)" "stamped"
        post_vibez "t" "b" "needs-input" "on" "pvB" "cc"
        check_eq "stamp-on-fail-rolls-back"    "$(stampprobe pvB)" "clean"

        # Burst under-block fix: a DELIVERED reply (shield:off) clears the
        # session stamp so the next agent block RE-BLOCKS instead of being
        # debounced. Without this, approving a permission (reply unblocks)
        # silently swallowed the next permission prompt that landed within
        # the window. on → off(success) must leave the stamp clean, and a
        # follow-up on must NOT add a 'debounced:' line.
        curl() { return 0; }
        post_vibez "t" "b" "needs-input" "on" "pvC" "cc"
        post_vibez "t" "b" "replied" "off" "pvC" "cc"
        check_eq "stamp-off-clears-on-success" "$(stampprobe pvC)" "clean"
        dbcount_before="$(grep -c 'debounced:' "${LOG_FILE}")"
        post_vibez "t" "b" "needs-input" "on" "pvC" "cc"
        check_eq "reply-clears-debounce" "$(grep -c 'debounced:' "${LOG_FILE}")" "${dbcount_before}"
        unset -f curl
        LOG_FILE="${saved_log}"
        VIBEZ_ID="${saved_id}"

        DEBOUNCE_SECONDS="${saved_debounce}"
        rm -rf "${CONFIG_DIR}"

        # jq_get — the default must apply when the field is absent or
        # empty, not only when jq itself fails (it silently returned ""
        # for missing fields, leaving 'nosid'-style defaults dead).
        saved_input="${INPUT}"
        INPUT='{"present":"val","empty":""}'
        check_eq "jqget-present-field"   "$(jq_get '.present' 'fb')" "val"
        check_eq "jqget-missing-default" "$(jq_get '.missing' 'fb')" "fb"
        check_eq "jqget-empty-default"   "$(jq_get '.empty' 'fb')"   "fb"
        INPUT=''
        check_eq "jqget-noinput-default" "$(jq_get '.x' 'fb')" "fb"
        INPUT="${saved_input}"

        # stop_pending_work — a Stop that fires while the harness still
        # owns work that will resume the session (background workflow /
        # shell / subagent, or a /loop-ScheduleWakeup-CronCreate wakeup)
        # is a pause, not a stop, and must not push done/shield:on.
        # Output is "<tasks> <crons>". Absent fields (Claude Code
        # < 2.1.145, or task registry unreachable) and malformed values
        # must read "0 0" — fail open to the pre-gate behavior.
        saved_input="${INPUT}"
        INPUT='{}'
        check_eq "pendwork-absent-fails-open" "$(stop_pending_work)" "0 0"
        INPUT='{"background_tasks":[],"session_crons":[]}'
        check_eq "pendwork-both-empty"        "$(stop_pending_work)" "0 0"
        INPUT='{"background_tasks":[{"id":"bt1","type":"shell","status":"running","command":"sleep 30"}],"session_crons":[]}'
        check_eq "pendwork-bg-task"           "$(stop_pending_work)" "1 0"
        INPUT='{"background_tasks":[],"session_crons":[{"id":"19759f27","schedule":"53 14 * * *","recurring":false,"prompt":"probe"}]}'
        check_eq "pendwork-cron"              "$(stop_pending_work)" "0 1"
        INPUT='{"background_tasks":[{"id":"a"},{"id":"b"}],"session_crons":[{"id":"c"}]}'
        check_eq "pendwork-both-kinds"        "$(stop_pending_work)" "2 1"
        INPUT='{"background_tasks":"junk","session_crons":42}'
        check_eq "pendwork-malformed"         "$(stop_pending_work)" "0 0"
        INPUT=''
        check_eq "pendwork-no-stdin"          "$(stop_pending_work)" "0 0"
        INPUT="${saved_input}"

        # Deferred-stop completion-boundary fix: the Stop push is stashed in
        # a per-session marker and delivered by a detached worker only if a
        # resume/activity hook didn't cancel it first. Exercised against a
        # throwaway CONFIG_DIR with curl shadowed, grace pinned to 0 (no
        # real sleep), VIBEZ_ID forced, debounce off, and LOG_FILE inside
        # the throwaway dir.
        saved_grace="${STOP_GRACE_SECONDS}"
        saved_log_ds="${LOG_FILE}"
        saved_id_ds="${VIBEZ_ID}"
        saved_deb_ds="${DEBOUNCE_SECONDS}"
        STOP_GRACE_SECONDS=0
        DEBOUNCE_SECONDS=0
        CONFIG_DIR="$(mktemp -d)"
        LOG_FILE="${CONFIG_DIR}/dslog"
        : >"${LOG_FILE}"  # ensure it exists so grep -c yields a clean 0
        VIBEZ_ID="self-test-self-test"
        curl() { return 0; }
        # clear_stop_pending removes the per-session marker(s).
        printf '%s' '{"sid":"dsA","title":"t","body":"b","event":"done"}' >"${CONFIG_DIR}/stop-pending.dsA.1.json"
        check_eq "deferstop-marker-written" "$( [ -f "${CONFIG_DIR}/stop-pending.dsA.1.json" ] && echo yes || echo no )" "yes"
        clear_stop_pending "dsA"
        check_eq "deferstop-clear-removes"  "$(ls "${CONFIG_DIR}"/stop-pending.dsA.*.json 2>/dev/null | wc -l | tr -d '[:space:]')" "0"
        clear_stop_pending "nosid"  # must be a no-op, never error
        # A CANCELLED push (marker cleared) must NOT send.
        printf '%s' '{"sid":"dsB","title":"tb","body":"b","event":"done"}' >"${CONFIG_DIR}/stop-pending.dsB.1.json"
        clear_stop_pending "dsB"
        run_deferred_stop "${CONFIG_DIR}/stop-pending.dsB.1.json"
        check_eq "deferstop-cancelled-no-send" "$(grep -c 'sent:' "${LOG_FILE}" 2>/dev/null | tr -d '[:space:]')" "0"
        # A LIVE push (marker present) sends exactly once and is consumed.
        ds_live="${CONFIG_DIR}/stop-pending.dsC.1.json"
        printf '%s' '{"sid":"dsC","title":"tc","body":"b","event":"done"}' >"${ds_live}"
        run_deferred_stop "${ds_live}"
        check_eq "deferstop-live-sends"     "$(grep -c 'sent: tc (event=done)' "${LOG_FILE}" 2>/dev/null | tr -d '[:space:]')" "1"
        check_eq "deferstop-live-consumed"  "$( [ -f "${ds_live}" ] && echo yes || echo no )" "no"
        # defer_stop_push with grace=0 sends inline (clean rollback path).
        defer_stop_push "dsD" "td" "b" "needs-input"
        check_eq "deferstop-grace0-inline"  "$(grep -c 'sent: td (event=needs-input)' "${LOG_FILE}" 2>/dev/null | tr -d '[:space:]')" "1"
        unset -f curl
        STOP_GRACE_SECONDS="${saved_grace}"
        LOG_FILE="${saved_log_ds}"
        VIBEZ_ID="${saved_id_ds}"
        DEBOUNCE_SECONDS="${saved_deb_ds}"
        rm -rf "${CONFIG_DIR}"

        # Log rotation — an oversized log keeps its newest half; a log
        # under the cap is untouched.
        saved_log="${LOG_FILE}"
        saved_logmax="${LOG_MAX_BYTES:-}"
        LOG_FILE="$(mktemp)"
        LOG_MAX_BYTES=10000
        head -c 20000 /dev/zero | tr '\0' 'x' >"${LOG_FILE}"
        rotate_log_if_needed
        check_eq "logrotate-trims-oversized" "$(wc -c <"${LOG_FILE}" | tr -d '[:space:]')" "5000"
        head -c 400 /dev/zero | tr '\0' 'x' >"${LOG_FILE}"
        rotate_log_if_needed
        check_eq "logrotate-keeps-small"     "$(wc -c <"${LOG_FILE}" | tr -d '[:space:]')" "400"
        rm -f "${LOG_FILE}"
        LOG_FILE="${saved_log}"
        LOG_MAX_BYTES="${saved_logmax}"

        printf '%d passed, %d failed\n' "$pass" "$fail"
        if [ "$fail" = "0" ]; then exit 0; else exit 1; fi
        ;;

    *)
        log "unknown event: ${EVENT}"
        ;;
esac

exit 0
