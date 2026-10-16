#!/bin/sh
set -e

# Build and package Triage as a signed, notarized DMG for distribution.
#
# Triage has two targets: the main menu bar app and an embedded MailKit
# extension (TriageExtension.appex). Both are signed independently
# with their own entitlements before the DMG is created.
#
# Prerequisites:
#   brew install create-dmg
#
# Environment variables (optional — prompted if missing):
#   APPLE_ID        — your Apple ID email for notarization
#   TEAM_ID         — your Apple Developer team ID (default: 84CC987JU3)
#   APP_PASSWORD    — app-specific password for notarytool
#
# Usage:
#   ./Scripts/create-dmg.sh                   # full build + sign + notarize
#   ./Scripts/create-dmg.sh --skip-notarize   # build + sign only

APP_NAME="Triage"
PRODUCT_NAME="Triage"
BUNDLE_ID="com.subversivesoftware.triage"
EXTENSION_NAME="TriageExtension"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
DERIVED_DATA="$BUILD_DIR/DerivedData"

# ── Verify clean working directory ──────────────────────────────
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if [ -n "$(git status --porcelain)" ]; then
        echo "Error: Working directory has uncommitted changes."
        echo "Commit or stash them before building a release."
        echo ""
        git status --short
        exit 1
    fi
fi

# ── Auto-increment build number ──────────────────────────────────
PLIST="$PROJECT_DIR/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
NEW_BUILD=$((CURRENT_BUILD + 1))
echo "==> Incrementing build number: $CURRENT_BUILD → $NEW_BUILD"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$PLIST"

DMG_NAME="Triage-${VERSION}-b${NEW_BUILD}.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"
STAGING_DIR="$BUILD_DIR/dmg-staging"
NOTARIZE_TIMEOUT="15m"

SKIP_NOTARIZE=false
if [ "${1:-}" = "--skip-notarize" ]; then
    SKIP_NOTARIZE=true
fi

# ── Find Developer ID certificate ────────────────────────────────
IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)".*/\1/')
if [ -z "$IDENTITY" ]; then
    echo "Error: No 'Developer ID Application' certificate found in keychain."
    if [ "$SKIP_NOTARIZE" = true ]; then
        echo "Continuing with ad-hoc signing..."
        IDENTITY=""
    else
        exit 1
    fi
fi

# ── Notarization credentials ─────────────────────────────────────
if [ "$SKIP_NOTARIZE" = false ] && [ -n "$IDENTITY" ]; then
    TEAM_ID="${TEAM_ID:-84CC987JU3}"

    if [ -z "${APPLE_ID:-}" ]; then
        printf "Apple ID (email) for notarization: "
        read -r APPLE_ID
    fi
    if [ -z "${APP_PASSWORD:-}" ]; then
        printf "App-specific password: "
        stty -echo
        read -r APP_PASSWORD
        stty echo
        echo ""
    fi
fi

cd "$PROJECT_DIR"

# ── Build (universal binary) ─────────────────────────────────────
echo "==> Building $PRODUCT_NAME v$VERSION build $NEW_BUILD (Release, universal)..."
xcodebuild -project "$PROJECT_DIR/$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    DEVELOPMENT_TEAM="${TEAM_ID:-84CC987JU3}" \
    CODE_SIGNING_ALLOWED=NO \
    clean build \
    | tail -5

APP_PATH="$DERIVED_DATA/Build/Products/Release/$PRODUCT_NAME.app"
if [ ! -d "$APP_PATH" ]; then
    echo "Error: Build failed — $PRODUCT_NAME.app not found"
    exit 1
fi

if [ ! -f "$APP_PATH/Contents/MacOS/$PRODUCT_NAME" ]; then
    echo "Error: Build produced an app bundle but the binary is missing!"
    exit 1
fi

EXTENSION_PATH="$APP_PATH/Contents/PlugIns/$EXTENSION_NAME.appex"
if [ ! -d "$EXTENSION_PATH" ]; then
    echo "Warning: MailKit extension not found at $EXTENSION_PATH"
    echo "         The DMG will not include the mail extension."
fi

