#!/usr/bin/env python3
"""Mutation testing for the three contracts.

A passing test suite says the code does what the tests check. It does not say the
tests check anything. Mutation testing asks the only question that matters: if the
contract were subtly wrong, would anything fail?

**Three outcomes, and the third is why this exists.**

    KILLED    the mutant compiles and at least one test fails. The suite caught it.
    SURVIVED  the mutant compiles and every test passes. The suite did NOT catch
              it, and that is a hole — either a missing test or dead code.
    INVALID   the mutant does not compile. It proves nothing either way.

An earlier generation of this repository's harnesses counted INVALID as KILLED.
That inflates the score with mutants no test could ever have caught, and the
number it produces looks like evidence. **INVALID is reported separately here and
is never scored.** The headline rate is killed / (killed + survived).

Speed. The full suite is dominated by invariant fuzzing, so mutants are run
against the fast suites first and only survivors are put through the invariant
run. A mutant killed by a unit test does not need the fuzzer, and this keeps a
campaign to minutes rather than hours.

Usage
-----
    python3 tools/mutate.py src/Moderation.sol
    python3 tools/mutate.py --all
"""

from __future__ import annotations

import argparse
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass

ROOT = pathlib.Path(__file__).resolve().parent.parent
#: `--fail-fast` stops at the first failing test. Most mutants die, and a dead
#: mutant needs one failure, not a whole suite.
FAST = ["forge", "test", "--no-match-path", "test/Invariant.t.sol", "--fail-fast"]
SLOW = ["forge", "test", "--match-path", "test/Invariant.t.sol"]

#: Campaigns compile through the LEGACY pipeline, not `via_ir`.
#:
#: Compilation is most of what a mutant costs, and `via_ir` is 30s a clean build
#: against 4.6s. That is 14s an iteration against 4s — a 400-mutant sweep in half
#: an hour rather than most of a day.
#:
#: Sound because a campaign measures the TEST SUITE, not the deployed bytecode.
#: Both pipelines implement the same Solidity semantics and differ in
#: optimization, so a test that catches a logic bug catches it under either. The
#: shipped profile and the ordinary `forge test` still use `via_ir`, so what ships
#: is still what is tested.
ENV = {**os.environ, "FOUNDRY_VIA_IR": "false"}

#: Set by `scratch()`. Every mutation and every `forge` run happens here.
WORK = ROOT


def scratch() -> pathlib.Path:
    """A throwaway copy of the project to mutate.

    **The real working tree is never touched.** An earlier run mutated `src/` in
    place, and a `git add -A` that happened to land mid-campaign committed two
    live mutants to main — one of them a `vt.settled = false` that makes a vote
    claimable repeatedly. The harness restored the originals correctly; the
    problem is that a campaign makes the tree untrustworthy for as long as it
    runs, and nothing else in the repository knows that.

    `lib/` is symlinked rather than copied: it is 9.5 MB of dependencies that no
    mutation touches.
    """
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="mutate-"))
    for d in ("src", "test", "script"):
        shutil.copytree(ROOT / d, tmp / d)
    shutil.copy2(ROOT / "foundry.toml", tmp / "foundry.toml")
    os.symlink(ROOT / "lib", tmp / "lib")
    return tmp

KILLED, SURVIVED, INVALID = "KILLED", "SURVIVED", "INVALID"


@dataclass
class Mutant:
    line_no: int
    before: str
    after: str
    rule: str
    verdict: str = ""
    killer: str = ""


# Each rule is (name, pattern, replacement). Patterns are applied to one line at
# a time and every distinct match position yields its own mutant.
RULES: list[tuple[str, str, str]] = [
    ("ge->gt", r">=", ">"),
    ("le->lt", r"<=", "<"),
    ("gt->ge", r"(?<![>=<])>(?![=>])", ">="),
    ("lt->le", r"(?<![<=>])<(?![=<])", "<="),
    ("eq->ne", r"==", "!="),
    ("ne->eq", r"!=", "=="),
    ("and->or", r"&&", "||"),
    ("or->and", r"\|\|", "&&"),
    ("plus->minus", r"(?<![+\-=<>!])\+(?![+=])", "-"),
    ("minus->plus", r"(?<![+\-=<>!])-(?![-=>])", "+"),
    ("true->false", r"\btrue\b", "false"),
    ("false->true", r"\bfalse\b", "true"),
    ("incr->decr", r"\+\+", "--"),
    ("zero->one", r"(?<![\w.])0(?![\w.x])", "1"),
    ("one->zero", r"(?<![\w.])1(?![\w.])", "0"),
    ("two->three", r"(?<![\w.])2(?![\w.])", "3"),
    ("three->two", r"(?<![\w.])3(?![\w.])", "2"),
]

#: Lines that cannot carry a meaningful mutation. Comments and pragmas produce
#: nothing but INVALID noise and slow the campaign down for no information.
SKIP = re.compile(r"^\s*(//|/\*|\*|pragma|import|$)")


