---
name: refresh
description: "Reconcile an existing repo's og setup with the current plugin: check plugin freshness, find duplicated generics, migrate legacy numbered rules to the namespaced scheme, lint for anti-patterns, and fact-check the overlay against the actual repo. Report-first; nothing changes without confirmation."
disable-model-invocation: true
argument-hint: "[--report-only]"
allowed-tools: Read, Glob, Grep, Bash, Edit, Write, Task
---

# Refresh: reconcile this repo's og setup with the current plugin

`/og:orchestrate-init` creates a setup. **This maintains one.** Overlays rot, and they rot *quietly*, because nothing type-checks a claim like "run `make test`."

`--report-only` = find drift, change nothing.

If invoked with `--report-only`, **export the guard before anything else**:

```bash
export OG_REFRESH_REPORT_ONLY=1   # migrate_rules REFUSES --apply while this is set.
```

The contract used to be enforced by asking you not to pass `--apply`. It is a guard now, because a promise the code cannot keep is not a promise. Do not run `og-sync --fix` either.

## Three rules, in priority order

1. **Report, confirm, fix, verify. Never blind-rewrite.**
2. **A silent pass is the worst outcome** -- worse than a crash, worse than a false positive. If a check could not actually run, say "could not verify". Never let an empty result read as "clean". Most of this document exists to prevent that one failure.
3. **"Unverifiable" is not "false."** If you cannot see the thing a claim refers to, the claim is *unchecked*, not wrong. Deleting correct documentation because you were in the wrong directory is the failure this skill must never have.

---

## The library -- source it at the top of EVERY phase

**Shell state does not persist between tool calls.** A variable set in Phase 0 is *unset* in Phase 2. Combine that with a stray `2>/dev/null` and a phase greps nothing, prints nothing, and reads exactly like "no problems found."

So the checks are **code, not prose** -- shipped in `refresh-lib.sh` beside this file, and sourced by every phase:

```bash
REG="$HOME/.claude/plugins/installed_plugins.json"
command -v jq >/dev/null || { echo "FATAL: jq is required"; exit 1; }
[ -r "$REG" ] || { echo "FATAL: cannot read $REG -- is the og plugin installed?"; exit 1; }
# Check those FIRST: without them, jq fails silently and the script falls through to "need
# exactly one og install", which points at entirely the wrong problem.
# Do NOT `head -1` here: with two og installs that silently sources the WRONG library, before
# og_context's guard ever runs. Require exactly one, or bail to the same OG_ID escape hatch.
# NOT `mapfile`: that is bash 4+, and macOS still ships bash 3.2.
_og=""; _n=0
while IFS= read -r _p; do _og="$_p"; _n=$((_n + 1)); done < <(
  jq -r --arg sel "${OG_ID:-}" '.plugins | to_entries[]
    | select(.key|startswith("og@")) | select($sel == "" or .key == $sel)
    | .value[0].installPath' "$REG")
[ "$_n" -eq 1 ] || { echo "FATAL: need exactly one og install; set OG_ID=og@<marketplace>"; exit 1; }
. "$_og/skills/refresh/refresh-lib.sh"
set -u                     # an unset var expanding to "" is the silent-empty failure this
                           # skill exists to prevent. Set here, visibly -- NOT inside the lib,
                           # where sourcing would flip it on in the caller behind their back.
og_context || exit 1       # sets ROOT OG OG_ID OG_VER REG; FATALs loudly on any failure
```

| Function | Does |
|---|---|
| `og_context` | re-derive `$ROOT`/`$OG`/`$OG_ID`; FATAL on non-git, missing jq, missing or ambiguous install |
| `is_og_shaped <overlay>` | Gate A. Anchored so `Changelog:` does not count as `og:` |
| `subjects_of <overlay> <root>` | Gate B. Parse `## Subject repos`. rc=0 declared, rc=2 provisional (convention), rc=1 unresolved |
| `classify_path <path> <subject-dir> <root>` | Phase 6. Returns OK / DANGLING / UNVERIF / SKIP(glob). Walks the full parent chain |
| `check_freshness <id> <reg>` | Phase 1. SHA comparison. Returns UNVERIF -- never "up to date" -- if the fetch fails or the marketplace is missing |

