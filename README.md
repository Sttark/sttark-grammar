# ClaudeGrammar

A Mac menu bar app that checks your spelling and grammar as you type, in any app, using Claude. It works like Grammarly: mistakes get underlined, you hover one to see the fix, and you click it or press Tab to take it.

- Red underline: spelling
- Amber underline: grammar
- Blue underline: capitals

![ClaudeGrammar underlining mistakes in TextEdit, with the hover card open](screenshot.png)

## Install

You need a Mac on macOS 14 or later, and your own Anthropic API key.

1. Install Apple's command line tools if you don't have them. In Terminal:
   ```
   xcode-select --install
   ```
2. Download, build and install:
   ```
   gh repo clone Sttark/claude-grammar ~/claude-grammar
   ~/claude-grammar/install.sh
   ```
   This puts the app in `~/Applications`, sets it to start when you log in, and opens it.
3. macOS asks you to allow ClaudeGrammar under **System Settings > Privacy & Security > Accessibility**. Turn it on. The app can't see what you type until you do.
4. Paste your Anthropic API key when the app asks. Get a key at [console.anthropic.com](https://console.anthropic.com). It's saved in your Mac's Keychain.

The app is also attached to each [release](https://github.com/Sttark/claude-grammar/releases) as a zip. Because the app isn't signed with an Apple developer account, macOS blocks a downloaded copy the first time you open it. To allow it, go to **System Settings > Privacy & Security** and click **Open Anyway**. Building with `install.sh` avoids that.

## Using it

- Type anywhere. About 3 seconds after you pause, mistakes get underlined.
- Hover an underline to see the fix. Click the blue fix, or press **Tab**, to take it. **Esc** ignores it.
- **Add to dictionary** stops a word from being flagged. Use it for names and jargon.
- The badge in the corner of the text box shows how many mistakes there are. Click it to fix them all.
- **Control-Option-F** fixes the paragraph you're in.

### Translate to Chinese

Select any text, right-click, and choose **Translate to Chinese with Claude**. On some Macs it's inside a **Services** submenu at the bottom of the right-click menu. About 4 seconds later a card next to the mouse shows:
- the Chinese
- an English translation of that Chinese, so you can check it says what you meant

The Chinese is copied, so you can paste it straight away. If the text you selected can be edited, **Replace selection** swaps it for the Chinese. Select Chinese text and you get English instead.

Translation uses Claude Opus 5, which wrote more natural Chinese than Haiku in testing. It costs about 1 cent for a short message.

The menu bar icon (an I-beam cursor) has:
- On/off
- Skip the app you're in
- Pause for 1 hour
- Model choice
- Today's checks and cost
- Your dictionary
- Change API key

Terminal, iTerm2, Ghostty, Warp, 1Password and Keychain Access are skipped from the start. Password fields are never readable by any app, and search boxes are skipped.

## Cost and privacy

Each paragraph you write is sent to Claude through Anthropic's API, billed to your API key. With the default model (Claude Haiku 4.5), one check costs about $0.003. A heavy day of typing comes to around 30 to 50 cents. The menu shows today's total.

The text goes to Anthropic and nowhere else. The app keeps no copy of it on disk. Results are remembered in memory until the app quits, so unchanged paragraphs aren't sent twice.

## Troubleshooting

- **Nothing gets underlined.** Make sure ClaudeGrammar is on in System Settings > Privacy & Security > Accessibility. A triangle in the menu bar icon means it's missing that permission or a key.
- **It worked, then stopped after an update.** Reinstalling makes macOS treat the app as new, so its Accessibility permission has to be turned on again.
- **Underlines in the wrong place, or none in one app.** Some apps don't tell other apps where their text sits on screen. Use Skip in the menu for that app.
- **Red dotted underlines that aren't from ClaudeGrammar.** Chrome and the Claude app have their own spell checkers. Chrome's is under Settings > Languages > Spell check.

## Update

```
cd ~/claude-grammar && git pull && ./install.sh
```

Turn Accessibility back on afterward (see Troubleshooting).

## Uninstall

```
~/claude-grammar/uninstall.sh
```

This removes the app, the login item, your saved key, settings, and dictionary.

## How it works

1. Every 0.12 s the app reads the focused text box through the macOS Accessibility API.
2. When you stop typing for 1.2 s, each changed paragraph of 3+ words goes to Claude. Claude sends back a corrected copy plus a short reason for each change. The Mac's built-in spell checker also checks every word Claude left alone. That catches made-up typos like "somnerhqw" that Claude has no fix for. Capitalized words mid-sentence are skipped as likely names.
3. The app compares your text with the corrected copy word by word to get exact positions. A transparent overlay draws the underlines. Chrome-based apps (the Claude app, Slack, web pages) return an empty box when asked where a range of their text sits on screen. For those, the app asks each run of text inside the box instead.
4. Fixes go in through the Accessibility API. Apps that ignore it get the fix pasted over a selection, and the clipboard is restored afterward. If the app won't let the word be selected, the fix is skipped instead of pasted.

On a test paragraph with 12 mistakes, Haiku 4.5 caught 11 or 12 in about 3 s. Sonnet 5 (in the menu) took about 4.5 s, cost twice as much, and caught 8 to 11.

### Files

- `Sources/AX.swift`: Accessibility API helpers (focused text box, where text sits on screen, edits)
- `Sources/Checker.swift`: Claude request, prompt, API key storage, and the word-by-word comparison
- `Sources/Controller.swift`: main loop, underline layout, hover card, fixes, keys, menu
- `Sources/UI.swift`: underline overlay, hover card, badge
- `Sources/Translate.swift`: the right-click translate item and its card. It's declared under `NSServices` in `Info.plist`.
- `build.sh`: builds `build/ClaudeGrammar.app` for Apple Silicon and Intel
- `install.sh`, `uninstall.sh`
- `mockup.html`: the original design mockup

Settings: `defaults read com.sttark.claude-grammar`. Dictionary: `~/Library/Application Support/ClaudeGrammar/dictionary.txt`. Key: Keychain item `claude-grammar` / `anthropic-api-key`. An `ANTHROPIC_API_KEY` environment variable takes priority over the Keychain.

Debug log: `open -a ~/Applications/ClaudeGrammar.app --env CG_DEBUG=1 --stderr /tmp/claude-grammar.log`. The log includes the start of each paragraph checked, so delete it when you're done.
