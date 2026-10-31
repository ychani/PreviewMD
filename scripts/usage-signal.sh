#!/usr/bin/env bash
# Prints one line of PreviewMD usage numbers for the weekly scoreboard.
# PreviewMD has no telemetry, so these GitHub counters are the signal:
#   - release asset downloads (DMG only; .sha256 excluded), public
#   - stars on ychani/PreviewMD and ychani/homebrew-tap, public
#   - homebrew-tap clones/views, owner-only, rolling 14 days
# `brew install --cask ychani/tap/previewmd` clones the tap, so tap clones
# approximate Homebrew installs and updates (CI and mirrors also count).
#
# Owner-only numbers need a token with push access: $GITHUB_TOKEN, or
# `gh auth token`. Without one they print as "n/a" and the line still prints.
#
# Usage: scripts/usage-signal.sh
# Needs: curl, jq.
set -euo pipefail

APP_REPO="ychani/PreviewMD"
TAP_REPO="ychani/homebrew-tap"
API="https://api.github.com"

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

releases="$(gh_get "/repos/$APP_REPO/releases?per_page=100")"
app="$(gh_get "/repos/$APP_REPO")"
tap="$(gh_get "/repos/$TAP_REPO")"
clones="$(gh_get "/repos/$TAP_REPO/traffic/clones" auth)"
views="$(gh_get "/repos/$TAP_REPO/traffic/views" auth)"

dmg='[.[] | select(.draft | not) | .assets[] | select(.name | endswith(".dmg")) | .download_count] | add // 0'
latest='(map(select(.draft or .prerelease | not))[0] // {}) as $r | "\($r.tag_name // "none") \([$r.assets[]? | select(.name | endswith(".dmg")) | .download_count] | add // 0)"'

printf '%s PreviewMD · DMG downloads %s (latest %s) · stars %s · tap stars %s · tap 14d clones %s (%s unique), views %s (%s unique)\n' \
    "$(date +%F)" \
    "$(or_na "$releases" "$dmg")" \
    "$(or_na "$releases" "$latest")" \
    "$(or_na "$app" '.stargazers_count')" \
    "$(or_na "$tap" '.stargazers_count')" \
    "$(or_na "$clones" '.count')" "$(or_na "$clones" '.uniques')" \
    "$(or_na "$views" '.count')" "$(or_na "$views" '.uniques')"
