#!/usr/bin/env bash
# run-tests.sh -- guard against the one bug this skill keeps having.
#
# THREE adversarial execution rounds all found the same shape:
#   THE CHECK THAT IS WRITTEN IS NOT THE CHECK THAT RUNS.
#     round 1: prose described checks; no code implemented them.
#     round 2: the redesign fixed the prose, not the code.
#     round 3: refresh-lib.sh implemented every check correctly -- and SKILL.md's phases never
#              CALLED it, still running old buggy inline copies. Three EXISTING files were
#              reported as DANGLING on the maintainer's own repo.
#
# So this harness does two things:
#   1. WIRING -- parse SKILL.md and assert each phase actually CALLS the library function it
#      is supposed to (a call inside a fenced bash block; a mere mention in prose does NOT
#      count). This is what catches "implemented but never wired in".
#   2. BEHAVIOUR -- exercise refresh-lib.sh's functions against fixtures, including the
#      hostile cases (fenced code blocks inside a rules section, absent subject repos,
#      ambiguous citations, unreadable plugin).
#
# It does NOT execute SKILL.md's phases end-to-end -- those mutate repos and call the network.
# Live end-to-end runs are done by hand against throwaway worktrees.

set -uo pipefail
command -v jq >/dev/null || { echo "FATAL: jq is required to run these tests" >&2; exit 1; }
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SKILL="$HERE/../SKILL.md"
LIB="$HERE/../refresh-lib.sh"
FIX="$HERE/fixtures"                 # static fixtures, committed
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT   # generated fixtures (incl. a git repo) -- NEVER committed
pass=0; fail=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n     %s\n' "$1" "$2"; fail=$((fail+1)); }

# --- 1. Every lib function the phases need must actually be CALLED by SKILL.md ---
#
# A mention in prose is NOT a call. Counting bare occurrences means a function that is only
# *described* passes -- which is precisely the vacuous-pass this harness exists to prevent.
# So: look for a call-shaped use INSIDE a fenced code block.
calls_in_fence() {   # $1 = function name -> prints the number of call-shaped uses in fences
  awk -v fn="$1" '
    /^```/ { fence = !fence; next }
    !fence { next }
    $0 ~ ("(^|[^A-Za-z0-9_])" fn "([ \t]|$)") { n++ }
    END { print n+0 }
  ' "$SKILL"
}
for fn in is_og_shaped subjects_of classify_path check_freshness migrate_rules; do
  n=$(calls_in_fence "$fn")
  if [ "$n" -ge 1 ]; then ok "SKILL.md CALLS $fn() ($n use(s) in code)"
  else bad "SKILL.md never CALLS $fn()" "it is implemented in refresh-lib.sh but no phase invokes it inside a code block -- the phase is running its own inline copy, or only describing the function in prose"; fi
done

# The wiring check must itself be falsifiable: a function that exists but is never called
# must FAIL. Prove the check can fire.
if [ "$(calls_in_fence definitely_not_a_real_function)" -eq 0 ]; then
  ok "wiring check can actually fire (a never-called function scores 0)"
else
  bad "wiring check is vacuous" "it scores >0 for a function that does not exist -- it would pass anything"
fi

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

# universal_upper_bound must work against BOTH header formats. The section header lost its
# range in the namespacing change; a helper that grepped it would silently return empty.
OGDIR0=""
if [ -r "$HOME/.claude/plugins/installed_plugins.json" ]; then
  OGDIR0=$(jq -r '.plugins | to_entries[] | select(.key|startswith("og@")) | .value[0].installPath' \
           "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null | head -1)
fi
for og_try in "$OGDIR0" "$HERE/../../.."; do
  [ -f "$og_try/docs/universal-orchestrator-rules.md" ] || continue
  OG="$og_try"; n=$(universal_upper_bound)
  [ -n "$n" ] && ok "universal_upper_bound($(basename "$og_try")) = $n" \
    || bad "universal_upper_bound($(basename "$og_try"))" "returned EMPTY -- would read as 'no universal rules'"
done

# --- migration ---
OGDIR=""
if [ -r "$HOME/.claude/plugins/installed_plugins.json" ]; then
  OGDIR=$(jq -r '.plugins | to_entries[] | select(.key|startswith("og@")) | .value[0].installPath' \
          "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null | head -1)
fi
# Fall back to THIS checkout: the harness must run with no Claude install (CI, clean container).
[ -f "${OGDIR:-}/docs/universal-orchestrator-rules.md" ] || OGDIR="$HERE/../../.."
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
