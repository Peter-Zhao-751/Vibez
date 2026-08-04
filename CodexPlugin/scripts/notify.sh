#!/usr/bin/env bash
#
# vibez hook script (Codex side).
#
# Dispatches Codex lifecycle events to the Vibez Firebase backend as
# push notifications. Vibez ID is shared with the Claude Code vibez
# plugin at ~/.config/vibez/vibez-id so a single ID on the phone covers
# both agents.
#
# Hooks must never block Codex — this script always exits 0, network
# failures are swallowed.

set -uo pipefail

EVENT="${1:-}"

CONFIG_DIR="${HOME}/.config/vibez"
ID_FILE="${CONFIG_DIR}/vibez-id"
LEGACY_TOPIC_FILE="${CONFIG_DIR}/topic"
LOG_FILE="${CONFIG_DIR}/log"
BACKEND_URL="${VIBEZ_BACKEND_URL:-https://us-central1-vibez-backend.cloudfunctions.net}"

# Where setup.sh lives. Codex doesn't set a CLAUDE_PLUGIN_ROOT env
# var, so we resolve via BASH_SOURCE — works for the cache layout
# where notify.sh sits at <plugin>/scripts/notify.sh.
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
    printf '[%s] cx %s\n' "$(date -u +%FT%TZ)" "$*" >>"${LOG_FILE}" 2>/dev/null || true
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

    local extra="{}" line
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

    # ONE jq per record. post-tool-use is the hottest hook in the script (it
    # fires on every tool call), so the timestamp is computed inside this same
    # invocation rather than by a second one — BSD date has no %N, and jq is
    # already a hard dependency here. Only `start` pays for the extra
    # process-chain jq above, once per session.
    line="$(jq -nc \
        --argjson v 1 \
        --arg sid "${sid}" --arg agent "cx" --arg kind "${kind}" \
        --arg proj "${proj}" --arg cwd "${cwd}" \
        --arg title "$(clamp_field "${title}" 100)" \
        --arg body "$(clamp_field "${body}" 200)" \
        --arg tool "${tool}" \
        --argjson extra "${extra}" \
        '{v:$v, ts:(now * 1000 | floor), sid:$sid, agent:$agent, kind:$kind, proj:$proj, cwd:$cwd, title:$title}
         + (if $body != "" then {body:$body} else {} end)
         + (if $tool != "" then {tool:$tool} else {} end)
         + $extra')" || return 0

    printf '%s\n' "${line}" >> "${HUD_LOG}" 2>/dev/null || true
    chmod 600 "${HUD_LOG}" 2>/dev/null || true
}

# Cap on the append-only log. Without one it grows forever (one line
# per hook event). Checked once per session (session-start), not per
# event; an oversized log is trimmed to its newest half. Mirrors the
# Claude plugin (shared LOG_FILE — either plugin's session can trim).
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
        return 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        log "skip: jq not installed (event=${EVENT})"
        return 1
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
        # (Fixes the burst under-block.) Success only — a failed off
        # unblocked nothing, so leave the stamp for the real block to ride.
        [ "${shield}" = "off" ] && clear_event "${session}" || true
        return 0
    else
        log "send failed: ${title} (event=${event})"
        # Roll the claim back — shield:on only (off never claimed, and
        # clearing here would erase a legitimate agent stamp): the
        # phone never got this push, so the next agent event for the
        # session must not be debounced against it.
        [ "${shield}" = "on" ] && clear_event "${session}" || true
        return 1
    fi
}

# Codex has no hook that fires on the user's response to a PermissionRequest
# (approve/deny selection in Codex). PostToolUse is too late for long-running
# shell commands because it fires only after the command completes. For Bash
# approvals, permission-request therefore starts a detached watcher that
# snapshots matching Codex child processes before the prompt appears and sends
# shield:off as soon as a new matching command process starts. A denial never
# starts the command, so it remains blocked. PostToolUse stays as the fallback
# for fast commands, edits, MCP calls, and picker responses.
#
# permission-request and pre-tool-use(question picker) drop a per-session
# marker; the first successful unblock path clears it. stop and
# user-prompt-submit also clear it so a stale marker cannot trigger a false
# shield-off later.
pending_marker_path() {
    local sid="$1"
    [ -z "${sid}" ] || [ "${sid}" = "nosid" ] && return 1
    printf '%s/pending.%s' "${CONFIG_DIR}" "${sid}"
}

