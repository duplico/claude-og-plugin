#!/usr/bin/env bash
# shellcheck disable=SC2015,SC1090,SC2016
#   SC2015 -- the `cond && ok "..." || bad "..."` assertion idiom is safe here: ok() is an echo
#             plus a counter increment and cannot fail, so bad() never runs on a passing check.
#   SC1090 -- $LIB is resolved at runtime relative to this script; shellcheck cannot follow it.
#   SC2016 -- the single-quoted printf strings contain backticks ON PURPOSE (they are markdown
#             fixtures); expansion is exactly what we do not want.
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
TMP=$(mktemp -d "${TMPDIR:-/tmp}/og-refresh-test.XXXXXX") \
  || { echo "FATAL: cannot create a temp dir" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT   # generated fixtures (incl. a git repo) -- NEVER committed
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
    /^ ? ? ?```bash/ { fence = 1; next }        # ONLY a bash fence is code. An untagged fence
    /^ ? ? ?```/     { fence = 0; next }        # (the Phase 8 example report) is OUTPUT, not code:
                                          # counting it let a decoy there fake a wiring pass.
    !fence { next }
    /^[ \t]*#/ { next }    # a comment NAMING a function is not a CALL of it
    $0 ~ ("(^|[^A-Za-z0-9_])" fn "([ \t]|$)") { n++ }
    END { print n+0 }
  ' "$SKILL"
}
for fn in is_og_shaped subjects_of classify_path check_freshness migrate_rules; do
  n=$(calls_in_fence "$fn")
  if [ "$n" -ge 1 ]; then ok "SKILL.md CALLS $fn() ($n use(s) in code)"
  else bad "SKILL.md never CALLS $fn()" "it is implemented in refresh-lib.sh but no phase invokes it inside a code block -- the phase is running its own inline copy, or only describing the function in prose"; fi
done

# The reference table must not advertise a function no phase calls. That is how
# lowest_project_rule and universal_upper_bound survived as dead code while the table implied
# a phase used them -- the table lied, and a future edit would have "fixed" a phase to match.
while read -r fn; do
  [ -n "$fn" ] || continue
  if [ "$(calls_in_fence "$fn")" -ge 1 ]; then ok "table function $fn() is actually called"
  else bad "table advertises $fn() but no phase calls it" "dead row -- delete the function or wire it in"; fi
done < <(grep -oE '^\| `[a-z_]+' "$SKILL" | tr -d '|` ')

# Phase 0 must not silently launder a GUESSED subject as a verified one. subjects_of returns
# rc=2 when it fell back to convention; those overlays are refreshable, but every Phase 6
# finding against them is only as good as the guess. If the report cannot name them, a
# convention-inferred run reads as fully verified. Assert Phase 0 both TRACKS and PRINTS them.
phase0=$(sed -n '/^## Phase 0/,/^## Phase 1/p' "$SKILL")
grep -q 'rc" -eq 2 \]; then PROVISIONAL+=' <<<"$phase0" \
  && ok "Phase 0 TRACKS provisional (rc=2) subjects" \
  || bad "Phase 0 does not track rc=2" "convention-guessed subjects get bucketed with declared ones"
grep -q "printf 'PROVISIONAL" <<<"$phase0" \
  && ok "Phase 0 REPORTS the provisional list" \
  || bad "Phase 0 tracks provisional but never prints it" "a list nobody prints is not a report"
grep -q 'PROVISIONAL=()' <<<"$phase0" \
  && ok "PROVISIONAL is initialised (set -u safe)" \
  || bad "PROVISIONAL never initialised" "unbound under set -u"

# The wiring check must itself be falsifiable: a function that exists but is never called
# must FAIL. Prove the check can fire.
if [ "$(calls_in_fence definitely_not_a_real_function)" -eq 0 ]; then
  ok "wiring check can actually fire (a never-called function scores 0)"
else
  bad "wiring check is vacuous" "it scores >0 for a function that does not exist -- it would pass anything"
fi

# --- 3. Behavioural tests of the lib, against fixtures ---
. "$LIB"