Every one of these fails **loudly**. None returns an empty result that could be read as "clean".

## Phase 0 -- Gates. Build the overlay list the later phases will iterate.

The gates must **remove** overlays from the list, not merely print about them. A gate that
`echo`s "LEGACY" and lets every later phase run anyway is not a gate.

```bash
# (source the lib + og_context, as above)
OVERLAYS=(); LEGACY=(); UNRESOLVED=(); PROVISIONAL=()
for d in "$ROOT"/.claude/skills/*-orchestrator; do
  [ -d "$d" ] || continue
  if ! is_og_shaped "$d"; then LEGACY+=("$d"); continue; fi     # Gate A
  subjects_of "$d" "$ROOT" >/dev/null; rc=$?                     # Gate B
  # rc=0 declared, rc=2 provisional (still usable -- say so), rc=1 genuinely unresolved.
  # `||` here would be a bug: it treats the provisional case as a failure and silently
  # skips every single-repo project.
  if [ "$rc" -eq 1 ]; then UNRESOLVED+=("$d"); continue; fi
  # rc=2 is refreshable but its subject was GUESSED. Track it separately: every Phase 6
  # finding against a guessed subject is only as good as the guess, and a report that
  # cannot say which those are reads as fully verified when it is not.
  if [ "$rc" -eq 2 ]; then PROVISIONAL+=("$d"); fi
  OVERLAYS+=("$d")
done

if [ "${#OVERLAYS[@]}" -eq 0 ] && [ "${#LEGACY[@]}" -eq 0 ] && [ "${#UNRESOLVED[@]}" -eq 0 ]; then
  echo "No og overlay here. You want /og:orchestrate-init."; exit 0
fi
printf 'refreshable: %s\n' "${OVERLAYS[@]:-}"
printf 'LEGACY (pre-og; migrate with /og:orchestrate-init, do NOT half-reconcile): %s\n' "${LEGACY[@]:-}"
printf 'UNRESOLVED (add a "## Subject repos" table): %s\n' "${UNRESOLVED[@]:-}"
printf 'PROVISIONAL (subject INFERRED, not declared -- findings are only as good as the guess): %s\n' "${PROVISIONAL[@]:-}"

# Gate C -- is .claude/ tracked? If not, `git diff` is empty and Phase 8's review contract is void.
git -C "$ROOT" ls-files --error-unmatch .claude >/dev/null 2>&1 \
  || echo "WARNING: .claude/ is UNTRACKED -- git diff will show nothing. 'git add' changes explicitly."
```

**Report all four lists, always.** A refresh that examined 4 of 6 overlays and said "clean" is a lie. State how many you checked, how many you skipped and why, and which ones rest on an *inferred* subject -- a PROVISIONAL overlay's Phase 6 findings are only as trustworthy as the convention that guessed its subject, so say so rather than presenting them as verified. The fix is to add a `## Subject repos` table.

`subjects_of` resolves an overlay's subject repo(s) from its `## Subject repos` table (rc=0), falling back to the `<name>-orchestrator -> <name>/` convention or, for a single-repo project, to the repo itself (rc=2, provisional -- say so). It returns rc=1 only when it genuinely cannot tell.

## Phase 1 -- Plugin freshness

```bash
check_freshness "$OG_ID" "$REG"    # OK | STALE (+ the missing commits) | UNVERIF
```

**A version comparison is not enough**, and `check_freshness` does not use one: plugin releases do not always bump the version string, so `claude plugin update` can report "already at the latest version" while the plugin is several commits behind. It compares the installed `gitCommitSha` against the marketplace's upstream head, and prints the commits you are missing.

It returns **UNVERIF -- never "up to date"** -- if the fetch fails or the marketplace checkout is absent. An offline run must not silently pass.

If STALE: `claude plugin update "$OG_ID"` (the marketplace suffix is part of the id; a bare name fails), **then restart** -- a refresh run before the restart is still reading the old rules. Offer to stop.

