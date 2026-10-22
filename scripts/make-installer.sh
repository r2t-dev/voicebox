#!/bin/sh
# Builds build/Voicebox-<version>.pkg, an installer package that puts Voicebox.app into /Applications.
# It runs scripts/build-app.sh first, so SIGN_IDENTITY works as there.
# INSTALLER_SIGN_IDENTITY selects a "Developer ID Installer" certificate for the package. Without it,
# the package is not signed.
set -eu

cd "$(dirname "$0")/.."
INSTALLER_SIGN_IDENTITY="${INSTALLER_SIGN_IDENTITY:-}"
APP="build/Voicebox.app"

./scripts/build-app.sh

plist="$APP/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist").pkg"
MIN_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist")"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/Voicebox" | tr ' ' ',')"
PKG="build/Voicebox-$VERSION.pkg"

# The work folder is inside build/, which git ignores. The script deletes it at the end.
WORK="build/installer"
rm -rf "$WORK"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/root" "$WORK/scripts" "$WORK/packages"
ditto "$APP" "$WORK/root/Voicebox.app"

# By default, Installer puts a new version where it finds an app with the same bundle identifier, for example
# into build/. A bundle that is not relocatable always goes to /Applications. The version stays the same
# between builds, so Installer must not compare versions, or it can keep the installed build.
pkgbuild --analyze --root "$WORK/root" "$WORK/components.plist"
plutil -replace 0.BundleIsRelocatable -bool NO "$WORK/components.plist"
plutil -replace 0.BundleIsVersionChecked -bool NO "$WORK/components.plist"

cat > "$WORK/scripts/preinstall" <<'EOF'
#!/bin/sh
# Quits a running Voicebox, so that the new version starts after the install.
pkill -x Voicebox || true
exit 0
EOF
cat > "$WORK/scripts/postinstall" <<'EOF'
#!/bin/sh
# Starts Voicebox for the user at the console. Installer runs this script as root, and $2 is /Applications.
user="$(stat -f %Su /dev/console)"
if [ -n "$user" ] && [ "$user" != "root" ]; then
    launchctl asuser "$(id -u "$user")" sudo -u "$user" open "$2/Voicebox.app" || true
fi
exit 0
EOF
chmod 755 "$WORK/scripts/preinstall" "$WORK/scripts/postinstall"

pkgbuild --root "$WORK/root" --component-plist "$WORK/components.plist" --scripts "$WORK/scripts" \
    --identifier "$IDENTIFIER" --version "$VERSION" --install-location /Applications \
    "$WORK/packages/Voicebox.pkg"

# The distribution gives the installer its title and refuses other Macs and older macOS versions.
cat > "$WORK/distribution.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>Voicebox</title>
    <options customize="never" require-scripts="false" hostArchitectures="$ARCHS"/>
    <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
    <volume-check>
        <allowed-os-versions>
            <os-version min="$MIN_MACOS"/>
        </allowed-os-versions>
    </volume-check>
    <choices-outline>
        <line choice="$IDENTIFIER"/>
    </choices-outline>
    <choice id="$IDENTIFIER" visible="false">
        <pkg-ref id="$IDENTIFIER"/>
    </choice>
    <pkg-ref id="$IDENTIFIER" version="$VERSION" onConclusion="none">Voicebox.pkg</pkg-ref>
</installer-gui-script>
EOF

if [ -n "$INSTALLER_SIGN_IDENTITY" ]; then
    productbuild --distribution "$WORK/distribution.xml" --package-path "$WORK/packages" \
        --sign "$INSTALLER_SIGN_IDENTITY" "$PKG"
else
    productbuild --distribution "$WORK/distribution.xml" --package-path "$WORK/packages" "$PKG"
fi
echo "Built $PKG"
