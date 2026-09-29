#!/bin/bash
# Claude Code status line.
#
# Line 1, in order:
#   1. Context window usage (progress bar + percentage)
#   2. Plan rate limits: 5h and 7d used percentage (hidden for API-key users),
#      including when the 5h window resets (local time + time remaining)
#   3. Current folder (full path when short, else basename)
#   4. Current git branch (only inside a git repo)
#
# Line 2:
#   5. Token usage — SESSION TOTALS across the main thread and all subagent
#      transcripts (dedup'd by message id, since a single API response can
#      appear on multiple JSONL lines), plus CURRENT-TURN deltas (everything
#      used since the user's last real prompt, across main + subagents).
#      Falls back to the single-turn context_window figures from stdin
#      (labeled "tok (ctx)", no turn parts) when the transcript can't be read.
#   6. Session counters (only when the transcript stats above are available,
#      omitted on the "tok (ctx)" fallback): turns (real user prompts in the
#      main transcript), steps (unique API calls, main + subagents), tools
#      (unique tool calls, main + subagents).
#
# Reads the Claude Code status-line JSON payload from stdin.

input=$(cat)

# USD per 1M tokens per model: [input, output, cache_read]; matched by id prefix, longest first.
# Calls with usage.speed == "fast" are priced from fast_models (falling back to models).
# Cache writes are priced from the input rate by TTL: 5-minute = 1.25x, 1-hour = 2x.
RATES='{
  "models": {
    "claude-fable-5-1":  [10, 50, 0.25],
    "claude-mythos-5-1": [10, 50, 0.25],
    "claude-fable-5":    [10, 50, 1.00],
    "claude-mythos-5":   [10, 50, 1.00],
    "claude-opus-5-5":   [4, 20, 0.20],
    "claude-opus-5":     [5, 25, 0.50],
    "claude-opus-4":     [5, 25, 0.50],
    "claude-sonnet-5-5": [2, 10, 0.20],
    "claude-sonnet-5":   [2, 10, 0.20],
    "claude-sonnet-4":   [3, 15, 0.30],
    "claude-haiku-4-5":  [1, 5, 0.10]
  },
  "fast_models": {
    "claude-opus-5-5":   [8, 40, 0.40],
    "claude-opus-5":     [10, 50, 1.00],
    "claude-opus-4-8":   [10, 50, 1.00]
  },
  "cache_write_5m": 1.25,
  "cache_write_1h": 2
}'

# ---- Palette (Claude Code muted look) ----
RESET=$'\033[0m'
GRAY=$'\033[38;5;245m'    # labels / separators
ORANGE=$'\033[38;5;208m'  # accent / highlight
WHITE=$'\033[38;5;231m'   # filled progress-bar blocks
YELLOW=$'\033[38;5;178m'  # warning threshold (>70%)
RED=$'\033[38;5;167m'     # critical threshold (>90%)

# Color a percentage value by threshold: normal(gray) / >70(yellow) / >90(red).
color_for_pct() {
  local pct_int
  pct_int=$(awk -v p="$1" 'BEGIN { printf "%d", (p+0) }')
  if [ "$pct_int" -ge 90 ]; then
    printf '%s' "$RED"
  elif [ "$pct_int" -ge 70 ]; then
    printf '%s' "$YELLOW"
  else
    printf '%s' "$GRAY"
  fi
}

# Render a block-style progress bar (white filled / dim empty) for 0-100.
render_bar() {
  local pct="$1" width=10 filled empty i bar
  filled=$(awk -v p="$pct" -v w="$width" 'BEGIN { v = (p*w/100)+0.5; if (v<0) v=0; if (v>w) v=w; printf "%d", v }')
  [ -z "$filled" ] && filled=0
  empty=$((width - filled))
  bar=""
  for ((i = 0; i < filled; i++)); do bar+="▓"; done
  bar+="${RESET}${GRAY}"
  for ((i = 0; i < empty; i++)); do bar+="░"; done
  printf '%s%s%s' "$WHITE" "$bar" "$RESET"
}

