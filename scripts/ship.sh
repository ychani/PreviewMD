#!/bin/bash
# Ships a PreviewMD release through the release signer.
#
# Nothing here signs anything with a release key. Developer ID signing and
# notarization happen in the separate `releaser` macOS account
# (~/workspace/narnar-release), and only after Yun taps Approve on the phone.
# This account, and every agent running in it, holds no release key and must
# never try to obtain one.
#
#   scripts/ship.sh --dry-run       full rehearsal: real signing and
#                                   notarization, nothing kept, nothing uploaded
#   scripts/ship.sh                 sign for real; the result waits in the outbox
#   scripts/ship.sh --publish       sign, then create the draft GitHub release
#   scripts/ship.sh --publish-only  draft the release for an already signed VERSION
#
# Builds from a clean develop (or a release tag on origin/develop), at the
# version in packaging/Info.plist. `swift test` runs first (SKIP_TESTS=1 for an
# emergency only). Also available as `make ship`.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

APP_NAME=PreviewMD
APP_ID=previewmd
APP="$ROOT/dist/$APP_NAME.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' packaging/Info.plist)"
SIGNER=/usr/local/libexec/narnar-release/release.sh
SHARED=/Users/Shared/narnar-release
TAP_WAIT_MINUTES=30   # the signer keeps the request open 12 hours; we stop watching sooner
SIGN_WAIT_MINUTES=90  # after the tap: signing and notarization; Apple is sometimes slow

DRY=0; PUBLISH=0; PUBLISH_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY=1 ;;
        --publish) PUBLISH=1 ;;
        --publish-only) PUBLISH=1; PUBLISH_ONLY=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done
[ "$DRY" = 1 ] && [ "$PUBLISH" = 1 ] && { echo "--dry-run and --publish exclude each other" >&2; exit 2; }

say() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[ -x "$SIGNER" ] || die "the release signer is not installed ($SIGNER). Ask Yun; see narnar-release/docs/SETUP.md."
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version '$VERSION' is not x.y.z"
OB="$SHARED/outbox/$APP_ID/$VERSION"
DMG_NAME="$APP_NAME-$VERSION.dmg"

# The outbox is written only by releaser. Check what we are about to publish
# against its own checksums and against Gatekeeper, never trust it blindly.
verify_outbox() {
    say "Checking the signed output in $OB"
    [ -f "$OB/release.json" ] || die "$OB/release.json missing: was $VERSION signed?"
    (cd "$OB" && shasum -a 256 -c SHA256SUMS) || die "checksums in $OB do not match"
    /usr/bin/python3 -I - "$OB/release.json" "$VERSION" <<'PY' || die "release.json does not describe $VERSION"
import json, sys
r = json.load(open(sys.argv[1]))
assert r["version"] == sys.argv[2] and not r.get("dry_run"), r
print("  built from commit", r["commit"])
PY
    spctl -a -t open --context context:primary-signature -vv "$OB/$DMG_NAME" 2>&1 \
        | tee /dev/stderr | grep -q "source=Notarized Developer ID" \
        || die "Gatekeeper does not accept the signed DMG"
    # The launch verdict on the app inside: what a first download goes through.
    local mnt pkg verdict
    mnt="$(hdiutil attach -nobrowse -readonly "$OB/$DMG_NAME" | awk -F'\t' '/\/Volumes\//{print $NF}')"
    pkg="$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$mnt/$APP_NAME.app/Contents/Info.plist" 2>/dev/null || true)"
    verdict="$(spctl -a -vvv -t exec "$mnt/$APP_NAME.app" 2>&1 || true)"
    hdiutil detach -quiet "$mnt"
    if [ "$pkg" != APPL ] || ! grep -q accepted <<<"$verdict" || ! grep -q "Notarized Developer ID" <<<"$verdict"; then
        echo "$verdict" >&2
        die "Gatekeeper would refuse to open the app in the DMG (CFBundlePackageType: ${pkg:-missing})"
    fi
    echo "  app in the DMG: accepted for launch"
}

publish() {
    verify_outbox
    say "Creating the draft GitHub release v$VERSION"
    make release-notes >/dev/null
    gh release create "v$VERSION" "$OB/$DMG_NAME" --draft \
        --title "$APP_NAME $VERSION" --notes-file dist/RELEASE_NOTES.md
    echo
    echo "Drafted v$VERSION. Still to do: review and publish the draft on GitHub, then"
    echo "update the Homebrew cask (packaging/homebrew/previewmd.rb and ychani/homebrew-tap):"
    echo "  version \"$VERSION\""
    echo "  sha256 \"$(shasum -a 256 "$OB/$DMG_NAME" | awk '{print $1}')\""
}

if [ "$PUBLISH_ONLY" = 1 ]; then publish; exit 0; fi

# ── 1. Source: clean develop or a release tag, on origin/develop ─────────
[ -z "$(git status --porcelain)" ] || die "uncommitted changes: ship from a clean checkout"
branch="$(git symbolic-ref --quiet --short HEAD || true)"
if [ "$branch" != develop ]; then
    [ -z "$branch" ] || die "side branch '$branch': use develop or check out a release tag on origin/develop"
    git tag --points-at HEAD | grep -qE '^v?[0-9]+\.[0-9]+\.[0-9]+$' \
        || die "detached commit is not a release tag: use develop or a release tag on origin/develop"
