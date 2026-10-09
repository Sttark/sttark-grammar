#!/bin/zsh
# Removes SttarkGrammar (and ClaudeGrammar, its old name): the app, its login item, saved API keys, settings, and dictionary.
pkill -x SttarkGrammar 2>/dev/null
pkill -x ClaudeGrammar 2>/dev/null
osascript -e 'tell application "System Events" to if exists login item "ClaudeGrammar" then delete login item "ClaudeGrammar"' >/dev/null 2>&1
for d in ~/Applications /Applications; do rm -rf $d/SttarkGrammar.app $d/ClaudeGrammar.app; done
security delete-generic-password -s claude-grammar -a anthropic-api-key >/dev/null 2>&1
security delete-generic-password -s claude-grammar -a openai-api-key >/dev/null 2>&1
defaults delete com.sttark.sttark-grammar >/dev/null 2>&1
defaults delete com.sttark.claude-grammar >/dev/null 2>&1
rm -rf ~/Library/Application\ Support/SttarkGrammar ~/Library/Application\ Support/ClaudeGrammar
tccutil reset Accessibility com.sttark.sttark-grammar >/dev/null 2>&1
tccutil reset Accessibility com.sttark.claude-grammar >/dev/null 2>&1
echo "Sttark Grammar removed."
