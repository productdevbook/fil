#!/bin/zsh
# Build, sign and notarize the fil CLI, and write the release tarball to dist/.
#
#   scripts/release.sh 0.1.0
#
# Needs a "Developer ID Application" identity in the keychain and notary credentials: either an
# App Store Connect API key (FIL_NOTARY_KEY = path to the .p8, FIL_NOTARY_KEY_ID, FIL_NOTARY_ISSUER),
# as in .github/workflows/release.yml, or a notarytool keychain profile (FIL_NOTARY_PROFILE,
# default "fil-notary"), created once with `xcrun notarytool store-credentials`.
# Publishing (GitHub release, Homebrew cask) is done by the release workflow.
set -euo pipefail

VERSION=${1:?usage: scripts/release.sh <version>}
if [[ -n ${FIL_NOTARY_KEY:-} ]]; then
  NOTARY_AUTH=(--key $FIL_NOTARY_KEY --key-id ${FIL_NOTARY_KEY_ID:?} --issuer ${FIL_NOTARY_ISSUER:?})
else
  NOTARY_AUTH=(--keychain-profile ${FIL_NOTARY_PROFILE:-fil-notary})
fi
ROOT=${0:A:h:h}
DIST=$ROOT/dist
NAME=fil-$VERSION-arm64

cd $ROOT
grep -q "^let version = \"$VERSION\"$" Sources/fil/main.swift \
  || { echo "Sources/fil/main.swift does not declare version $VERSION" >&2; exit 1; }
[[ -z $(git status --porcelain) ]] || { echo "working tree is not clean" >&2; exit 1; }

# The same certificate can appear several times in the keychain list; sign by its hash.
IDENTITY=${FIL_SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | awk '/"Developer ID Application/ { print $2; exit }')}
[[ -n $IDENTITY ]] || { echo "no Developer ID Application identity found" >&2; exit 1; }

swift build -c release --arch arm64
BIN=$(swift build -c release --arch arm64 --show-bin-path)/fil

rm -rf $DIST/$NAME && mkdir -p $DIST/$NAME
cp $BIN $DIST/$NAME/fil
codesign --force --options runtime --timestamp --sign $IDENTITY \
  --identifier com.productdevbook.fil $DIST/$NAME/fil
codesign --verify --strict --verbose=2 $DIST/$NAME/fil
[[ $($DIST/$NAME/fil --version) == "fil $VERSION" ]] || { echo "version check failed" >&2; exit 1; }

# notarytool takes a zip; a bare Mach-O cannot be stapled, Gatekeeper checks the ticket online.
ditto -c -k $DIST/$NAME/fil $DIST/$NAME.zip
xcrun notarytool submit $DIST/$NAME.zip "${NOTARY_AUTH[@]}" --wait
rm $DIST/$NAME.zip

# "Accepted" comes minutes before Gatekeeper's online lookup finds the ticket; a release published
# earlier is killed on first run. Wait until the ticket is visible.
for i in {1..40}; do
  codesign -v --check-notarization -R=notarized $DIST/$NAME/fil 2>/dev/null && break
  (( i == 40 )) && { echo "notarization ticket not visible after 20 minutes" >&2; exit 1; }
  sleep 30
done

tar -C $DIST/$NAME -czf $DIST/$NAME.tar.gz fil
shasum -a 256 $DIST/$NAME.tar.gz | tee $DIST/$NAME.tar.gz.sha256
