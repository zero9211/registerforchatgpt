#!/usr/bin/env bash
#
# Batch test IPRoyal proxy sessions against ChatGPT (and other reference targets).
#
# Input format (one per line):
#   HOST:PORT:USERNAME:PASSWORD
#
# Example line:
#   geo.iproyal.com:12321:AxrvQi8XV0w3Hxha:KrIZgFiHm7TIBmBI_country-us_session-JMqMPu07_lifetime-20m
#
# Usage:
#   ./test_proxy_chatgpt.sh <proxy_list_file>
#   ./test_proxy_chatgpt.sh proxies.txt
#   cat proxies.txt | ./test_proxy_chatgpt.sh -
#
# Output: colored summary per session, plus a final tally of how many can reach chatgpt.com.

set -u

# ---- config ----
TIMEOUT=10
# Ordered targets; ChatGPT is the one we actually care about,
# but the others help diagnose whether a failure is session-wide or ChatGPT-specific.
TARGETS=(
  "https://ipv4.icanhazip.com"   # 1. proxy liveness + exit IP
  "https://www.google.com"        # 2. non-Cloudflare baseline
  "https://www.cloudflare.com"    # 3. Cloudflare baseline (ChatGPT is also on CF)
  "https://chatgpt.com"           # 4. the real goal
)

# ---- colors ----
# Use $'...' so the escapes expand at assignment time, which works with
# plain `echo` under macOS bash 3.2 (no -e needed).
if [ -t 1 ]; then
  GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[1;33m'
  BOLD=$'\033[1m';     DIM=$'\033[2m';   RESET=$'\033[0m'
else
  GREEN=''; RED=''; YELLOW=''; BOLD=''; DIM=''; RESET=''
fi

usage() {
  grep -E '^# ' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

[ "$#" -ge 1 ] || usage

input_file="$1"
if [ "$input_file" = "-" ]; then
  proxy_lines=$(cat)
else
  [ -f "$input_file" ] || { echo "${RED}File not found: $input_file${RESET}" >&2; exit 1; }
  proxy_lines=$(cat "$input_file")
fi

# ---- counters ----
total=0
chatgpt_pass=0
chatgpt_fail=0

printf "${BOLD}%-12s %-28s %s${RESET}\n" "TARGET" "RESULT" "EXTRA"
printf '%s\n' "---------------------------------------------------------------"

session_idx=0
while IFS= read -r line; do
  # Skip blanks and comments
  line_stripped=$(echo "$line" | tr -d '[:space:]')
  [ -z "$line_stripped" ] && continue
  case "$line_stripped" in \#*) continue ;; esac

  # Parse HOST:PORT:USER:PASS (PASS may contain underscores/hyphens, but no colons)
  host=$(echo "$line_stripped" | cut -d: -f1)
  port=$(echo "$line_stripped" | cut -d: -f2)
  user=$(echo "$line_stripped" | cut -d: -f3)
  pass=$(echo "$line_stripped" | cut -d: -f4-)

  if [ -z "$host" ] || [ -z "$port" ] || [ -z "$user" ] || [ -z "$pass" ]; then
    echo "${YELLOW}Skipping malformed line: $line${RESET}" >&2
    continue
  fi

  session_idx=$((session_idx + 1))
  total=$((total + 1))

  # Extract session label from password for readability (e.g. session-JMqMPu07)
  session_label=$(echo "$pass" | grep -oE 'session-[A-Za-z0-9]+' || echo "session-$session_idx")

  proxy_url="http://${user}:${pass}@${host}:${port}"

  echo ""
  printf "${BOLD}[%02d] %s${RESET} ${DIM}(%s)${RESET}\n" "$session_idx" "$session_label" "$host:$port"

  chatgpt_ok=0
  target_idx=0
  for target in "${TARGETS[@]}"; do
    target_idx=$((target_idx + 1))
    # -s silent, -o discard body, -w format. %{exitcode} only in newer curl, so use curl return code too.
    # We want: http_code, time, and the body for icanhazip (exit IP).
    if [[ "$target" == *"icanhazip"* ]]; then
      # Capture body to see exit IP
      out=$(curl -sS -x "$proxy_url" "$target" \
        --max-time "$TIMEOUT" \
        -w "\n__STATUS__:%{http_code}\n__TIME__:%{time_total}\n" 2>&1)
      rc=$?
      body=$(echo "$out" | sed -n '/^__STATUS__:/!p' | grep -v '^__TIME__:' | tr -d '[:space:]')
      http_code=$(echo "$out" | awk -F: '/^__STATUS__/{print $2}')
      time_s=$(echo "$out" | awk -F: '/^__TIME__/{print $2}')
    else
      out=$(curl -sS -o /dev/null -x "$proxy_url" "$target" \
        --max-time "$TIMEOUT" \
        -w "%{http_code}|%{time_total}" 2>&1)
      rc=$?
      http_code=$(echo "$out" | awk -F'|' '{print $1}')
      time_s=$(echo "$out" | awk -F'|' '{print $2}')
      body=""
    fi

    # Decide pass/fail
    if [ "$rc" -eq 0 ] && [ -n "$http_code" ] && [ "$http_code" != "000" ]; then
      status="${GREEN}OK  HTTP $http_code${RESET}"
      extra="${DIM}${time_s}s${RESET}"
      if [ -n "$body" ]; then
        extra="${extra} ${DIM}exit=${body}${RESET}"
      fi
      [ "$target" = "https://chatgpt.com" ] && chatgpt_ok=1
    else
      # curl error (e.g. 56=RST, 28=timeout, 7=refused)
      err=$(echo "$out" | tr -d '\n' | sed 's/.*curl: //' | head -c 60)
      status="${RED}FAIL rc=$rc${RESET}"
      extra="${DIM}${err}${RESET}"
    fi

    printf "  ${DIM}%-24s${RESET} %-30b %b\n" "$(echo "$target" | sed 's|https://||')" "$status" "$extra"
  done

  if [ "$chatgpt_ok" -eq 1 ]; then
    chatgpt_pass=$((chatgpt_pass + 1))
    printf "  ${GREEN}${BOLD}=> ChatGPT reachable${RESET}\n"
  else
    chatgpt_fail=$((chatgpt_fail + 1))
    printf "  ${RED}${BOLD}=> ChatGPT unreachable${RESET}\n"
  fi
done <<< "$proxy_lines"

echo ""
echo "================================================================"
printf "${BOLD}Summary${RESET}: tested ${BOLD}%d${RESET} sessions\n" "$total"
printf "  ${GREEN}ChatGPT reachable: %d${RESET}\n" "$chatgpt_pass"
printf "  ${RED}ChatGPT failed   : %d${RESET}\n" "$chatgpt_fail"
if [ "$total" -gt 0 ]; then
  rate=$(awk -v p="$chatgpt_pass" -v t="$total" 'BEGIN{printf "%.0f", (p/t)*100}')
  printf "  Hit rate         : ${BOLD}%d%%${RESET}\n" "$rate"
fi
echo "================================================================"

# Exit 0 if at least one session works, 1 otherwise
[ "$chatgpt_pass" -gt 0 ] && exit 0 || exit 1