t_path() {  # $1 = label, $2 = path, $3 = subject dir, $4 = expected classification prefix
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
# Phase 0 must treat rc=2 (provisional) as USABLE and only rc=1 as unresolved. Grepping for a
# string is not enough -- it would pass if the string sat in a comment. Assert BOTH that the
# rc==1 guard is present in a code fence AND that the buggy `subjects_of ... ||` form (which
# fires on rc=2 and silently skips every single-repo project) is absent.
guard=$(awk '/^ ? ? ?```bash/{f=1;next} /^ ? ? ?```/{f=0;next} f' "$SKILL" | grep -c 'rc" -eq 1' || true)
buggy=$(awk '/^ ? ? ?```bash/{f=1;next} /^ ? ? ?```/{f=0;next} f' "$SKILL" | grep -cE 'subjects_of [^|]*\|\|' || true)
if [ "$guard" -ge 1 ] && [ "$buggy" -eq 0 ]; then
  ok "Phase 0 accepts rc=2 (provisional) and has no '|| skip' on subjects_of"
else
  bad "Phase 0 provisional handling" "guard_in_code=$guard buggy_or_form=$buggy -- '|| after subjects_of' fires on rc=2 and drops every single-repo project"
fi

# A failed --apply must halt the SKILL, not just the loop. `|| echo` does not stop at all;
# `break` leaves the loop but lets Phases 4-8 run against a HALF-MIGRATED repo and report on it
# as if it were consistent. Both spellings have shipped in this file already. Assert the exit.
apply=$(awk '/^ ? ? ?```bash/{f=1;next} /^ ? ? ?```/{f=0;next} f' "$SKILL" | grep -A6 'migrate_rules .* --apply' || true)
if grep -q 'exit 1' <<<"$apply"; then
  ok "Phase 3 --apply failure EXITS (does not fall through to later phases)"
else
  bad "Phase 3 --apply failure does not exit" "break/|| echo leave later phases running against a half-migrated repo: $apply"
fi

# Bash-4-only builtins must not creep in: macOS ships bash 3.2, where `mapfile`/`readarray`
# is a "command not found" and the array is silently EMPTY -- so the loop over it runs zero
# times and every check inside it is skipped while the run reports success. SKILL.md line ~37
# already warns about exactly this, and a mapfile still got added; prose is not a guard.
if grep -rqE --exclude="$(basename "$0")" '(^|[^A-Za-z0-9_])(mapfile|readarray)[ 	]' "$HERE/.."; then
  bad "bash-4-only mapfile/readarray" "macOS ships bash 3.2: the array comes back EMPTY and every check inside the loop is silently skipped. Offender(s): $(grep -rlE --exclude="$(basename "$0")" '(^|[^A-Za-z0-9_])(mapfile|readarray)[ 	]' "$HERE/..")"
else
  ok "no bash-4-only mapfile/readarray (bash 3.2 safe)"
fi

# The \b word-boundary bug must not come back: it is GNU-only, matches nothing on BSD, and an
# empty citation set reads as "no citations" while the rules get rewritten anyway.
#
# Match ANY grep whose flags contain E and whose pattern contains a literal backslash-b --
# not just `grep -oE`. The bug is just as fatal as `grep -E '\b...'`, and an earlier version of
# this check keyed on `-oE` alone and sailed straight past that form. Verified against all of
# `grep -oE`, `grep -E` and `grep -rqE`. It deliberately does NOT fire on perl, where \b is
# supported and which migrate_rules relies on.
#
# The test file is excluded: it necessarily contains the pattern it hunts for, and a check that
# always matches itself is a check that can never go green -- or, worse, never go red.
BUG_B='grep [^;|]*-[a-zA-Z]*E[^;|]*\\b'
if grep -rqE --exclude="$(basename "$0")" "$BUG_B" "$HERE/.."; then
  bad "GNU-only \\b in a grep -E pattern" "BSD/macOS grep -E does not support \\b -- it matches nothing and silently skips every citation. Offender(s): $(grep -rlE --exclude="$(basename "$0")" "$BUG_B" "$HERE/..")"
else
  ok "no GNU-only \\b in any grep -E pattern (all -E forms scanned)"
fi

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

A fenced example quoting the OLD numbering, deliberately:

```markdown
13. **Second.** See Rule 12 here.
```
EOF
out=$(migrate_rules "$M" "$OGDIR" --apply 2>&1)
body=$(sed -n '/^## Project Rules/,/^## Next/p' "$M/SKILL.md")
grep -q 'THING-1\. \*\*First' <<<"$body" && ok "migrate: rules renumbered to PREFIX-1" || bad "migrate: rules" "$body"
grep -q 'See THING-2' <<<"$body"          && ok "migrate: own-rule citation -> THING-2"  || bad "migrate: own citation" "$body"
# A citation inside og's range is AMBIGUOUS (genuine universal ref, or a stale project ref
# from before a renumber). It must be LEFT ALONE and flagged -- rewriting it to OG-N would be
# silently wrong in the stale case. Visible-legacy beats silently-wrong.
grep -q 'Required by Rule 2' <<<"$body"   && ok "migrate: og-range citation LEFT ALONE (not silently rewritten)" \
  || bad "migrate: og-range citation" "must NOT be auto-rewritten to OG-2 -- it is ambiguous. Got: $body"
grep -q 'NOT REWRITTEN' <<<"$out"         && ok "migrate: og-range citation flagged with the OG rule's title" \
  || bad "migrate: og-range flag" "$out"
grep -q 'pointer to Rule 99' <<<"$body"   && ok "migrate: ambiguous citation LEFT ALONE" || bad "migrate: ambiguous" "must not be rewritten"
grep -q 'AMBIGUOUS' <<<"$out"             && ok "migrate: ambiguous citation FLAGGED"    || bad "migrate: ambiguous flag" "$out"

# Fenced content is quoted on purpose (examples, fixtures, history). Migration must not change one
# byte of it. The header pass was fence-aware from the start; the CITATION pass was not, so a fence
# saying "See Rule 12" got rewritten to "See THING-1" -- corrupting a block that quoted history
# deliberately. Assert the fence is byte-identical, not merely that no rule HEADER leaked.
fence=$(awk '/^ ? ? ?```/{f=!f;next} f' "$M/SKILL.md")
if [ "$fence" = '13. **Second.** See Rule 12 here.' ]; then
  ok "migrate: FENCED content byte-identical (header AND citation passes skip fences)"
else
  bad "migrate: fenced content was rewritten" "expected '13. **Second.** See Rule 12 here.' got '$fence'"
fi
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

# --- 4. Phase 6, EXECUTED ---------------------------------------------------------------------
# Three real bugs have shipped in Phase 6's aggregation (head -1; the path x subject cross-product;
# UNVERIF burying a proven DANGLING). None was visible to a harness that only greps SKILL.md.
# So run it. VERBATIM from the fence -- a hand-copied version would test the copy and pass while
# the real phase stayed broken, which is the whole failure mode this file exists to prevent.
p6=$(awk '/^ ? ? ?```bash/ {f=1; blk=""; next}
           /^ ? ? ?```/    {if (f && blk ~ /classify_path/) printf "%s", blk; f=0; next}
           f         {blk = blk $0 "\n"}' "$SKILL")
if [ -z "$p6" ]; then
  bad "could not extract Phase 6 from SKILL.md" "the end-to-end checks below would be vacuous"
else
  R="$TMP/p6/root"
  mkdir -p "$R/.claude/skills/multi-orchestrator" "$R/suba/scripts"      # suba present, subb NOT
  printf 'og:orchestrate\n\n## Subject repos\n\n| Path | Prefix | Slug | Default branch |\n|---|---|---|---|\n| `suba` | A | o/suba | `main` |\n| `subb` | A | o/subb | `main` |\n\nCites `scripts/gone.sh` and `scripts/here.sh`.\n' \
    > "$R/.claude/skills/multi-orchestrator/SKILL.md"
  : > "$R/suba/scripts/here.sh"                    # here.sh exists in suba; gone.sh exists nowhere
  # shellcheck disable=SC2034  # ROOT/OVERLAYS are read by the eval'd Phase 6 body
  run_p6() { ( . "$LIB"; ROOT="$R"; OVERLAYS=("$R/.claude/skills/multi-orchestrator"); eval "$p6" ); }

  out=$(run_p6)
  grep -q 'here.sh' <<<"$out" \
    && bad "Phase 6: false DANGLING on a path that EXISTS in a sibling subject" "$out" \
    || ok "Phase 6: a path present in ONE subject is not DANGLING against the others"
  grep -q 'DANGLING(partial).*absent in: suba.*NOT CHECKED OUT: subb' <<<"$out" \
    && ok "Phase 6: proven-absent + unseen subject -> DANGLING(partial), not bare UNVERIF" \
    || bad "Phase 6: UNVERIF from an unchecked subject buried a proven DANGLING" "$out"

  mkdir -p "$R/subb/scripts"; : > "$R/subb/scripts/here.sh"       # now BOTH subjects are visible
  out=$(run_p6)
  grep -qE '^DANGLING  .*none of: suba subb.*gone\.sh' <<<"$out" \
    && ok "Phase 6: absent from EVERY visible subject hardens to a plain DANGLING" \
    || bad "Phase 6: should harden to DANGLING once every subject is checked out" "$out"
fi

# Legacy numbering can have GAPS (someone deleted a rule). The old arithmetic form
# (n - first + 1) turned 12,14 into PREFIX-1,PREFIX-3 while announcing "PREFIX-1..PREFIX-2" --
# non-contiguous IDs and a report that disagreed with the file. Rules are a list, not an
# address space. Also: fences may be INDENTED up to 3 spaces and are still fences; a column-0
# regex let migrate_rules rewrite inside one. Both in a single fixture.
G="$TMP/gap-orchestrator"; mkdir -p "$G"
printf 'og:orchestrate\n\n## Subject repos\n\n| Path | Prefix | Slug | Default branch |\n|---|---|---|---|\n| `.` | GAP | o/g | `main` |\n\n## Project Rules\n\n12. **A.** x\n14. **C.** See Rule 12.\n\n## Notes\n\n- a list item, with an INDENTED fence:\n\n   ```markdown\n   14. **C.** See Rule 12.\n   ```\n' > "$G/SKILL.md"
migrate_rules "$G" "$OGDIR" --apply >/dev/null 2>&1
rules=$(grep -cE '^GAP-[12]\. ' "$G/SKILL.md")
[ "$rules" -eq 2 ] && ok "migrate: gapped legacy numbering renumbers CONTIGUOUSLY (12,14 -> GAP-1,GAP-2)" \
  || bad "migrate: gapped numbering" "expected GAP-1 and GAP-2, got: $(grep -E '^GAP-' "$G/SKILL.md")"
ind=$(awk '/^ ? ? ?```/{f=!f;next} f' "$G/SKILL.md" | tr -d ' ')
[ "$ind" = '14.**C.**SeeRule12.' ] \
  && ok "migrate: an INDENTED fence is still a fence (content untouched)" \
  || bad "migrate: indented fence was rewritten" "got '$ind'"

# DUPLICATE legacy numbers make the old->new map ambiguous ("See Rule 12" -> which one?). With a
# non-unique map the last entry won and BOTH headers were rewritten to the same id: two X-2 rules,
# no X-1, written to disk, with the count assertion passing because it counts lines not ids.
D="$TMP/dup-orchestrator"; mkdir -p "$D"
printf 'og:orchestrate\n\n## Subject repos\n\n| Path | Prefix | Slug | Default branch |\n|---|---|---|---|\n| `.` | D | o/d | `main` |\n\n## Project Rules\n\n12. **A.** x\n12. **B.** y\n\n## End\n' > "$D/SKILL.md"
cp "$D/SKILL.md" "$TMP/dup.before"
migrate_rules "$D" "$OGDIR" --apply >/dev/null 2>&1
if cmp -s "$TMP/dup.before" "$D/SKILL.md"; then
  ok "migrate: DUPLICATE legacy numbers refuse (file untouched)"
else
  bad "migrate: duplicate numbers corrupted the file" "$(grep -E '^D-' "$D/SKILL.md")"
fi

# Rules are a LIST: renumber in DOCUMENT order. Sorting numerically renumbered an out-of-order
# overlay descending -- the first rule in the file came out PREFIX-2.
O="$TMP/ooo-orchestrator"; mkdir -p "$O"
printf 'og:orchestrate\n\n## Subject repos\n\n| Path | Prefix | Slug | Default branch |\n|---|---|---|---|\n| `.` | O | o/o | `main` |\n\n## Project Rules\n\n14. **First.** x\n12. **Second.** See Rule 14.\n\n## End\n' > "$O/SKILL.md"
migrate_rules "$O" "$OGDIR" --apply >/dev/null 2>&1
first=$(grep -oE '^O-[0-9]+' "$O/SKILL.md" | head -1)
[ "$first" = "O-1" ] \
  && ok "migrate: out-of-order legacy numbering renumbers in DOCUMENT order (first rule -> O-1)" \
  || bad "migrate: out-of-order renumbered by value, not position" "first rule became $first"

# The OTHER rule syntax. Overlays write rules two ways -- `12. **Title.**` and
# `**Rule 12 -- Title.**` -- and every fixture above used the first. On the first REAL repo this
# was pointed at, the distinct-id assertion counted zero for a `**Rule 12**` overlay (its lines
# start `**SCORING-1`, not `SCORING-1`) and aborted a perfectly valid migration. 44 assertions
# missed it because they all spoke one dialect.
B="$TMP/bold-orchestrator"; mkdir -p "$B"
printf 'og:orchestrate\n\n## Subject repos\n\n| Path | Prefix | Slug | Default branch |\n|---|---|---|---|\n| `.` | B | o/b | `main` |\n\n## Project Rules\n\n**Rule 12 -- Alpha.** x\n\n**Rule 13 -- Beta.** See Rule 12.\n\n## End\n' > "$B/SKILL.md"
migrate_rules "$B" "$OGDIR" --apply >/dev/null 2>&1
if grep -q '^\*\*B-1 -- Alpha' "$B/SKILL.md" && grep -q '^\*\*B-2 -- Beta' "$B/SKILL.md" \
   && grep -q 'See B-1' "$B/SKILL.md"; then
  ok "migrate: the **Rule N -- Title** syntax migrates (headers AND citations)"
else
  bad "migrate: **Rule N** syntax" "$(grep -E '^\*\*|See ' "$B/SKILL.md")"
fi

# IMPRECISE: docs cite a path the way people SAY it, not the way it sits on disk --
# `02_network/dns.tf` for `terraform/2026/regionals/02_network/dns.tf`. The file EXISTS; the
# citation is loose. Calling that DANGLING is how a refresh talks someone into "fixing" correct
# documentation. Both of these were real false positives on real repos, not invented cases.
S="$TMP/subj"; ( cd "$S" && git init -q . && git config user.email t@t && git config user.name t )
mkdir -p "$S/deep/nested/mod" "$S/deep/libdir"
: > "$S/deep/nested/mod/dns.tf"; : > "$S/deep/libdir/impl.c"
( cd "$S" && git add -A >/dev/null && git commit -qm x >/dev/null )
case "$(classify_path 'mod/dns.tf' "$S")" in
  IMPRECISE*) ok "classify_path: a FILE cited by shorthand is IMPRECISE, not DANGLING" ;;
  *) bad "classify_path: shorthand file" "got '$(classify_path 'mod/dns.tf' "$S")', want IMPRECISE" ;;