mark_pending() {
    local sid="$1" path
    path="$(pending_marker_path "${sid}")" || return 0
    : >"${path}" 2>/dev/null || true
}

clear_pending() {
    local sid="$1" path
    path="$(pending_marker_path "${sid}")" || return 0
    rm -f "${path}" 2>/dev/null || true
}

has_pending() {
    local sid="$1" path
    path="$(pending_marker_path "${sid}")" || return 1
    [ -f "${path}" ]
}

# Find the Codex process that launched this hook. The approval watcher uses
# that process as its tree root so an unrelated command elsewhere on the Mac
# cannot be mistaken for this approval.
find_codex_ancestor() {
    local pid="${PPID}" comm base lower next
    while [ -n "${pid}" ] && [ "${pid}" -gt 1 ] 2>/dev/null; do
        comm="$(ps -p "${pid}" -o comm= 2>/dev/null | sed -E 's/^[[:space:]]+//')"
        base="${comm##*/}"
        lower="$(printf '%s' "${base}" | tr '[:upper:]' '[:lower:]')"
        case "${lower}" in
            codex|codex-*) printf '%s' "${pid}"; return 0 ;;
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
                # Escalation needles arrive shlex-joined as a spawn vector
                # ("zsh -lc <cmd>"); stdin-typed (fork) sessions never spawn
                # that wrapper process — only the command itself shows up in
                # ps. Try the prefix-stripped needle too.
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
    root_pid="$(find_codex_ancestor)" || {
        log "approval-watch: no Codex ancestor (session=${sid})"
        return 0
    }
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
    # Redirect every descriptor so Codex does not wait for the detached watcher
    # to close the hook process pipes.
    nohup bash "${BASH_SOURCE[0]}" _watch-approval "${state}" \
        </dev/null >/dev/null 2>&1 &
}

watch_approval_start() {
    local state="$1" sid title tool_name command root_pid baseline timeout deadline
    local pid

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

    timeout="${VIBEZ_APPROVAL_WATCH_SECONDS:-600}"
    case "${timeout}" in
        ''|*[!0-9]*) timeout=600 ;;
    esac
    local started
    started="$(date +%s)"
    deadline="$(( started + timeout ))"

    local end_reason="timeout"
    while [ "$(date +%s)" -lt "${deadline}" ]; do
        if ! has_pending "${sid}"; then end_reason="pending-cleared"; break; fi
        if ! kill -0 "${root_pid}" 2>/dev/null; then end_reason="codex-exited"; break; fi

        for pid in $(matching_approval_processes "${root_pid}" "${command}"); do
            case " ${baseline} " in
                *" ${pid} "*) continue ;;
            esac
            if post_vibez "${title}" "(approved: ${tool_name})" \
                "replied" "off" "${sid}" "cx"; then
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
# "/foo" form or Claude Code's "<command-name>...</command-name>" wrapper
# (also produced by Codex's transcript when a slash command is the entry
# point). Used to suppress pushes for scheduled cron-style commands.
is_slash_command() {
    case "$1" in
        "<command-name>"*|"<command-message>"*|"/"[a-zA-Z]*) return 0 ;;
    esac
    return 1
}