# True (0) if the value is empty or the literal string "null" (as produced by `jq -r ... // empty`).
is_empty() {
  [ -z "$1" ] || [ "$1" = "null" ]
}

# Compactly format a token count: 999 -> 999, 1000 -> 1.0k, 1500000 -> 1.5M.
fmt_num() {
  is_empty "$1" && return
  awk -v n="$1" 'BEGIN {
    n = n + 0
    if (n < 0) n = 0
    if (n >= 1000000) printf "%.1fM", n / 1000000
    else if (n >= 1000) printf "%.1fk", n / 1000
    else printf "%d", n
  }'
}

# Format a duration in seconds compactly: 1h03m (>=1h), 31m (>=1m, no seconds
# when >=10m), 2m17s (>=1m, <10m, seconds appended), else 45s.
fmt_dur() {
  local total="${1:-0}"
  awk -v s="$total" 'BEGIN {
    s = s + 0
    if (s < 0) s = 0
    h = int(s / 3600)
    m = int((s % 3600) / 60)
    sec = int(s % 60)
    if (h > 0) printf "%dh%02dm", h, m
    else if (m > 0) {
      if (m < 10) printf "%dm%02ds", m, sec
      else printf "%dm", m
    } else printf "%ds", sec
  }'
}

line1_segments=()
line2_segments=()
line3_segments=()

