#!/bin/bash
# Xcode cannot select a Catalyst variant for a native macOS target dependency.
set -euo pipefail

: "${SRCROOT:?Run this script from the iMCP Xcode build phase.}"
: "${TARGET_BUILD_DIR:?Missing Xcode product directory.}"
: "${WRAPPER_NAME:?Missing Xcode app wrapper name.}"
: "${CONFIGURATION:?Missing Xcode configuration.}"
: "${PROJECT_TEMP_DIR:?Missing Xcode intermediates directory.}"

# Developer ID builds can't carry the HomeKit entitlement,
# so release builds leave the helper out;
# developers build and sign it with Scripts/install-helper.sh.
if [[ "${EMBED_HOME_HELPER:-YES}" != YES ]]; then
    echo "Skipping iMCP Helper (EMBED_HOME_HELPER=${EMBED_HOME_HELPER})."
    # Remove a helper left by an earlier build in the same directory.
    rm -rf "$TARGET_BUILD_DIR/$WRAPPER_NAME/Contents/Helpers/iMCP Helper.app"
    rm -rf "$TARGET_BUILD_DIR/$WRAPPER_NAME/Contents/Library/LoginItems/iMCP Helper.app"
    rm -f "$TARGET_BUILD_DIR/$WRAPPER_NAME/Contents/Library/LaunchAgents/$PRODUCT_BUNDLE_IDENTIFIER.home-helper.plist"
    exit 0
fi

helper_derived_data="$PROJECT_TEMP_DIR/HelperDerivedData"
helper_signing="${HELPER_CODE_SIGNING_ALLOWED:-YES}"

xcodebuild_args=(
    -quiet
    -project "$SRCROOT/iMCP.xcodeproj"
    -scheme "iMCP Helper"
    -configuration "$CONFIGURATION"
    -destination 'platform=macOS,variant=Mac Catalyst'
    -derivedDataPath "$helper_derived_data"
)
if [[ "$helper_signing" == YES ]]; then
    xcodebuild_args+=(-allowProvisioningUpdates)
fi
xcodebuild_args+=(
    CODE_SIGNING_ALLOWED="$helper_signing"
    CODE_SIGNING_REQUIRED="$helper_signing"
    build
)

# Keep the nested build's environment, products, and build database separate.
# Inherited Xcode settings otherwise rename package products after the native app.
env -i PATH="$PATH" HOME="$HOME" USER="$USER" LOGNAME="$LOGNAME" \
    TMPDIR="${TMPDIR:-/tmp}" DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}" \
    xcodebuild "${xcodebuild_args[@]}"

helper_product="$helper_derived_data/Build/Products/$CONFIGURATION-maccatalyst/iMCP Helper.app"
helper_destination="$TARGET_BUILD_DIR/$WRAPPER_NAME/Contents/Helpers/iMCP Helper.app"
if [[ ! -d "$helper_product/Contents/MacOS" ]]; then
    echo 'error: The iMCP Helper build did not produce a Catalyst app.' >&2
    exit 1
fi
mkdir -p "$(dirname "$helper_destination")"
# ditto preserves the helper's development signature when the native Debug app is unsigned.
# Remove stale files if the nested app's contents changed between builds.
rm -rf "$helper_destination"
ditto "$helper_product" "$helper_destination"

# Write the launch agent that iMCP registers with SMAppService.
# Its names derive from iMCP's bundle identifier, as HomeHelperIdentity does.
agent_dir="$TARGET_BUILD_DIR/$WRAPPER_NAME/Contents/Library/LaunchAgents"
mkdir -p "$agent_dir"
sed "s/__APP_BUNDLE_IDENTIFIER__/$PRODUCT_BUNDLE_IDENTIFIER/g" \
    "$SRCROOT/Scripts/home-helper.launchd.plist.in" \
    >"$agent_dir/$PRODUCT_BUNDLE_IDENTIFIER.home-helper.plist"
plutil -lint "$agent_dir/$PRODUCT_BUNDLE_IDENTIFIER.home-helper.plist"

# Bundle cloudflared inside Contents/Helpers with sandbox-inherit entitlements when installed locally,
# so the sandboxed Mac app can run Cloudflare Tunnel without reading outside its container.
cloudflared_src=""
for candidate in /opt/homebrew/bin/cloudflared /usr/local/bin/cloudflared /opt/local/bin/cloudflared; do
    if [[ -x "$candidate" ]]; then
        cloudflared_src="$candidate"
        break
    fi
done
cloudflared_dst="$TARGET_BUILD_DIR/$WRAPPER_NAME/Contents/Helpers/cloudflared"
if [[ -n "$cloudflared_src" ]]; then
    cp -fL "$cloudflared_src" "$cloudflared_dst"
    chmod 755 "$cloudflared_dst"
    if [[ "${CODE_SIGNING_ALLOWED:-NO}" == YES ]] && [[ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
        codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" -o runtime --timestamp=none \
            --entitlements "$SRCROOT/Scripts/Cloudflared.entitlements" \
            "$cloudflared_dst"
    fi
else
    rm -f "$cloudflared_dst"
fi
