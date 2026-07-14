#!/usr/bin/env bash
# refresh-lib.sh -- executable helpers for /og:refresh.
#
# Source this at the top of EVERY phase. Shell state does not persist between tool calls,
# so a variable set in one phase is unset in the next; re-deriving is not optional.
#
#   . "$OG/skills/refresh/refresh-lib.sh"   # after og_context sets $OG... chicken/egg:
#   # bootstrap: find the lib via the registry first, then source it.
#
# Every function here fails LOUDLY. Nothing returns an empty result that could be mistaken
# for "clean" -- that is the single failure mode this skill exists to avoid.

# NOTE: this library does NOT `set -u` for you. It used to, from inside og_context(), which
# silently flipped nounset on in whatever shell sourced it -- a side effect that could break
# caller code never written for it. The phases in SKILL.md set it themselves, visibly, up top.
og_context() {   # sets ROOT OG OG_ID OG_VER REG ; RETURNS non-zero on any failure; callers must handle it (`og_context || exit 1`)
  ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "FATAL: not in a git repo" >&2; return 1; }
  REG="$HOME/.claude/plugins/installed_plugins.json"
  command -v jq >/dev/null || { echo "FATAL: jq is required" >&2; return 1; }
  [ -r "$REG" ] || { echo "FATAL: cannot read $REG -- is og installed?" >&2; return 1; }
  local sel="${OG_ID:-}" matches
  matches=$(jq -r --arg sel "$sel" '.plugins | to_entries[]
    | select(.key | startswith("og@")) | select($sel == "" or .key == $sel)
    | "\(.key)\t\(.value[0].installPath)\t\(.value[0].version)"' "$REG")
  [ "$(printf '%s' "$matches" | grep -c .)" -eq 1 ] || {
    echo "FATAL: need exactly one og install; set OG_ID=og@<marketplace>. Found:" >&2
    printf '%s\n' "$matches" | cut -f1 | sed 's/^/  /' >&2; return 1; }
  IFS=$'\t' read -r OG_ID OG OG_VER <<<"$matches"
  [ -f "$OG/docs/universal-orchestrator-rules.md" ] || { echo "FATAL: bad og install at $OG" >&2; return 1; }
  export ROOT OG OG_ID OG_VER REG
}

# ---- Gate A: og-shaped? (\bog: anchored -- 'Changelog:' must NOT match) ----
is_og_shaped() {  # $1 = overlay dir
  grep -qE '(^|[^A-Za-z0-9_])og:|og plugin|universal-orchestrator-rules' "$1/SKILL.md"
}

