#!/bin/bash
set -e
cd "$(dirname "$0")"

DEST="simulator"

while [[ $# -gt 0 ]]; do
    case "$1" in
        device)    DEST="device"; shift ;;
        simulator) DEST="simulator"; shift ;;
        *)         shift ;;
    esac
done

VERSION="1.0.0"
BUILD="$(git rev-parse --short=8 HEAD 2>/dev/null || echo deadbeef)"
DATE="$(date '+%b %-d, %Y')"

cat > Sources/Firehose/Version.swift <<EOF
// Overwritten by build.sh with the real git hash and build date.
enum Version {
    static let version = "${VERSION}"
    static let build = "${BUILD}"
    static let date = "${DATE}"
}
EOF

echo "firehose-ios ${VERSION}/${BUILD}"

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

if [ "$DEST" = "device" ]; then
    unlock_keychain_if_needed
    BUILD_LOG=$(mktemp)
    trap 'rm -f "$BUILD_LOG"' EXIT
    set +e
    xcodebuild -project Firehose.xcodeproj -scheme Firehose \
        -destination 'generic/platform=iOS' \
        -allowProvisioningUpdates "${TEAM_ARGS[@]}" build 2>&1 | tee "$BUILD_LOG"
    BUILD_STATUS=${PIPESTATUS[0]}
    set -e
    if [ "$BUILD_STATUS" -ne 0 ] && grep -q 'is not installed. Please download and install the platform' "$BUILD_LOG"; then
        echo
        echo "hint: your device is running a newer iOS than Xcode has platform support for."
        echo "fix:  xcodebuild -downloadPlatform iOS"
    fi
    if [ "$BUILD_STATUS" -ne 0 ] && grep -q 'errSecInternalComponent' "$BUILD_LOG"; then
        echo
        echo "hint: codesign could not reach the signing key in your login keychain."
        echo "fix:  security unlock-keychain ~/Library/Keychains/login.keychain-db"
        echo "      if it still fails, allow codesign to use the key without a prompt:"
        echo "      security set-key-partition-list -S apple-tool:,apple: -s \\"
        echo "          -k <password> ~/Library/Keychains/login.keychain-db"
    fi
    exit $BUILD_STATUS
else
    xcodebuild -project Firehose.xcodeproj -scheme Firehose \
        -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
fi
