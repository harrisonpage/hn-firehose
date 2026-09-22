#!/bin/bash
# Shared functions for deploying Firehose to iOS devices

# Overridable so other developers can deploy under their own team; see build.sh.
BUNDLE_ID="${BUNDLE_ID_PREFIX:-page.harrison}.Firehose"

find_device() {
    local name="$1"
    # Older devicectl prints a CoreDevice UUID (8-4-4-4-12); Xcode 27 prints
    # the hardware UDID (8-16). --device accepts either.
    xcrun devicectl list devices 2>&1 | awk -v name="$name" \
        'tolower($1) == tolower(name) { match($0, /[0-9A-F]{8}-([0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}|[0-9A-F]{16})/); if (RSTART) print substr($0, RSTART, RLENGTH) }'
}

deploy_to_device() {
    local device_id="$1"
    local device_name="$2"

    ./build.sh device

    APP_PATH=$(xcodebuild -project Firehose.xcodeproj -scheme Firehose \
        -destination 'generic/platform=iOS' \
        -showBuildSettings 2>/dev/null | grep -m1 'BUILT_PRODUCTS_DIR' | awk '{print $3}')/Firehose.app

    echo "Installing on ${device_name}..."
    xcrun devicectl device install app --device "$device_id" "$APP_PATH"
    echo "Launching..."
    xcrun devicectl device process launch --device "$device_id" "$BUNDLE_ID"

    echo "Firehose running on ${device_name}"
}
