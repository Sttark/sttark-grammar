#!/bin/zsh
# Builds ClaudeGrammar.app into ./build. Runs on Apple Silicon and Intel Macs, macOS 14 or later.
set -e
cd "$(dirname "$0")"
command -v swiftc >/dev/null || { echo "Needs Apple's command line tools. Run: xcode-select --install"; exit 1; }
APP=build/ClaudeGrammar.app
rm -rf build
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $arch-apple-macos14.0 Sources/*.swift -o build/ClaudeGrammar-$arch
done
lipo -create build/ClaudeGrammar-arm64 build/ClaudeGrammar-x86_64 -output $APP/Contents/MacOS/ClaudeGrammar
rm build/ClaudeGrammar-arm64 build/ClaudeGrammar-x86_64
cp Info.plist $APP/Contents/Info.plist
codesign --force --sign - --identifier com.sttark.claude-grammar $APP
echo "built $APP"
