#!/bin/bash
# The update path, 0.4.0 → this build, on the oldest macOS we can test, in
# throwaway Tart VMs.
#
#   tools/test-old-macos-update.sh [ventura|sonoma|sequoia|all] [dmg|brew]
#                                  [--new-dmg PATH] [--old-dmg PATH] [--pull] [--keep] [--gui]
#
#   os:   ventura (13, the minimum), sonoma (14), sequoia (15), or all (the
#         default): every one whose base image is on this Mac, the rest skipped.
#         An OS named outright must have its image, or --pull fetches it (~25 GB).
#   flow: dmg (drag-install 0.4.0, then replace it with the new DMG) or brew
#         (`brew install --cask` 0.4.0 from packaging/homebrew/previewmd.rb in
#         a local tap, then `brew upgrade --cask` to the new DMG). Both by default,
#         each in its own fresh VM.
#   --new-dmg: the release candidate's DMG (dist/PreviewMD-X.Y.Z.dmg after
#         `make notarize`). Without it the script builds this checkout (arm64,
#         ad-hoc signed) into a DMG of its own; if packaging/Info.plist still
#         says 0.4.0, that build is stamped 0.4.1 so there is an update to take.
#   --old-dmg: the 0.4.0 DMG. Default dist/PreviewMD-0.4.0.dmg, else downloaded
#         from the GitHub release; either way it must match the cask's sha256.
#   --keep keeps each VM afterwards; --gui shows its screen.
#
# Each flow, in a Mac that has never seen PreviewMD: 0.4.0 installs, opens a
# window and stays up, its Quick Look extension is registered and turned on,
# and Space-style previews of a sample .md are drawn by it. Then the update,
# and the same checks against the new version: the bundle on disk, the About
# panel (read back from its screenshot), a launch that stays up with no crash
# report, exactly one Quick Look registration and it is the new one, still
# turned on without anyone touching it, and a preview drawn by the new
# extension process. Anything wrong fails the run (exit 1).
#
# Not covered: the Gatekeeper "downloaded from the Internet" prompt (it needs
# a click; ShotJar-style checks of it belong to the first-run test) — so the
# copies here carry no quarantine flag, and Homebrew's is cleared after each
# install. And updating while the old version is still running: each flow
# quits it first, as the DMG's Finder replace asks you to.
#
# Screens land in build/old-macos/out/<os>/<flow>/ (old-*.png before the
# update, new-*.png after), with the text read off each and the guest's
# pluginkit and brew output beside them.
#
# Needs Tart (brew install openai/tools/tart; in ~/dotfiles/Brewfile) and the
# Cirrus Labs base image (it carries the guest agent `tart exec` needs; ~25 GB
# on first pull, shared with the other projects' VM tests). Tart runs at most
# two macOS VMs at once, so the script waits for a free slot.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

OLD_VERSION=0.4.0
OLD_SHA=98681440cbf57bb042e8fdfecf2cc48c80845d9dbaadbacdc15a2aa827677d7f
OLD_URL="https://github.com/ychani/PreviewMD/releases/download/v$OLD_VERSION/PreviewMD-$OLD_VERSION.dmg"
QL_ID=com.narnarlabs.previewmd.quicklook

ALL_OSES=(ventura sonoma sequoia)
OSES=() FLOWS=() NAMED=0 PULL=0 KEEP=0 GUI=0 NEW_DMG="" OLD_DMG=""
usage() { echo "usage: $0 [ventura|sonoma|sequoia|all] [dmg|brew] [--new-dmg PATH] [--old-dmg PATH] [--pull] [--keep] [--gui]" >&2; exit 2; }
while (( $# )); do
    case "$1" in
        ventura|sonoma|sequoia) OSES+=("$1"); NAMED=1 ;;
        all) OSES+=("${ALL_OSES[@]}") ;;
        dmg|brew) FLOWS+=("$1") ;;
        --new-dmg) shift; NEW_DMG="${1:-}"; [[ -n "$NEW_DMG" ]] || usage ;;
        --old-dmg) shift; OLD_DMG="${1:-}"; [[ -n "$OLD_DMG" ]] || usage ;;
        --pull) PULL=1 ;;
        --keep) KEEP=1 ;;
        --gui) GUI=1 ;;
        *) usage ;;
    esac
    shift