def generate(src: str) -> list[Mutant]:
    out: list[Mutant] = []
    for i, line in enumerate(src.splitlines(), start=1):
        if SKIP.match(line):
            continue
        # strip trailing comments so a mutation inside one is never generated
        code = line.split("//")[0]
        if not code.strip():
            continue
        for rule, pat, rep in RULES:
            for m in re.finditer(pat, code):
                mutated = code[: m.start()] + rep + code[m.end() :] + line[len(code) :]
                if mutated == line:
                    continue
                out.append(Mutant(i, line, mutated, rule))
    return out


def run(cmd: list[str], timeout: int) -> tuple[bool, str]:
    try:
        p = subprocess.run(
            cmd, cwd=WORK, capture_output=True, text=True, timeout=timeout, env=ENV
        )
        return p.returncode == 0, p.stdout + p.stderr
    except subprocess.TimeoutExpired:
        return False, "TIMEOUT"


def compiles(out: str) -> bool:
    """A compile failure is INVALID, not a kill. Distinguishing the two is the
    whole reason this harness is trusted at all."""
    markers = (
        "Compiler run failed",
        "Compilation failed",
        "error[",
        "ParserError",
        "TypeError",
        "DeclarationError",
    )
    return not any(m in out for m in markers)


def first_failure(out: str) -> str:
    m = re.search(r"\[FAIL:?[^\]]*\]\s+(\w+)", out)
    return m.group(1) if m else "?"


def campaign(rel: str, limit: int | None, timeout: int) -> dict:
    """`rel` is a path relative to the project root, mutated inside `WORK`."""
    path = WORK / rel
    original = path.read_text()
    lines = original.splitlines(keepends=True)
    mutants = generate(original)
    if limit:
        # deterministic thinning, spread across the file rather than the head
        step = max(1, len(mutants) // limit)
        mutants = mutants[::step][:limit]

    print(f"\n=== {path.name}: {len(mutants)} mutants ===", flush=True)
    started = time.time()

    try:
        for n, mut in enumerate(mutants, start=1):
            patched = list(lines)
            patched[mut.line_no - 1] = mut.after + "\n"
            path.write_text("".join(patched))

            ok, out = run(FAST, timeout)
            if not compiles(out):
                mut.verdict = INVALID
            elif not ok:
                mut.verdict = KILLED
                mut.killer = first_failure(out)
            else:
                # survived the fast suites — the fuzzer gets a turn
                ok2, out2 = run(SLOW, timeout)
                if not compiles(out2):
                    mut.verdict = INVALID
                elif not ok2:
                    mut.verdict = KILLED
                    mut.killer = first_failure(out2) + " (invariant)"
                else:
                    mut.verdict = SURVIVED

            mark = {KILLED: ".", SURVIVED: "S", INVALID: "i"}[mut.verdict]
            print(mark, end="", flush=True)
            if n % 60 == 0:
                print(f"  {n}/{len(mutants)}", flush=True)
    finally:
        path.write_text(original)

    killed = [m for m in mutants if m.verdict == KILLED]
    survived = [m for m in mutants if m.verdict == SURVIVED]
    invalid = [m for m in mutants if m.verdict == INVALID]
    scored = len(killed) + len(survived)

    print(f"\n\n{path.name}  ({time.time() - started:.0f}s)")
    print(f"  killed   {len(killed)}")
    print(f"  survived {len(survived)}")
    print(f"  INVALID  {len(invalid)}   (not scored — these prove nothing)")
    print(f"  rate     {len(killed)}/{scored} = {100 * len(killed) / scored:.1f}%" if scored else "  rate   n/a")

    if survived:
        print("\n  survivors:")
        for m in survived:
            print(f"    L{m.line_no:<5} {m.rule:<14} {m.before.strip()[:72]}")

    return {
        "file": path.name,
        "killed": len(killed),
        "survived": len(survived),
        "invalid": len(invalid),
        "survivors": survived,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="*")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--limit", type=int, default=None, help="thin to N mutants per file")
    ap.add_argument("--timeout", type=int, default=300)
    args = ap.parse_args()

    targets = (
        [f"src/{f}" for f in ("Moderation.sol", "StakeRegistry.sol", "IndexRegistry.sol")]
        if args.all
        else [str(pathlib.Path(f)) for f in args.files]
    )
    if not targets:
        ap.error("give a file or --all")

    global WORK
    WORK = scratch()
    print(f"mutating a copy at {WORK}\nthe real tree is untouched\n")

    try:
        ok, out = run(FAST, args.timeout)
        if not ok:
            print("the suite is not green before mutating; fix that first", file=sys.stderr)
            return 2

        results = [campaign(t, args.limit, args.timeout) for t in targets]
    finally:
        shutil.rmtree(WORK, ignore_errors=True)

    k = sum(r["killed"] for r in results)
    s = sum(r["survived"] for r in results)
    i = sum(r["invalid"] for r in results)
    print("\n" + "=" * 60)
    print(f"combined: {k} killed, {s} survived, {i} INVALID (unscored)")
    if k + s:
        print(f"combined rate: {k}/{k + s} = {100 * k / (k + s):.1f}%")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
