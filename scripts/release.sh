#!/bin/zsh
# Build Glyph Cast, sign it with Developer ID (hardened runtime), notarize and staple the disk
# image, check a quarantined copy passes Gatekeeper, and publish a GitHub release on
# fru-dev3/glyph-cast: Glyph-Cast-<version>.dmg plus Glyph-Cast.dmg (the stable
# releases/latest/download link). Run it in the public clone.
# Needs a "Developer ID Application" certificate in the keychain, an App Store Connect API key
# for notarization (ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH in the environment), and gh signed in.
set -euo pipefail
cd "${0:A:h}/.."
: ${ASC_KEY_ID:?set ASC_KEY_ID} ${ASC_ISSUER_ID:?set ASC_ISSUER_ID} ${ASC_KEY_PATH:?set ASC_KEY_PATH}
identity=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')
[[ -n $identity ]] || { echo "no Developer ID Application certificate in the keychain"; exit 1; }
version=$(awk -F= '/^VERSION=/{print $2; exit}' scripts/build.sh)
repo=fru-dev3/glyph-cast

echo "building Glyph Cast $version"
SIGN_IDENTITY="$identity" ./scripts/build.sh
app="build/Glyph Cast.app"
codesign --verify --strict --deep "$app"
sig=$(codesign -dvv "$app" 2>&1)
[[ $sig == *"(runtime)"* ]] || { echo "not signed with the hardened runtime"; exit 1; }

echo "making the disk image"
rm -rf dist && mkdir -p dist/stage
cp -R "$app" dist/stage/ && ln -s /Applications dist/stage/Applications
dmg=dist/Glyph-Cast-$version.dmg
hdiutil create -volname "Glyph Cast $version" -srcfolder dist/stage -fs HFS+ -format UDZO -ov "$dmg" -quiet
codesign --sign "$identity" --timestamp "$dmg"

echo "notarizing (a few minutes)"
result=$(xcrun notarytool submit "$dmg" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait --timeout 20m)
echo "$result"
if ! grep -q "status: Accepted" <<<"$result"; then
  id=$(awk '/^ *id:/{print $2; exit}' <<<"$result")
  xcrun notarytool log "$id" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID"
  echo "notarization was not accepted (log above)"; exit 1
fi
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"

echo "checking a downloaded copy passes Gatekeeper"
cp "$dmg" dist/check.dmg
xattr -w com.apple.quarantine "0081;00000000;Safari;" dist/check.dmg
spctl --assess --type open --context context:primary-signature -v dist/check.dmg
rm dist/check.dmg
cp "$dmg" dist/Glyph-Cast.dmg

# The version's whole entry in the README (its first line and the indented lines under it).
notes=$(awk -v v="**$version**" 'index($0, "- " v) == 1 {sub(/^- /, ""); out=$0; on=1; next} on && /^  /{sub(/^ +/, ""); out=out " " $0; next} on{exit} END{print out}' README.md)
if gh release view "v$version" --repo $repo >/dev/null 2>&1; then
  gh release upload "v$version" "$dmg" dist/Glyph-Cast.dmg --repo $repo --clobber
else
  gh release create "v$version" "$dmg" dist/Glyph-Cast.dmg --repo $repo --title "Glyph Cast $version" --notes "${notes:-Glyph Cast $version}"
fi
echo "released: https://github.com/$repo/releases/tag/v$version"
