#!/usr/bin/env bash
#
# vibez hook script (Cursor side).
#
# Dispatches Cursor agent-hook events to the Vibez Firebase backend as
# push notifications. Vibez ID is shared with the Claude Code and Codex
# vibez plugins at ~/.config/vibez/vibez-id so a single ID on the phone
# covers every agent.
#
# Unlike the Claude/Codex plugins, ONE argless command is registered
# for every hook event and dispatch happens on the payload's
# hook_event_name field — Cursor's hooks.json "command" string is a
# bare executable path, so this avoids relying on argument parsing.
# An explicit argv[1] (e.g. _selftest) overrides the stdin dispatch.
#
# Registered events (see the vibez-cursor installer):
#   sessionStart        first-run ID gen + background-agent marker + hygiene
#   beforeSubmitPrompt  user replied → shield:off  (always answers
#                       {"continue": true} — this hook must NEVER block)
#   afterAgentResponse  stash the assistant's final text (no network)
#   stop                agent loop ended → done / needs-input shield:on
#   sessionEnd          per-session state cleanup
#
# Hooks must never block Cursor — this script always exits 0, network
# failures are swallowed. Per the Cursor docs, exit codes other than
# 0/2 fail OPEN, and 2 is never used here.

set -uo pipefail

CONFIG_DIR="${HOME}/.config/vibez"
ID_FILE="${CONFIG_DIR}/vibez-id"
LOG_FILE="${CONFIG_DIR}/log"
BACKEND_URL="${VIBEZ_BACKEND_URL:-https://us-central1-vibez-backend.cloudfunctions.net}"

# Where setup.sh lives (sibling of this script — the installer copies
# both into ~/.cursor/vibez/).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "${CONFIG_DIR}" 2>/dev/null || true
chmod 700 "${CONFIG_DIR}" 2>/dev/null || true

log() {
    printf '[%s] cu %s\n' "$(date -u +%FT%TZ)" "$*" >>"${LOG_FILE}" 2>/dev/null || true
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
        --arg sid "${sid}" --arg agent "cu" --arg kind "${kind}" \
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

# --- end of the block mirrored from ClaudePlugin/CodexPlugin ---------------
# Cursor-only: no payload here carries a cwd, so the first workspace root
# stands in for it and its basename is the project label the panel shows.
# One jq spawn, resolved once per recording handler.
HUD_CWD=""
HUD_PROJ=""
hud_identity() {
    HUD_CWD="$(jq_get '.workspace_roots[0]')"
    HUD_PROJ="$(basename "${HUD_CWD:-unknown}")"
}

# Cap on the append-only log. Mirrors the Claude/Codex plugins (shared
# LOG_FILE — any plugin's session can trim). Checked once per session.
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
clamp_field() {
    local raw="$1" max="$2"
    if [ "${#raw}" -gt "${max}" ]; then
        printf '%s…' "${raw:0:$((max - 1))}"
    else
        printf '%s' "${raw}"
    fi
}

# Per-session block debounce — identical policy to the Claude/Codex
# plugins (see CLAUDE.md "Same-conversation block debounce"): the first
# shield:on of a burst blocks + banners the phone; followers inside the
# window are noise. shield:off (replies) is invisible to the debounce
# in BOTH directions. Stamp files hold an epoch second; 0 disables.
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
    # not debounce. Check-then-stamp is not atomic across hook
    # processes; accepted — worst case is one extra banner.
    [ "${delta}" -ge 0 ] && [ "${delta}" -lt "${DEBOUNCE_SECONDS}" ]
}

# POST a Vibez payload to the backend's /notify endpoint. Identical to
# the Codex plugin's post_vibez (stamp policy and all) apart from the
# log prefix; see CLAUDE.md for the stamp/debounce policy rationale.
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

    if [ "${shield}" = "on" ] && within_debounce_window "${session}"; then
        mark_event "${session}"
        log "debounced: ${title} (event=${event} session=${session})"
        return 0
    fi

    # Claim the stamp BEFORE the network call (shield:on only) so a
    # concurrent shield:on can't double-send during the curl; a failed
    # send rolls the claim back below.
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
        # A DELIVERED reply (shield:off) just unblocked the phone; the
        # next agent block for this session must re-block, not get
        # debounced against the pre-reply stamp.
        [ "${shield}" = "off" ] && clear_event "${session}" || true
        return 0
    else
        log "send failed: ${title} (event=${event})"
        [ "${shield}" = "on" ] && clear_event "${session}" || true
        return 1
    fi
}

