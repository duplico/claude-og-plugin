#!/usr/bin/env bash
# run-tests.sh -- execute the ACTUAL code blocks from SKILL.md against fixture repos.
#
# WHY THIS EXISTS
#   Three consecutive adversarial reviews of this skill found the same shape of bug:
#   THE CHECK THAT IS WRITTEN IS NOT THE CHECK THAT RUNS.
#     round 1: prose described checks; no code implemented them.
#     round 2: the redesign fixed the prose, not the code.
#     round 3: refresh-lib.sh implemented the checks correctly -- and SKILL.md's phases
#              never called it, still running the old buggy inline snippets. The skill
#              reported three EXISTING files as DANGLING on the maintainer's own repo.
#   Testing the library in isolation passes every time and catches none of that. This
#   harness extracts the bash from SKILL.md itself and runs it, so a phase that does not
#   call the library fails here.
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SKILL="$HERE/../SKILL.md"
LIB="$HERE/../refresh-lib.sh"
FIX="$HERE/fixtures"                 # static fixtures, committed
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT   # generated fixtures (incl. a git repo) -- NEVER committed
pass=0; fail=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n     %s\n' "$1" "$2"; fail=$((fail+1)); }

# --- 1. Every lib function the phases need must actually be CALLED by SKILL.md ---
# A function that appears only in the reference table is not wired in.
for fn in is_og_shaped subjects_of classify_path check_freshness migrate_rules; do
  # strip the reference table (lines starting with '|') before counting real uses
  n=$(grep -v '^|' "$SKILL" | grep -c "$fn" || true)
  if [ "$n" -ge 1 ]; then ok "SKILL.md calls $fn()"
  else bad "SKILL.md never calls $fn()" "it is implemented in refresh-lib.sh but no phase invokes it -- the phase is running its own inline copy"; fi
done

# --- 2. No phase may reimplement a check inline ---
if grep -qE '^\s*grep -oE .`\[\^`\]\+.' "$SKILL"; then
  bad "Phase 6 has an inline path-extraction snippet" "it must call classify_path()"
else ok "Phase 6 has no inline path classifier"; fi
if grep -q 'if \[ ! -d "\$MP/.git" \]; then' "$SKILL" || grep -q 'rev-parse origin/HEAD' "$SKILL"; then
  bad "Phase 1 has an inline freshness snippet" "it must call check_freshness()"
else ok "Phase 1 has no inline freshness check"; fi

# --- 3. Behavioural tests of the lib, against fixtures ---
. "$LIB"

t_rule() {  # name, fixture file, expected P
  local got; got=$(lowest_project_rule "$FIX/$2")
  [ "$got" = "$3" ] && ok "lowest_project_rule($2) = ${3:-<empty>}" \
    || bad "lowest_project_rule($2)" "expected '${3:-<empty>}', got '${got:-<empty>}'"
}
t_rule "plain"        overlay-plain.md        12
t_rule "fenced block" overlay-fenced.md       12   # a ```1. bump``` inside the section must NOT win
t_rule "nested list"  overlay-nested.md       12
t_rule "no rules"     overlay-norules.md      ""   # must be empty, not 1
t_rule "collision"    overlay-collision.md    11

t_path() {  # path, subject, expected
  local got; got=$(classify_path "$2" "$3")
  case "$got" in "$4"*) ok "classify_path($2) -> $4" ;;
    *) bad "classify_path($2)" "expected $4, got '$got'" ;; esac
}
mkdir -p "$TMP/subj/scripts" "$TMP/subj/src/present"; : > "$TMP/subj/scripts/real.sh"
t_path a "./scripts/real.sh"        "$TMP/subj" OK
t_path b "scripts/nope.sh"          "$TMP/subj" DANGLING       # missing file, dir present
t_path c "src/present/gone.py"      "$TMP/subj" DANGLING       # missing file inside a PRESENT dir
t_path d "anything.md"             "$TMP/NO_SUCH_SUBJECT" UNVERIF   # subject repo absent -> cannot see
t_path e "terraform/**/*.tf"        "$TMP/subj" SKIP
# workspace-relative reference: not under the subject, but present at ROOT -> OK, not DANGLING
mkdir -p "$TMP/wsroot/docs"; : > "$TMP/wsroot/docs/shared.md"; mkdir -p "$TMP/wsroot/subj"
got=$(classify_path "docs/shared.md" "$TMP/wsroot/subj" "$TMP/wsroot")
[ "$got" = "OK" ] && ok "classify_path(workspace-relative) -> OK" \
  || bad "classify_path(workspace-relative)" "expected OK (present at ROOT), got '$got'"