# ---- Gate B: resolve subject repos from the declaration (EXECUTABLE) ----
subjects_of() {   # $1 = overlay dir, $2 = ROOT ; prints path<TAB>PREFIX<TAB>slug<TAB>branch
  local f="$1/SKILL.md" root="$2" name rows
  rows=$(awk '/^## Subject repos/{f=1;next} /^## /{f=0} f' "$f" \
         | grep -E '^\|' | grep -viE '^\| *Path' | grep -vE '^\|[ :-]*\|[ :-]*\|' \
         | sed 's/^| *//; s/ *|$//; s/ *| */\t/g' | tr -d '`')
  if [ -n "$rows" ]; then printf '%s\n' "$rows"; return 0; fi
  name=$(basename -- "$1"); name=${name%-orchestrator}   # not `basename X -orchestrator`: a suffix
                                                       # beginning with - can parse as an option
  # If the overlay could plausibly mean BOTH the root repo and a same-named subdirectory, that is
  # a genuine ambiguity. Guessing either way is a silent wrong answer, and Phase 6 would then
  # resolve every path against the wrong repo. Refuse, and make the human declare a table.
  if [ -d "$root/$name" ] && [ "$name" = "$(basename -- "$root")" ]; then
    echo "AMBIGUOUS: $1 could mean the root repo OR $root/$name -- declare a '## Subject repos' table" >&2
    return 1
  fi
  if [ -d "$root/$name" ]; then printf '%s\t?\t?\t?\n' "$name"; return 2; fi  # 2 = provisional

  # The "." fallback is ONLY for an overlay that is plausibly about the root repo itself --
  # i.e. its name matches the root's basename, or it is the only overlay here (a single-repo
  # project). Falling back to "." unconditionally is a silent wrong answer: in a WORKTREE where
  # magpie/ simply is not checked out, magpie-orchestrator would be declared to be about the
  # WORKSPACE, and Phase 6 would then resolve magpie's paths against the wrong repo and
  # misclassify every one of them. An absent subject is UNRESOLVED, not "the root".
  local nov=0 d
  for d in "$root"/.claude/skills/*-orchestrator; do [ -d "$d" ] && nov=$((nov + 1)); done
  if [ "$name" = "$(basename "$root")" ] || [ "$nov" -eq 1 ]; then
    printf '.\t?\t?\t?\n'; return 2
  fi
  return 1   # cannot tell -- the caller must report it, not guess
}

# ---- Phase 6: classify a referenced path against its SUBJECT repo ----
classify_path() {  # $1 = path, $2 = subject repo dir, $3 = ROOT (optional). OK|DANGLING|UNVERIF|SKIP
  local p="$1" base="$2" root="${3:-}" t
  case "$p" in *'*'*) echo "SKIP glob"; return 0 ;; esac      # globs are patterns, not paths

  # Cannot SEE the subject repo (worktree, partial clone)? Then nothing about it is checkable.
  # UNVERIFIABLE, not wrong -- calling it dangling is how a refresh talks someone into
  # deleting correct documentation.
  if [ ! -d "$base" ]; then echo "UNVERIF (subject repo not present: $base)"; return 0; fi

  if [ "${p#\~/}" != "$p" ]; then t="$HOME/${p#\~/}"
  elif [ "${p#/}" != "$p" ];  then t="$p"
  else                              t="$base/${p#./}"
  fi
  [ -e "$t" ] && { echo "OK"; return 0; }

  # An overlay in a workspace routinely cites WORKSPACE-relative paths (a shared doc, or a
  # sibling repo) alongside subject-relative ones. Try the workspace root before declaring a
  # path dangling, or every such reference is a false positive.
  if [ -n "$root" ] && [ "${p#/}" = "$p" ] && [ "${p#\~}" = "$p" ]; then
    [ -e "$root/${p#./}" ] && { echo "OK"; return 0; }
  fi

  # Subject is present and the path is in neither place: genuinely dangling. This includes a
  # missing intermediate directory -- a module renamed upstream is exactly what Phase 5 exists
  # to catch, and must not be excused as "could not verify".
  echo "DANGLING"
}

# ---- Phase 1: staleness by SHA, with NO silent pass ----
check_freshness() {  # $1 = OG_ID, $2 = REG
  local og_id="$1" reg="$2" sha mp up
  sha=$(jq -r --arg k "$og_id" '.plugins[$k][0].gitCommitSha // empty' "$reg")
  [ -n "$sha" ] || { echo "UNVERIF: installed_plugins.json has no gitCommitSha for $og_id"; return 2; }
  mp="$HOME/.claude/plugins/marketplaces/${og_id#*@}"
  if [ ! -d "$mp/.git" ]; then
    echo "UNVERIF: no marketplace checkout at $mp -- cannot compare. (Local-path or renamed marketplace?)"
    return 2
  fi
  if ! git -C "$mp" fetch -q origin; then
    echo "UNVERIF: git fetch failed (offline? auth?) -- freshness NOT checked. Do NOT assume up to date."
    return 2
  fi
  up=$(git -C "$mp" rev-parse origin/HEAD) || { echo "UNVERIF: cannot resolve origin/HEAD"; return 2; }
  if [ "$sha" = "$up" ]; then echo "OK: up to date (${sha:0:8})"; return 0; fi
  echo "STALE: installed ${sha:0:8}, upstream ${up:0:8}. Missing:"
  git -C "$mp" log --oneline "$sha..$up" | sed 's/^/    /'
  return 1
}

# ---- Migration: legacy shared-integer rules -> namespaced <PREFIX>-N ----
#
# THE MOST DANGEROUS OPERATION IN THIS SKILL. It rewrites rule headers AND the citations that
# point at them. Get the citation mapping wrong and an overlay ends up pointing at one of the
# plugin's rules instead of its own -- which is the exact bug the namespacing exists to kill.
#
# Safety: build an explicit old->new map first, apply only that map, and assert the rule count
# is preserved. Never a blind substitution.

rule_prefix_of() {   # $1 = overlay dir. Prints the declared prefix from ## Subject repos.
  awk '/^## Subject repos/{f=1;next} /^## /{f=0} f' "$1/SKILL.md" \
    | grep -E '^\|' | grep -viE '^\| *Path' | grep -vE '^\|[ :-]*\|' \
    | sed 's/^| *//; s/ *| */\t/g' | tr -d '`' | cut -f2 | grep -E '^[A-Z][A-Z0-9]*$' | head -1
}

migrate_rules() {    # $1 = overlay dir, $2 = OG install, $3 = --apply|--dry
  local ov="$1" og="$2" mode="${3:---dry}"
  local f="$ov/SKILL.md"
  local prefix; prefix=$(rule_prefix_of "$ov")
  [ -n "$prefix" ] || { echo "FATAL: $ov has no Prefix in its ## Subject repos table"; return 1; }

  # og's own rule range -- a citation at or below this is a UNIVERSAL rule, not a project one.
  # Accept BOTH header formats: the installed plugin may predate the OG-* namespacing.
  # If we cannot determine the range, REFUSE -- guessing here mis-points citations at the
  # wrong rules, which is precisely the bug the namespacing exists to eliminate.
  local ogmax
  ogmax=$(grep -oE '^### (OG-)?[0-9]+\.' "$og/docs/universal-orchestrator-rules.md" \
          | grep -oE '[0-9]+' | sort -n | tail -1)
  if ! [ "${ogmax:-}" -eq "${ogmax:-}" ] 2>/dev/null; then
    echo "FATAL: cannot read og's rule range from $og/docs/universal-orchestrator-rules.md"
    echo "       Refusing to migrate: every citation would be misclassified."
    return 1
  fi

  # Legacy rule numbers, scoped to the section and fence-aware (a "1." inside a ``` example
  # must not be mistaken for a rule).
  local nums; nums=$(awk '
      /^## Project Rules/ {inr=1; next} /^## / {if(inr) exit} !inr {next}
      /^ ? ? ?```/ {fence=!fence; next} fence {next}
      /^[0-9]+\. \*\*/ {print $1} /^\*\*Rule [0-9]+/ {print $2}
    ' "$f" | tr -d '.' | grep -oE '^[0-9]+$' | sort -n)
  [ -n "$nums" ] || { echo "$ov: no legacy rules (already migrated, or none)"; return 0; }

  # Ordinal position, NOT (n - first + 1): legacy numbering can have GAPS (a deleted rule), and
  # the arithmetic form turned 12,14 into PREFIX-1,PREFIX-3 while announcing "PREFIX-1..PREFIX-2".
  # Rules are a list, not an address space. Renumber them 1..N as they appear.
  local n new i=0 map=""
  for n in $nums; do
    i=$((i + 1))
    new="${prefix}-${i}"
    map="${map}${n}=${new}"$'\n'
  done

  echo "$ov  (prefix $prefix, $(printf '%s\n' "$nums" | wc -l) rules)"
  printf '%s' "$map" | sed 's/^/    /'

  # Citations. A number <= ogmax that is NOT one of this overlay's own rules is a UNIVERSAL
  # citation -> OG-N. A number in the map is this overlay's own -> PREFIX-N. Anything else is
  # ambiguous: FLAG IT, do not guess.
  local cite
  while read -r cite; do
    if printf '%s' "$map" | grep -q "^${cite}="; then
      echo "    cite Rule ${cite} -> $(printf '%s' "$map" | grep "^${cite}=" | cut -d= -f2)  (own rule)"
    elif [ "$cite" -le "$ogmax" ]; then
      # AMBIGUOUS BY NATURE, so we do NOT rewrite it. A legacy citation inside og's range is
      # either a genuine universal reference, or a STALE project citation from before some
      # earlier renumber -- and the number alone cannot tell them apart.
      #
      # Rewriting it to OG-N would be SILENTLY WRONG in the stale case: it would point at a
      # real universal rule that says something else. Leaving it as "Rule N" leaves it
      # VISIBLY legacy -- nothing else in a migrated overlay says "Rule N" -- so it stands
      # out and gets fixed. A visible failure beats a silent wrong answer.
      # Accept both header formats: an older installed plugin still uses "### N." Without this
      # the title comes back empty and the CONFIRM line loses the one thing that makes it
      # actionable -- the human cannot see WHICH rule they are being pointed at.
      local title
      title=$(grep -m1 -E "^### (OG-)?${cite}\." "$og/docs/universal-orchestrator-rules.md" \
              | sed -E "s/^### (OG-)?${cite}\. *//")
      echo "    cite Rule ${cite} -> NOT REWRITTEN. Probably OG-${cite}: \"${title}\""
      echo "        ^ if that IS what the overlay meant, change it to OG-${cite} by hand."
      echo "          If it is not, it is a stale citation of a project rule from before a"
      echo "          renumber -- fix it to the right <PREFIX>-N. Either way a human decides:"
      echo "          rewriting it automatically would be silently wrong in the stale case."
    else
      echo "    cite Rule ${cite} -> *** AMBIGUOUS: not one of this overlay's rules and beyond OG-${ogmax}. Resolve by hand. ***"
    fi
  done < <(grep -oE '(^|[^A-Za-z0-9_])Rule [0-9]+' "$f" | grep -oE '[0-9]+' | sort -un)

  [ "$mode" = "--apply" ] || return 0

  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/og-refresh.XXXXXX") || { echo "    FATAL: cannot create a temp file"; return 1; }

  # BOUNDED AND FENCE-AWARE. A global substitution here corrupts the file: an unrelated
  # numbered list elsewhere in the overlay (an Ansible playbook list, a checklist) and any
  # "12. **x**" inside a ``` example get rewritten into rules. This skill's own doctrine says
  # "bound every substitution to the ## Project Rules section" -- so do it, in one awk pass
  # that tracks section and fence state, instead of `perl -pi` across the whole file.
  #
  # Citations ARE rewritten anywhere in the file (they can legitimately appear in the agent
  # table, prose, etc.) -- but only for numbers in the map, i.e. this overlay's own rules.
  # Citations inside og's range are deliberately left alone (see above).
  awk -v map="$map" -v prefix="$prefix" '
    BEGIN {
      n = split(map, rows, "\n")
      for (i = 1; i <= n; i++) {
        if (rows[i] == "") continue
        split(rows[i], kv, "=")
        old[kv[1]] = kv[2]
      }
    }
    /^ ? ? ?```/ { fence = !fence; print; next }
    fence  { print; next }                      # never touch anything inside a fence

    /^## Project Rules/ { inrules = 1; sub(/ *\([^)]*\) *$/, ""); print; next }
    /^## /              { inrules = 0 }

    {
      line = $0
      # rule HEADERS: only inside the ## Project Rules section
      if (inrules) {
        for (k in old) {
          if (line ~ ("^" k "\\. \\*\\*"))      { sub("^" k "\\.", old[k] ".", line); break }
          if (line ~ ("^\\*\\*Rule " k " "))      { sub("^\\*\\*Rule " k " ", "**" old[k] " ", line); break }
        }
      }
      print line
    }
  ' "$f" > "$tmp"

  # Citations: a separate, explicit pass, only for numbers in the map (this overlay is own
  # rules). Bounded by the map, so a number not in it is never touched.
  # FENCE-AWARE, like the header pass above. `perl -pi` alone rewrites the whole file, so a
  # fenced example quoting the OLD numbering ("See Rule 12") got rewritten into the new scheme
  # -- corrupting a code block that was quoting history on purpose. The header pass already
  # skipped fences; this one did not, which is worse than either being wrong consistently.
  local n new2
  for n in $nums; do
    new2=$(printf '%s' "$map" | grep "^${n}=" | cut -d= -f2)
    perl -pi -e "if (/^ ? ? ?\`\`\`/) { \$fence = !\$fence }
                 elsif (!\$fence) { s/(^|[^A-Za-z0-9_])Rule ${n}(?![0-9])/\${1}${new2}/g }" "$tmp"
  done

  # ASSERT: the rule count survived, and NOTHING outside the section was renamed.
  local got want outside
  got=$(awk '/^## Project Rules/{f=1;next} /^## /{if(f)exit} f' "$tmp" \
        | grep -cE "^${prefix}-[0-9]+\. \*\*|^\*\*${prefix}-[0-9]+ ")
  want=$(printf '%s\n' "$nums" | wc -l | tr -d ' ')
  outside=$(awk -v p="$prefix" '
      /^ ? ? ?```/ {fence=!fence; next} fence {next}
      /^## Project Rules/ {inr=1; next} /^## / {inr=0}
      !inr && $0 ~ ("^" p "-[0-9]+\\.") {c++}
      END {print c+0}' "$tmp")
  # Fenced content is quoted on purpose -- examples, fixtures, history. Migration must not change
  # one byte of it. The check above cannot see this: it `next`s past fences, so it was blind to
  # exactly the corruption that shipped. Assert the invariant directly instead.
  local fence_before fence_after
  fence_before=$(awk '/^ ? ? ?```/{f=!f;next} f' "$f")
  fence_after=$(awk '/^ ? ? ?```/{f=!f;next} f' "$tmp")
  if [ "$got" -ne "$want" ] || [ "$outside" -ne 0 ] || [ "$fence_before" != "$fence_after" ]; then
    echo "    ABORT: rewrote $got of $want rules, $outside line(s) OUTSIDE the rules section"
    [ "$fence_before" != "$fence_after" ] && echo "           and it MODIFIED FENCED CONTENT"
    echo "           -- refusing to write a corrupted file"
    rm -f "$tmp"; return 1
  fi
  mv "$tmp" "$f"
  echo "    APPLIED: $got rules -> ${prefix}-1..${prefix}-${got}"
}