esac
case "$(classify_path 'libdir/' "$S")" in
  IMPRECISE*) ok "classify_path: a DIRECTORY cited by shorthand is IMPRECISE (ls-files lists no dirs)" ;;
  *) bad "classify_path: shorthand dir" "got '$(classify_path 'libdir/' "$S")', want IMPRECISE" ;;
esac
case "$(classify_path 'genuinely/absent.tf' "$S")" in
  DANGLING*) ok "classify_path: a path that is nowhere is still DANGLING" ;;
  *) bad "classify_path: absent path" "got '$(classify_path 'genuinely/absent.tf' "$S")', want DANGLING" ;;
esac

# PATTERNS are not paths. Real overlays are full of them and only `*` was recognised, so on the
# real workspace `terraform/YYYY/{quals,regionals}/`, `ansible/roles/YYYY/` and `docs/repo/<repo>/`
# were all reported DANGLING while the real directories sat right there. The narrowness matters
# as much as the rule: CODEOWNERS and API are real names and must still be CHECKED.
t_skip() {  # $1 = path, $2 = expected verdict prefix
  local got; got=$(classify_path "$1" "$S")
  case "$got" in "$2"*) ok "classify_path($1) -> $2" ;;
    *) bad "classify_path($1)" "expected $2, got '$got'" ;; esac
}
t_skip 'terraform/YYYY/{quals,regionals}/' 'SKIP brace'
t_skip 'docs/repo/<repo>/'                 'SKIP placeholder'
t_skip 'ansible/roles/YYYY/'               'SKIP placeholder segment'
t_skip 'terraform/**/*.tf'                 'SKIP glob'
t_skip '.github/CODEOWNERS'                'DANGLING'   # a real all-caps NAME is not a placeholder