# and Phase 0 must accept rc=2 (provisional), not treat it as a failure
grep -q 'rc" -eq 1' "$SKILL" && ok "Phase 0 treats rc=2 (provisional) as usable" \
  || bad "Phase 0 rejects provisional subjects" "|| after subjects_of drops every single-repo project"

t_shape() { is_og_shaped "$TMP/$1" && r=og || r=legacy
  [ "$r" = "$2" ] && ok "is_og_shaped($1) = $2" || bad "is_og_shaped($1)" "expected $2, got $r"; }
mkdir -p "$TMP/shape-og" "$TMP/shape-legacy"
printf 'Adopt the `og:orchestrate` role\n' > "$TMP/shape-og/SKILL.md"
printf 'See the Changelog: `docs/CHANGELOG.md`\n' > "$TMP/shape-legacy/SKILL.md"
t_shape shape-og og
t_shape shape-legacy legacy

# root-repo overlay must resolve to '.', not UNRESOLVED
t_subj_root() {
  local d="$TMP/rootrepo"; mkdir -p "$d/.claude/skills/rootrepo-orchestrator"
  ( cd "$d" && git init -q )
  printf 'og:orchestrate\n## Project Rules\n12. x\n' > "$d/.claude/skills/rootrepo-orchestrator/SKILL.md"
  local out; out=$(subjects_of "$d/.claude/skills/rootrepo-orchestrator" "$d"); local rc=$?
  local path; path=$(printf '%s' "$out" | cut -f1)
  if [ "$rc" -ne 1 ] && [ "$path" = "." ]; then ok "subjects_of(root-repo overlay) -> '.'"
  else bad "subjects_of(root-repo overlay)" "expected '.', got rc=$rc path='${path:-<none>}' -- a single-repo project would be SKIPPED ENTIRELY"; fi
}
t_subj_root

# --- migration ---
OGDIR=$(jq -r '.plugins | to_entries[] | select(.key|startswith("og@")) | .value[0].installPath' \
        "$HOME/.claude/plugins/installed_plugins.json" | head -1)
M="$TMP/mig-orchestrator"; mkdir -p "$M"
cat > "$M/SKILL.md" <<'EOF'
## Subject repos

| Path | Prefix | Slug | Default branch |
|---|---|---|---|
| `.` | THING | o/thing | `main` |

## Project Rules (12+)

12. **First.** See Rule 13.
13. **Second.** Required by Rule 2.
14. **Third.** Legacy pointer to Rule 99.

## Next
EOF
out=$(migrate_rules "$M" "$OGDIR" --apply 2>&1)
body=$(sed -n '/^## Project Rules/,/^## Next/p' "$M/SKILL.md")
grep -q 'THING-1\. \*\*First' <<<"$body" && ok "migrate: rules renumbered to PREFIX-1" || bad "migrate: rules" "$body"
grep -q 'See THING-2' <<<"$body"          && ok "migrate: own-rule citation -> THING-2"  || bad "migrate: own citation" "$body"
grep -q 'Required by OG-2' <<<"$body"     && ok "migrate: universal citation -> OG-2"    || bad "migrate: universal citation" "$body"
grep -q 'pointer to Rule 99' <<<"$body"   && ok "migrate: ambiguous citation LEFT ALONE" || bad "migrate: ambiguous" "must not be rewritten"
grep -q 'AMBIGUOUS' <<<"$out"             && ok "migrate: ambiguous citation FLAGGED"    || bad "migrate: ambiguous flag" "$out"
grep -q '^## Project Rules$' <<<"$body"   && ok "migrate: (12+) header range removed"    || bad "migrate: header" "$body"
# must FATAL, not guess, when og's range is unreadable
fat=$(migrate_rules "$M" /nonexistent --dry 2>/dev/null || true)
grep -q FATAL <<<"$fat" \
  && ok "migrate: FATALs on unreadable og range" || bad "migrate: unreadable og" "must refuse, not misclassify"
# must FATAL when no prefix is declared
N="$TMP/noprefix-orchestrator"; mkdir -p "$N"; printf '## Project Rules\n12. **x**\n' > "$N/SKILL.md"
fat=$(migrate_rules "$N" "$OGDIR" --dry 2>/dev/null || true)
grep -q FATAL <<<"$fat" \
  && ok "migrate: FATALs when no Prefix declared" || bad "migrate: no prefix" "must refuse, not invent one"

echo
printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