# ── Code signing (inside-out: Sparkle → extension → app) ─────────
if [ -n "$IDENTITY" ]; then
    echo "==> Signing embedded frameworks and helpers..."
    SPARKLE_FW="$APP_PATH/Contents/Frameworks/Sparkle.framework"
    if [ -d "$SPARKLE_FW" ]; then
        for xpc in "$SPARKLE_FW"/Versions/B/XPCServices/*.xpc; do
            [ -d "$xpc" ] && codesign --force --options runtime --sign "$IDENTITY" --timestamp "$xpc"
        done
        for app in "$SPARKLE_FW"/Versions/B/*.app; do
            [ -d "$app" ] && codesign --force --options runtime --sign "$IDENTITY" --timestamp "$app"
        done
        for bin in "$SPARKLE_FW"/Versions/B/Autoupdate; do
            [ -f "$bin" ] && codesign --force --options runtime --sign "$IDENTITY" --timestamp "$bin"
        done
        codesign --force --options runtime --sign "$IDENTITY" --timestamp "$SPARKLE_FW"
    fi

    # Sign the MailKit extension (inside-out signing order)
    if [ -d "$EXTENSION_PATH" ]; then
        echo "==> Signing extension: $EXTENSION_NAME"
        codesign --force --options runtime \
            --sign "$IDENTITY" \
            --timestamp \
            --entitlements "$PROJECT_DIR/$EXTENSION_NAME/$EXTENSION_NAME.entitlements" \
            "$EXTENSION_PATH"
        codesign --verify --verbose=2 "$EXTENSION_PATH"
        echo "    Extension signature OK"
    fi

    echo "==> Signing app with: $IDENTITY"
    codesign --force --options runtime \
        --sign "$IDENTITY" \
        --timestamp \
        --entitlements "$PROJECT_DIR/$APP_NAME.entitlements" \
        "$APP_PATH"
    echo "==> Verifying signature..."
    codesign --verify --verbose=2 --deep "$APP_PATH"
    echo "    Signature OK"
fi

# ── Verify binary architecture ────────────────────────────────────
ARCHS=$(lipo -archs "$APP_PATH/Contents/MacOS/$PRODUCT_NAME" 2>/dev/null || echo "unknown")
echo "    Architecture: $ARCHS"

# ── Create DMG ───────────────────────────────────────────────────
echo "==> Creating DMG..."
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"
rm -f "$DMG_PATH"

if command -v create-dmg >/dev/null 2>&1; then
    ICON_PATH="$APP_PATH/Contents/Resources/AppIcon.icns"
    VOL_ICON_FLAG=""
    if [ -f "$ICON_PATH" ]; then
        VOL_ICON_FLAG="--volicon $ICON_PATH"
    fi

    create-dmg \
        --volname "$PRODUCT_NAME" \
        $VOL_ICON_FLAG \
        --window-pos 200 120 \
        --window-size 600 400 \
        --icon-size 100 \
        --icon "$PRODUCT_NAME.app" 175 190 \
        --app-drop-link 425 190 \
        --hide-extension "$PRODUCT_NAME.app" \
        "$DMG_PATH" \
        "$STAGING_DIR" \
        || true
    if [ ! -f "$DMG_PATH" ]; then
        echo "Error: create-dmg failed to produce $DMG_NAME"
        exit 1
    fi
else
    ln -sf /Applications "$STAGING_DIR/Applications"
    hdiutil create -volname "$PRODUCT_NAME" \
        -srcfolder "$STAGING_DIR" \
        -ov -format UDZO \
        "$DMG_PATH"
fi

# Sign the DMG
if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" --timestamp "$DMG_PATH"
fi

# ── Notarize ─────────────────────────────────────────────────────
if [ "$SKIP_NOTARIZE" = false ] && [ -n "$IDENTITY" ]; then
    echo "==> Submitting for notarization (timeout: ${NOTARIZE_TIMEOUT})..."
    if xcrun notarytool submit "$DMG_PATH" \
        --apple-id "$APPLE_ID" \
        --team-id "$TEAM_ID" \
        --password "$APP_PASSWORD" \
        --wait \
        --timeout "$NOTARIZE_TIMEOUT"; then

        echo "==> Stapling..."
        xcrun stapler staple "$DMG_PATH"

        echo "==> Verifying notarization..."
        spctl --assess --type open --context context:primary-signature "$DMG_PATH" && echo "    Notarization OK" || echo "    Warning: spctl check failed (may need to retry)"
    else
        echo ""
        echo "WARNING: Notarization did not complete within ${NOTARIZE_TIMEOUT}."
        echo "Check status: xcrun notarytool history --apple-id $APPLE_ID --team-id $TEAM_ID --password YOUR_PASSWORD"
        echo "Then staple:  xcrun stapler staple $DMG_PATH"
    fi
fi

# ── Sparkle update archive + appcast ────────────────────────────
echo "==> Creating Sparkle update archive..."
SPARKLE_DIR="$BUILD_DIR/sparkle"
rm -rf "$SPARKLE_DIR"
mkdir -p "$SPARKLE_DIR"

ZIP_NAME="Triage-${VERSION}-b${NEW_BUILD}.zip"
ZIP_PATH="$SPARKLE_DIR/$ZIP_NAME"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
echo "  Archive: $ZIP_PATH"

GENERATE_APPCAST="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
if [ -x "$GENERATE_APPCAST" ]; then
    echo "==> Generating appcast..."
    "$GENERATE_APPCAST" "$SPARKLE_DIR"
    echo "  Appcast: $SPARKLE_DIR/appcast.xml"
else
    echo "WARNING: generate_appcast not found at $GENERATE_APPCAST"
    echo "  Run 'swift package resolve' first, then re-run this script."
fi

# ── Stage appcast to website (binaries go to GitHub Releases) ────
WWW_UPDATES="$PROJECT_DIR/../www/static/updates/triage"
if [ -d "$PROJECT_DIR/../www" ]; then
    mkdir -p "$WWW_UPDATES"
    [ -f "$SPARKLE_DIR/appcast.xml" ] && cp -f "$SPARKLE_DIR/appcast.xml" "$WWW_UPDATES/"
    echo "  Appcast staged to: $WWW_UPDATES/appcast.xml"
fi

# ── Cleanup ──────────────────────────────────────────────────────
rm -rf "$STAGING_DIR"

echo ""
echo "Done!"
echo "  DMG:      $DMG_PATH ($(ls -lh "$DMG_PATH" | awk '{print $5}'))"
echo "  ZIP:      $ZIP_PATH (for Sparkle auto-update)"
echo "  Version:  $VERSION (build $NEW_BUILD)"
echo "  Arch:     $ARCHS"
if [ -d "$EXTENSION_PATH" ]; then
    echo "  Extension: MailKit extension included"
fi
if [ -n "$IDENTITY" ]; then
    echo "  Signed:   $IDENTITY"
    if [ "$SKIP_NOTARIZE" = false ]; then
        echo "  Notarized and stapled"
    else
        echo "  NOT notarized (--skip-notarize)"
    fi
else
    echo "  WARNING: Unsigned — users will see Gatekeeper warnings"
fi
echo ""
echo "Build number $NEW_BUILD has been written to Info.plist."

# ── Git tag + push ───────────────────────────────────────────────
TAG="v${VERSION}-b${NEW_BUILD}"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git add "$PLIST"
    git commit -m "Build $NEW_BUILD for v$VERSION distribution" 2>/dev/null || true
    git tag -a "$TAG" -m "$PRODUCT_NAME $VERSION build $NEW_BUILD"
    echo "  Tagged: $TAG"
    echo "==> Pushing to remote..."
    git push && git push --tags
fi

# ── GitHub Release ───────────────────────────────────────────────
if command -v gh >/dev/null 2>&1; then
    echo "==> Creating GitHub release..."
    PREV_TAG=$(git tag --sort=-v:refname | grep -v "^$TAG$" | head -1)
    if [ -n "$PREV_TAG" ]; then
        RELEASE_NOTES=$(git log --pretty=format:"- %s" "$PREV_TAG".."$TAG" -- . ':!Info.plist' | grep -v "^- Build [0-9]")
    fi
    if [ -z "$RELEASE_NOTES" ]; then
        RELEASE_NOTES="$PRODUCT_NAME $VERSION build $NEW_BUILD"
    fi

    NOTES_BODY="## What's New

$RELEASE_NOTES

## Install

Download **$DMG_NAME**, open it, and drag Triage to your Applications folder.

Existing users with auto-update enabled will receive this update automatically via Sparkle."

    REPO_SLUG=$(gh repo view --json nameWithOwner -q .nameWithOwner)

    gh release create "$TAG" "$DMG_PATH" "$ZIP_PATH" \
        --title "$PRODUCT_NAME $VERSION (build $NEW_BUILD)" \
        --notes "$NOTES_BODY" \
        && echo "  Release: https://github.com/$REPO_SLUG/releases/tag/$TAG" \
        || echo "  WARNING: GitHub release creation failed."

    # Rewrite appcast enclosure URL to point at GitHub Releases
    GITHUB_ZIP_URL="https://github.com/$REPO_SLUG/releases/download/$TAG/$ZIP_NAME"
    if [ -f "$WWW_UPDATES/appcast.xml" ]; then
        sed -i '' "s|url=\"[^\"]*$ZIP_NAME\"|url=\"$GITHUB_ZIP_URL\"|" "$WWW_UPDATES/appcast.xml"
        echo "  Appcast URL rewritten to: $GITHUB_ZIP_URL"
    fi
else
    echo "  gh CLI not found — skipping GitHub release. Install with: brew install gh"
fi

# ── Website deploy reminder ──────────────────────────────────────
echo ""
if [ -d "$WWW_UPDATES" ]; then
    echo "Next: cd ../www && git add -A && git commit -m \"Triage $VERSION build $NEW_BUILD\" && git push"
fi
