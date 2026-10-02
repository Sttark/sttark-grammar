#!/bin/zsh
# Builds ClaudeGrammar, puts it in ~/Applications, starts it at login, and opens it.
set -e
cd "$(dirname "$0")"
./build.sh
pkill -x ClaudeGrammar 2>/dev/null || true
mkdir -p ~/Applications
rm -rf ~/Applications/ClaudeGrammar.app
cp -R build/ClaudeGrammar.app ~/Applications/
# a rebuilt app looks new to macOS, so an old Accessibility approval no longer applies
tccutil reset Accessibility com.sttark.claude-grammar >/dev/null 2>&1 || true
osascript -e 'tell application "System Events"
  if not (exists login item "ClaudeGrammar") then make login item at end with properties {path:(POSIX path of (path to home folder)) & "Applications/ClaudeGrammar.app", hidden:false}
end tell' >/dev/null
/System/Library/CoreServices/pbs -update   # make the right-click translate item show up right away
open ~/Applications/ClaudeGrammar.app
echo
echo "Installed. Two things to do:"
echo "  1. Allow ClaudeGrammar in System Settings > Privacy & Security > Accessibility."
echo "  2. Paste your Anthropic API key when it asks."