fi
git fetch --quiet origin '+refs/heads/develop:refs/remotes/origin/develop' --tags || die "could not fetch origin/develop"
COMMIT="$(git rev-parse HEAD)"
git merge-base --is-ancestor "$COMMIT" origin/develop \
    || die "$COMMIT is not on origin/develop: merge it first, then ship from develop"
if [ "$DRY" = 0 ] && [ -e "$OB" ]; then
    die "$OB already exists: $VERSION was signed before. Bump the version, or --publish-only."
fi

# ── 2. Tests ─────────────────────────────────────────────────────────────
if [ "${SKIP_TESTS:-}" = "1" ]; then
    echo "!!! SKIP_TESTS=1: shipping WITHOUT running the tests !!!" >&2
else
    swift test || die "tests failed: refusing to ship (SKIP_TESTS=1 to override)"
fi

# ── 3. Build, ad-hoc signed ──────────────────────────────────────────────
# The signer strips and re-signs the Quick Look extension and the app with
# Developer ID, inner to outer.
say "Building $APP_NAME $VERSION from $COMMIT"
BUILD_START=$(date +%s)
make app SIGN_IDENTITY=- DEVELOPER_ID= >/dev/null
[ -d "$APP" ] || die "$APP not produced"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }
[ "$(plist CFBundleShortVersionString)" = "$VERSION" ] || die "$APP is not version $VERSION"
[ "$(plist CFBundleIdentifier)" = com.narnarlabs.previewmd ] || die "unexpected bundle id $(plist CFBundleIdentifier)"
[ "$(stat -f %m "$APP/Contents/MacOS/$APP_NAME")" -ge "$BUILD_START" ] || die "$APP was not rebuilt by this run"
[ -d "$APP/Contents/PlugIns/$APP_NAME-QL.appex" ] || die "the Quick Look extension is missing"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/$APP_NAME" | tr ' ' '\n' | sort | tr '\n' ' ' | xargs)"
[ "$ARCHS" = "arm64 x86_64" ] || die "binary is not universal: $ARCHS"

# ── 4. Hand it to the signer ─────────────────────────────────────────────
say "Sending the app to the release signer"
ARGS=(stage --app "$APP_ID" --version "$VERSION" --commit "$COMMIT")
[ "$DRY" = 1 ] && ARGS+=(--dry-run)
OUT="$(/usr/bin/ditto -c -k --keepParent "$APP" - | sudo -n -u releaser "$SIGNER" "${ARGS[@]}")" \
    || die "the signer refused the build (output above)"
echo "$OUT"
JOB="$(printf '%s\n' "$OUT" | sed -n 's/^Job \([A-Za-z0-9._-]*\) is waiting.*/\1/p')"
[ -n "$JOB" ] || die "could not read the job id from the signer's output"

# ── 5. Wait for Yun's tap and the signing ────────────────────────────────
say "Waiting for Yun to approve on the phone, then for signing and notarization"
STATUS="$SHARED/jobs/$JOB.status"
deadline=$(( $(date +%s) + TAP_WAIT_MINUTES * 60 )); last=""; tapped=0
while :; do
    # Status line: "<time> <state> [detail]"
    state="$(awk '{print $2}' "$STATUS" 2>/dev/null || true)"
    [ "$state" != "$last" ] && { echo "  $(date +%H:%M:%S) $state"; last="$state"; }
    case "$state" in
        done) break ;;
        failed|rejected|expired|cancelled)
            echo "--- last lines of $SHARED/logs/$JOB.log:" >&2
            grep '^\[' "$SHARED/logs/$JOB.log" | tail -8 >&2
            [ "$state" = expired ] && echo "To ask Yun again for this same build (within 7 days): sudo -n -u releaser $SIGNER retry --job $JOB" >&2
            die "signing ended: $state. Nothing was signed for release." ;;
    esac
    case "$state" in
        checked|waiting_approval) ;;
        *) [ "$tapped" = 1 ] || { tapped=1; deadline=$(( $(date +%s) + SIGN_WAIT_MINUTES * 60 )); } ;;
    esac
    if [ "$(date +%s)" -ge "$deadline" ]; then
        if [ "$tapped" = 0 ]; then
            # Not an error: the request stays open on Yun's phone for 12 hours,
            # and the signer finishes on its own after the tap.
            echo
            echo "Yun hasn't tapped yet. The request stays open until the time on the phone"
            echo "notification (12 hours from staging); the signer finishes by itself after the tap."
            echo "  Progress: $STATUS"
            if [ "$DRY" = 1 ]; then
                echo "  Dry run: when it says done, the report is in $SHARED/outbox/$APP_ID/$VERSION-dry-run/"
            else
                echo "  When it says done: scripts/ship.sh --publish-only (after the release card) drafts the GitHub release."
            fi
            echo "  To withdraw it: sudo -n -u releaser $SIGNER cancel --job $JOB"
            echo "  If it expires: sudo -n -u releaser $SIGNER retry --job $JOB asks Yun again."
            exit 3
        fi
        die "still '$state' $SIGN_WAIT_MINUTES min after the tap; check $SHARED/logs/$JOB.log"
    fi
    sleep 10
done

if [ "$DRY" = 1 ]; then
    say "Dry run OK"
    cat "$SHARED/outbox/$APP_ID/$VERSION-dry-run/release.json"
    exit 0
fi

if [ "$PUBLISH" = 1 ]; then
    publish
else
    verify_outbox
    say "Signed and waiting in the outbox"
    echo "  $OB"
    echo "Draft the GitHub release with: scripts/ship.sh --publish-only"
fi
