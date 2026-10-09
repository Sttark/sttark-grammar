#!/bin/zsh
# Builds SttarkGrammar.app into ./build. Runs on Apple Silicon and Intel Macs, macOS 14 or later.
# The version is 1.<number of commits>, so every build of main is numbered higher than the last.
# It's signed with the Sttark Grammar Signing certificate when this Mac has it (GitHub's release builds do),
# which is what keeps the Accessibility permission on through updates. Without it the build is signed
# ad hoc and Accessibility has to be turned on again after each install.
set -e
cd "$(dirname "$0")"
command -v swiftc >/dev/null || { echo "Needs Apple's command line tools. Run: xcode-select --install"; exit 1; }
APP=build/SttarkGrammar.app
BUILD=${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 0)}
rm -rf build
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $arch-apple-macos14.0 Sources/*.swift -o build/SttarkGrammar-$arch
done
lipo -create build/SttarkGrammar-arm64 build/SttarkGrammar-x86_64 -output $APP/Contents/MacOS/SttarkGrammar
rm build/SttarkGrammar-arm64 build/SttarkGrammar-x86_64
cp Info.plist $APP/Contents/Info.plist
cp Resources/* $APP/Contents/Resources/
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" -c "Set :CFBundleShortVersionString 1.$BUILD" $APP/Contents/Info.plist
SIGN_ID=${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Sttark Grammar Signing"/ {print $2; exit}')}
if [[ -n $SIGN_ID ]]; then
  codesign --force --sign $SIGN_ID --identifier com.sttark.sttark-grammar $APP
else
  echo "No Sttark Grammar Signing certificate here, so this build is signed ad hoc."
  codesign --force --sign - --identifier com.sttark.sttark-grammar $APP
fi
echo "built $APP, version 1.$BUILD"