# Pull a JSON field with a default, swallowing jq errors. The default
# applies whenever the result is EMPTY — field absent, explicitly "",
# jq failure, or no stdin.
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

# ---- Per-session stash files -------------------------------------------
#
# Cursor's stop payload carries only {status, loop_count} — no text. The
# push body therefore comes from afterAgentResponse, stashed per session.
# Same for the title: there is no thread name in any payload, so the
# first real user prompt (from beforeSubmitPrompt) becomes the title.
# Background-agent sessions are marked at sessionStart and never push.
# All three decay via the session-start hygiene sweep, and sessionEnd
# deletes its own session's files eagerly.

stash_path() {
    # $1 = kind (last|title|bg), $2 = sid
    local kind="$1" sid="$2"
    [ -z "${sid}" ] || [ "${sid}" = "nosid" ] && return 1
    printf '%s/cursor%s.%s' "${CONFIG_DIR}" "${kind}" "${sid}"
}

stash_write() {
    # $1 = kind, $2 = sid, $3 = content. Content is capped at 16 KB —
    # last_turn_is_asking scans the whole text, and an unbounded stash
    # would let one giant response bloat ~/.config/vibez. The byte cut
    # can split a multibyte UTF-8 char, and BSD awk/sed abort on invalid
    # UTF-8 (which would misclassify an asking stop as done) — iconv -c
    # drops the trailing partial sequence. tmp+mv keeps the write atomic:
    # afterAgentResponse and stop fire back-to-back as separate
    # processes, and stop must never read a truncated half-write.
    local path tmp
    path="$(stash_path "$1" "$2")" || return 0
    tmp="${path}.tmp.$$"
    if command -v iconv >/dev/null 2>&1; then
        printf '%s' "$3" | head -c 16384 \
            | iconv -c -f UTF-8 -t UTF-8 >"${tmp}" 2>/dev/null || true
        # iconv -c exits nonzero when it had to drop bytes — the output
        # is still exactly what we want, so judge by output, not exit
        # code. Raw-cut fallback only when iconv emitted nothing for
        # non-empty input (a genuinely broken iconv).
        if [ -n "$3" ] && [ ! -s "${tmp}" ]; then
            printf '%s' "$3" | head -c 16384 >"${tmp}" 2>/dev/null || true
        fi
    else
        printf '%s' "$3" | head -c 16384 >"${tmp}" 2>/dev/null || true
    fi
    chmod 600 "${tmp}" 2>/dev/null || true
    mv -f "${tmp}" "${path}" 2>/dev/null || rm -f "${tmp}" 2>/dev/null || true
}

stash_read() {
    local path
    path="$(stash_path "$1" "$2")" || return 1
    [ -f "${path}" ] || return 1
    cat "${path}" 2>/dev/null
}

stash_clear() {
    # $1 = kind, $2 = sid
    local path
    path="$(stash_path "$1" "$2")" || return 0
    rm -f "${path}" 2>/dev/null || true
}

stash_clear_session() {
    local sid="$1" kind
    for kind in last title bg; do
        stash_clear "${kind}" "${sid}"
    done
}

is_background_session() {
    local path
    path="$(stash_path bg "$1")" || return 1
    [ -f "${path}" ]
}

# Block (bounded) while this session has a reply send still in flight —
# the detached _flush-reply child deletes its job file only after its
# POST returns. Without this, a near-instant stop's shield:on could be
# seq-stamped by /notify BEFORE the reply's shield:off, leaving the
# phone unblocked while Cursor waits (the sibling plugins get this
# ordering for free by sending replies synchronously). A crashed child
# leaves a stale job: the wait gives up after ~2s and the hygiene sweep
# removes the file.
wait_for_pending_reply() {
    local sid="$1" i
    [ -z "${sid}" ] || [ "${sid}" = "nosid" ] && return 0
    for i in $(seq 1 20); do
        set -- "${CONFIG_DIR}/replyjob.${sid}."*
        [ -e "$1" ] || return 0
        sleep 0.1
    done
    return 0
}

# Title for a push: the stashed first user prompt, else the basename of
# the first workspace root, else "cursor".
resolve_title() {
    local sid="$1" title root
    title="$(stash_read title "${sid}")" || title=""
    if [ -z "${title}" ]; then
        root="$(jq_get '.workspace_roots[0]')"
        [ -n "${root}" ] && title="$(basename "${root}")"
    fi
    [ -z "${title}" ] && title="cursor"
    printf '%s' "${title}"
}