# The og rules doc exists in TWO formats: pre-namespacing (`### 11.`) and post (`### OG-11.`).
# migrate_rules reads the OG range from it to classify citations, and an INSTALLED plugin can be
# either -- a stale install still has the old form, which is exactly what the live testbed had.
# If the range cannot be read, migrate_rules FATALs (correctly), so a parser that handles only
# one format would break every migration the moment the plugin updates. Assert both.
for fmt in old new; do
  F="$TMP/ogfmt-$fmt/docs"; mkdir -p "$F"
  if [ "$fmt" = old ]; then printf '### 0. A\n### 11. Use the Project Tooling\n' > "$F/universal-orchestrator-rules.md"
  else                      printf '### OG-0. A\n### OG-11. Use the Project Tooling\n' > "$F/universal-orchestrator-rules.md"; fi
  got=$(grep -oE '^### (OG-)?[0-9]+\.' "$F/universal-orchestrator-rules.md" | grep -oE '[0-9]+' | sort -n | tail -1)
  [ "$got" = "11" ] && ok "og rule range parses from the $fmt rules-doc format (ogmax=11)" \
    || bad "og rule range unreadable in $fmt format" "got '$got' -- migrate_rules would FATAL on every overlay"
done

# "--report-only changes nothing" is the contract a user is relying on when they type the flag.
# It was enforced by PROSE -- by asking the model not to pass --apply. Every other destructive
# path here fails closed; that one failed open. A promise the code cannot keep is not a promise.
RO="$TMP/ro-orchestrator"; mkdir -p "$RO"
printf 'og:orchestrate\n\n## Subject repos\n\n| Path | Prefix | Slug | Default branch |\n|---|---|---|---|\n| `.` | RO | o/ro | `main` |\n\n## Project Rules\n\n12. **A.** x\n\n## End\n' > "$RO/SKILL.md"
cp "$RO/SKILL.md" "$TMP/ro.before"
( export OG_REFRESH_REPORT_ONLY=1; migrate_rules "$RO" "$OGDIR" --apply >/dev/null 2>&1 )
if cmp -s "$TMP/ro.before" "$RO/SKILL.md"; then
  ok "--report-only REFUSES --apply (guard, not prose)"
