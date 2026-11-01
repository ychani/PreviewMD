#!/bin/bash
# PreviewMD's first run on older macOS, in throwaway Tart VMs.
#
#   tools/test-old-macos.sh [os...] [--pull] [--keep] [--gui]
#
#   os: ventura (13, the minimum), sonoma (14), sequoia (15), or all (the
#   default). An OS whose image is not on this Mac is skipped, unless named:
#   then it fails. --pull fetches a missing image (~25 GB each, once).
#   --keep keeps each VM afterwards; --gui shows its screen.
#   PREVIEWMD_APP=<path to PreviewMD.app> tests that bundle (a signed or
#   notarized release build) instead of building one.
#
# Needs Tart (brew install openai/tools/tart). The images are Cirrus Labs'
# ghcr.io/cirruslabs/macos-<os>-base (base, not vanilla: only base carries the
# guest agent `tart exec` needs). Each run boots a copy-on-write clone, in
# seconds, and deletes it. Nothing is granted on this Mac: the guest is
# driven with `tart exec`, and the guest agent may already read window titles
# and the screen there.
#
# Flows, in a Mac that has never seen PreviewMD, the app installed in
# /Applications the way the DMG puts it:
#   launch      the first launch: one window, titled PreviewMD, with the
#               "No file open" empty state
#   open-file   `open -a` on a .md (Finder's Open With): the window takes its
#               name and the preview shows it rendered, not as raw Markdown
#   open-folder `open -a` on a folder: the sidebar lists its files, the first
#               one is selected and rendered, and the workspace is remembered
#   quicklook   the first launch registered the Quick Look extension
#               (pluginkit), and Quick Look renders a .md through it: the
#               extension logs its render and the panel shows the HTML. (Not
#               `qlmanage -t`: PreviewMD has no thumbnail extension, so that
#               draws macOS's plain-text thumbnail and never calls ours.)
# Each saves a PNG of the screen at every checked state under
# build/old-macos/out/<os>/<flow>/; any wrong state fails the run.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

ALL_OSES=(ventura sonoma sequoia)
OSES=() NAMED=0 PULL=0 KEEP=0 GUI=0
usage() { echo "usage: $0 [ventura|sonoma|sequoia|all] [--pull] [--keep] [--gui]" >&2; exit 2; }
for a in "$@"; do
    case "$a" in
        ventura|sonoma|sequoia) OSES+=("$a"); NAMED=1 ;;
        all) OSES+=("${ALL_OSES[@]}") ;;
        --pull) PULL=1 ;;
        --keep) KEEP=1 ;;
        --gui) GUI=1 ;;
        *) usage ;;
    esac
done
(( ${#OSES[@]} )) || OSES=("${ALL_OSES[@]}")

command -v tart >/dev/null || { echo "needs Tart: brew install openai/tools/tart (and add it to ~/dotfiles/Brewfile)" >&2; exit 2; }

WORK="$ROOT/build/old-macos"
SHARE="$WORK/share"   # read-only in the guest: the app, the probe, the fixtures
OUT="$WORK/out"       # read-write in the guest: the screenshots and logs
APP_SRC="${PREVIEWMD_APP:-$WORK/dist/PreviewMD.app}"

FAILED=() SKIPPED=()
BLOCKED=0
step() {   # step "<name>" <command...>: ok or FAIL, with the output's tail
    local name="$1"; shift
    printf '%-52s ' "$name"
    if (( BLOCKED )); then echo "BLOCKED (an earlier step it needs failed)"; FAILED+=("$OS_LABEL$name"); return; fi
    local out
    if out=$("$@" 2>&1); then
        echo "ok"
        echo "$out" | grep '^NOTE:' | sed 's/^NOTE:/    note:/' || true
    else
        echo "FAIL"
        echo "$out" | tail -20 | sed 's/^/    /'
        FAILED+=("$OS_LABEL$name")
    fi
}
failed() { [[ " ${FAILED[*]-} " == *" $OS_LABEL$1 "* ]]; }

image_for() { echo "ghcr.io/cirruslabs/macos-$1-base:latest"; }
major_for() { case "$1" in ventura) echo 13 ;; sonoma) echo 14 ;; sequoia) echo 15 ;; esac; }
image_local() { tart list --source oci -q 2>/dev/null | grep -qx "$(image_for "$1")"; }

