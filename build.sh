#!/bin/bash
set -e
cd "$(dirname "$0")"

DEST="simulator"

while [[ $# -gt 0 ]]; do
    case "$1" in
        device)    DEST="device"; shift ;;
        simulator) DEST="simulator"; shift ;;
        release)   DEST="release"; shift ;;
        *)         shift ;;
    esac
done

VERSION="1.0.0"
BUILD="$(git rev-parse --short=8 HEAD 2>/dev/null || echo deadbeef)"
# CFBundleVersion must be a small dotted integer that grows with every upload,
# so the commit count is the build number; the short hash is only for display.
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
DATE="$(date '+%b %-d, %Y')"

cat > Sources/Firehose/Version.swift <<EOF
// Overwritten by build.sh with the real git hash and build date.
enum Version {
    static let version = "${VERSION}"
    static let build = "${BUILD}"
    static let date = "${DATE}"
}
EOF

echo "firehose-ios ${VERSION}/${BUILD} (build ${BUILD_NUMBER})"

# Device signing needs an Apple Developer team. The team ID is not checked in;
# export DEVELOPMENT_TEAM (see harrison.sh in the private repo) or set your own.
#
# Bundle IDs are unique across all Apple teams, so a build signed by another
# team cannot use page.harrison.Firehose: automatic provisioning fails with
# "An App ID with Identifier ... is not available". Export BUNDLE_ID_PREFIX
# (e.g. com.example) to build as com.example.Firehose instead. The test
# target and the iCloud KVS entitlement follow the prefix automatically.
TEAM_ARGS=()
if [ -n "$DEVELOPMENT_TEAM" ]; then
    TEAM_ARGS+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
fi
if [ -n "$BUNDLE_ID_PREFIX" ]; then
    TEAM_ARGS+=("FIREHOSE_BUNDLE_ID_PREFIX=$BUNDLE_ID_PREFIX")
fi
VERSION_ARGS=("MARKETING_VERSION=$VERSION" "CURRENT_PROJECT_VERSION=$BUILD_NUMBER")

# Signing a device build needs the private key that lives in your login
# keychain, and getting at it over SSH takes an extra step.
#
# In a desktop session the login keychain is unlocked when you log in, and if
# something still needs permission the SecurityAgent puts a dialog on screen.
# An SSH session has neither: the keychain is locked, and there is no window
# server to draw a prompt on, so macOS refuses the request rather than asking.
# codesign can still read the certificate — `security find-identity` lists it,
# which makes this look like a working setup — but the private key is out of
# reach, and the build dies partway through with:
#
#     <app>/Firehose.debug.dylib: errSecInternalComponent
#     Command CodeSign failed with a nonzero exit code
#
# So unlock the keychain ourselves, using the tty we do have. `security
# unlock-keychain` with no -p reads the password from the terminal without
# echoing it; KEYCHAIN_PASSWORD is there for when nothing is watching (CI, a
# cron job, an agent shell). The unlock lasts until the keychain relocks — on
# its idle timeout, on sleep, or at logout — so expect to type it again in a
# later session, not on every build.
#
# If the unlock is not enough and codesign still returns errSecInternalComponent,
# the key's ACL is asking for a confirmation nobody can click. Granting the
# codesign tools standing access to it, once, settles that:
#
#     security set-key-partition-list -S apple-tool:,apple: -s \
#         -k <password> ~/Library/Keychains/login.keychain-db
#
# (-s picks the keys that can sign, -S is who may use them without asking.)
#
# None of this applies when you build from Xcode or a Terminal on the machine
# itself; show-keychain-info succeeds there and this function does nothing.
unlock_keychain_if_needed() {
    local keychain="$HOME/Library/Keychains/login.keychain-db"
    [ -f "$keychain" ] || return 0
    security show-keychain-info "$keychain" >/dev/null 2>&1 && return 0

    if [ -n "$KEYCHAIN_PASSWORD" ]; then
        security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$keychain"
    elif [ -t 0 ]; then
        echo "login keychain is locked (signing needs it); enter your macOS password:"
        security unlock-keychain "$keychain"
    else
        echo "warning: login keychain is locked and no tty to unlock it on."
        echo "         set KEYCHAIN_PASSWORD or run: security unlock-keychain"
    fi
}