## Phase 2 -- Duplicated generics

og's agents are addressed `og:<name>`; project agents are bare. They are **distinct names and coexist** -- a project `editor` does not make `og:editor` unreachable. So the case for removing a duplicate is **maintenance, not shadowing**: a forked copy of a generic agent stops receiving upstream fixes and rots.

Report same-named pairs and **diff them**. Recommend deletion only where the project copy is a stale fork with no added domain knowledge, and show the diff. If it carries real domain knowledge it is a specialization with a colliding name: **rename it, do not delete it.** Also look for *functional* duplicates under different names, which exact-name matching misses.

## Phase 3 -- Rule namespacing (detect legacy numbering; migrate it)

**There is no collision detection here, and no renumbering.** Rules are namespaced by the repo that owns them (`OG-*` for the plugin, `<PREFIX>-*` for a repo), so a collision is impossible by construction. The plugin can add `OG-12` and no project changes anything.

That deletes what used to be the most destructive code in this skill. What is left is (a) migrating repos still on the old shared number line, and (b) checking citations resolve.

### Legacy numbering -> namespaced

Any repo bootstrapped before the prefix scheme has bare `12.`-style rules. Migrate them:

```bash
for ov in "${OVERLAYS[@]}"; do
  migrate_rules "$ov" "$OG" --dry      # show the old->new map and how every citation resolves
done

# ...then, only after the user confirms, and NEVER under --report-only.
# Note the loop: applying outside it would migrate only the LAST overlay and silently leave
# the rest on legacy numbering, while reporting success.
for ov in "${OVERLAYS[@]}"; do
  # A failed migration must halt THE SKILL, not just this loop. `|| echo` does not stop at all,
  # and `break` only leaves the loop -- Phases 4-8 then run against a repo where some overlays
  # are migrated and some are not, and report on it as if it were consistent. That is the
  # partial migration this skill exists to refuse. Exit non-zero and make the state explicit.
  migrate_rules "$ov" "$OG" --apply || {
    echo "FATAL: migration FAILED for $ov"
    echo "  Overlays before it in the list are ALREADY MIGRATED. This repo is now HALF-MIGRATED."
    echo "  Do NOT continue to Phase 4. Either fix the cause and re-run, or restore with"
    echo "  'git -C \"$ROOT\" checkout -- .claude/' and start over."
    exit 1
  }
done
```

`migrate_rules` is **the most dangerous thing this skill does**, because it rewrites rule headers *and the citations that point at them*. Get the citation mapping wrong and an overlay ends up pointing at one of the **plugin's** rules instead of its own -- which is exactly the bug the namespacing exists to eliminate. So it:

- reads the prefix from the overlay's `## Subject repos` table, and **FATALs** if absent rather than inventing one;
- builds an **explicit old->new map** and applies only that map -- never a blind substitution;
- classifies each citation into one of three buckets, and **rewrites only the first**:
  - a number in the map -> **this overlay's own rule**. Rewritten: `Rule 13` -> `SCORING-2`.
  - a number in og's range and not in the map -> **probably universal** (`Rule 2` -> `OG-2`).
    Reported with the OG rule's title so a human can confirm, and **left alone**. It only
    *probably* means OG-2: the old scheme told projects to start at 12 precisely so they would
    not collide with og's 0-11, so a low number is more likely a stale citation than an
    intentional one. Rewriting on a likelihood is the guess that namespacing exists to kill.
  - anything else -> ***AMBIGUOUS***. Flagged for a human, **left alone**.
- **FATALs if it cannot read og's rule range**, rather than misclassifying every citation;
- **asserts the rule count survived** and aborts rather than writing a half-migrated file. A partial rewrite that reads as success is the failure mode this skill exists to prevent.

Rules restart at **1** after migration -- they no longer have to dodge the plugin's range. That is the whole point.

### Citations must resolve

