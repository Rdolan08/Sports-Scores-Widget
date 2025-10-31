command: """
gdate='/opt/homebrew/bin/gdate'
now=$(date -u +%s)
CURL='curl -sS --compressed --connect-timeout 5 --max-time 15 --retry 2 --retry-delay 1 --retry-all-errors'

# Harden script and keep stderr out of widget output
set -euo pipefail
exec 2>/dev/null

# ---- Quiet, resilient JSON fetch w/ caching for Übersicht ----
CACHE_DIR="/tmp/uebersicht-cache"
mkdir -p "$CACHE_DIR"

# fetch_json URL [cache_filename] [ttl_seconds]
fetch_json() {
  local url="$1"
  local cache_file="${2:-}"
  local ttl="${3:-900}"

  # Derive a safe cache filename if none provided
  if [[ -z "$cache_file" ]]; then
    if command -v md5 >/dev/null 2>&1; then
      cache_file="$(md5 -q <<<"$url").json"
    else
      cache_file="$(printf "%s" "$url" | md5sum | awk '{print $1}').json"
    fi
  fi

  local path="$CACHE_DIR/$cache_file"
  local now epoch_mtime age
  now="$(date +%s)"
  if [[ -f "$path" ]]; then
    epoch_mtime="$(stat -f %m "$path" 2>/dev/null || stat -c %Y "$path")"
    age=$(( now - epoch_mtime ))
  else
    age=$(( ttl + 1 ))
  fi

  # Use cache if fresh
  if (( age <= ttl )); then
    cat "$path"
    return 0
  fi

  # Try to refresh the cache quietly with retries/timeouts
  local tmp="$path.tmp.$$"
  if $CURL "$url" -o "$tmp"; then
    if head -c 1 "$tmp" | grep -q '[{\[]'; then
      mv "$tmp" "$path"
      cat "$path"
      return 0
    fi
  fi

  # Fall back to stale cache if present
  if [[ -f "$path" ]]; then
    cat "$path"
    return 0
  fi

  # Last resort: empty JSON
  printf '{}'
}

# Same as fetch_json but with a bearer-style header (used for football-data.org token)
# fetch_json_auth URL TOKEN [cache_filename] [ttl_seconds]
fetch_json_auth() {
  local url="$1"
  local token="$2"
  local cache_file="${3:-}"
  local ttl="${4:-900}"

  if [[ -z "$cache_file" ]]; then
    if command -v md5 >/dev/null 2>&1; then
      cache_file="$(md5 -q <<<"$url|$token").json"
    else
      cache_file="$(printf "%s" "$url|$token" | md5sum | awk '{print $1}').json"
    fi
  fi
  local path="$CACHE_DIR/$cache_file"
  local now epoch_mtime age
  now="$(date +%s)"
  if [[ -f "$path" ]]; then
    epoch_mtime="$(stat -f %m "$path" 2>/dev/null || stat -c %Y "$path")"
    age=$(( now - epoch_mtime ))
  else
    age=$(( ttl + 1 ))
  fi
  if (( age <= ttl )); then
    cat "$path"
    return 0
  fi
  local tmp="$path.tmp.$$"
  if $CURL -H "X-Auth-Token: $token" "$url" -o "$tmp"; then
    if head -c 1 "$tmp" | grep -q '[{\[]'; then
      mv "$tmp" "$path"
      cat "$path"
      return 0
    fi
  fi
  if [[ -f "$path" ]]; then
    cat "$path"
    return 0
  fi
  printf '{}'
}

teamList="⚾️ Twins|baseball/mlb|Minnesota Twins
🏈 Vikings|football/nfl|Minnesota Vikings
🏈 Bengals|football/nfl|Cincinnati Bengals
🏀 T-Wolves|basketball/nba|Minnesota Timberwolves
🏀 Lynx|basketball/wnba|Minnesota Lynx
🏒 Wild|hockey/nhl|Minnesota Wild
🏒 Capitals|hockey/nhl|Washington Capitals
🏈 Gophers|football/college-football|Minnesota Golden Gophers
⚽️ Loons|soccer/usa.1|Minnesota United"

output="<span class='header'>Scores / Upcoming Schedule</span>\\n"

while IFS='|' read -r label path name; do
  start=$($gdate -u -d '-1 day' '+%Y%m%d')
  end=$($gdate -u -d '+7 days' '+%Y%m%d')
  data="$(fetch_json "https://site.api.espn.com/apis/site/v2/sports/$path/scoreboard?limit=300&dates=$start-$end" "" 900)"

  # Skip this team if the API did not return JSON
  if ! echo "$data" | jq -e . >/dev/null 2>&1; then
    continue
  fi

  # Pick the nearest event for this team: prefer future, else latest past
  event=$(echo "$data" | jq -c --arg n "$name" --argjson now "$now" '
    [ (.events // [])[]
      | select(
          any((.competitions[0].competitors // [])[];
            (try (.team.displayName | tostring | test($n; "i")) catch false) or
            (try (.team.shortDisplayName | tostring | test($n; "i")) catch false) or
            (try (.team.abbreviation | tostring | test($n; "i")) catch false)
          )
        )
    ] as $evts
    | ( $evts
        | map( . + {
            ts: ( .date
                  | (strptime("%Y-%m-%dT%H:%MZ")
                     // strptime("%Y-%m-%dT%H:%M:%SZ")
                     // strptime("%Y-%m-%dT%H:%M:%S%z"))
                  | mktime )
          })
        | ( [ .[] | select(.ts >= $now) ] | sort_by(.ts) | .[0] )
          // ( sort_by(.ts) | .[-1] )
      )')

  # Skip if no matching event found
  if [ -z "$event" ] || [ "$event" = "null" ]; then
    continue
  fi

  comp=$(echo "$event" | jq -c '.competitions[0]')
  if [ -z "$comp" ] || [ "$comp" = "null" ]; then
    continue
  fi
  date=$(echo "$event" | jq -r '.date')
  ts=$($gdate -d "$date" +%s 2>/dev/null)
  diff=$((now - ts))

  home=$(echo "$comp" | jq -r '.competitors[] | select(.homeAway=="home") | .team.displayName')
  away=$(echo "$comp" | jq -r '.competitors[] | select(.homeAway=="away") | .team.displayName')
  homeScore=$(echo "$comp" | jq -r '.competitors[] | select(.homeAway=="home") | .score // empty')
  awayScore=$(echo "$comp" | jq -r '.competitors[] | select(.homeAway=="away") | .score // empty')
  isHome=$([ "$home" = "$name" ] && echo "true" || echo "false")
  winner=$(echo "$comp" | jq -r --arg n "$name" '.competitors[] | select(.team.displayName==$n) | .winner')

  formatted=$(TZ="America/Chicago" $gdate -d "$date" "+%a, %b %d at %I:%M %p")

  if [ "$winner" != "null" ] && [ "$ts" -le "$now" ] && [ "$diff" -le 43200 ]; then
    outcome=$([ "$winner" = "true" ] && echo "W" || echo "L")
    score="${homeScore:-0}–${awayScore:-0}"
    vs=$([ "$isHome" = "true" ] && echo "vs $away" || echo "@ $home")
    output+="$label: $outcome $score $vs ($formatted)\\n"
  else
    vs=$([ "$isHome" = "true" ] && echo "vs $away" || echo "@ $home")
    output+="$label: Next $vs ($formatted)\\n"
  fi

done <<< "$teamList"

# ⚽️ Bayern Munich via football-data.org (Team ID: 5) — all competitions, safe fails
FD_TOKEN="${FD_TOKEN:-89733dc42759431a949e4f46e6947ff5}"

# Window: next 60 days (upcoming), and last 1 day (recent results)
fd_from=$($gdate -u '+%Y-%m-%d')
fd_to=$($gdate -u -d '+60 days' '+%Y-%m-%d')

# Fetch upcoming
fd_next="$(fetch_json_auth "https://api.football-data.org/v4/teams/5/matches?dateFrom=$fd_from&dateTo=$fd_to&status=SCHEDULED&competitions=BL1,CL,DFB" "$FD_TOKEN" "" 1800)" || fd_next='{}'
# Validate JSON; if invalid, force empty matches to avoid jq errors
if ! echo "$fd_next" | jq -e . >/dev/null 2>&1; then fd_next='{"matches":[]}' ; fi

fd_next_match=$(echo "$fd_next" | jq -c '(.matches // []) | sort_by(.utcDate) | .[0]')

if [ -n "$fd_next_match" ] && [ "$fd_next_match" != "null" ]; then
  ndate=$(echo "$fd_next_match" | jq -r '.utcDate')
  nhome=$(echo "$fd_next_match" | jq -r '.homeTeam.name')
  naway=$(echo "$fd_next_match" | jq -r '.awayTeam.name')
  nhome_id=$(echo "$fd_next_match" | jq -r '.homeTeam.id')
  isHome=$([ "$nhome_id" = "5" ] && echo "true" || echo "false")
  vs=$([ "$isHome" = "true" ] && echo "vs $naway" || echo "@ $nhome")
  when=$(TZ="America/Chicago" $gdate -d "$ndate" "+%a, %b %d at %I:%M %p")
  output+="⚽️ Bayern: Next $vs ($when)\n"
else
  # Fetch most recent finished (past 1 day)
  fd_prev_from=$($gdate -u -d '-1 day' '+%Y-%m-%d')
  fd_prev="$(fetch_json_auth "https://api.football-data.org/v4/teams/5/matches?dateFrom=$fd_prev_from&dateTo=$fd_from&status=FINISHED&competitions=BL1,CL,DFB" "$FD_TOKEN" "" 1800)" || fd_prev='{}'
  if ! echo "$fd_prev" | jq -e . >/dev/null 2>&1; then fd_prev='{"matches":[]}' ; fi
  fd_prev_match=$(echo "$fd_prev" | jq -c '(.matches // []) | sort_by(.utcDate) | .[-1]')
  if [ -n "$fd_prev_match" ] && [ "$fd_prev_match" != "null" ]; then
    pdate=$(echo "$fd_prev_match" | jq -r '.utcDate')
    pts=$($gdate -d "$pdate" +%s 2>/dev/null)
    pdiff=$((now - pts))
    if [ "$pts" -le "$now" ] && [ "$pdiff" -le 43200 ]; then
      phome=$(echo "$fd_prev_match" | jq -r '.homeTeam.name')
      paway=$(echo "$fd_prev_match" | jq -r '.awayTeam.name')
      phome_id=$(echo "$fd_prev_match" | jq -r '.homeTeam.id')
      isHome=$([ "$phome_id" = "5" ] && echo "true" || echo "false")
      hs=$(echo "$fd_prev_match" | jq -r '.score.fullTime.home // 0')
      as=$(echo "$fd_prev_match" | jq -r '.score.fullTime.away // 0')
      if [ "$hs" -eq "$as" ]; then result="D"
      elif [ "$hs" -gt "$as" ] && [ "$isHome" = "true" ]; then result="W"
      elif [ "$as" -gt "$hs" ] && [ "$isHome" = "false" ]; then result="W"
      else result="L"; fi
      when=$(TZ="America/Chicago" $gdate -d "$pdate" "+%a, %b %d at %I:%M %p")
      score="${hs}–${as}"
      vs=$([ "$isHome" = "true" ] && echo "vs $paway" || echo "@ $phome")
      output+="⚽️ Bayern: $result $score $vs ($when)\n"
    else
      output+="⚽️ Bayern: No upcoming match listed\n"
    fi
  else
    output+="⚽️ Bayern: No upcoming match listed\n"
  fi
fi

echo -e "$output"
echo "Updated: $(date '+%Y-%m-%d %I:%M:%S %p')"
"""
refreshFrequency: 3600000

style: """
  bottom: 90px
  left: 460px
  color: #f2f2f2
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, 'Open Sans', 'Helvetica Neue', sans-serif
  font-size: 16px
  background: rgba(20, 20, 20, 0.3)
  padding: 5px 15px
  border-radius: 20px
  box-shadow: 0 4px 12px rgba(0,0,0,0.3)
  line-height: 1.6
  white-space: pre
  overflow-y: auto
  max-height: 178px
.header {
  font-size: 18px;
  font-weight: bold;
  margin-bottom: 0px;
}
"""