# ---- Single jq call: read all needed stdin fields at once (perf) ----
# One value per line (not @tsv): bash `read`/IFS=$'\t' collapses consecutive
# tabs (tab is IFS whitespace), which shifts columns whenever a field is
# empty. readarray over newline-delimited output preserves empty fields.
readarray -t _f < <(
  printf '%s' "$input" | jq -r '
    [ (.context_window.used_percentage // ""),
      (.context_window.total_input_tokens // ""),
      (.context_window.context_window_size // ""),
      (.context_window.total_output_tokens // ""),
      (.context_window.current_usage.input_tokens // ""),
      (.context_window.current_usage.cache_creation_input_tokens // ""),
      (.context_window.current_usage.cache_read_input_tokens // ""),
      (.context_window.current_usage.output_tokens // ""),
      (if .context_window.current_usage == null then "" else "1" end),
      (.rate_limits.five_hour.used_percentage // ""),
      (.rate_limits.five_hour.resets_at // ""),
      (.rate_limits.seven_day.used_percentage // ""),
      (.workspace.current_dir // ""),
      (.transcript_path // "")
    ] | .[] | tostring' 2>/dev/null
)
ctx_pct=${_f[0]:-}; cw_total_input=${_f[1]:-}; cw_size=${_f[2]:-}; cw_total_output=${_f[3]:-}
cu_input=${_f[4]:-}; cu_cc=${_f[5]:-}; cu_cr=${_f[6]:-}; cu_output=${_f[7]:-}; cu_present=${_f[8]:-}
five_pct=${_f[9]:-}; five_resets=${_f[10]:-}; week_pct=${_f[11]:-}; cwd=${_f[12]:-}; transcript=${_f[13]:-}

# ---- 1. Context window usage ----
if [ -z "$ctx_pct" ] || [ "$ctx_pct" = "null" ]; then
  ctx_pct=$(awk -v i="${cw_total_input:-0}" -v s="${cw_size:-0}" 'BEGIN { if (i>0 && s>0) printf "%.17g", (i/s*100) }')
fi
if [ -n "$ctx_pct" ] && [ "$ctx_pct" != "null" ]; then
  ctx_bar=$(render_bar "$ctx_pct")
  ctx_color=$(color_for_pct "$ctx_pct")
  ctx_r=$(awk -v p="$ctx_pct" 'BEGIN{printf "%.0f", p}')
  line1_segments+=("${GRAY}ctx${RESET} ${ctx_bar} ${ctx_color}${ctx_r}%${RESET}")
fi

# ---- 2. Plan rate limits (5h / 7d usage) + 5h reset time ----
if { [ -n "$five_pct" ] && [ "$five_pct" != "null" ]; } || { [ -n "$week_pct" ] && [ "$week_pct" != "null" ]; }; then
  limit_str=""
  if [ -n "$five_pct" ] && [ "$five_pct" != "null" ]; then
    five_color=$(color_for_pct "$five_pct")
    five_r=$(awk -v p="$five_pct" 'BEGIN{printf "%.0f", p}')
    limit_str+="${GRAY}5h${RESET} ${five_color}${five_r}%${RESET}"
  fi
  if [ -n "$week_pct" ] && [ "$week_pct" != "null" ]; then
    week_color=$(color_for_pct "$week_pct")
    week_r=$(awk -v p="$week_pct" 'BEGIN{printf "%.0f", p}')
    [ -n "$limit_str" ] && limit_str+="${GRAY} · ${RESET}"
    limit_str+="${GRAY}7d${RESET} ${week_color}${week_r}%${RESET}"
  fi
  if [ -n "$five_resets" ] && [ "$five_resets" != "null" ]; then
    reset_clock=$(date -d "@${five_resets}" +%H:%M 2>/dev/null)
    if [ -n "$reset_clock" ]; then
      now=$(date +%s)
      diff=$((five_resets - now))
      if [ "$diff" -gt 0 ]; then
        h=$((diff / 3600))
        m=$(((diff % 3600) / 60))
        if [ "$h" -gt 0 ]; then
          remaining=$(printf '%dh %dm' "$h" "$m")
        else
          remaining=$(printf '%dm' "$m")
        fi
        limit_str+="${GRAY} (resets ${reset_clock}, in ${remaining})${RESET}"
      else
        limit_str+="${GRAY} (resets ${reset_clock})${RESET}"
      fi
    fi
  fi

  # ---- Pace: projects whether the 5h limit will be hit at the current avg rate ----
  # elapsed = time already spent in the current 5h window (18000s), clamped to [0,18000].
  # projected = used_pct extrapolated to the full window at the current rate.
  # Thresholds: projected/used >=100 -> will hit (red up-arrow); >=85 -> close (yellow
  # right-arrow); else -> won't hit (gray down-arrow). Omitted if elapsed < 300s (too early).
  if [ -n "$five_pct" ] && [ "$five_pct" != "null" ] && [ -n "$five_resets" ] && [ "$five_resets" != "null" ]; then
    pace_now=$(date +%s)
    pace_state=$(awk -v u="$five_pct" -v r="$five_resets" -v now="$pace_now" 'BEGIN {
      window = 18000
      elapsed = window - (r - now)
      if (elapsed < 0) elapsed = 0
      if (elapsed > window) elapsed = window
      if (elapsed < 300) { exit }
      projected = u * window / elapsed
      if (u >= 100 || projected >= 100) print "hit"
      else if (projected >= 85) print "close"
      else print "ok"
    }')
    if [ -n "$pace_state" ]; then
      case "$pace_state" in
        hit) pace_color="$RED"; pace_char="↑" ;;
        close) pace_color="$YELLOW"; pace_char="→" ;;
        *) pace_color="$GRAY"; pace_char="↓" ;;
      esac
      limit_str+="${GRAY} · ${RESET}${GRAY}pace${RESET} ${pace_color}${pace_char}${RESET}"
    fi
  fi

  line1_segments+=("$limit_str")
fi

# ---- 3. Current folder ----
if [ -n "$cwd" ] && [ "$cwd" != "null" ]; then
  base=$(basename "$cwd")
  display_path="$cwd"
  if [ -n "${HOME:-}" ] && [ "${cwd#"$HOME"}" != "$cwd" ]; then
    display_path="~${cwd#"$HOME"}"
  fi
  if [ "${#display_path}" -le 40 ]; then
    line1_segments+=("${ORANGE}${display_path}${RESET}")
  else
    line1_segments+=("${ORANGE}${base}${RESET}")
  fi

  # ---- 4. Git branch (only when inside a git repo) ----
  branch=$(git --no-optional-locks -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)
  if [ -n "$branch" ]; then
    line1_segments+=("${GRAY}${branch}${RESET}")
  fi
fi

# ---- 5. Token usage — session totals + current-turn deltas ----
stats=""
since=""
active=0
if [ -n "$transcript" ] && [ "$transcript" != "null" ] && [ -f "$transcript" ]; then
  # Subagent discovery across continued sessions: a session can be "continued" into a
  # new transcript file, splitting subagent transcripts across
  # <projdir>/<old-session-id>/subagents/ and <projdir>/<new-session-id>/subagents/.
  # Scan every session dir under the project dir and keep only the subagent transcripts
  # whose tool_use id actually has a result in THIS transcript (main thread replays full
  # history on continuation, so this correctly picks up carried-over subagents too).
  # Finished-task detection is jq-based on real user entries (never a plain grep), since
  # tool outputs may contain literal <task-id>...</task-id> text.
  projdir=$(dirname "$transcript")
  done_json=$(jq -c -s '
    { notified: [ .[] | select(.type=="user" and (.message.content|type)=="string" and (.message.content|startswith("<task-notification>")))
                  | .message.content | capture("<task-id>(?<id>[^<]+)</task-id>") | .id ] | unique,
      results:  [ .[] | select(.type=="user" and (.message.content|type)=="array") | .message.content[] | select(.type=="tool_result") | .tool_use_id ] | unique,
      uses:     [ .[] | select(.type=="assistant") | .message.content[]? | select(.type=="tool_use") | .id ] | unique,
      main_running: ([.[] | select(.type=="assistant" or .type=="user")] | last | if . == null then false else (.type != "assistant" or (.message.stop_reason // "") != "end_turn") end) }' "$transcript" 2>/dev/null)
  main_running="false"
  if [ -n "$done_json" ]; then
    main_running=$(printf '%s' "$done_json" | jq -r '.main_running // false')
  fi
  subfiles=()
  shopt -s nullglob
  metas=( "$projdir"/*/subagents/agent-*.meta.json )
  shopt -u nullglob
  if [ ${#metas[@]} -gt 0 ] && [ -n "$done_json" ]; then
    sub_res=$(jq -c -n --argjson done "$done_json" '
      [inputs | . as $m | input_filename as $f
       | ($f | sub("\\.meta\\.json$"; "") | sub(".*/agent-"; "")) as $id
       | select(($m.toolUseId // "") as $tu | $tu != "" and ($done.uses | index($tu)) != null)
       | { file: ($f | sub("\\.meta\\.json$"; ".jsonl")),
           active: (if (($m.requestShape // "") == "background")
                    then (($done.notified | index($id)) == null)
                    else (($done.results | index($m.toolUseId)) == null) end) } ]
      | { files: map(.file), active: (map(select(.active)) | length) }' "${metas[@]}" 2>/dev/null)
    if [ -n "$sub_res" ]; then
      active=$(printf '%s' "$sub_res" | jq -r '.active // 0')
      while IFS= read -r f; do [ -f "$f" ] && subfiles+=("$f"); done < <(printf '%s' "$sub_res" | jq -r '.files[]?')
    fi
  fi

  # Timestamps of the user's real (typed) prompts, from the MAIN transcript only
  # (subagent transcripts have their own isSidechain=true user entries, which don't count).
  # Captured once: line count -> turns, last line -> since (current-turn cutoff).
  since_all=$(jq -r 'select(.type=="user" and ((.isSidechain // false)|not)
    and (((.message.content|type)=="string") or ((.message.content|type)=="array" and .message.content[0].type=="text"))
    and ((.message.content | if type=="string" then . else .[0].text end)
         | (startswith("<task-notification>") or startswith("<local-command") or startswith("<system-reminder>")) | not))
    | .timestamp' "$transcript" 2>/dev/null)
  turns=$(printf '%s\n' "$since_all" | grep -c .)
  since=$(printf '%s\n' "$since_all" | tail -1)
  stats=$( { cat "$transcript" 2>/dev/null; [ ${#subfiles[@]} -gt 0 ] && cat "${subfiles[@]}" 2>/dev/null; } | jq -c -s --arg since "$since" --arg now "$(date -u +%FT%TZ)" --argjson rates "$RATES" '
    def ts: (.timestamp // "" | if . == "" then null else (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) end);
    def agg: group_by(.message.id)
      | map({i:(map(.message.usage.input_tokens//0)|max), cc:(map(.message.usage.cache_creation_input_tokens//0)|max), cr:(map(.message.usage.cache_read_input_tokens//0)|max), o:(map(.message.usage.output_tokens//0)|max)})
      | {i:(map(.i)|add//0), cc:(map(.cc)|add//0), cr:(map(.cr)|add//0), o:(map(.o)|add//0), n:length};
    # price each deduped assistant message by ITS OWN model (rate matched by longest id prefix)
    def rate_in($table; $model): ($table // {} | to_entries | map(select(.key as $k | $model | startswith($k))) | sort_by(.key | length) | last);
    def rate_for($model; $speed): (if $speed == "fast" then rate_in($rates.fast_models; $model) else null end) // rate_in($rates.models; $model);
    def cost_stats: group_by(.message.id)
      | map({i:(map(.message.usage.input_tokens//0)|max), cc:(map(.message.usage.cache_creation_input_tokens//0)|max), cr:(map(.message.usage.cache_read_input_tokens//0)|max), o:(map(.message.usage.output_tokens//0)|max),
             c5:(map(.message.usage.cache_creation.ephemeral_5m_input_tokens // 0)|max), c1:(map(.message.usage.cache_creation.ephemeral_1h_input_tokens // 0)|max),
             model:(.[0].message.model // ""), speed:(map(.message.usage.speed // empty) | first // "standard")})
      | map(if (.c5 == 0 and .c1 == 0 and .cc > 0) then . + {c5: .cc} else . end)
      | map(. + {rate: rate_for(.model; .speed)})
      | { cost: (map(select(.rate != null) | (.i*.rate.value[0] + .o*.rate.value[1] + .cr*.rate.value[2] + .c5*.rate.value[0]*$rates.cache_write_5m + .c1*.rate.value[0]*$rates.cache_write_1h) / 1e6) | add // 0),
          unknown: (map(select(.rate == null)) | length) };
    . as $all
    | ([$all[] | select(.type=="assistant" and (.message.usage? != null))]) as $a
    # tools: match tool_use -> tool_result by id, excluding subagent-dispatch ("Agent") uses
    | ([$all[] | select(.type=="assistant") | . as $e | ($e|ts) as $t | .message.content[]? | select(.type=="tool_use") | {id, name, t: $t}]
         | unique_by(.id) | map({key: .id, value: {name, t}}) | from_entries) as $uses
    | ([$all[] | select(.type=="user") | . as $e | ($e|ts) as $t | .message.content[]? | select(.type=="tool_result") | {id: .tool_use_id, t: $t}]
         | unique_by(.id)) as $results
    | ($results | map(. as $r | $uses[$r.id] as $u | select($u != null and $u.name != "Agent" and $r.t != null and $u.t != null) | ($r.t - $u.t)) | add // 0) as $tool_secs
    # main thread busy time: per real user prompt, latest main-thread entry before next prompt minus prompt time
    | ([$all[] | select(.type=="user" and ((.isSidechain // false)|not)
         and (((.message.content|type)=="string") or ((.message.content|type)=="array" and .message.content[0].type=="text"))
         and ((.message.content | if type=="string" then . else .[0].text end) | (startswith("<task-notification>") or startswith("<local-command") or startswith("<system-reminder>")) | not))
         | ts] | map(select(. != null)) | sort) as $prompts
    | ([$all[] | select(((.isSidechain // false)|not) and (.type=="assistant" or .type=="user")) | ts] | map(select(. != null)) | sort) as $main_ts
    | ($prompts | to_entries | map(.value as $p | (if (.key+1) < ($prompts|length) then $prompts[.key+1] else 1e12 end) as $next
         | ([$main_ts[] | select(. >= $p and . < $next)] | max // $p) - $p) | add // 0) as $main_busy
    # subagent run time: per subagent (sidechain entries grouped by agentId), last - first timestamp
    | ([$all[] | select((.isSidechain // false) and (.timestamp != null)) | {a: (.agentId // .sessionId // "?"), t: ts}] | group_by(.a)
         | map({first: (map(.t)|min), last: (map(.t)|max)}) | map(.last - .first) | add // 0) as $sub_secs
    | {total: ($a|agg), turn: ($a | map(select(($since != "") and ((.timestamp//"") >= $since))) | agg),
       tools: ([$all[] | select(.type=="assistant") | .message.content[]? | select(.type=="tool_use") | .id] | unique | length),
       agent_secs: $main_busy, sub_secs: $sub_secs, tool_secs: $tool_secs}
      + ($a|cost_stats)' 2>/dev/null)
fi

tok_line=""
counts_line=""
durations_line=""
cost_line=""
if [ -n "$stats" ] && [ "$stats" != "null" ]; then
  IFS=$'\t' read -r steps tools_n t_i t_cc t_cr t_o turn_i turn_cc turn_cr turn_o agent_secs sub_secs tool_secs t_cost t_unknown < <(
    printf '%s' "$stats" | jq -r '
      [.total.n // 0, .tools // 0, .total.i // 0, .total.cc // 0, .total.cr // 0, .total.o // 0,
       .turn.i // 0, .turn.cc // 0, .turn.cr // 0, .turn.o // 0,
       (.agent_secs // 0), (.sub_secs // 0), (.tool_secs // 0),
       (.cost // 0), (.unknown // 0)] | @tsv' 2>/dev/null
  )
  counts_line="${GRAY}turns${RESET} ${turns}${GRAY} · ${RESET}${GRAY}steps${RESET} ${steps}${GRAY} · ${RESET}${GRAY}tools${RESET} ${tools_n}"
  durations_line="${GRAY}agents${RESET} $(fmt_dur "$agent_secs")${GRAY} · ${RESET}${GRAY}subs${RESET} $(fmt_dur "$sub_secs")${GRAY} · ${RESET}${GRAY}tools${RESET} $(fmt_dur "$tool_secs")"

  # ---- Session API cost — priced per call by its own model (line 3) ----
  known_count=$(( ${steps:-0} - ${t_unknown:-0} ))
  cost_gt0=0
  awk -v c="${t_cost:-0}" 'BEGIN { exit !(c > 0) }' 2>/dev/null && cost_gt0=1
  if [ "$known_count" -gt 0 ] 2>/dev/null || [ "$cost_gt0" -eq 1 ]; then
    cost_str=$(awk -v c="${t_cost:-0}" 'BEGIN {
      if (c <= 0) printf "$0.00"
      else if (c < 0.01) printf "<$0.01"
      else printf "$%.2f", c
    }')
    if [ "${t_unknown:-0}" -gt 0 ] 2>/dev/null; then
      cost_str="≥${cost_str}"
    fi
    cost_line="${GRAY}cost${RESET} ${cost_str}"
  fi

  if [ -n "$t_i" ] && [ -n "$t_cc" ] && [ -n "$t_cr" ] && [ -n "$t_o" ]; then
    t_up=$((t_i + t_cc + t_cr))
    tok_line="${GRAY}tok${RESET} ↑$(fmt_num "$t_up")"
    if [ -n "$since" ] && [ -n "$turn_i" ] && [ -n "$turn_cc" ] && [ -n "$turn_cr" ]; then
      turn_up=$((turn_i + turn_cc + turn_cr))
      tok_line+=" ${GRAY}(turn${RESET} $(fmt_num "$turn_up")${GRAY})${RESET}"
    fi
    tok_line+=" ↓$(fmt_num "$t_o")"
    if [ -n "$since" ] && [ -n "$turn_o" ]; then
      tok_line+=" ${GRAY}(turn${RESET} $(fmt_num "$turn_o")${GRAY})${RESET}"
    fi
    # cache: ↓ = read from cache, ↑ = written to cache
    tok_line+="${GRAY} · ${RESET}${GRAY}cache${RESET} ↓$(fmt_num "$t_cr") ↑$(fmt_num "$t_cc")"

    t_cached_pct=$(awk -v r="$t_cr" -v t="$t_up" 'BEGIN { if (t > 0) printf "%.0f", (r / t * 100) }')
    if [ -n "$t_cached_pct" ]; then
      tok_line+="${GRAY} · ${RESET}${ORANGE}${t_cached_pct}%${RESET} ${GRAY}cached${RESET}"
    fi

    main_running_flag=0
    [ "$main_running" = "true" ] && main_running_flag=1
    agents_n=$((active + main_running_flag))

    if [ "$agents_n" -gt 0 ] 2>/dev/null; then
      agents_color="$ORANGE"
    else
      agents_color="$WHITE"
    fi
    if [ "$active" -gt 0 ] 2>/dev/null; then
      sub_color="$ORANGE"
    else
      sub_color="$WHITE"
    fi
    tok_line+="${GRAY} · ${RESET}${agents_color}${agents_n}${RESET} ${GRAY}agents${RESET}${GRAY} · ${RESET}${sub_color}${active}${RESET} ${GRAY}sub${RESET}"
  fi
fi

# Fallback: single-turn context_window figures from stdin (not a session total).
if [ -z "$tok_line" ]; then
  cw_in="$cw_total_input"; is_empty "$cw_in" && cw_in="$cu_input"
  cw_out="$cw_total_output"; is_empty "$cw_out" && cw_out="$cu_output"
  cw_cr="$cu_cr"
  cw_cc="$cu_cc"

  if ! is_empty "$cw_in" || ! is_empty "$cw_out"; then
    io_str=""
    if ! is_empty "$cw_in"; then io_str+="↑$(fmt_num "$cw_in")"; fi
    if ! is_empty "$cw_out"; then
      [ -n "$io_str" ] && io_str+=" "
      io_str+="↓$(fmt_num "$cw_out")"
    fi
    tok_line="${GRAY}tok (ctx)${RESET} ${io_str}"

    if ! is_empty "$cw_cr" || ! is_empty "$cw_cc"; then
      cr0="$cw_cr"; is_empty "$cr0" && cr0=0
      cc0="$cw_cc"; is_empty "$cc0" && cc0=0
      # cache: ↓ = read from cache, ↑ = written to cache
      tok_line+="${GRAY} · ${RESET}${GRAY}cache${RESET} ↓$(fmt_num "$cr0") ↑$(fmt_num "$cc0")"

      cw_cached_pct=$(awk -v i="${cu_input:-0}" -v w="${cu_cc:-0}" -v r="${cu_cr:-0}" 'BEGIN {
        t = i + w + r
        if (t > 0) printf "%.17g", (r / t * 100)
      }')
      if ! is_empty "$cw_cached_pct"; then
        cw_cached_pct_r=$(awk -v p="$cw_cached_pct" 'BEGIN{printf "%.0f", p}')
        tok_line+="${GRAY} · ${RESET}${ORANGE}${cw_cached_pct_r}%${RESET} ${GRAY}cached${RESET}"
      fi
    fi
  fi
fi

if [ -n "$tok_line" ]; then
  line2_segments+=("$tok_line")
fi
if [ -n "$counts_line" ]; then
  line3_segments+=("$counts_line")
fi
if [ -n "$durations_line" ]; then
  line3_segments+=("$durations_line")
fi
if [ -n "$cost_line" ]; then
  line3_segments+=("$cost_line")
fi

# ---- Join non-empty segments with a dim separator ----
sep="${GRAY} │ ${RESET}"
join_segments() {
  local out=""
  local seg
  for seg in "$@"; do
    [ -z "$seg" ] && continue
    if [ -z "$out" ]; then
      out="$seg"
    else
      out="${out}${sep}${seg}"
    fi
  done
  printf '%s' "$out"
}

line1=$(join_segments "${line1_segments[@]}")
line2=$(join_segments "${line2_segments[@]}")
line3=$(join_segments "${line3_segments[@]}")

output_lines=()
for candidate in "$line1" "$line2" "$line3"; do
  [ -n "$candidate" ] && output_lines+=("$candidate")
done

out=""
for l in "${output_lines[@]}"; do
  if [ -z "$out" ]; then
    out="$l"
  else
    out="${out}"$'\n'"${l}"
  fi
done
printf '%s' "$out"