```bash
# NOT `\b`: that is a GNU grep extension. BSD/macOS `grep -E` does not treat it as a word
# boundary, so it matches NOTHING -- and an empty result here reads as "no citations".
grep -oE '(^|[^A-Za-z0-9_])[A-Z][A-Z0-9]*-[0-9]+' "$ov/SKILL.md" \
  | grep -oE '[A-Z][A-Z0-9]*-[0-9]+' | sort -u        # OG-3, DEPLOY-1, ...
```

Every `OG-N` must exist in the plugin's rules doc; every `<PREFIX>-N` must exist in an overlay reachable from here. A citation that does not resolve is a real bug -- and it used to be an *invisible* one: under the old shared number line, an overlay saying "see Rule 11" (meaning its own eleventh rule) silently began resolving to universal `OG-11`, a real rule that says something else entirely. Prefixes make that impossible; this catches the leftovers.

Also flag:
- **A project rule restating an `OG-*` rule.** The plugin already guarantees it; the copy will drift.
- **A project rule restating another repo's rule.** It should be a citation (`see DEPLOY-3`), not a second copy.

## Phase 4 -- Anti-patterns

Grep for each; do not eyeball.

1. **A project rule restating a plugin rule.** Check **both** rule docs -- the plugin ships two, and an overlay can restate either:

   | Doc | Rules | Audience |
   |---|---|---|
   | `docs/universal-orchestrator-rules.md` | `OG-0`..`OG-11` | orchestrators |
   | `docs/claude-agent-rules.md` | `R1`..`R9` | every subagent |

   Reading only the first is how a live run missed an overlay restating **R1** (AI disclosure) nearly verbatim, exception list and all.

   Then apply the same discipline Phase 2 uses for agents, and for the same reason: **diff before you delete.** A pure restatement becomes a **citation** (`see OG-11`, `see R1`) -- the copy drifts, and the drift is the bug. But a rule that restates a plugin rule *and adds a real project constraint on top* is not a duplicate: keep the delta, drop the copied part, and cite the rest. Deleting the whole rule because its first sentence was familiar throws away the sentence that mattered.
2. **A rule shaped as a list of forbidden binaries** (`NEVER invoke pytest, ruff, docker compose`). It collides with legitimate ad-hoc use, and an agent that meets a contradiction stops trusting the rule. If the plugin ships a "use the project's tooling" rule, this is a restatement of it -- **look up its number, do not assume it.**
3. **A blanket "NEVER do X" the overlay itself violates.** Extract each prohibition and grep for its counterexample.

## Phase 5 -- Fact-check the overlay (the phase that earns this skill)

**The overlay is the primary instruction an agent follows. If it lies, the agent acts on the lie.** Nothing validates it, so it rots invisibly -- until an agent runs a command that does not exist.

Delegate this; it is read-heavy. One agent per overlay, in parallel. Record every claim as **verified / FALSE / VIOLATED / unverifiable**, and never collapse the last into FALSE.

**Sort the claim before you judge it.** An overlay says two different kinds of thing, and they fail differently:

- A **descriptive** claim ("the CLI is built on Textual", "the default branch is `main`") can be *FALSE*.
- A **normative** rule ("never use `powerdns_record`; always `dns_a_record_set`") cannot be false -- it is a policy. What it can be is **VIOLATED**, by code that does the forbidden thing.

Marking a normative rule FALSE because the code disobeys it is backwards, and the remedy it implies -- "correct the overlay" -- would delete the rule instead of fixing the code. So: for every "never X" / "always Y" rule, grep the **subject repo** for its counterexample and report **VIOLATED** with the offending files. That is a finding about the *repo*, not the overlay, and it is often the most valuable thing this phase produces.

(Found by running this. A workspace rule said `powerdns_record` was permitted only for NS/glue in one file; the fact-check reported the rule FALSE. The rule was right -- five current Terraform files were breaking it.)

| Claim | How to falsify it |
|---|---|
| Build/test/lint commands | Read the justfile/Makefile/package.json. Does the recipe exist? Does CI run it? |
| Default branch | `git -C <subject> remote show origin` -- **never** the cached `origin/HEAD`, which can name a branch that no longer exists |
| GitHub slug | `gh repo view <slug>` -- renamed repos redirect, so a stale name still "works" |
| Paths, classes, modules | `ls` / grep them, **inside the subject repo** |
| Agent names | Do they resolve, bare or `og:`-prefixed? |
| Ports, containers, hostnames | Check the compose file |
| Issues/PRs cited as open | `gh issue view N` -- still open, or closed months ago? |

