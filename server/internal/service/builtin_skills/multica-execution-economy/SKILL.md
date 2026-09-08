---
name: multica-execution-economy
description: "Use when executing a task that will take many tool round-trips and grow a large context: multi-file or multi-repo changes, deep investigation, acceptance or verification runs, or large-diff reviews — also when a tool or environment failure is blocking the task. Not for one-shot tasks."
user-invocable: false
---

# Economize long-task execution

**Model turns and context are the budget; tools are nearly free.** In one
instrumented 40-minute session, tools were busy ~12% of wall time; ~87% went
to model turns between tool results. ~90% of shell calls ran one per turn, and
sixteen files were re-read whole after already being read (22 redundant
reads). Every rule below exists because that session did the opposite.

A second session — one `create` command taking 5.4 minutes — spent 4.5 of
them hunting a missing credential through platform internals; the documented
mechanism was one skill read away ninety seconds in, and the hunt continued
three minutes past it. Rules 2 and 7 exist for that session. A third session —
a 53-minute live acceptance run — spent 12 minutes re-reading context its
dispatch had already summarized, swept the same service logs nine times, and
lost two minutes to one unbounded probe; rules 2, 5, and 8 carry its numbers.

Work the rules in order of impact: batch turns, then checkpoint, then shrink
context, then keep commands from failing. The later rules fire on their
triggers: a review round to consolidate (6), an environment failure (7), a
verification run opening (8).

## 1. Batch independent work into one turn

Issue independent lookups — searches, file reads, status checks — as parallel
tool calls in the same turn. Serialize only when the next action genuinely
depends on the previous result.

- Yes: one turn runs the three searches whose answers you will weigh together.
- No: "search, read result, decide the next search, run it" — that is one turn
  of overhead per lookup.
- Deciding whether results are independent is the crux of this rule: two
  lookups are dependent only when the second one's *arguments* come from the
  first one's output. "What other callers exist" after a search names no
  arguments from that search — run it in the same turn.

## 2. Checkpoint a conclusion once — a gate, a dead end, or a finding

When a design gate, verification, or investigation concludes, write its
conclusion to your notes/plan file in one line. Every later turn that needs
that fact **cites the file** — it does not re-run the evidence, re-grep, or
re-read what produced it.

- Re-verifying an unchanged fact is the largest avoidable cost in a long task:
  one session re-derived the same passed gate six times, each at a 30–70
  second turn.
- A conclusion is stale only when its inputs changed — a file you edited, a
  branch that moved, a deploy that replaced the state it was checked against.
  Name the input in the checkpoint line so staleness is decidable:
  `masking gate passed (checked: v1.0.3 DDL, converter paths)`, not
  `masking gate passed`.

**Dead ends are conclusions too.** When you are investigating — a failed
command, a missing credential, an unexpected behavior — keep a probe log in
your notes before the first probe: one line per source checked and what it
yielded, one line per established fact. Check the log before every new probe;
a source already in it is not probed again, and a fact already in it is not
re-derived. One session re-probed the same config three times, the same log
five times, and re-ran the same whole-tree search four times because none of
it was written down.

**A log you re-check needs a watermark.** Note where the last sweep ended
(time or line) and scan only the delta. Re-scanning the same window each
check is re-probing; one acceptance run swept the same service logs nine
times.

## 3. Read deliberately; never re-read a whole file

A file read whole this session is context you already paid for. When it comes
up again, recall from your own notes and cite line numbers; do not re-read it
unless it changed.

First read of a file that is *evidence* (not the object of your edit):

- Prefer search output with context over a whole-file read: line-numbered
  matches (`grep -n`) or a context window (`grep -n -C 5`) usually answers
  "where and how is this used".
- Read a whole file only when it genuinely is the object of work — the file
  you are about to edit, or the diff you are reviewing.
- Every kilobyte of full-file content slows every later turn, and it stays
  for the rest of the task.

## 4. Keep tool output small before it enters context

Pipe noisy command output through `tail`, `grep`, or a count before it lands:
`pnpm exec tsc --noEmit 2>&1 | tail -20` beats a full dump. Trimming must not
hide the command's own exit status — with a pipe, `$?` is the last stage's,
so run `set -o pipefail` (or capture `${PIPESTATUS[0]}`) when the status
matters. Use quiet flags on build/test tools. Print compact markers
(`=== result: 3 matches ===`) instead of full listings when all that matters
is presence or count. The platform truncates oversized output, but truncation
happens *after* the waste.

## 5. Make every shell command self-contained, bounded, and honest

A failed command costs a repair turn; a command that "fails" on an empty
result costs a wrong turn; a command that hangs costs minutes. When a command
*must* succeed, the cheapest failure is a loud one — read the error once and
fix, do not rerun blind. For the rest:

- Shell state does not survive between tool calls: background processes,
  tunnels, and exported variables are gone when the command returns. A step
  that needs one — an SSH tunnel, a long-lived token, a dev server — must
  create, use, and destroy it in a single command. One session rebuilt the
  same tunnel and re-injected the same variable twice before learning this.
- Bound every network probe with a timeout (`curl --max-time 10`, `ssh -o
  ConnectTimeout=10`). An unresponsive endpoint should cost seconds, not the
  two minutes one unreachable probe cost in an acceptance run.
- Quote every shell glob: `--include='*.java'`, never `--include=*.java`. An
  unquoted glob with no matches aborts the command before it runs; one session
  hit the same quoting error three times before learning it.
- A search that legitimately finds nothing is not a failure. When empty output
  is a valid outcome, end the command with `|| true` (or record the exit code
  with `; echo exit:$?`) so the result is a fact, not an error.

## 6. Consolidate verification into one round

Run independent reviews and checks in one parallel round, fix in one
consolidated pass, verify once. A review → fix → next review → fix chain
multiplies context-warmup turns: each new review re-derives the state the
previous one established. When you know two reviews will both be needed,
dispatch them together before any fixes — the fixes can then land in one pass.

## 7. Environment failure is a state to exit or report, not a problem to solve

When a command fails for an environmental reason — a missing credential or
tool, an error naming infrastructure instead of your task — that component is
not your task. Follow the bounded script:

1. Two probes at most to confirm it is environmental (is the credential or
   tool absent for every command?).
2. Read the platform skill or documentation for the intended mechanism before
   probing further. In the session above the mechanism was one skill read
   away, and the hunt continued three minutes past that read.
3. If the documented mechanism does not hold and you are not the platform's
   owner, stop and report the failure with your evidence. Do not repair the
   platform from inside the task — do not walk its process tree for
   credentials, mine its logs or past transcripts, or read its sources for a
   workaround. The report is the deliverable.

When the platform is your task — you are developing or debugging it — the
forensics are the work; rule 2's probe log applies to them too.

## 8. In verification runs, probe first and read docs to interpret

A read-only acceptance or verification run whose dispatch already names the
acceptance criteria should open with the cheapest live probe of the top-risk
item — not with a full re-read of the plan, spec, design, and past reports.
Probe results tell you which document you actually need; reading everything
first pays off only after you probe anyway. One acceptance run spent 12 of
its 53 minutes re-deriving context its dispatch had already summarized before
its first acceptance probe.

When the run must first *establish* something — a gate the plan makes
mandatory, a baseline later steps compare against — establish it first. That
is a dependency, not recon, and rule 2's checkpoint still applies to it.

The run's own checks are never rule-2 re-verification: acceptance exists to
produce independent evidence of the live system, and that evidence — not an
earlier session's checkpoint — is the deliverable.

## Red flags — stop and apply the rule

| You catch yourself doing this | Rule |
|---|---|
| "One more quick grep to be sure" about a conclusion already recorded | 2 — the checkpoint line is the recorded answer; re-check only if its named inputs changed |
| Probing the same config, log, or directory tree again during a diagnosis | 2 — the probe log lists what you checked |
| Debugging a missing credential or tool from inside a task | 7 — two probes, then the docs, then report |
| Rebuilding a tunnel, server, or env var that an earlier call already created | 5 — create, use, destroy in one command |
| Full doc re-read before the first probe in an acceptance run | 8 — the dispatch named the criteria; probe first |
| Running independent lookups one at a time, each in its own turn | 1 |
| Re-reading a file to recall what it contains | 3 — you wrote it down; cite it |
| A search command aborted on an empty match | 5 — it was a valid answer |
| Full build output dumped into the result | 4 |
| Starting the second review only after the first one's fixes landed | 6 |

## Common mistakes

- **Batching dependent work.** Parallel calls are only safe when arguments do
  not come from each other's results. When in doubt, one turn with the cheap
  lookups, then the dependent one.
- **Checkpointing without naming inputs.** A conclusion line that does not say
  what it was checked against forces a re-check the moment anything changes.
- **Over-trimming output.** Truncating the one line you actually need to read
  (an error message, a test failure) saves nothing. Trim the noise, keep the
  signal.
- **Deliberating before an obvious first step.** The 5.4-minute create-command
  session from the introduction opened with a 35-thousand-character analysis
  and still made the obvious first call. When the next action is unambiguous,
  run it — the result teaches more than the deliberation.
- **Diagnosis without a probe log.** Re-deriving the same deduction every turn
  and re-probing the same sources is what happens when findings stay in your
  head. One written line per dead end ends the loop.