# True when this hook is firing for an ephemeral / internal sub-LLM thread
# spawned by Codex Desktop, not a real user-facing conversation. Codex Desktop
# fires the full SessionStart / UserPromptSubmit / Stop hook lifecycle on
# ephemeral threads it starts internally for thread-title generation, message
# summarization, ambient-suggestion safety classification, and similar
# bookkeeping. Those threads use prompts like
# "You are a helpful assistant. You will be presented with a user prompt…"
# and return structured JSON like {"title":"…"} — neither of which is useful
# noise to wake the user's phone for. They also use `ephemeral: true` /
# `persistExtendedHistory: false`, so Codex never writes a rollout file for
# them; transcript_path is either null or points at a path that was never
# created. A real Codex session always writes its session_meta record (and
# therefore creates the rollout file) before any UserPromptSubmit or Stop
# fires, so a missing transcript file at hook-firing time is a reliable
# ephemeral-session signal.
is_ephemeral_session() {
    [ -z "${transcript}" ] && return 0
    [ ! -f "${transcript}" ] && return 0
    return 1
}

# True when this Codex session was launched by Claude Code's codex-rescue
# agent rather than run standalone. codex-rescue drives Codex over
# `codex app-server`, spawned with Claude Code's inherited environment, so
# CLAUDECODE / CLAUDE_CODE_ENTRYPOINT are present in the hook's env; a
# terminal Codex session has neither. Used to suppress the duplicate cx
# push — Claude Code's own Stop hook already fires a cc "done" for the same
# logical task, so a cx "done" here just double-blocks the phone. Detected
# via the inherited env, NOT process ancestry: codex-rescue can reuse a
# detached broker app-server that reparents to launchd, breaking the PPID
# chain, but the captured env survives.
is_claude_subagent() {
    [ -n "${CLAUDECODE:-}" ] || [ -n "${CLAUDE_CODE_ENTRYPOINT:-}" ]
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

# Pull the most recent thread name Codex Desktop has generated for this
# session. Codex Desktop spawns an ephemeral sub-LLM call per turn to
# produce a short title (see Wt() in the Codex Desktop bundle) and writes
# the result back to the parent rollout as an event_msg payload of shape
# {type:"thread_name_updated", thread_name:"<title>"}. This is what the
# user sees in the app's sidebar, so it's the least-surprising thing to
# put on their phone. Returns empty for codex-tui CLI sessions (the CLI
# doesn't generate titles), in which case the caller should fall back to
# first_user_prompt_from_transcript.
read_thread_name_from_transcript() {
    local transcript="$1"
    [ -z "${transcript}" ] && return 0
    [ ! -f "${transcript}" ] && return 0
    command -v jq >/dev/null 2>&1 || return 0

    jq -r '
        select(.payload.type == "thread_name_updated")
        | .payload.thread_name // empty
    ' "${transcript}" 2>/dev/null \
        | grep -v '^[[:space:]]*$' \
        | tail -n 1 \
        | tr '\n' ' '
}

# Pull the first real user prompt from a Codex rollout transcript so we
# have a meaningful title instead of always using basename(cwd). Codex
# writes records like {"type":"response_item","payload":{"type":"message",
# "role":"user","content":[{"text":"<the prompt>"}]}} — but the first user
# record is always an "<environment_context>…</environment_context>" block
# injected by Codex itself, which we skip.
#
# Returns nothing if no usable prompt is found (caller falls back to
# basename(cwd) which is fine in that edge case).
first_user_prompt_from_transcript() {
    local transcript="$1"
    [ -z "${transcript}" ] && return 0
    [ ! -f "${transcript}" ] && return 0
    command -v jq >/dev/null 2>&1 || return 0

    jq -r '
        select(.type == "response_item" and .payload.type == "message" and .payload.role == "user")
        | (.payload.content // [])
        | map(.text // .input_text // "")
        | join(" ")
        | select(length > 0)
        | select(startswith("<environment_context>") | not)
        | select(startswith("<user_instructions>") | not)
    ' "${transcript}" 2>/dev/null \
        | head -n 1 \
        | tr '\n' ' '
}

# Cap a string at 72 chars with a trailing ellipsis for titles.
clip_title() {
    local raw="$1"
    raw="$(printf '%s' "${raw}" | tr '\n' ' ' | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')"
    if [ "${#raw}" -gt 72 ]; then
        printf '%s…' "${raw:0:71}"
    else
        printf '%s' "${raw}"
    fi
}

# Cap a string at 160 chars for the body.
clip_body() {
    local raw="$1"
    raw="$(printf '%s' "${raw}" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g;s/^[[:space:]]+//;s/[[:space:]]+$//')"
    if [ "${#raw}" -gt 160 ]; then
        printf '%s…' "${raw:0:159}"
    else
        printf '%s' "${raw}"
    fi
}

# Returns 0 (true) when the assistant text looks like Codex is waiting on the
# user. Mirrors the Claude Code plugin's heuristic so the iOS app's shield
# behavior is consistent across both agents.
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

    case "${cleaned}" in
        *\?*) return 0 ;;
    esac

    local last
    last="$(printf '%s' "${cleaned}" \
        | tr '\n' ' ' \
        | sed -E 's/([.!?]+)[[:space:]]+/\1\n/g' \
        | grep -v '^[[:space:]]*$' \
        | tail -n 1 \
        | sed -E 's/^[[:space:]]+//')"

    [ -z "${last}" ] && return 1

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

# Suppress every push-producing event when this Codex session is a Claude
# Code sub-agent (codex-rescue). Without this, a rescue task fires a cx
# "done" when Codex finishes AND a cc "done" when the parent Claude turn
# ends — two terminal pushes, two shields, for one task. Claude Code's cc
# lifecycle is the user-facing one, so the cx sub-run stays silent.
# session-start is intentionally not guarded: its ID-gen + hygiene are
# harmless and never push to the phone.
case "${EVENT}" in
    stop|permission-request|pre-tool-use|post-tool-use|user-prompt-submit)
        if is_claude_subagent; then
            log "${EVENT}: skipping — Codex running as a Claude Code sub-agent"
            exit 0
        fi
        ;;
esac

case "${EVENT}" in

    session-start)
        # HUD first: it must land even if ID generation below fails, and it
        # writes to a file, never to stdout (the systemMessage JSON below is
        # a hook output contract).
        #
        # Deliberately NOT gated on is_ephemeral_session, unlike every handler
        # that produces a visible row. That predicate means "rollout file
        # missing", and nothing guarantees Codex has written the rollout by
        # the time SessionStart fires — only that it exists by the first
        # UserPromptSubmit/Stop. Gating here would strip agentPid/agentStart
        # (liveness — without it a killed terminal only reaches ENDED via the
        # staleness timer) and appPid/app (click-to-jump) from real sessions,
        # and buy nothing: this is the ONLY record that carries them, and a
        # session holding just a `start` seeds the reducer at .idle, which
        # renders in no column. So an ephemeral thread whose row-producing
        # events are all gated stays invisible either way.
        sid="$(jq_get '.session_id' 'nosid')"
        cwd="$(jq_get '.cwd')"
        proj="$(basename "${cwd:-unknown}")"
        # No thread name exists yet at session start; the project name is the
        # honest label, and the first prompt/tool record supersedes it.
        hud_record "start" "${sid}" "${proj}" "${cwd}" "${proj}"
        # Codex passes source ∈ {startup, resume, clear}. Only do the
        # welcome banner on the very first run (no ID file yet);
        # subsequent startups are silent.
        if [ -z "${VIBEZ_ID}" ]; then
            ensure_vibez_id
            if [ -n "${VIBEZ_ID}" ]; then
                log "generated Vibez ID ${VIBEZ_ID}"
                msg="vibez plugin: your Vibez ID is ${VIBEZ_ID}. Type it into the Vibez iPhone app (Set up notifications widget) to pair this Mac with your phone."
                # Codex accepts the same systemMessage / hookSpecificOutput
                # shape as Claude Code; SessionStartHookSpecificOutputWire
                # supports additionalContext.
                printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"vibez first-run setup complete. Vibez ID: %s. The iOS app pairs with this ID."}}\n' \
                    "${msg}" "${VIBEZ_ID}"
            else
                log "vibez ID generation failed"
            fi
        else
            log "session-start (Vibez ID exists)"
        fi
        [ -f "${LEGACY_TOPIC_FILE}" ] && rm -f "${LEGACY_TOPIC_FILE}" 2>/dev/null || true
        rotate_log_if_needed
        # Sweep stale debounce stamps so dead sessions don't pile up.
        # (BSD find: -mtime +1 deletes after ~2 days. Stamps go inert
        # seconds after the window closes anyway — this is hygiene.)
        find "${CONFIG_DIR}" -maxdepth 1 -name 'lastevent.*' -mtime +1 -delete 2>/dev/null || true
        find "${CONFIG_DIR}" -maxdepth 1 -name 'approval-watch.*.json' -mtime +1 -delete 2>/dev/null || true
        # pending.* markers from killed sessions otherwise live forever, and a
        # resumed session id would treat its first autonomous PostToolUse as a
        # reply (spurious shield:off).
        find "${CONFIG_DIR}" -maxdepth 1 -name 'pending.*' -mtime +1 -delete 2>/dev/null || true
        ;;

    permission-request)
        # Skip modes where the user has explicitly opted out of being asked —
        # no point pinging the phone for a decision that won't be shown.
        mode="$(jq_get '.permission_mode' 'default')"
        case "${mode}" in
            dontAsk|bypassPermissions)
                log "permission-request: skipping (mode=${mode})"
                exit 0 ;;
        esac

        sid="$(jq_get '.session_id' 'nosid')"
        cwd="$(jq_get '.cwd')"
        transcript="$(jq_get '.transcript_path')"
        is_ephemeral_session && { log "permission-request: skipping ephemeral session"; exit 0; }
        tool_name="$(jq_get '.tool_name' 'tool')"
        proj="$(basename "${cwd:-unknown}")"
        title_raw="$(read_thread_name_from_transcript "${transcript}")"
        [ -z "${title_raw}" ] && title_raw="$(first_user_prompt_from_transcript "${transcript}")"
        [ -z "${title_raw}" ] && title_raw="${proj}"

        # Build a short body: tool name + a snippet of the input. tool_input
        # is `any`, so we re-serialize to JSON via jq when present.
        tool_input_str=""
        if command -v jq >/dev/null 2>&1 && [ -n "${INPUT}" ]; then
            tool_input_str="$(printf '%s' "${INPUT}" | jq -rc '.tool_input // empty | if type == "string" then . else tostring end' 2>/dev/null || true)"
        fi

        if [ -n "${tool_input_str}" ]; then
            body="${tool_name}: ${tool_input_str}"
        else
            body="Permission required to run ${tool_name}"
        fi

        # Before post_vibez, so the same-session block debounce (which exists
        # to spare the phone a second banner) can't hide the ask from the HUD.
        hud_record "needs-input" "${sid}" "${proj}" "${cwd}" \
            "$(clip_title "${title_raw}")" "$(clip_body "${body}")" "${tool_name}"
        post_vibez "$(clip_title "${title_raw}")" "$(clip_body "${body}")" \
            "needs-input" "on" "${sid}" "cx"
        mark_pending "${sid}"
        case "${tool_name}" in
            Bash|bash|shell|exec_command)
                command="$(jq_get '.tool_input.command')"
                [ -z "${command}" ] && command="$(jq_get '.tool_input.cmd')"
                start_approval_watcher \
                    "${sid}" "$(clip_title "${title_raw}")" "${tool_name}" "${command}"
                ;;
        esac
        ;;

    stop)
        sid="$(jq_get '.session_id' 'nosid')"
        cwd="$(jq_get '.cwd')"
        transcript="$(jq_get '.transcript_path')"
        is_ephemeral_session && { log "stop: skipping ephemeral session"; exit 0; }
        proj="$(basename "${cwd:-unknown}")"
        title_raw="$(read_thread_name_from_transcript "${transcript}")"
        [ -z "${title_raw}" ] && title_raw="$(first_user_prompt_from_transcript "${transcript}")"
        [ -z "${title_raw}" ] && title_raw="${proj}"
        is_slash_command "${title_raw}" && exit 0
        # Codex puts the final assistant text directly in the Stop payload —
        # no transcript polling needed for the body (unlike the Claude Code
        # plugin), but we still read the transcript for the title.
        excerpt="$(jq_get '.last_assistant_message')"
        # Classify on the full excerpt, clip only the push body. Empty text
        # can't hold a question, so an excerpt-less turn classifies as done.
        body="$(clip_body "${excerpt}")"
        title="$(clip_title "${title_raw}")"
        if last_turn_is_asking "${excerpt}"; then
            stop_kind="needs-input"
        else
            stop_kind="done"
        fi
        # HUD first, and UNCONDITIONALLY — above the excerpt skip below. The
        # turn ended, so the panel must stop showing WORKING whether or not
        # the payload carried any text.
        hud_record "${stop_kind}" "${sid}" "${proj}" "${cwd}" "${title}" "${body}"
        # The PUSH keeps its own skip: with no text, a generic "Codex finished
        # a turn." is just noise on the phone. Deliberately a bare exit — it
        # must not clear this session's pending markers.
        if [ -z "${excerpt}" ]; then
            log "stop: empty last_assistant_message, skipping"
            exit 0
        fi
        post_vibez "${title}" "${body}" "${stop_kind}" "on" "${sid}" "cx"
        # Stop is a terminal "needs you" signal — any pending shield-on from
        # an earlier permission/picker in this turn has been superseded.
        clear_pending "${sid}"
        ;;

    pre-tool-use)
        # request_user_input is Codex's interactive picker. Older builds and
        # imported Claude-compatible configs may call it ask_user_question or
        # AskUserQuestion, so keep all three spellings.
        tool_name="$(jq_get '.tool_name')"
        case "${tool_name}" in
            request_user_input|ask_user_question|AskUserQuestion) ;;
            *) exit 0 ;;
        esac

        sid="$(jq_get '.session_id' 'nosid')"
        cwd="$(jq_get '.cwd')"
        transcript="$(jq_get '.transcript_path')"
        is_ephemeral_session && { log "pre-tool-use: skipping ephemeral session"; exit 0; }
        proj="$(basename "${cwd:-unknown}")"
        title_raw="$(read_thread_name_from_transcript "${transcript}")"
        [ -z "${title_raw}" ] && title_raw="$(first_user_prompt_from_transcript "${transcript}")"
        [ -z "${title_raw}" ] && title_raw="${proj}"
        is_slash_command "${title_raw}" && exit 0

        # Codex uses .questions[0].question; retain the singular fallback for
        # older/imported question-tool schemas.
        question="$(jq_get '.tool_input.questions[0].question')"
        [ -z "${question}" ] && question="$(jq_get '.tool_input.question')"
        [ -z "${question}" ] && question="Codex is asking a question."

        hud_record "needs-input" "${sid}" "${proj}" "${cwd}" \
            "$(clip_title "${title_raw}")" "$(clip_body "${question}")" "${tool_name}"
        post_vibez "$(clip_title "${title_raw}")" "$(clip_body "${question}")" \
            "needs-input" "on" "${sid}" "cx"
        mark_pending "${sid}"
        ;;

    post-tool-use)
        # The approval watcher handles long-running shell commands at process
        # start. PostToolUse remains the fallback for edits, MCP calls, commands
        # too short for the watcher to observe, and question-picker responses.
        # Only push when an earlier interactive event left a pending marker;
        # otherwise autonomous tool calls would drown the phone.
        sid="$(jq_get '.session_id' 'nosid')"
        cwd="$(jq_get '.cwd')"
        transcript="$(jq_get '.transcript_path')"
        is_ephemeral_session && { log "post-tool-use: skipping ephemeral session"; exit 0; }
        proj="$(basename "${cwd:-unknown}")"
        tool_name="$(jq_get '.tool_name' 'tool')"
        # HUD ABOVE the autonomous-tool early-exit below. That exit is a push
        # suppression (one shield:off per tool call would drown the phone);
        # for the notch panel every tool call is exactly the "still working"
        # heartbeat it needs. Title is deliberately empty — the reducer keeps
        # the session's known title, and the transcript reads below are too
        # expensive to run on every PostToolUse.
        hud_record "tool" "${sid}" "${proj}" "${cwd}" "" "" "${tool_name}"

        has_pending "${sid}" || exit 0

        title_raw="$(read_thread_name_from_transcript "${transcript}")"
        [ -z "${title_raw}" ] && title_raw="$(first_user_prompt_from_transcript "${transcript}")"
        [ -z "${title_raw}" ] && title_raw="${proj}"

        # For ask_user_question the response is the user's actual answer,
        # which is meaningful body content. For shell/apply_patch/etc. the
        # tool_response is command output that may be huge or contain
        # secrets — keep it generic.
        case "${tool_name}" in
            request_user_input|ask_user_question|AskUserQuestion)
                body="$(jq_get '.tool_response.content')"
                [ -z "${body}" ] && body="(answered)"
                ;;
            *)
                body="(approved: ${tool_name})"
                ;;
        esac

        post_vibez "$(clip_title "${title_raw}")" "$(clip_body "${body}")" \
            "replied" "off" "${sid}" "cx"
        clear_pending "${sid}"
        ;;

    _watch-approval)
        watch_approval_start "${2:-}"
        ;;

    user-prompt-submit)
        sid="$(jq_get '.session_id' 'nosid')"
        cwd="$(jq_get '.cwd')"
        transcript="$(jq_get '.transcript_path')"
        is_ephemeral_session && { log "user-prompt-submit: skipping ephemeral session"; exit 0; }
        proj="$(basename "${cwd:-unknown}")"
        prompt="$(jq_get '.prompt')"
        is_slash_command "${prompt}" && exit 0
        # Title preference order: Codex Desktop's agent-generated thread name
        # (what the user sees in the app sidebar), then the transcript's first
        # user prompt (CLI fallback — CLI doesn't generate titles), then the
        # just-submitted prompt, then cwd basename.
        title_raw="$(read_thread_name_from_transcript "${transcript}")"
        [ -z "${title_raw}" ] && title_raw="$(first_user_prompt_from_transcript "${transcript}")"
        [ -z "${title_raw}" ] && title_raw="${prompt:-${proj}}"
        title="$(clip_title "${title_raw}")"
        if [ -z "${prompt}" ]; then
            prompt="(replied)"
        fi
        hud_record "prompt" "${sid}" "${proj}" "${cwd}" "${title}" "$(clip_body "${prompt}")"
        post_vibez "${title}" "$(clip_body "${prompt}")" \
            "replied" "off" "${sid}" "cx"
        clear_pending "${sid}"
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

        long_field="$(printf 'a%.0s' $(seq 1 150))"
        check_eq "clamp-field-caps"   "$(clamp_field "${long_field}" 100)" "${long_field:0:99}…"
        check_eq "clamp-field-passes" "$(clamp_field "short" 100)" "short"

        # Approval process matching — a newly spawned descendant containing
        # the exact requested command must be observable, while the current
        # selftest process must not match before that child exists.
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

        # Escalation needles arrive shlex-joined as "<shell> -lc '<cmd>'". In
        # stdin-typed (zsh-fork) sessions no process ever carries that prefix —
        # only the bare command appears in ps. The matcher must also try the
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
        post_vibez "t" "b" "replied" "off" "pvA" "cx"
        check_eq "stamp-off-send-no-claim"     "$(stampprobe pvA)" "clean"
        post_vibez "t" "b" "needs-input" "on" "pvA" "cx"
        check_eq "stamp-reply-then-ask-sends"  "$(grep -c 'debounced:' "${LOG_FILE}")" "0"
        check_eq "stamp-on-send-claims"        "$(stampprobe pvA)" "stamped"
        post_vibez "t" "b" "done" "on" "pvA" "cx"
        check_eq "stamp-burst-still-debounced" "$(grep -c 'debounced:' "${LOG_FILE}")" "1"
        curl() { return 22; }
        post_vibez "t" "b" "replied" "off" "pvA" "cx"
        check_eq "stamp-off-fail-preserves"    "$(stampprobe pvA)" "stamped"
        post_vibez "t" "b" "needs-input" "on" "pvB" "cx"
        check_eq "stamp-on-fail-rolls-back"    "$(stampprobe pvB)" "clean"

        # Burst under-block fix: a DELIVERED reply (shield:off) clears the
        # session stamp so the next agent block RE-BLOCKS instead of being
        # debounced. Without this, approving a permission (reply unblocks)
        # silently swallowed the next permission prompt that landed within
        # the window. on → off(success) must leave the stamp clean, and a
        # follow-up on must NOT add a 'debounced:' line.
        curl() { return 0; }
        post_vibez "t" "b" "needs-input" "on" "pvC" "cx"
        post_vibez "t" "b" "replied" "off" "pvC" "cx"
        check_eq "stamp-off-clears-on-success" "$(stampprobe pvC)" "clean"
        dbcount_before="$(grep -c 'debounced:' "${LOG_FILE}")"
        post_vibez "t" "b" "needs-input" "on" "pvC" "cx"
        check_eq "reply-clears-debounce" "$(grep -c 'debounced:' "${LOG_FILE}")" "${dbcount_before}"

        # Full watcher path: begin with a pending session, start a matching
        # process after the watch loop is active, and verify the successful
        # shield-off clears pending before PostToolUse would run.
        approval_sid="approval-selftest"
        approval_marker="vibez-watch-integration-$$"
        approval_state="${CONFIG_DIR}/approval-watch.selftest.json"
        mark_pending "${approval_sid}"
        jq -nc \
            --arg sid "${approval_sid}" \
            --arg title "approval test" \
            --arg toolName "Bash" \
            --arg command "${approval_marker}" \
            --arg rootPid "$$" \
            '{sid:$sid,title:$title,toolName:$toolName,command:$command,
              rootPid:$rootPid,baseline:""}' >"${approval_state}"
        printf '%s' "${approval_marker}" >"${CONFIG_DIR}/approval-marker"
        (
            sleep 0.2
            marker="$(cat "${CONFIG_DIR}/approval-marker")"
            bash -c 'sleep 2 & wait' "${marker}"
        ) &
        approval_launcher_pid=$!
        curl() { return 0; }
        watch_approval_start "${approval_state}"
        if has_pending "${approval_sid}"; then
            approval_pending="pending"
        else
            approval_pending="cleared"
        fi
        check_eq "approval-watch-clears-pending" "${approval_pending}" "cleared"
        kill "${approval_launcher_pid}" 2>/dev/null || true
        wait "${approval_launcher_pid}" 2>/dev/null || true

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

        # is_claude_subagent — Codex launched by Claude Code's codex-rescue
        # inherits CLAUDECODE / CLAUDE_CODE_ENTRYPOINT through the app-server
        # spawn; a standalone terminal Codex session has neither. The
        # push-producing handlers skip their send when it's true so the cx
        # "done" doesn't duplicate Claude Code's own cc "done".
        sub_probe() {
            if is_claude_subagent; then printf 'subagent'; else printf 'standalone'; fi
        }
        saved_cc="${CLAUDECODE:-}"
        saved_entry="${CLAUDE_CODE_ENTRYPOINT:-}"
        unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT
        check_eq "subagent-clean-env"   "$(sub_probe)" "standalone"
        CLAUDECODE=1
        check_eq "subagent-claudecode"  "$(sub_probe)" "subagent"
        unset CLAUDECODE
        CLAUDE_CODE_ENTRYPOINT=cli
        check_eq "subagent-entrypoint"  "$(sub_probe)" "subagent"
        unset CLAUDE_CODE_ENTRYPOINT
        [ -n "${saved_cc}" ] && CLAUDECODE="${saved_cc}"
        [ -n "${saved_entry}" ] && CLAUDE_CODE_ENTRYPOINT="${saved_entry}"

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
