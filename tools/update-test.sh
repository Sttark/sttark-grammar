#!/bin/zsh
# Tests the update that installs by itself, with the real Sources/Update.swift in a stand-in app
# (tools/update-test/main.swift) that has its own ID and settings, in a temporary folder.
# The installed app, its settings, dictionary, keys and log are not touched, and nothing is published.
# It runs three cases against a fake release on disk:
#   1. a newer version, while the menu is "open" for 5 s: it waits, then installs and restarts with no notice
#   2. a newer version that isn't signed like this app: it fails with a notice and no dialog,
#      and a second check doesn't try that version again
#   3. the same version as this one: nothing happens
set -u
cd "$(dirname "$0")/.."
T=$(mktemp -d)
ID=com.sttark.grammar-update-test
pass=0; fail=0
ok() { if eval "$2"; then echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1"; fail=$((fail+1)); fi }

swiftc -O -swift-version 5 Sources/Update.swift tools/update-test/main.swift -o $T/bin || exit 1

# make <folder> <build> <id>: a stand-in SttarkGrammar.app with that build number, ad hoc signed with that ID
make() {
  local A=$1/SttarkGrammar.app
  mkdir -p $A/Contents/MacOS && cp $T/bin $A/Contents/MacOS/SttarkGrammar
  cat > $A/Contents/Info.plist <<P
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$3</string><key>CFBundleExecutable</key><string>SttarkGrammar</string>
<key>CFBundleVersion</key><string>$2</string><key>CFBundleShortVersionString</key><string>1.$2</string>
<key>LSUIElement</key><true/></dict></plist>
P
  codesign --force --sign - --identifier $3 $A 2>/dev/null
}
# release <name> <build> <id>: a zip and a feed file like GitHub's latest-release answer
release() {
  make $T/$1 $2 $3
  (cd $T/$1 && ditto -c -k --keepParent SttarkGrammar.app $T/$1.zip)
  echo "{\"tag_name\":\"v1.$2\",\"assets\":[{\"name\":\"SttarkGrammar.zip\",\"browser_download_url\":\"file://$T/$1.zip\"}]}" > $T/$1.json
}
# run <case> <feed> [extra json]: start build 1 in its own folder and wait for it (and any restart) to exit
run() {
  defaults delete $ID >/dev/null 2>&1
  local R=$T/run-$1; mkdir -p $R; make $R 1 $ID
  echo "{\"feed\":\"file://$T/$2.json\",\"log\":\"$R/log\",\"exitAfter\":15${3:-}}" > $R/test.json
  [[ $1 == 1 ]] && { touch $R/busy; (sleep 5; rm $R/busy) & }
  $R/SttarkGrammar.app/Contents/MacOS/SttarkGrammar &
  wait $!
  # case 1 restarts through `open`, so wait for the new copy to finish too
  [[ $1 == 1 ]] && for i in {1..60}; do grep -q "exit 1.2" $R/log && break; sleep 0.5; done
  echo "--- case $1 log"; cut -d' ' -f2- $R/log
}

release new 2 $ID
release foreign 2 com.example.not-sttark
release same 1 $ID

run 1 new
L=$T/run-1/log
ok "1: waits while the menu is open" '[[ $(( $(awk "/downloading/{print int(\$1);exit}" $L) - $(awk "/started 1.1/{print int(\$1);exit}" $L) )) -ge 4 ]]'
ok "1: installs by itself" 'grep -q "update: downloading 1.2 by itself" $L && grep -q "update: installed 1.2, restarting" $L'
ok "1: the new version starts" 'grep -q "started 1.2" $L'
ok "1: no notice" '! grep -q notice: $L'

run 2 foreign ',"recheck":4'
L=$T/run-2/log
ok "2: fails without a dialog" 'grep -q "update failed: The download isn.t signed by Sttark" $L && grep -q "exit 1.1" $L'
ok "2: one notice" '[[ $(grep -c "notice: Sttark Grammar 1.2 didn.t install" $L) == 1 ]]'
ok "2: no second try" 'grep -q "check again" $L && [[ $(grep -c "downloading" $L) == 1 ]]'
ok "2: still the old version" '[[ $(defaults read $T/run-2/SttarkGrammar.app/Contents/Info CFBundleVersion) == 1 ]]'

run 3 same
L=$T/run-3/log
ok "3: same version does nothing" '! grep -q downloading $L && grep -q "exit 1.1" $L'

defaults delete $ID >/dev/null 2>&1
for a in $T/*/SttarkGrammar.app; do /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u $a 2>/dev/null; done
rm -rf $T
echo "$pass passed, $fail failed"
[[ $fail == 0 ]]
