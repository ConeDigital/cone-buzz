#!/usr/bin/env bash
# The rebrand's mutation test (cone-buzz-infra Slice 36, criterion 1): each
# planted change must make `cone/rebrand.sh check` fail with the diagnostic
# that guard emits, naming the planted path.
#
#   bash cone/rebrand-test.sh        (from the repository root, hermit active)
#
# Every case runs in a disposable worktree at HEAD where the plant is
# COMMITTED (review of ConeDigital/cone-buzz#8: an uncommitted plant was
# refused by the dirty-tree guard, which named the path too, so the intended
# guard was never exercised). The worktree borrows this checkout's
# node_modules. The last two cases test the bundle gate on a built asset and
# need no snapshot.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"

pass=0; fail=0
snapshot() { # prints the path of a fresh committed worktree at HEAD
  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cone-rebrand-test.XXXXXX")"
  git worktree add -q --detach "$tmp" HEAD
  ln -s "$ROOT/node_modules" "$tmp/node_modules"
  ln -s "$ROOT/desktop/node_modules" "$tmp/desktop/node_modules"
  printf '/node_modules\n/desktop/node_modules\n' >> "$(git -C "$tmp" rev-parse --git-path info/exclude)"
  echo "$tmp"
}
drop() { git worktree remove --force "$1" >/dev/null 2>&1 || true; }

# case_ <name> <path that must be named> <diagnostic that must appear> <plant function>
case_() {
  local name="$1" want_path="$2" want_diag="$3" plant="$4" tmp out
  tmp="$(snapshot)"
  ( cd "$tmp" && "$plant" && git add -A && git -c user.name=test -c user.email=test@cone.digital commit -q -m "plant: $name" )
  if out="$( cd "$tmp" && cone/rebrand.sh check 2>&1 )"; then
    echo "FAIL $name: the check passed"; fail=$((fail + 1))
  elif grep -qF "is not clean" <<<"$out"; then
    echo "FAIL $name: refused as dirty instead of judged"; fail=$((fail + 1))
  elif ! grep -qF "$want_path" <<<"$out" || ! grep -qF "$want_diag" <<<"$out"; then
    echo "FAIL $name: failed without '$want_diag' on $want_path"; echo "$out" | tail -4; fail=$((fail + 1))
  else
    echo "ok   $name"; pass=$((pass + 1))
  fi
  drop "$tmp"
}

# 1. an extra "Buzz" string in a listed file: the count moves
p1() { printf '\nexport const PLANTED_ONE = "Planted Buzz string";\n' >> desktop/src/features/settings/ui/VoiceSettingsCard.tsx; }
case_ "extra Buzz string in a listed file" desktop/src/features/settings/ui/VoiceSettingsCard.tsx "in string text, strings.tsv says" p1

# 2. a "Block …" string in a listed file: the count is unchanged, the scan must see it
p2() { printf '\nexport const PLANTED_TWO = "Block built this";\n' >> desktop/src/features/settings/ui/VoiceSettingsCard.tsx; }
case_ "Block string in a listed file" desktop/src/features/settings/ui/VoiceSettingsCard.tsx "rebrand scan: desktop/src/features/settings/ui/VoiceSettingsCard.tsx" p2

# 3. a "Buzz" string in an unlisted file
p3() { printf '\nexport const PLANTED_THREE = "Buzz here";\n' >> desktop/src/shared/lib/cn.ts; }
case_ "Buzz string in an unlisted file" desktop/src/shared/lib/cn.ts "strings.tsv says 0" p3

# 4. a line in an embedded template
p4() { printf '\nPlanted: the Buzz CLI again.\n' >> desktop/src-tauri/src/managed_agents/nest_skill.md; }
case_ "line in an embedded template" desktop/src-tauri/src/managed_agents/nest_skill.md "in string text, strings.tsv says" p4

# 5. a motif word
p5() { printf '\nexport const PLANTED_FIVE = "a honeycomb background";\n' >> desktop/src/shared/lib/cn.ts; }
case_ "honeycomb string" desktop/src/shared/lib/cn.ts "honeycomb" p5

# 6. a lines.tsv row whose upstream text was edited
p6() { sed -i '' 's/const DEFAULT_ACCENT = "#3b82f6";/const DEFAULT_ACCENT = "#3b82f7";/' desktop/src/shared/theme/ThemeProvider.tsx; }
case_ "edited lines.tsv target" desktop/src/shared/theme/ThemeProvider.tsx "found 0 times, expected 1" p6

# 7. a deleted replacement target
p7() { rm desktop/src/features/onboarding/ui/LandingBees.tsx; }
case_ "deleted replacement target" desktop/src/features/onboarding/ui/LandingBees.tsx "replacement target missing upstream" p7

# 8. a replacement whose upstream content was edited: the hash moves
p8() { printf '\n// upstream edited this file\n' >> desktop/src/shared/ui/buzz-logo/BuzzMark.tsx; }
case_ "edited replacement upstream" desktop/src/shared/ui/buzz-logo/BuzzMark.tsx "upstream content changed" p8

# 9. a block whose upstream text moved
p9() { sed -i '' 's/const SAMPLES_PER_AXIS: u32 = 4;/const SAMPLES_PER_AXIS: u32 = 8;/' desktop/src-tauri/src/tray_menu.rs; }
case_ "edited block target" desktop/src-tauri/src/tray_menu.rs "block tray-icon found 0 times" p9

# 10. a new include_str! source with the word
p10() { printf '\nconst PLANTED_TEN: &str = include_str!("planted.md");\n' >> desktop/src-tauri/src/managed_agents/nest.rs; printf '# Buzz planted\n' > desktop/src-tauri/src/managed_agents/planted.md; }
case_ "new embedded template" desktop/src-tauri/src/managed_agents/planted.md "strings.tsv says 0" p10

# 11. a block for a Rust file that would end a r#"…"# raw string (the hex-colour trap of merge 1)
p11() { printf '%s\n' '<stop stop-color="#78206a"/>' >> cone/rebrand/blocks/builderlab-mark.new; }
case_ "raw-string terminator in a block" desktop/src-tauri/src/builderlab.rs "ends a Rust r#" p11

# 12–13. the bundle gate, on a built asset (no snapshot: bundle-scan reads dist only)
mkdir -p desktop/dist/assets && printf 'const x={isBuzzHost:1,fooBuzzBar:2};\n' > desktop/dist/assets/planted-test.js
if out="$(cone/rebrand.sh bundle-scan 2>&1)"; then echo "FAIL bundle identifier outside the allowlist: passed"; fail=$((fail + 1));
elif ! grep -qF "'fooBuzzBar'" <<<"$out"; then echo "FAIL bundle identifier outside the allowlist: not named"; fail=$((fail + 1));
else echo "ok   bundle identifier outside the allowlist"; pass=$((pass + 1)); fi
printf 'const y="Hello Buzz";\n' > desktop/dist/assets/planted-test.js
if out="$(cone/rebrand.sh bundle-scan 2>&1)"; then echo "FAIL whole word in the bundle: passed"; fail=$((fail + 1));
elif ! grep -qF "the word Buzz 1 time(s)" <<<"$out"; then echo "FAIL whole word in the bundle: wrong diagnostic"; fail=$((fail + 1));
else echo "ok   whole word in the bundle"; pass=$((pass + 1)); fi
rm -f desktop/dist/assets/planted-test.js

echo "rebrand-test: $pass passed, $fail failed"
(( fail == 0 ))