else
  bad "--report-only was defeated by --apply" "the file was rewritten while OG_REFRESH_REPORT_ONLY=1"
fi
# ...and it must not become a blanket block: --apply still works without the guard set.
migrate_rules "$RO" "$OGDIR" --apply >/dev/null 2>&1
grep -q '^RO-1\.' "$RO/SKILL.md" \
  && ok "--apply still works when the guard is NOT set (not a blanket block)" \
  || bad "--apply broken" "the guard blocks even when unset: $(grep -E '^(RO-|12\.)' "$RO/SKILL.md")"

# An overlay has ONE flat rule list, so it has ONE prefix; a multi-subject overlay repeats it on
# every row (deployment + infra-deployment both say DEPLOY). `head -1` across rows declaring
# DIFFERENT prefixes silently picked the first, and every rule would be rewritten into a namespace
# the author never chose. Refuse. And do NOT let the guard block the legitimate repeated case.
TWO="$TMP/two-orchestrator"; mkdir -p "$TWO"
printf 'og:orchestrate\n\n## Subject repos\n\n| Path | Prefix | Slug | Default branch |\n|---|---|---|---|\n| `a` | ALPHA | o/a | `main` |\n| `b` | BETA | o/b | `main` |\n\n## Project Rules\n\n12. **X.** y\n\n## End\n' > "$TWO/SKILL.md"
cp "$TWO/SKILL.md" "$TMP/two.before"
migrate_rules "$TWO" "$OGDIR" --apply >/dev/null 2>&1
cmp -s "$TMP/two.before" "$TWO/SKILL.md" \
  && ok "migrate: an overlay with TWO DIFFERENT prefixes refuses (file untouched)" \
  || bad "migrate: multi-prefix overlay was rewritten" "rules went into a namespace nobody chose"