VM="" RUN_PID="" OS="" OS_LABEL=""
# Runs a bash script in the guest as its logged-in user, with helpers:
#   shot <flow> <name>      the whole screen to out/<os>/<flow>/<name>.png
#   wait_title <title>      until PreviewMD has a window of that title (20 s)
#   seen <png> <text>...    each text is in what OCR reads in the PNG
#   alive                   PreviewMD is running and left no crash report
GUEST_LIB='
S="/Volumes/My Shared Files/pmd"; O="/Volumes/My Shared Files/out"
APP=/Applications/PreviewMD.app; FX="$HOME/pmd-fixtures"; PROBE="$S/probe"
shot() { mkdir -p "$1" && screencapture -x "$1/$2.png" && echo "NOTE: saved $1/$2.png"; }
titles() { "$PROBE" windows PreviewMD 2>/dev/null | cut -f2; }
wait_title() {
    for _ in $(seq 40); do titles | grep -qxF "$1" && return 0; sleep 0.5; done
    echo "no PreviewMD window titled \"$1\"; its windows: [$(titles | paste -sd "|" -)]"; return 1
}
ocr() { "$PROBE" ocr "$1" 2>/dev/null; }
seen() {
    local png="$1" text bad=0; shift
    local read; read=$(ocr "$png")
    grep -q "is requesting" <<<"$read" && { echo "a system prompt covers the screen"; bad=1; }
    for text in "$@"; do
        grep -qF "$text" <<<"$read" || { echo "not on screen: \"$text\""; bad=1; }
    done
    (( bad )) && { echo "OCR of $(basename "$png") read:"; sed "s/^/  | /" <<<"$read" | head -40; }
    return $bad
}
crashes() { ls "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | grep -i previewmd; }
alive() {
    local c; c=$(crashes); [ -z "$c" ] || { echo "crash report: $c"; return 1; }
    pgrep -x PreviewMD >/dev/null || { echo "PreviewMD is not running"; return 1; }
}
'
guest() { tart exec "$VM" /bin/bash -c "$GUEST_LIB
OUT_OS=\"\$O/$OS\"; cd \"\$OUT_OS\" || exit 1
$1"; }

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

boot() {
    VM="previewmd-run-$OS"
    step "fresh VM cloned" bash -c 'tart delete "$2" >/dev/null 2>&1; tart clone "$1" "$2"' _ "$(image_for "$OS")" "$VM"
    failed "fresh VM cloned" && BLOCKED=1
    if (( ! BLOCKED )); then
        local graphics=(--no-graphics) waited=0; (( GUI )) && graphics=()
        # macOS runs at most two VMs at once, and other checkouts' tests use
        # the same Mac: wait for a free slot (up to 30 minutes) rather than fail.
        while :; do
            tart run ${graphics[@]+"${graphics[@]}"} --dir="pmd:$SHARE:ro" --dir="out:$OUT" "$VM" \
                >"$WORK/tart-$OS.log" 2>&1 &
            RUN_PID=$!
            sleep 3
            kill -0 "$RUN_PID" 2>/dev/null || ! grep -q "exceeds the system limit" "$WORK/tart-$OS.log" && break
            wait "$RUN_PID" 2>/dev/null
            (( waited )) || echo "    waiting for a free VM slot ($(grep -o 'other running VMs: .*' "$WORK/tart-$OS.log"))"
            waited=$((waited + 30)); (( waited > 1800 )) && break
            sleep 27
        done
    fi
    # The guest agent answers once the guest has booted and logged in.
    step "guest boots" bash -c '
        for _ in $(seq 90); do
            kill -0 "$2" 2>/dev/null || { echo "tart run exited:"; cat "$3"; exit 1; }
            tart exec "$1" true >/dev/null 2>&1 && exit 0
            sleep 2
        done
        echo "no answer from the guest agent after 3 minutes"; exit 1' _ "$VM" "${RUN_PID:-0}" "$WORK/tart-$OS.log"
    failed "guest boots" && BLOCKED=1
    step "guest is macOS $(major_for "$OS")" guest '
        v=$(sw_vers -productVersion); echo "NOTE: guest runs macOS $v ($(uname -m))"
        [ "${v%%.*}" = '"$(major_for "$OS")"' ]'
    failed "guest is macOS $(major_for "$OS")" && BLOCKED=1
}

# The base image opens System Settings at login; close it so each screenshot
# shows PreviewMD alone. Then the app, as the DMG installs it, and the
# fixtures in the guest's own home (not on the share: Finder-like paths).
install_app() {
    step "app installed in /Applications" guest '
        pkill -x "System Settings"; sleep 1
        rm -rf "$APP" && ditto "$S/PreviewMD.app" "$APP" || exit 1
        rm -rf "$FX" && ditto "$S/fixtures" "$FX" || exit 1
        defaults delete com.narnarlabs.previewmd >/dev/null 2>&1
        # macOS 15 asks again, over the window, whether the guest agent may
        # keep capturing the screen. Pre-approve it, as a Mac would after a
        # click on Allow; replayd rereads its approvals when restarted.
        if [ "$(sw_vers -productVersion | cut -d. -f1)" -ge 15 ]; then
            agent=$(ps -axo comm= | grep -m1 "/tart-guest-agent$")
            [ -n "$agent" ] || { echo "tart-guest-agent not found running"; exit 1; }
            # Keyed by the resolved binary (Homebrew Cellar), not the symlink.
            agent=$(realpath "$agent") || exit 1
            far="3024-01-01T00:00:00Z"
            defaults write "$HOME/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals" \
                "$agent" -dict kScreenCaptureApprovalLastAlerted -date "$far" \
                kScreenCaptureApprovalLastUsed -date "$far" kScreenCapturePrivacyHintDate -date "$far" || exit 1
            killall replayd 2>/dev/null
        fi
        # A Mac that has never seen PreviewMD has no extension of ours yet.
        reg=$(pluginkit -m -i com.narnarlabs.previewmd.quicklook)
        [ -z "$reg" ] || { echo "Quick Look extension registered before the first launch: $reg"; exit 1; }'
    failed "app installed in /Applications" && BLOCKED=1
}

flow_launch() {
    step "launch: first window, empty state" guest '
        open "$APP" || exit 1
        wait_title PreviewMD || exit 1
        n=$(titles | wc -l | tr -d " ")
        [ "$n" = 1 ] || { echo "expected one window, found $n: [$(titles | paste -sd "|" -)]"; exit 1; }
        sleep 2; shot launch 1-empty-window || exit 1
        seen launch/1-empty-window.png "No file open" "Open a Markdown file or folder to get started" || exit 1
        alive'
    failed "launch: first window, empty state" && BLOCKED=1
}

flow_open_file() {
    step "open-file: sample.md opens and renders" guest '
        open -a "$APP" "$FX/sample.md" || exit 1
        wait_title sample.md || exit 1
        sleep 3; shot open-file 1-sample-rendered || exit 1
        # Rendered: the heading and bold text without their Markdown marks.
        seen open-file/1-sample-rendered.png "First-run check" "Rendered bold text" "Fenced code stays monospaced" || exit 1
        raw=$(ocr open-file/1-sample-rendered.png | grep -E "^#|\*\*")
        [ -z "$raw" ] || { echo "raw Markdown on screen: $raw"; exit 1; }
        recents=$(defaults read com.narnarlabs.previewmd RecentFileURLs 2>/dev/null)
        grep -q "sample.md" <<<"$recents" || { echo "sample.md not in recents: $recents"; exit 1; }
        alive'
}

flow_open_folder() {
    step "open-folder: notes/ lists, selects, renders" guest '
        open -a "$APP" "$FX/notes" || exit 1
        wait_title alpha.md || exit 1
        sleep 3; shot open-folder 1-folder-open || exit 1
        # The sidebar lists the folder (names without .md); the first file is
        # selected and rendered.
        seen open-folder/1-folder-open.png "notes" "guides" "alpha.md" "beta" "Alpha note heading" || exit 1
        defaults read com.narnarlabs.previewmd WorkspaceRootBookmarks >/dev/null 2>&1 \
            || { echo "the folder was not saved as the workspace"; exit 1; }
        alive'
}

flow_quicklook() {
    # The first launch is what registers the extension, as for a customer.
    step "quicklook: extension registered and enabled" guest '
        reg=$(pluginkit -m -v -i com.narnarlabs.previewmd.quicklook)
        echo "$reg" | sed "s/^ */NOTE: /"
        grep -qF "$APP/Contents/PlugIns/PreviewMD-QL.appex" <<<"$reg" \
            || { echo "not registered from $APP: [$reg]"; exit 1; }
        # "-" in front means the user (or the system) turned it off.
        ! grep -qE "^ *-" <<<"$reg" || { echo "registered but disabled: $reg"; exit 1; }'
    failed "quicklook: extension registered and enabled" && BLOCKED=1
    step "quicklook: sample.md previews through it" guest '
        pkill -x PreviewMD; sleep 1
        log stream --level info --predicate "subsystem == \"com.narnarlabs.previewmd.quicklook\"" >ql.log 2>&1 &
        LP=$!; sleep 2
        qlmanage -p "$FX/sample.md" >qlmanage.log 2>&1 &
        QP=$!
        ok=0
        for _ in $(seq 40); do grep -q "providePreview: rendered [0-9]* bytes of HTML" ql.log && { ok=1; break; }; sleep 0.5; done
        sleep 3; shot quicklook 1-sample-preview
        kill $QP $LP 2>/dev/null; wait $QP $LP 2>/dev/null
        mv ql.log qlmanage.log quicklook/ 2>/dev/null
        (( ok )) || { echo "PreviewMD-QL never rendered sample.md; its log:"; cat quicklook/ql.log; exit 1; }
        grep -q "providePreview: sample.md" quicklook/ql.log || { echo "the render was not of sample.md"; exit 1; }
        grep "rendered" quicklook/ql.log | sed "s/.*providePreview: /NOTE: PreviewMD-QL /"
        seen quicklook/1-sample-preview.png "First-run check" "Rendered bold text" || exit 1
        c=$(crashes); [ -z "$c" ] || { echo "crash report: $c"; exit 1; }'
}

collect() {
    guest '
        for f in "$HOME"/Library/Logs/DiagnosticReports/*; do
            case "$(basename "$f")" in *[Pp]review[Mm][Dd]*) cp "$f" "$OUT_OS/" ;; esac
        done; true' >/dev/null 2>&1
    echo "    screenshots: build/old-macos/out/$OS/"
}

echo "== host"
OS_LABEL=""
if [ -n "${PREVIEWMD_APP:-}" ]; then
    step "app given: $PREVIEWMD_APP" test -x "$APP_SRC/Contents/MacOS/PreviewMD"
else
    step "app builds (make app)" make app DIST_DIR="$WORK/dist"
fi
failed "app builds (make app)" && BLOCKED=1
failed "app given: ${PREVIEWMD_APP:-}" && BLOCKED=1
step "guest probe builds (macOS 13, arm64)" \
    swiftc -O -target arm64-apple-macos13 tools/old-macos/probe.swift -o "$WORK/probe"
failed "guest probe builds (macOS 13, arm64)" && BLOCKED=1
step "shared folder staged" bash -c '
    rm -rf "$1" && mkdir -p "$1" "$2" || exit 1
    ditto "$3" "$1/PreviewMD.app" && cp "$4" "$1/probe" && ditto tools/old-macos/fixtures "$1/fixtures"' \
    _ "$SHARE" "$OUT" "$APP_SRC" "$WORK/probe"
failed "shared folder staged" && BLOCKED=1
HOST_BLOCKED=$BLOCKED

RAN=()
for OS in "${OSES[@]}"; do
    OS_LABEL="$OS: "
    echo "== macOS $(major_for "$OS") ($OS)"
    BLOCKED=$HOST_BLOCKED
    if ! image_local "$OS"; then
        if (( PULL )); then
            echo "pulling $(image_for "$OS") (~25 GB, once)…"
            tart pull "$(image_for "$OS")" || { FAILED+=("$OS: image pull"); continue; }
        elif (( NAMED )); then
            echo "no $(image_for "$OS") on this Mac: add --pull to fetch it (~25 GB)"
            FAILED+=("$OS: no image"); continue
        else
            echo "skipped: no $(image_for "$OS") on this Mac (--pull fetches it, ~25 GB)"
            SKIPPED+=("$OS"); continue
        fi
    fi
    RAN+=("$OS")
    # Only this script's flows: the update test keeps its own beside them.
    rm -rf "$OUT/$OS"/{launch,open-file,open-folder,quicklook} && mkdir -p "$OUT/$OS"
    boot
    install_app
    flow_launch
    flow_open_file
    flow_open_folder
    flow_quicklook
    (( HOST_BLOCKED )) || [ -z "$VM" ] || collect
    stop_vm
done

echo
(( ${#SKIPPED[@]} )) && echo "skipped (no image): ${SKIPPED[*]}"
if (( ${#FAILED[@]} )); then
    echo "FAILED (${#FAILED[@]}):"
    printf '  %s\n' "${FAILED[@]}"
    exit 1
fi
(( ${#RAN[@]} )) || { echo "nothing ran: no macOS image on this Mac"; exit 1; }
echo "all passed (${RAN[*]})"