# True when the argument is a slash-command invocation. Cursor slash
# commands (/Generate Commit Message and custom commands) shouldn't
# wake the phone. A prompt that merely STARTS with an absolute path
# ("/Users/dev/crash.log shows a segfault, fix it") is a real reply —
# the first token of a slash command never contains a second slash.
is_slash_command() {
    local first="${1%%[[:space:]]*}"
    case "${first}" in
        "/"[a-zA-Z]*)
            case "${first#/}" in
                */*) return 1 ;;
            esac
            return 0
            ;;
    esac
    return 1
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

# Returns 0 (true) when the assistant text looks like Cursor is waiting
# on the user. Mirrors the Claude Code / Codex plugins' heuristic so the
# iOS app's shield behavior is consistent across agents.
last_turn_is_asking() {
    local text="$1"
    [ -z "${text}" ] && return 1

    # Strip anything that displays as code or as a literal quoted span,
    # so a "?" inside a code sample or quoted phrase doesn't
    # false-positive. Order matters: fenced blocks first (multi-line),
    # then inline spans. Apostrophes are too noisy to handle safely, so
    # single quotes are left alone.
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

# Dispatch: an explicit argv[1] (selftest and friends) wins; otherwise
# the payload's hook_event_name decides.
EVENT="${1:-}"
if [ -z "${EVENT}" ]; then
    if ! command -v jq >/dev/null 2>&1; then
        # Without jq we can't even tell which event this is. Answer the
        # one response that could matter (beforeSubmitPrompt's permit —
        # harmless JSON for every other event) and bow out.
        log "skip: jq not installed (cannot dispatch)"
        printf '{"continue": true}\n'
        exit 0
    fi
    EVENT="$(jq_get '.hook_event_name')"
fi

SID="$(jq_get '.conversation_id')"
[ -z "${SID}" ] && SID="$(jq_get '.session_id' 'nosid')"

case "${EVENT}" in

    sessionStart)
        # Background agents (bugbot, cloud-style runs) fire the full
        # lifecycle but aren't a human waiting at the keyboard — mark
        # the session so no later hook ever pushes for it.
        if [ "$(jq_get '.is_background_agent')" = "true" ]; then
            stash_write bg "${SID}" "1"
            log "sessionStart: background agent, muting session ${SID}"
            exit 0
        fi

        # HUD first: it must land even if ID generation below fails, and it
        # writes to a file, never to stdout (the additional_context JSON below
        # is a hook output contract). Below the background-agent gate on
        # purpose — a muted session is invisible to the panel too.
        hud_identity
        # No prompt has been submitted yet, so the workspace name is the
        # honest label; the first prompt record supersedes it.
        hud_record "start" "${SID}" "${HUD_PROJ}" "${HUD_CWD}" "${HUD_PROJ}"

        if [ -z "${VIBEZ_ID}" ]; then
            ensure_vibez_id
            if [ -n "${VIBEZ_ID}" ]; then
                log "generated Vibez ID ${VIBEZ_ID}"
                # sessionStart output may inject conversation context;
                # surface the fresh ID so the agent can tell the user.
                # (The npx installer is the primary surface for the ID —
                # this covers installs where setup.sh never ran.)
                jq -nc --arg id "${VIBEZ_ID}" \
                    '{additional_context: ("vibez plugin first-run setup complete. Vibez ID: \($id). If the user asks about Vibez or pairing their phone, tell them to type this ID into the Setup card of the Vibez iPhone app.")}'
            else
                log "vibez ID generation failed"
            fi
        else
            log "sessionStart (Vibez ID exists)"
        fi
        rotate_log_if_needed
        # Sweep stale per-session state so dead sessions don't pile up.
        # (BSD find: -mtime +1 deletes after ~2 days.)
        find "${CONFIG_DIR}" -maxdepth 1 \( \
            -name 'lastevent.*' -o -name 'cursorlast.*' -o \
            -name 'cursortitle.*' -o -name 'cursorbg.*' -o \
            -name 'replyjob.*' \) \
            -mtime +1 -delete 2>/dev/null || true
        ;;

    beforeSubmitPrompt)
        # This hook GATES the user's prompt: Cursor waits for the
        # response before submitting. Two invariants — every path must
        # fall through to the {"continue": true} at the end, and the
        # network send must NOT happen in this process (offline, curl's
        # --max-time 5 would stall every prompt). The send is handed to
        # a detached child via a job file; this process answers
        # immediately.
        if ! is_background_session "${SID}"; then
            prompt="$(jq_get '.prompt')"
            if [ -n "${prompt}" ] && ! is_slash_command "${prompt}"; then
                # First real prompt becomes the session's push title.
                if ! stash_read title "${SID}" >/dev/null 2>&1; then
                    stash_write title "${SID}" "$(clip_title "${prompt}")"
                fi
                # Turn boundary: drop the previous turn's stashed
                # response so a stop with no fresh text (error, CLI)
                # can't push stale content from the last turn.
                stash_clear last "${SID}"
                title="$(resolve_title "${SID}")"
                # Ahead of the detached send, and unable to disturb the
                # {"continue": true} below: hud_record only ever appends to a
                # file or swallows its own errors, never writes stdout.
                hud_identity
                hud_record "prompt" "${SID}" "${HUD_PROJ}" "${HUD_CWD}" \
                    "$(clip_title "${title}")" "$(clip_body "${prompt}")"
                job="$(mktemp "${CONFIG_DIR}/replyjob.${SID}.XXXXXX" 2>/dev/null)" || job=""
                if [ -n "${job}" ] && jq -nc \
                    --arg title "$(clip_title "${title}")" \
                    --arg body "$(clip_body "${prompt}")" \
                    --arg sid "${SID}" \
                    '{title:$title,body:$body,sid:$sid}' >"${job}" 2>/dev/null; then
                    chmod 600 "${job}" 2>/dev/null || true
                    nohup bash "${BASH_SOURCE[0]}" _flush-reply "${job}" \
                        </dev/null >/dev/null 2>&1 &
                else
                    # Job-file plumbing failed — send synchronously
                    # rather than not at all (the phone must unblock).
                    rm -f "${job}" 2>/dev/null || true
                    post_vibez "$(clip_title "${title}")" "$(clip_body "${prompt}")" \
                        "replied" "off" "${SID}" "cu"
                fi
            fi
        fi
        printf '{"continue": true}\n'
        ;;

    _flush-reply)
        # Detached continuation of beforeSubmitPrompt: read the job file
        # and deliver the shield:off push without holding up the prompt.
        # The job file is removed AFTER the POST returns (success or
        # fail) — its existence is the "reply still in flight" signal
        # the stop branch waits on to keep server-side seq ordering
        # (an instant stop's shield:on must not be seq-stamped before
        # the reply's shield:off, or the phone ends up unblocked while
        # Cursor waits).
        job="${2:-}"
        [ -n "${job}" ] && [ -f "${job}" ] || exit 0
        title="$(jq -r '.title // empty' "${job}" 2>/dev/null)"
        body="$(jq -r '.body // empty' "${job}" 2>/dev/null)"
        sid="$(jq -r '.sid // empty' "${job}" 2>/dev/null)"
        [ -n "${title}" ] || title="cursor"
        [ -n "${body}" ] || body="(replied)"
        post_vibez "${title}" "${body}" "replied" "off" "${sid}" "cu"
        rm -f "${job}" 2>/dev/null || true
        ;;

    afterAgentResponse)
        # Pure stash, no network: Cursor's stop payload has no text, so
        # the most recent assistant message becomes the stop push body.
        if ! is_background_session "${SID}"; then
            text="$(jq_get '.text')"
            [ -n "${text}" ] && stash_write last "${SID}" "${text}"
            # The agent produced a response and the loop continues — this is
            # Cursor's only mid-turn "still working" heartbeat. Recorded even
            # when the payload had no text, because the transition is the
            # signal; the title/detail the panel shows are already known.
            hud_identity
            hud_record "tool" "${SID}" "${HUD_PROJ}" "${HUD_CWD}" ""
        fi
        ;;

    stop)
        is_background_session "${SID}" && exit 0
        status="$(jq_get '.status' 'completed')"
        hud_identity
        # An abort is the user hitting Stop in the IDE — they're at the
        # machine, not doomscrolling. No push. The HUD still needs the
        # transition: an aborted turn that recorded nothing would leave the
        # panel claiming WORKING until staleness ended it.
        if [ "${status}" = "aborted" ]; then
            log "stop: aborted by user, skipping (session=${SID})"
            hud_record "end" "${SID}" "${HUD_PROJ}" "${HUD_CWD}" \
                "$(clip_title "$(resolve_title "${SID}")")"
            exit 0
        fi
        wait_for_pending_reply "${SID}"
        title="$(clip_title "$(resolve_title "${SID}")")"
        excerpt="$(stash_read last "${SID}")" || excerpt=""
        if [ "${status}" = "error" ]; then
            body="$(clip_body "${excerpt:-Cursor stopped with an error.}")"
            stop_kind="needs-input"
        elif last_turn_is_asking "${excerpt}"; then
            body="$(clip_body "${excerpt}")"
            stop_kind="needs-input"
        else
            body="$(clip_body "${excerpt:-Finished.}")"
            stop_kind="done"
        fi
        # Before post_vibez, so the same-session block debounce (which exists
        # to spare the phone a second banner) can't hide the turn end.
        hud_record "${stop_kind}" "${SID}" "${HUD_PROJ}" "${HUD_CWD}" "${title}" "${body}"
        post_vibez "${title}" "${body}" "${stop_kind}" "on" "${SID}" "cu"
        ;;

    sessionEnd)
        # Above the cleanup: stash_clear_session drops both the background
        # marker this gate reads and the title resolve_title would find.
        if ! is_background_session "${SID}"; then
            hud_identity
            hud_record "end" "${SID}" "${HUD_PROJ}" "${HUD_CWD}" \
                "$(clip_title "$(resolve_title "${SID}")")"
        fi
        stash_clear_session "${SID}"
        clear_event "${SID}"
        log "sessionEnd: cleaned session state (${SID})"
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
        check "quoted-plus-real-q" "Renamed \`foo?\`. Anything else?"                1
        check "quoted-q-only"      "Set placeholder to \"Should I commit?\" — done." 0
        check "smart-quoted-q"     "Updated to “Should I commit?” — done."           0

        long_field="$(printf 'a%.0s' $(seq 1 150))"
        check_eq "clamp-field-caps"   "$(clamp_field "${long_field}" 100)" "${long_field:0:99}…"
        check_eq "clamp-field-passes" "$(clamp_field "short" 100)" "short"

        # Slash-command detection (Cursor only has the bare "/foo" form).
        # A leading absolute path is a real reply, not a command.
        if is_slash_command "/summarize this"; then slash1=1; else slash1=0; fi
        if is_slash_command "fix the bug"; then slash2=1; else slash2=0; fi
        if is_slash_command "/Users/dev/app/crash.log shows a segfault, fix it"; then slash3=1; else slash3=0; fi
        if is_slash_command "/tmp/x.log is empty"; then slash4=1; else slash4=0; fi
        check_eq "slash-detected"      "${slash1}" "1"
        check_eq "slash-not-detected"  "${slash2}" "0"
        check_eq "slash-path-not-cmd"  "${slash3}" "0"
        check_eq "slash-path2-not-cmd" "${slash4}" "0"

        # Debounce predicate — against a throwaway CONFIG_DIR so the
        # selftest never touches real ~/.config/vibez state.
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

        # post_vibez stamp policy — identical to the Codex plugin's:
        # only shield:on touches the stamp (claim on send, refresh on
        # suppress, roll back on failure); a delivered shield:off
        # clears it. curl is shadowed (no network).
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
        post_vibez "t" "b" "replied" "off" "pvA" "cu"
        check_eq "stamp-off-send-no-claim"     "$(stampprobe pvA)" "clean"
        post_vibez "t" "b" "needs-input" "on" "pvA" "cu"
        check_eq "stamp-reply-then-ask-sends"  "$(grep -c 'debounced:' "${LOG_FILE}")" "0"
        check_eq "stamp-on-send-claims"        "$(stampprobe pvA)" "stamped"
        post_vibez "t" "b" "done" "on" "pvA" "cu"
        check_eq "stamp-burst-still-debounced" "$(grep -c 'debounced:' "${LOG_FILE}")" "1"
        curl() { return 22; }
        post_vibez "t" "b" "replied" "off" "pvA" "cu"
        check_eq "stamp-off-fail-preserves"    "$(stampprobe pvA)" "stamped"
        post_vibez "t" "b" "needs-input" "on" "pvB" "cu"
        check_eq "stamp-on-fail-rolls-back"    "$(stampprobe pvB)" "clean"
        curl() { return 0; }
        post_vibez "t" "b" "needs-input" "on" "pvC" "cu"
        post_vibez "t" "b" "replied" "off" "pvC" "cu"
        check_eq "stamp-off-clears-on-success" "$(stampprobe pvC)" "clean"
        dbcount_before="$(grep -c 'debounced:' "${LOG_FILE}")"
        post_vibez "t" "b" "needs-input" "on" "pvC" "cu"
        check_eq "reply-clears-debounce" "$(grep -c 'debounced:' "${LOG_FILE}")" "${dbcount_before}"
        unset -f curl
        LOG_FILE="${saved_log}"
        VIBEZ_ID="${saved_id}"
        DEBOUNCE_SECONDS="${saved_debounce}"

        # Stash roundtrip + cleanup (still inside the throwaway dir).
        stash_write last  "sessA" "the final answer"
        stash_write title "sessA" "fix the parser"
        check_eq "stash-last-roundtrip"  "$(stash_read last sessA)"  "the final answer"
        check_eq "stash-title-roundtrip" "$(stash_read title sessA)" "fix the parser"
        stash_write last "sessA" "newer text"
        check_eq "stash-overwrites"      "$(stash_read last sessA)"  "newer text"
        if stash_read last sessB >/dev/null 2>&1; then absent="hit"; else absent="miss"; fi
        check_eq "stash-missing-misses"  "${absent}" "miss"
        big="$(printf 'x%.0s' $(seq 1 20000))"
        stash_write last "sessC" "${big}"
        check_eq "stash-caps-16k" "$(stash_read last sessC | wc -c | tr -d '[:space:]')" "16384"
        # A multibyte char straddling the 16 KB cut must not leave an
        # invalid UTF-8 tail (BSD awk/sed abort on one, flipping an
        # asking stop to done). 16383 ASCII + 4-byte emoji → the cut
        # keeps 1 lead byte → iconv strips it → 16383 valid bytes.
        utf8probe="$(printf 'x%.0s' $(seq 1 16383))🦀"
        stash_write last "sessU" "${utf8probe}"
        check_eq "stash-utf8-safe-cut" "$(stash_read last sessU | wc -c | tr -d '[:space:]')" "16383"
        if stash_read last sessU | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
            utf8valid="valid"
        else
            utf8valid="invalid"
        fi
        check_eq "stash-utf8-stays-valid" "${utf8valid}" "valid"
        stash_write bg "sessA" "1"
        if is_background_session "sessA"; then bgflag="bg"; else bgflag="fg"; fi
        check_eq "bg-marker-detected" "${bgflag}" "bg"
        stash_clear_session "sessA"
        if is_background_session "sessA"; then bgflag2="bg"; else bgflag2="fg"; fi
        check_eq "session-clear-removes" "${bgflag2}" "fg"
        if stash_read last sessA >/dev/null 2>&1; then cleared="hit"; else cleared="miss"; fi
        check_eq "session-clear-removes-last" "${cleared}" "miss"
        check_eq "stash-nosid-noop" "$(stash_write last nosid x; stash_read last nosid 2>/dev/null; printf 'ok')" "ok"

        # resolve_title preference order: stash > workspace root > "cursor".
        saved_input="${INPUT}"
        INPUT='{"workspace_roots":["/Users/x/proj-dir"]}'
        check_eq "title-from-workspace" "$(resolve_title sessD)" "proj-dir"
        stash_write title "sessD" "build the thing"
        check_eq "title-from-stash"     "$(resolve_title sessD)" "build the thing"
        INPUT='{}'
        check_eq "title-fallback"       "$(resolve_title sessE)" "cursor"
        INPUT="${saved_input}"

        rm -rf "${CONFIG_DIR}"

        # jq_get — the default must apply when the field is absent or
        # empty, not only when jq itself fails.
        saved_input="${INPUT}"
        INPUT='{"present":"val","empty":""}'
        check_eq "jqget-present-field"   "$(jq_get '.present' 'fb')" "val"
        check_eq "jqget-missing-default" "$(jq_get '.missing' 'fb')" "fb"
        check_eq "jqget-empty-default"   "$(jq_get '.empty' 'fb')"   "fb"
        INPUT=''
        check_eq "jqget-noinput-default" "$(jq_get '.x' 'fb')" "fb"
        INPUT="${saved_input}"

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
