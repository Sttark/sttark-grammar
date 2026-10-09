#!/bin/zsh
# Builds SttarkGrammar from this folder, puts it in ~/Applications and opens it. It sets itself to start at login.
# Most people don't need this: download the app from the Releases page instead, and it updates itself.
set -e
cd "$(dirname "$0")"
./build.sh
pkill -x SttarkGrammar 2>/dev/null || true
# the app's old name, ClaudeGrammar: settings, dictionary and keys carry over on first run
pkill -x ClaudeGrammar 2>/dev/null || true
osascript -e 'tell application "System Events" to if exists login item "ClaudeGrammar" then delete login item "ClaudeGrammar"' >/dev/null 2>&1 || true
rm -rf ~/Applications/ClaudeGrammar.app
mkdir -p ~/Applications
rm -rf ~/Applications/SttarkGrammar.app
cp -R build/SttarkGrammar.app ~/Applications/
# an ad hoc build looks new to macOS every time, so its old Accessibility approval no longer applies
if codesign -dr- ~/Applications/SttarkGrammar.app 2>&1 | grep -q cdhash; then
  tccutil reset Accessibility com.sttark.sttark-grammar >/dev/null 2>&1 || true
fi
/System/Library/CoreServices/pbs -update   # make the right-click translate item show up right away
open ~/Applications/SttarkGrammar.app
echo
echo "Installed. If it asks, allow Sttark Grammar in System Settings > Privacy & Security > Accessibility,"
echo "and paste the Anthropic and OpenAI keys you got from DT."