done
(( ${#OSES[@]} )) || OSES=("${ALL_OSES[@]}")
(( ${#FLOWS[@]} )) || FLOWS=(dmg brew)
[[ -z "$NEW_DMG" || -f "$NEW_DMG" ]] || { echo "no DMG at $NEW_DMG" >&2; exit 2; }
[[ -z "$OLD_DMG" || -f "$OLD_DMG" ]] || { echo "no DMG at $OLD_DMG" >&2; exit 2; }
command -v tart >/dev/null || { echo "needs Tart: brew install openai/tools/tart (and add it to ~/dotfiles/Brewfile)" >&2; exit 2; }

WORK="$ROOT/build/old-macos"
SHARE="$WORK/share-update"   # only what the guest needs; results come back here
TOOLS="$WORK/tools"

FAILED=() SKIPPED=() RAN=()
BLOCKED=0
TAG=host
step() {   # step "<name>" <command...>
    local name="$1"; shift
    printf '%-58s ' "$name"
    if (( BLOCKED )); then echo "BLOCKED (an earlier step it needs failed)"; FAILED+=("$TAG: $name"); return; fi
    local out
    if out=$("$@" 2>&1); then
        echo "ok"
        echo "$out" | grep '^NOTE:' | sed 's/^NOTE:/    note:/' || true
    else
        echo "FAIL"
        echo "$out" | tail -20 | sed 's/^/    /'
        FAILED+=("$TAG: $name")
    fi
}
failed() { [[ " ${FAILED[*]-} " == *" $TAG: $1 "* ]]; }
# A step the rest of the flow cannot do without.
must() { step "$@"; failed "$1" && BLOCKED=1; }

image_for() { echo "ghcr.io/cirruslabs/macos-$1-base:latest"; }
major_for() { case "$1" in ventura) echo 13 ;; sonoma) echo 14 ;; sequoia) echo 15 ;; esac; }

VM="" RUN_PID=""
# Every guest step gets 3 minutes: a dialog nobody can click must fail the
# step, not hang the run.
guest() {
    perl -e 'alarm 180; exec @ARGV' tart exec "$VM" /bin/bash -c "
        export PATH=/opt/homebrew/bin:/usr/local/bin:\$PATH HOMEBREW_NO_AUTO_UPDATE=1 \
            HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_INSTALL_CLEANUP=1
        S='/Volumes/My Shared Files/pmd'; OUT=\"\$S/out/$OS/$FLOW\"; L=\"\$HOME/pmd\"
        APP=/Applications/PreviewMD.app; PROC=PreviewMD.app/Contents/MacOS/PreviewMD
        QLPROC=PreviewMD-QL.appex/Contents/MacOS/PreviewMD-QL; QL_ID=$QL_ID
        shot() { perl -e 'alarm 20; exec @ARGV' screencapture -x \"\$OUT/\$1.png\" && [ -s \"\$OUT/\$1.png\" ]; }
        $1"
}

stop_vm() {
    [ -n "$VM" ] || return 0
    tart stop "$VM" >/dev/null 2>&1
    [ -n "$RUN_PID" ] && wait "$RUN_PID" 2>/dev/null
    if (( KEEP )); then
        echo "    kept: tart run $VM   (delete with: tart delete $VM)"
    else
        tart delete "$VM" >/dev/null 2>&1
    fi
    VM="" RUN_PID=""
}
trap stop_vm EXIT
trap 'exit 130' INT TERM

# Reads the text in a screenshot on the host (Vision), one line each, into
# <png>.txt; then each pattern must match (grep -E -i) and each !pattern must not.
read_png() {   # read_png <png> <pattern|!pattern>...
    local png="$1" txt; shift
    [ -s "$png" ] || { echo "no screenshot at $png"; return 1; }
    "$TOOLS/ocr" "$png" > "${png%.png}.txt" || { echo "could not read $png"; return 1; }
    txt=$(tr '\n' ' ' < "${png%.png}.txt")
    local p rc=0
    for p in "$@"; do
        if [[ $p == !* ]]; then
            grep -qiE -- "${p#!}" <<<"$txt" && { echo "the screen shows \"${p#!}\""; rc=1; }
        else
            grep -qiE -- "$p" <<<"$txt" || { echo "the screen does not show \"$p\""; rc=1; }
        fi
    done
    (( rc == 0 )) || { echo "it reads:"; sed 's/^/    | /' "${png%.png}.txt" | head -40; }
    return $rc
}

# --- the checks one version gets, before (old) or after (new) the update -----
# $1 = old|new, $2 = the version it must be, $3 = its build number.
check_version() {
    local p="$1" v="$2" b="$3"
    step "$p: the bundle on disk is $v ($b)" guest '
        have=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
        build=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Contents/Info.plist")
        ql=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/PlugIns/PreviewMD-QL.appex/Contents/Info.plist")
        [ "$have ($build)" = "'"$v ($b)"'" ] || { echo "app is $have ($build)"; exit 1; }
        [ "$ql" = "'"$v"'" ] || { echo "its Quick Look extension is $ql"; exit 1; }
        codesign --verify --deep --strict "$APP" || exit 1
        echo "NOTE: signed by $(codesign -dv "$APP" 2>&1 | sed -n "s/^Authority=//p" | head -1 | grep . || echo "ad-hoc (no Developer ID)")"'

    # A person opening it: a window must come up, and it must still be
    # running 20 s later with no crash report.
    step "$p: launches, opens a window, stays up 20 s" guest '
        open "$APP" || exit 1
        sleep 20
        crashes=$(ls "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | grep -i previewmd)
        [ -z "$crashes" ] || { echo "crash report: $crashes"; exit 1; }
        pgrep -f "$PROC" >/dev/null || { echo "the app quit within 20 seconds"; exit 1; }
        "$S/winlist" PreviewMD > "$OUT/'"$p"'-windows.txt"
        grep -qE "layer=0 .* w=[0-9]{3,}" "$OUT/'"$p"'-windows.txt" \
            || { echo "no PreviewMD window on screen:"; cat "$OUT/'"$p"'-windows.txt"; exit 1; }
        shot '"$p"'-window'

    # PreviewMD › About PreviewMD, pressed through Accessibility (see
    # tools/old-macos/menuclick.swift).
    step "$p: About says Version $v ($b)" guest '
        "$S/menuclick" PreviewMD PreviewMD "About PreviewMD" || exit 1
        sleep 2; shot '"$p"'-about'
    failed "$p: About says Version $v ($b)" || step "$p: About screenshot reads Version $v ($b)" \
        read_png "$SHARE/out/$OS/$FLOW/$p-about.png" "PreviewMD" "Version ${v//./\\.} \\($b\\)"

    # Quick Look below runs with the app quit, as in Finder most of the time
    # (and with no About panel over the preview).
    step "$p: quit" guest '
        pkill -x PreviewMD; for _ in $(seq 10); do pgrep -f "$PROC" >/dev/null || exit 0; sleep 1; done
        echo "the app would not quit"; exit 1'

    # The registration Quick Look actually uses: one entry, at /Applications,
    # this version. Before the update a person turns it on (what System
    # Settings › Extensions does); after it, nobody touches it again.
    if [[ $p == old ]]; then
        step "old: the Quick Look extension is turned on" guest '
            for _ in $(seq 30); do pluginkit -m -i "$QL_ID" | grep -q . && break; sleep 1; done
            pluginkit -e use -i "$QL_ID" || exit 1; sleep 2'
    fi
    step "$p: one Quick Look registration, $v, at /Applications, on" guest '
        for _ in $(seq 30); do
            r=$(pluginkit -m -A -D -v -i "$QL_ID")
            n=$(printf "%s\n" "$r" | grep -c "$QL_ID")
            [ "$n" = 1 ] && echo "$r" | grep -qF "($( /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/PlugIns/PreviewMD-QL.appex/Contents/Info.plist"))" && break
            sleep 1
        done
        printf "%s\n" "$r" > "$OUT/'"$p"'-pluginkit.txt"
        echo "NOTE: $r"
        [ "$n" = 1 ] || { echo "$n registrations of $QL_ID (want exactly 1)"; exit 1; }
        echo "$r" | grep -qF "('"$v"')" || { echo "registered version is not '"$v"'"; exit 1; }
        echo "$r" | grep -qF "$APP/Contents/PlugIns/PreviewMD-QL.appex" || { echo "registered at the wrong path"; exit 1; }
        echo "$r" | grep -qE "^ *\+" || { echo "the extension is not turned on (no +)"; exit 1; }'

    # Quick Look on a sample note, the way Space does it (qlmanage -p): our
    # extension must be the process drawing it, from /Applications, and what
    # it draws must be rendered Markdown, not the source text.
    step "$p: Quick Look preview drawn by the extension" guest '
        pkill -f "$QLPROC"; qlmanage -r >/dev/null 2>&1; qlmanage -r cache >/dev/null 2>&1; sleep 1
        qlmanage -p "$L/Update check.md" >/dev/null 2>&1 &
        for _ in $(seq 20); do pgrep -f "$QLPROC" >/dev/null && break; sleep 1; done
        sleep 4; shot '"$p"'-quicklook
        ext=$(ps -axo command | grep -F "$QLPROC" | grep -v grep | head -1)
        pkill -f "qlmanage -p"; pkill -f "$QLPROC"
        [ -n "$ext" ] || { echo "no PreviewMD-QL process: Quick Look did not use our extension"; exit 1; }
        case "$ext" in "$APP"/*) ;; *) echo "the extension ran from elsewhere: $ext"; exit 1 ;; esac
        echo "NOTE: drawn by $ext"'
    failed "$p: Quick Look preview drawn by the extension" || step "$p: the preview shows rendered Markdown" \
        read_png "$SHARE/out/$OS/$FLOW/$p-quicklook.png" "Update check" "Rendered by PreviewMD" "!\\*\\*" "!# Update check"

    # The Finder thumbnail, for the record. PreviewMD ships only a preview
    # extension (com.apple.quicklook.preview), so macOS draws this one as plain
    # text; the rendering check is the preview step above.
    step "$p: Quick Look thumbnail" guest '
        rm -rf "$L/thumbs" && mkdir -p "$L/thumbs"
        qlmanage -t -s 512 -o "$L/thumbs" "$L/Update check.md" >/dev/null 2>&1
        f=$(ls "$L/thumbs"/*.png 2>/dev/null | head -1)
        [ -s "$f" ] || { echo "no thumbnail written"; exit 1; }
        cp "$f" "$OUT/'"$p"'-thumbnail.png"'

}

# --- the flows ----------------------------------------------------------------
boot() {
    VM="previewmd-upd-$OS-$FLOW"
    # Tart runs two macOS VMs at most; another project's may hold both.
    must "free VM slot" bash -c '
        for _ in $(seq 240); do
            [ "$(tart list --format json | grep -c "\"State\" *: *\"running\"")" -lt 2 ] && exit 0
            sleep 15
        done; echo "two VMs still running after an hour"; exit 1'
    must "fresh VM cloned" bash -c 'tart delete "$2" >/dev/null 2>&1; tart clone "$1" "$2"' _ "$(image_for "$OS")" "$VM"
    if (( ! BLOCKED )); then
        local graphics=(--no-graphics); (( GUI )) && graphics=()
        nohup tart run ${graphics[@]+"${graphics[@]}"} --dir="pmd:$SHARE" "$VM" >"$WORK/tart-$OS-$FLOW.log" 2>&1 &
        RUN_PID=$!
    fi
    must "guest boots" bash -c '
        for _ in $(seq 90); do
            kill -0 "$2" 2>/dev/null || { echo "tart run exited:"; cat "$3"; exit 1; }
            tart exec "$1" true >/dev/null 2>&1 && exit 0
            sleep 2
        done
        echo "no answer from the guest agent after 3 minutes"; exit 1' _ "$VM" "${RUN_PID:-0}" "$WORK/tart-$OS-$FLOW.log"
    must "guest is macOS $(major_for "$OS")" guest '
        v=$(sw_vers -productVersion); echo "NOTE: guest runs macOS $v ($(uname -m))"
        [ "${v%%.*}" = '"$(major_for "$OS")"' ]'
    # Local copies: a share path has spaces, and the guest should not read
    # the DMGs over the share while installing.
    must "files copied into the guest" guest '
        rm -rf "$L" && mkdir -p "$L" "$OUT" && cp -R "$S/files/." "$L/"'
    # As in tools/test-old-macos.sh: the base image opens System Settings at
    # login, so close it; and macOS 15 asks again, over every screenshot,
    # whether the guest agent may keep capturing the screen, so pre-approve it
    # as a click on Allow would (replayd rereads its approvals when restarted).
    must "screen clear for screenshots" guest '
        pkill -x "System Settings"; sleep 1
        [ "$(sw_vers -productVersion | cut -d. -f1)" -ge 15 ] || exit 0
        agent=$(ps -axo comm= | grep -m1 "/tart-guest-agent$")
        [ -n "$agent" ] || { echo "tart-guest-agent not found running"; exit 1; }
        agent=$(realpath "$agent") || exit 1   # keyed by the Cellar binary, not the symlink
        far="3024-01-01T00:00:00Z"
        defaults write "$HOME/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals" \
            "$agent" -dict kScreenCaptureApprovalLastAlerted -date "$far" \
            kScreenCaptureApprovalLastUsed -date "$far" kScreenCapturePrivacyHintDate -date "$far" || exit 1
        killall replayd 2>/dev/null; true'
}

dmg_install() {   # dmg_install <dmg in the guest's files>: what Finder does on a drag
    must "$1: copied out of its DMG into /Applications" guest '
        M=$(hdiutil attach -nobrowse -readonly "$L/'"$2"'" | awk -F"\t" "/\/Volumes\//{print \$NF}")
        [ -d "$M/PreviewMD.app" ] || { echo "no PreviewMD.app in the DMG (mounted at $M)"; exit 1; }
        [ -L "$M/Applications" ] || echo "NOTE: the DMG has no Applications link"
        rm -rf "$APP" && ditto "$M/PreviewMD.app" "$APP"; rc=$?
        hdiutil detach -quiet "$M"; exit $rc'
}

flow_dmg() {
    dmg_install old old.dmg
    check_version old "$OLD_VERSION" "$OLD_BUILD"
    # Finder's "Replace": the old bundle goes, the new one is copied in.
    dmg_install new new.dmg
    check_version new "$NEW_VERSION" "$NEW_BUILD"
}

flow_brew() {
    must "brew is in the guest" guest 'brew --version | head -1 | sed "s/^/NOTE: /"'
    # A tap of our own, holding the cask exactly as packaging/ has it, with
    # only version, sha256 and url pointed at the local DMG.
    must "old: brew install --cask (local tap, $OLD_VERSION)" guest '
        brew tap-new --no-git local/previewmd >/dev/null || exit 1
        T="$(brew --repository)/Library/Taps/local/homebrew-previewmd"
        mkdir -p "$T/Casks" && cp "$L/previewmd-old.rb" "$T/Casks/previewmd.rb" || exit 1
        brew install --cask local/previewmd/previewmd > "$OUT/brew-install.txt" 2>&1; rc=$?
        tail -5 "$OUT/brew-install.txt"; [ $rc = 0 ] || exit 1
        xattr -dr com.apple.quarantine "$APP" 2>/dev/null; true'
    step "old: brew lists previewmd $OLD_VERSION" guest '
        v=$(brew list --cask --versions previewmd); echo "NOTE: $v"; [ "$v" = "previewmd '"$OLD_VERSION"'" ]'
    check_version old "$OLD_VERSION" "$OLD_BUILD"
    # The release: the tap's cask moves to the new version.
    must "new: brew upgrade --cask previewmd" guest '
        T="$(brew --repository)/Library/Taps/local/homebrew-previewmd"
        cp "$L/previewmd-new.rb" "$T/Casks/previewmd.rb" || exit 1
        brew outdated --cask --greedy-auto-updates | grep -q "^previewmd" \
            || { echo "brew does not see previewmd as outdated"; brew outdated --cask -v; exit 1; }
        brew upgrade --cask previewmd > "$OUT/brew-upgrade.txt" 2>&1; rc=$?
        tail -5 "$OUT/brew-upgrade.txt"; [ $rc = 0 ] || exit 1
        xattr -dr com.apple.quarantine "$APP" 2>/dev/null; true'
    step "new: brew lists previewmd $NEW_VERSION" guest '
        v=$(brew list --cask --versions previewmd); echo "NOTE: $v"; [ "$v" = "previewmd '"$NEW_VERSION"'" ]'
    check_version new "$NEW_VERSION" "$NEW_BUILD"
}

collect() {
    guest '
        for f in "$HOME"/Library/Logs/DiagnosticReports/*; do
            case "$(basename "$f")" in *[Pp]review[Mm][Dd]*) cp "$f" "$OUT/" ;; esac
        done; true' >/dev/null 2>&1
}

# --- host ---------------------------------------------------------------------
echo "== host"
cask_for() {   # cask_for <version> <sha256> <dmg file in the guest>
    sed -E -e "s|^(  version ).*|\1\"$1\"|" -e "s|^(  sha256 ).*|\1\"$2\"|" \
        -e "s|^(  url ).*|\1\"file:///Users/admin/pmd/$3\"|" packaging/homebrew/previewmd.rb
}
plist_of() { /usr/libexec/PlistBuddy -c "Print $2" "$1/Contents/Info.plist"; }
# Prints a DMG's PreviewMD.app version and build: "<version> <build>".
dmg_version() {
    local m; m=$(mktemp -d)
    hdiutil attach -nobrowse -readonly -mountpoint "$m" "$1" >/dev/null || return 1
    echo "$(plist_of "$m/PreviewMD.app" CFBundleShortVersionString) $(plist_of "$m/PreviewMD.app" CFBundleVersion)"
    hdiutil detach -quiet "$m"
}

mkdir -p "$WORK" "$TOOLS"
step "old DMG is the published $OLD_VERSION" bash -c '
    d="$1"; [ -n "$d" ] || d=dist/PreviewMD-$2.dmg
    if [ ! -f "$d" ]; then
        d="$4/cache/PreviewMD-$2.dmg"; mkdir -p "$4/cache"
        [ -f "$d" ] || curl -fsSL -o "$d" "$5" || { echo "could not download $5"; exit 1; }
    fi
    sha=$(shasum -a 256 "$d" | cut -d" " -f1)
    [ "$sha" = "$3" ] || { echo "$d has sha256 $sha, the $2 cask says $3"; exit 1; }
    mkdir -p "$4/stage" && cp "$d" "$4/stage/old.dmg"' _ "$OLD_DMG" "$OLD_VERSION" "$OLD_SHA" "$WORK" "$OLD_URL"
failed "old DMG is the published $OLD_VERSION" && BLOCKED=1

if [[ -n "$NEW_DMG" ]]; then
    step "new DMG: $(basename "$NEW_DMG")" cp "$NEW_DMG" "$WORK/stage/new.dmg"
else
    # This checkout, as a DMG laid out like `make dmg`'s, signed ad-hoc (no
    # Developer ID or notarization in a test build).
    step "new DMG built from this checkout" bash -c '
        set -e
        rm -rf "$1/new" && make app ARCHS=arm64 DIST_DIR="$1/new" >"$1/new-build.log" 2>&1 \
            || { tail -20 "$1/new-build.log"; exit 1; }
        app="$1/new/PreviewMD.app"
        v=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")
        if [ "$v" = "$2" ]; then
            nv="${v%.*}.$(( ${v##*.} + 1 ))"
            for p in "$app/Contents/Info.plist" "$app/Contents/PlugIns/PreviewMD-QL.appex/Contents/Info.plist"; do
                /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $nv" "$p"
            done
            codesign --sign - --force --options runtime --entitlements packaging/QL-entitlements.plist \
                "$app/Contents/PlugIns/PreviewMD-QL.appex" 2>/dev/null
            codesign --sign - --force --options runtime "$app" 2>/dev/null
            codesign --verify --deep --strict "$app"
            echo "NOTE: Info.plist still says $v: this test build is stamped $nv"
        fi
        rm -rf "$1/dmg-staging" && mkdir -p "$1/dmg-staging"
        ditto "$app" "$1/dmg-staging/PreviewMD.app" && ln -s /Applications "$1/dmg-staging/Applications"
        hdiutil create -quiet -volname PreviewMD -srcfolder "$1/dmg-staging" -ov -format UDZO "$1/stage/new.dmg"
        rm -rf "$1/dmg-staging"' _ "$WORK" "$OLD_VERSION"
fi
failed "new DMG built from this checkout" && BLOCKED=1
failed "new DMG: $(basename "$NEW_DMG")" && BLOCKED=1

OLD_BUILD="" NEW_VERSION="" NEW_BUILD=""
if (( ! BLOCKED )); then
    read -r _ OLD_BUILD < <(dmg_version "$WORK/stage/old.dmg")
    read -r NEW_VERSION NEW_BUILD < <(dmg_version "$WORK/stage/new.dmg")
    step "new DMG is newer: $OLD_VERSION ($OLD_BUILD) → $NEW_VERSION ($NEW_BUILD)" bash -c '
        [ -n "$3" ] && [ "$1" != "$3" ] || { echo "the new DMG is $3 ($4)"; exit 1; }
        [ "$4" -gt "$2" ] 2>/dev/null || { echo "build $4 is not above $2: Quick Look would keep the old extension"; exit 1; }' \
        _ "$OLD_VERSION" "$OLD_BUILD" "$NEW_VERSION" "$NEW_BUILD"
    failed "new DMG is newer: $OLD_VERSION ($OLD_BUILD) → $NEW_VERSION ($NEW_BUILD)" && BLOCKED=1
fi

if (( ! BLOCKED )); then
    cask_for "$OLD_VERSION" "$OLD_SHA" old.dmg > "$WORK/stage/previewmd-old.rb"
    cask_for "$NEW_VERSION" "$(shasum -a 256 "$WORK/stage/new.dmg" | cut -d' ' -f1)" new.dmg > "$WORK/stage/previewmd-new.rb"
fi
step "shared folder staged" bash -c '
    set -e
    rm -rf "$1" && mkdir -p "$1/files" "$1/out"
    cp "$2"/stage/{old.dmg,new.dmg,previewmd-old.rb,previewmd-new.rb} "$3/tools/old-macos/Update check.md" "$1/files/"
    # Window owners and sizes need no Screen Recording grant.
    swiftc -O -target arm64-apple-macos13.0 "$3/tools/old-macos/winlist.swift" -o "$1/winlist"
    swiftc -O -target arm64-apple-macos13.0 "$3/tools/old-macos/menuclick.swift" -o "$1/menuclick"
    swiftc -O "$3/tools/old-macos/ocr.swift" -o "$2/tools/ocr"' _ "$SHARE" "$WORK" "$ROOT"
failed "shared folder staged" && BLOCKED=1
HOST_BLOCKED=$BLOCKED

for OS in "${OSES[@]}"; do
    if ! tart list -q 2>/dev/null | grep -qxF "$(image_for "$OS")"; then
        if (( PULL )); then
            echo "pulling $(image_for "$OS") (~25 GB, once)…"
            tart pull "$(image_for "$OS")" || { FAILED+=("$OS: image pull"); continue; }
        elif (( NAMED )); then
            echo "no $(image_for "$OS") on this Mac: add --pull to fetch it (~25 GB)"
            FAILED+=("$OS: no image"); continue
        else
            echo "skipped macOS $(major_for "$OS"): no $(image_for "$OS") on this Mac (--pull fetches it, ~25 GB)"
            SKIPPED+=("$OS"); continue
        fi
    fi
    RAN+=("$OS")
    for FLOW in "${FLOWS[@]}"; do
        TAG="$OS/$FLOW"
        echo "== macOS $(major_for "$OS") ($OS), $FLOW: $OLD_VERSION → ${NEW_VERSION:-?}"
        BLOCKED=$HOST_BLOCKED
        rm -rf "$SHARE/out/$OS/$FLOW"; mkdir -p "$SHARE/out/$OS/$FLOW"
        boot
        "flow_$FLOW"
        collect
        stop_vm
        rm -rf "$WORK/out/$OS/$FLOW" && mkdir -p "$WORK/out/$OS" \
            && cp -R "$SHARE/out/$OS/$FLOW" "$WORK/out/$OS/$FLOW"
        echo "    results: build/old-macos/out/$OS/$FLOW/"
    done
done

echo
(( ${#SKIPPED[@]} )) && echo "skipped (no image): ${SKIPPED[*]}"
if (( ${#FAILED[@]} )); then
    echo "FAILED (${#FAILED[@]}): ${FAILED[*]}"
    exit 1
fi
(( ${#RAN[@]} )) || { echo "nothing ran: no macOS image on this Mac"; exit 1; }
echo "all passed (${RAN[*]}: ${FLOWS[*]}, $OLD_VERSION → $NEW_VERSION)"