# Runs xcodebuild with the given arguments, tees the log, and on failure
# prints a hint for the two failures that are easy to misread.
run_xcodebuild() {
    local log status
    log=$(mktemp)
    set +e
    xcodebuild "$@" 2>&1 | tee "$log"
    status=${PIPESTATUS[0]}
    set -e
    if [ "$status" -ne 0 ] && grep -q 'is not installed. Please download and install the platform' "$log"; then
        echo
        echo "hint: your device is running a newer iOS than Xcode has platform support for."
        echo "fix:  xcodebuild -downloadPlatform iOS"
    fi
    if [ "$status" -ne 0 ] && grep -q 'errSecInternalComponent' "$log"; then
        echo
        echo "hint: codesign could not reach the signing key in your login keychain."
        echo "fix:  security unlock-keychain ~/Library/Keychains/login.keychain-db"
        echo "      if it still fails, allow codesign to use the key without a prompt:"
        echo "      security set-key-partition-list -S apple-tool:,apple: -s \\"
        echo "          -k <password> ~/Library/Keychains/login.keychain-db"
    fi
    rm -f "$log"
    return "$status"
}

case "$DEST" in
device)
    unlock_keychain_if_needed
    run_xcodebuild -project Firehose.xcodeproj -scheme Firehose \
        -destination 'generic/platform=iOS' \
        -allowProvisioningUpdates "${TEAM_ARGS[@]}" "${VERSION_ARGS[@]}" build
    ;;
release)
    # Archive a Release build and export an App Store .ipa into build/export.
    # Uploading is a separate, manual step (Transporter.app or an App Store
    # Connect API key kept outside the repo); this script stops at the .ipa.
    if [ -z "$DEVELOPMENT_TEAM" ]; then
        echo "error: DEVELOPMENT_TEAM is not set; a release build cannot be signed without it." >&2
        echo "       export DEVELOPMENT_TEAM=<your 10-character team ID> and try again." >&2
        exit 1
    fi
    unlock_keychain_if_needed
    mkdir -p build
    # ExportOptions.plist carries the team ID, so it is generated here and
    # lives under build/, which is gitignored.
    cat > build/ExportOptions.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>teamID</key>
    <string>${DEVELOPMENT_TEAM}</string>
    <key>destination</key>
    <string>export</string>
    <key>uploadSymbols</key>
    <true/>
</dict>
</plist>
EOF
    rm -rf build/Firehose.xcarchive build/export
    run_xcodebuild -project Firehose.xcodeproj -scheme Firehose \
        -configuration Release \
        -destination 'generic/platform=iOS' \
        -archivePath build/Firehose.xcarchive \
        -allowProvisioningUpdates "${TEAM_ARGS[@]}" "${VERSION_ARGS[@]}" archive
    # xcodebuild shells out to `rsync` to assemble the .ipa and expects Apple's
    # openrsync. A Homebrew rsync earlier on PATH takes different options and
    # the export dies with nothing more than "Copy failed", so put /usr/bin first.
    PATH="/usr/bin:$PATH" run_xcodebuild -exportArchive \
        -archivePath build/Firehose.xcarchive \
        -exportOptionsPlist build/ExportOptions.plist \
        -exportPath build/export \
        -allowProvisioningUpdates
    echo
    echo "exported: $(pwd)/build/export/Firehose.ipa (${VERSION} build ${BUILD_NUMBER})"
    echo "upload it with Transporter.app or an App Store Connect API key."
    ;;
*)
    run_xcodebuild -project Firehose.xcodeproj -scheme Firehose \
        -destination 'platform=iOS Simulator,name=iPhone 17 Pro' "${VERSION_ARGS[@]}" build
    ;;
esac