**Run these against the repo the overlay is ABOUT** (`subjects_of`), not the repo you are standing in. In a workspace, one `git remote show origin` from the root answers for the *workspace* and is wrong for every sub-repo.

Real examples, all confidently stated, all false: "Makefile-first" in a repo whose Makefile has no task targets and whose CI runs `just`; "Rust CLI" for a Python repo; a submodule pinned to a branch that does not exist; a module renamed upstream months earlier.

## Phase 6 -- Dangling references

**Do not hardcode a list of today's filenames.** The repos most in need of a refresh are the *pre-og* ones, whose overlays point at pre-og paths. A grep for current names finds nothing there and reports clean -- exactly backwards.

Extract the paths each overlay references and classify each with `classify_path`, **against that overlay's subject repo**:

```bash
for ov in "${OVERLAYS[@]}"; do
  # A path belongs to the OVERLAY, not to one of its subjects: a multi-repo overlay documents
  # paths in both repos and says which is which only in prose. So classify each path against
  # EVERY subject and keep the best verdict. Checking each subject in turn and printing per
  # (subject,path) is a cross-product: `deployment/ops_container/...` exists, but checked against
  # the sibling `infra-deployment` it does not, and gets reported DANGLING. That is a false alarm
  # on a correct doc reference -- the one outcome Boundaries says is worse than a silent pass.
  # DANGLING only when the path resolves under NO subject.
  SUBS=(); while IFS= read -r _s; do [ -n "$_s" ] && SUBS+=("$_s"); done \
    < <(subjects_of "$ov" "$ROOT" | cut -f1)      # not `mapfile`: bash 4+, macOS ships 3.2
  while read -r p; do
    [ -n "$p" ] || continue
    best=""; where=""; missing=""; unseen=""; soft=""; softwhere=""
    for SUB in "${SUBS[@]}"; do
      BASE="$ROOT/$SUB"; [ "$SUB" = "." ] && BASE="$ROOT"
      c=$(classify_path "$p" "$BASE" "$ROOT")
      case "$c" in
        OK*)        best="$c"; where="$SUB"; break ;;               # resolved somewhere: done
        SKIP*)      [ -z "$best" ] && { best="$c"; where="$SUB"; } ;;  # a glob is not a file
        IMPRECISE*) [ -z "$soft" ] && { soft="$c"; softwhere="$SUB"; } ;;  # exists, cited loosely
        DANGLING*)  missing="$missing $SUB" ;;                       # subject SEEN, file absent
        UNVERIF*)   unseen="$unseen $SUB" ;;                         # subject not checked out
      esac
    done
    # IMPRECISE means the file EXISTS -- it outranks anything that says it does not.
    [ -z "$best" ] && [ -n "$soft" ] && { best="$soft"; where="$softwhere"; }
    # Only decide once every subject has voted. Letting UNVERIF beat DANGLING as we go would let
    # a subject that is merely NOT CHECKED OUT bury a DANGLING that another subject *proved* --
    # and UNVERIF means "the doc is probably right, you just cannot see it", which would then be
    # a lie. Letting DANGLING win outright is the opposite error: the file may well exist in the
    # subject we could not see. When both happen, say both.
    if [ -z "$best" ]; then
      if   [ -z "$unseen" ];  then best="DANGLING";         where="(none of:$missing)"
      elif [ -z "$missing" ]; then best="UNVERIF";          where="(not checked out:$unseen)"
      else                         best="DANGLING(partial)"; where="(absent in:$missing; NOT CHECKED OUT:$unseen)"
      fi
    fi
    printf '%s  [%s:%s] %s\n' "$best" "$(basename "$ov")" "$where" "$p"
  done < <(grep -oE '`[^`]+`' "$ov/SKILL.md" | tr -d '`' \
           | grep -E '^(~/|\./|[A-Za-z0-9_.-]+/)' \
           | grep -E '\.(md|json|ya?ml|sh|py|tf|toml|cfg|ini|lock)$|/(Dockerfile|Makefile|[Jj]ustfile|Cargo\.toml|go\.mod|CODEOWNERS|LICENSE|NOTICE|OWNERS)$|/$' \
           | sort -u)
done | grep -v '^OK'
```

`classify_path` returns **SKIP** for globs (a routing-table pattern is not a file), **UNVERIF** when the subject repo is not present at all (a worktree or partial clone -- the doc is probably right and you simply cannot see it), and **DANGLING** only for a path genuinely missing from a subject you *can* see.

It also emits **IMPRECISE**: the file *exists*, but the overlay cites it the way people say it rather than the way it sits on disk -- `02_network/dns.tf` for something that actually lives at `terraform/2026/regionals/02_network/dns.tf`. That is a documentation nit, **not** a dangling reference, and the difference matters: reported as DANGLING it invites "fixing" a doc that was correct. (This is not hypothetical. Both real citations of that path in this workspace were reported DANGLING until Phase 6 learned to look deeper.)

A multi-subject overlay can produce both at once, so Phase 6 also emits **DANGLING(partial)**: absent from a subject you *could* see, while another subject was not checked out. It is neither -- calling it UNVERIF buries a finding you actually proved, and calling it DANGLING invites deleting a doc whose file may be sitting in the repo you did not clone. Treat it as "check out the rest, then re-run".

Label findings by overlay. `basename` alone collapses six overlays to six identical `SKILL.md`s and makes the report unactionable.

Dated handovers and archived notes are **records, not instructions**. Do not rewrite them; add a "superseded" banner.

## Phase 7 -- Mechanical sync (report only)

```bash
og-sync          # REPORT. Do NOT pass --fix here.
```

`og-sync --fix` mutates, so it belongs in Phase 8 with every other change. Running it here breaks this skill's contract twice ("nothing changes before confirmation"; "`--report-only` changes nothing").

Validate read-only: each overlay's frontmatter `name:` matches its directory, and each agent file parses.

## Phase 8 -- Report, confirm, apply, verify

Report a table: category, what is wrong, the proposed fix, and **for every fact, the command that disproves the claim**. Keep unverifiable items in their own bucket, visibly separate from false ones. State how many overlays you checked, and name anything you skipped.

```text
DRIFT (repo: swccdc-workspace, 6 overlays checked, 0 skipped)

  plugin   og 0.1.5 installed, 0.1.7 available              -> update + restart
  agents   just-expert is a stale fork of og:just-expert    -> delete (2-line diff, no domain content)
  rules    scoring: legacy numbering (12., 13.)            -> migrate to SCORING-1..2
  FACT     scoring: "run `make test`" -> Makefile has no `test` target; CI runs `just test`
  UNVERIF  magpie: 4 paths -- magpie/ not present in this checkout (worktree? wrong cwd?)
  refs     2 docs point at a file that no longer exists
```

Then ask. Nothing is applied without confirmation, and **nothing at all under `--report-only`** -- not even `og-sync --fix`.

After applying: **re-verify. Do not assume the fix worked.** Re-run the checks and read the diff. When checking a value with a range or several spellings, enumerate the spellings -- a grep for `0-10` that misses `(11+)` is a false negative that reads exactly like a pass.

Leave the changes on a branch. **Do not open a PR and do not merge** (Rule 0).

---

## Boundaries

- **Never report a silent pass.** If a check could not run, say so.
- **Never rewrite an ambiguous citation.** A legacy `Rule N` inside the plugin's range may be a universal reference *or* a stale project one. Rewriting it is silently wrong in the second case; leaving it is visibly legacy. Flag it and let a human decide.
- **Never delete correct documentation because you could not see what it describes.** Unverifiable is not false.
- **Never delete a project agent carrying domain knowledge** because its name collides. Rename it.
- **Never rewrite dated handovers** to make them "correct". Banner them.
- **`--report-only` changes nothing.**
