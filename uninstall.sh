#!/bin/zsh
# Removes ClaudeGrammar: the app, its login item, saved API key, settings, and dictionary.
pkill -x ClaudeGrammar 2>/dev/null
osascript -e 'tell application "System Events" to if exists login item "ClaudeGrammar" then delete login item "ClaudeGrammar"' >/dev/null 2>&1
rm -rf ~/Applications/ClaudeGrammar.app
security delete-generic-password -s claude-grammar -a anthropic-api-key >/dev/null 2>&1
defaults delete com.sttark.claude-grammar >/dev/null 2>&1
rm -rf ~/Library/Application\ Support/ClaudeGrammar
tccutil reset Accessibility com.sttark.claude-grammar >/dev/null 2>&1
echo "ClaudeGrammar removed."
