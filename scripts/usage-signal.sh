#!/usr/bin/env bash
# Prints one line of PreviewMD usage numbers for the weekly scoreboard.
# PreviewMD has no telemetry, so these GitHub counters are the signal:
#   - release asset downloads (DMG only; .sha256 excluded), public
#   - stars on ychani/PreviewMD and ychani/homebrew-tap, public
#   - homebrew-tap clones/views, owner-only, rolling 14 days
#   - README visits to Univocal: requests for univocalapp.com/go/previewmd
#     (both slash forms), last 7 days, from Cloudflare zone request analytics
# `brew install --cask ychani/tap/previewmd` clones the tap, so tap clones
# approximate Homebrew installs and updates (CI and mirrors also count).
#
# Owner-only numbers need a token with push access: $GITHUB_TOKEN, or
# `gh auth token`. Without one they print as "n/a" and the line still prints.
# The Univocal count needs $CLOUDFLARE_API_TOKEN with Analytics Read on the
# univocalapp.com zone (plus Zone Read, or set $CLOUDFLARE_ZONE_ID); it is
# "n/a" without one, or if the query fails (e.g. past the plan's retention).
#
# Usage: scripts/usage-signal.sh
# Needs: curl, jq.
set -euo pipefail

APP_REPO="ychani/PreviewMD"
TAP_REPO="ychani/homebrew-tap"
API="https://api.github.com"
CF_API="https://api.cloudflare.com/client/v4"
GO_PATHS='["/go/previewmd","/go/previewmd/"]'

token="${GITHUB_TOKEN:-}"
if [[ -z "$token" ]] && command -v gh >/dev/null 2>&1; then
    token="$(gh auth token 2>/dev/null || true)"
fi

# gh_get <path> [auth]: prints the JSON body, or nothing on any HTTP error.
gh_get() {
    local args=(-sf -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")
    if [[ "${2:-}" == auth ]]; then
        [[ -n "$token" ]] || return 0
        args+=(-H "Authorization: Bearer $token")
    elif [[ -n "$token" ]]; then
        # Public reads also use the token when present, for the higher rate limit;
        # a stale token would 401, so fall back to anonymous.
        curl "${args[@]}" -H "Authorization: Bearer $token" "$API$1" 2>/dev/null && return 0
    fi
    curl "${args[@]}" "$API$1" 2>/dev/null || true
}

# or_na <json> <jq filter>: the filter's result, or "n/a" when the JSON is empty.
or_na() {
    if [[ -z "$1" ]]; then echo "n/a"; else jq -r "$2" <<<"$1"; fi
}

# days_ago <n>: midnight UTC n days ago, as an RFC 3339 time (BSD or GNU date).
days_ago() {
    date -u -v-"$1"d +%FT00:00:00Z 2>/dev/null || date -u -d "-$1 days" +%FT00:00:00Z
}

# go_visits: requests for $GO_PATHS over the last 7 days, or "n/a". Summed one
# day at a time, the longest window every plan's adaptive analytics allows.
go_visits() {
    local cf="${CLOUDFLARE_API_TOKEN:-}" zone="${CLOUDFLARE_ZONE_ID:-}" total=0 d day next body n
    [[ -n "$cf" ]] || { echo "n/a"; return; }
    if [[ -z "$zone" ]]; then
        zone="$(curl -sf -H "Authorization: Bearer $cf" "$CF_API/zones?name=univocalapp.com" 2>/dev/null \
            | jq -r '.result[0].id // empty' 2>/dev/null || true)"
        [[ -n "$zone" ]] || { echo "n/a"; return; }
    fi
    for d in 7 6 5 4 3 2 1; do
        day="$(days_ago "$d")"
        next="$(days_ago "$((d - 1))")"
        body="$(jq -nc --arg z "$zone" --arg a "$day" --arg b "$next" --argjson p "$GO_PATHS" '{
            query: "query($z: String!, $a: Time!, $b: Time!, $p: [String!]) { viewer { zones(filter: {zoneTag: $z}) { httpRequestsAdaptiveGroups(limit: 10, filter: {datetime_geq: $a, datetime_lt: $b, clientRequestPath_in: $p, requestSource: \"eyeball\"}) { count } } } }",
            variables: {z: $z, a: $a, b: $b, p: $p}}')"
        n="$(curl -sf -H "Authorization: Bearer $cf" -H "Content-Type: application/json" \
            -d "$body" "$CF_API/graphql" 2>/dev/null \
            | jq -r 'if (.errors // []) == [] and .data.viewer.zones[0] then [.data.viewer.zones[0].httpRequestsAdaptiveGroups[].count] | add // 0 else empty end' 2>/dev/null || true)"
        [[ -n "$n" ]] || { echo "n/a"; return; }
        total=$((total + n))
    done
    echo "$total"
}

releases="$(gh_get "/repos/$APP_REPO/releases?per_page=100")"
app="$(gh_get "/repos/$APP_REPO")"
tap="$(gh_get "/repos/$TAP_REPO")"
clones="$(gh_get "/repos/$TAP_REPO/traffic/clones" auth)"
views="$(gh_get "/repos/$TAP_REPO/traffic/views" auth)"

dmg='[.[] | select(.draft | not) | .assets[] | select(.name | endswith(".dmg")) | .download_count] | add // 0'
latest='(map(select(.draft or .prerelease | not))[0] // {}) as $r | "\($r.tag_name // "none") \([$r.assets[]? | select(.name | endswith(".dmg")) | .download_count] | add // 0)"'

printf '%s PreviewMD · DMG downloads %s (latest %s) · stars %s · tap stars %s · tap 14d clones %s (%s unique), views %s (%s unique) · Univocal /go/previewmd 7d %s\n' \
    "$(date +%F)" \
    "$(or_na "$releases" "$dmg")" \
    "$(or_na "$releases" "$latest")" \
    "$(or_na "$app" '.stargazers_count')" \
    "$(or_na "$tap" '.stargazers_count')" \
    "$(or_na "$clones" '.count')" "$(or_na "$clones" '.uniques')" \
    "$(or_na "$views" '.count')" "$(or_na "$views" '.uniques')" \
    "$(go_visits)"
