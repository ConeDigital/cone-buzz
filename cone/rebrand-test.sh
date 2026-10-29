#!/usr/bin/env bash
# The rebrand's mutation test (cone-buzz-infra Slice 36, criterion 1): each
# planted change must make `cone/rebrand.sh check` fail naming the path.
#
#   bash cone/rebrand-test.sh        (from the repository root, hermit active, tree clean)
#
# Every case plants one change into the working tree, runs the check, expects
# a failure that names the planted path, and restores the tree with git.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

dirty="$(git status --porcelain --untracked-files=all -- desktop/ | sed '/^$/d' || true)"
[[ -z "$dirty" ]] || { echo "rebrand-test: desktop/ is not clean" >&2; exit 1; }

pass=0; fail=0
expect_fail() { # <name> <path that must be named> — the tree holds the plant
  local name="$1" want="$2" out
  if out="$(cone/rebrand.sh check 2>&1)"; then
    echo "FAIL $name: the check passed"; fail=$((fail + 1))
  elif ! grep -qF "$want" <<<"$out"; then
    echo "FAIL $name: the check failed without naming $want"; echo "$out" | tail -5; fail=$((fail + 1))
  else
    echo "ok   $name"; pass=$((pass + 1))
  fi
  git checkout --quiet -- desktop/
  git clean --quiet -fd -- desktop/src desktop/public desktop/src-tauri/src desktop/src-tauri/assets
}

# 1. an extra "Buzz" string in a listed file (the count moves)
f=desktop/src/features/settings/ui/VoiceSettingsCard.tsx
printf '\nexport const PLANTED_ONE = "Planted Buzz string";\n' >> "$f"
expect_fail "extra Buzz string in a listed file" "$f"

# 2. a "Block …" string in a listed file (the count is unchanged; the scan must see it)
f=desktop/src/features/settings/ui/VoiceSettingsCard.tsx
printf '\nexport const PLANTED_TWO = "Block built this";\n' >> "$f"
expect_fail "Block string in a listed file" "$f"

# 3. a "Buzz" string in an unlisted file
f=desktop/src/shared/lib/cn.ts
printf '\nexport const PLANTED_THREE = "Buzz here";\n' >> "$f"
expect_fail "Buzz string in an unlisted file" "$f"

# 4. a line in an embedded template
f=desktop/src-tauri/src/managed_agents/nest_skill.md
printf '\nPlanted: the Buzz CLI again.\n' >> "$f"
expect_fail "line in an embedded template" "$f"

# 5. a motif word
f=desktop/src/shared/lib/cn.ts
printf '\nexport const PLANTED_FIVE = "a honeycomb background";\n' >> "$f"
expect_fail "honeycomb string" "$f"

# 6. a lines.tsv row whose upstream text was edited
f=desktop/src/shared/theme/ThemeProvider.tsx
sed -i '' 's/const DEFAULT_ACCENT = "#3b82f6";/const DEFAULT_ACCENT = "#3b82f7";/' "$f"
expect_fail "edited lines.tsv target" "$f"

# 7. a deleted replacement target
f=desktop/src/features/onboarding/ui/LandingBees.tsx
rm "$f"
expect_fail "deleted replacement target" "$f"

# 8. a replacement whose upstream content was edited (the hash moves)
f=desktop/src/shared/ui/buzz-logo/BuzzMark.tsx
printf '\n// upstream edited this file\n' >> "$f"
expect_fail "edited replacement upstream" "$f"

# 9. a block whose upstream text moved
f=desktop/src-tauri/src/tray_menu.rs
sed -i '' 's/const SAMPLES_PER_AXIS: u32 = 4;/const SAMPLES_PER_AXIS: u32 = 8;/' "$f"
expect_fail "edited block target" "$f"

# 10. a new include_str! source with the word
f=desktop/src-tauri/src/managed_agents/nest.rs
printf '\nconst PLANTED_TEN: &str = include_str!("planted.md");\n' >> "$f"
printf '# Buzz planted\n' > desktop/src-tauri/src/managed_agents/planted.md
expect_fail "new embedded template" "desktop/src-tauri/src/managed_agents/planted.md"

# 11. a block for a Rust file that would end a r#"…"# raw string (the hex-colour trap of merge 1)
cp cone/rebrand/blocks/builderlab-mark.new /tmp/rebrand-test-block.bak
printf '%s\n' '<stop stop-color="#78206a"/>' >> cone/rebrand/blocks/builderlab-mark.new
if out="$(cone/rebrand.sh check 2>&1)"; then echo "FAIL raw-string terminator in a block: the check passed"; fail=$((fail + 1));
elif ! grep -qF 'desktop/src-tauri/src/builderlab.rs' <<<"$out"; then echo "FAIL raw-string terminator in a block: not named"; fail=$((fail + 1));
else echo "ok   raw-string terminator in a block"; pass=$((pass + 1)); fi
mv /tmp/rebrand-test-block.bak cone/rebrand/blocks/builderlab-mark.new
git checkout --quiet -- desktop/

echo "rebrand-test: $pass passed, $fail failed"
(( fail == 0 ))