DEP="$TMP/dep-orchestrator"; mkdir -p "$DEP"
printf 'og:orchestrate\n\n## Subject repos\n\n| Path | Prefix | Slug | Default branch |\n|---|---|---|---|\n| `deployment` | DEPLOY | o/d | `master` |\n| `infra-deployment` | DEPLOY | o/i | `main` |\n\n## Project Rules\n\n12. **X.** y\n\n## End\n' > "$DEP/SKILL.md"
migrate_rules "$DEP" "$OGDIR" --apply >/dev/null 2>&1
grep -q '^DEPLOY-1\.' "$DEP/SKILL.md" \
  && ok "migrate: multi-subject overlay repeating ONE prefix still migrates (not a blanket block)" \
  || bad "migrate: the multi-prefix guard blocks the legitimate repeated case" "$(grep -E '^(DEPLOY|12)' "$DEP/SKILL.md")"

# A malformed registry must be diagnosed as a JSON problem, not as an OG_ID problem.
printf '{ not json' > "$TMP/bad.json"
out=$(check_freshness "og@duplico" "$TMP/bad.json" 2>&1)
case "$out" in
  *"cannot parse"*) ok "check_freshness: a malformed registry says JSON, not 'no gitCommitSha'" ;;
  *) bad "check_freshness misdiagnoses a jq failure" "got: $out" ;;
esac

echo
printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
