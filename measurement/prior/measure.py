"""The harness: run N moderator configurations over a corpus, report two numbers.

    prior  — P(a moderator agrees with ground truth), per difficulty band
    rho    — intra-item correlation across configurations

**Both outputs are load-bearing and the second has never been measured.**
`f(a) = 3a² − 2a³` is the CDF of the median of three uniforms, which assumes the
tally is composed of independent judgments. `v2-audit-checklist.md` P1-4 and §5.6
have carried "AI identities are not independent moderators" as DEFERRED since the
first audit. `rho` is that quantity: at `rho = 0` a cohort of 32 is 32 opinions,
at `rho = 1` it is one opinion sampled 32 times, and `simulation/v3/correlated.py`
turns the pair into the design's numbers.

A **configuration** is what an operator actually runs: a model, a prompt, a
provider, a temperature. Two operators running the same model on the same prompt
are one configuration sampled twice, and the measurement should say so rather than
counting them as two.

Model access is the caller's. Pass any `classify(system, user) -> bool`.
"""

from __future__ import annotations

import itertools
import json
import statistics
from dataclasses import dataclass, field
from typing import Callable, Dict, Iterable, List, Sequence, Tuple

from corpus import Item
from guidelines import GUIDELINES_V1, build_prompt

Classifier = Callable[[str, str], bool]   # (system, user) -> APPROVE?


@dataclass
class Config:
    name: str
    classify: Classifier
    guidelines: str = GUIDELINES_V1


@dataclass
class Result:
    votes: Dict[Tuple[str, str], bool] = field(default_factory=dict)  # (cfg, item)
    errors: List[str] = field(default_factory=list)

    def dump(self, path: str) -> None:
        with open(path, "w") as fh:
            json.dump({"votes": {f"{c}|{i}": v for (c, i), v in self.votes.items()},
                       "errors": self.errors}, fh, indent=2)


def run(configs: Sequence[Config], items: Sequence[Item],
        repeats: int = 1) -> Result:
    """`repeats > 1` separates model nondeterminism from disagreement between
    configurations. Without it a temperature-driven flip is indistinguishable
    from a genuine difference of judgment, and only the second is decorrelation
    the design can rely on."""
    r = Result()
    for cfg in configs:
        for item in items:
            sysmsg, usermsg = build_prompt(item.text, cfg.guidelines)
            for k in range(repeats):
                key = (f"{cfg.name}#{k}" if repeats > 1 else cfg.name, item.id)
                try:
                    r.votes[key] = bool(cfg.classify(sysmsg, usermsg))
                except Exception as exc:                      # noqa: BLE001
                    r.errors.append(f"{key}: {exc!r}")
    return r


def prior_by_band(res: Result, items: Sequence[Item]) -> Dict[str, Tuple[float, int]]:
    """`P(vote == truth)`, per difficulty band. **Never report one average.**
    §8.4 makes `REJECTED` permanent on the strength of a false-rejection rate;
    that rate is defensible at one band and not at another, and a single mean
    hides which."""
    truth = {i.id: i.truth for i in items}
    band = {i.id: i.difficulty for i in items}
    acc: Dict[str, List[int]] = {}
    for (_, item_id), vote in res.votes.items():
        acc.setdefault(band[item_id], []).append(int(vote == truth[item_id]))
    out = {b: (statistics.fmean(v), len(v)) for b, v in acc.items()}
    allv = [x for v in acc.values() for x in v]
    if allv:
        out["ALL"] = (statistics.fmean(allv), len(allv))
    return out


def rho(res: Result, items: Sequence[Item]) -> float:
    """Intra-item correlation of correctness across configurations.

    Estimated as the mean pairwise agreement-above-chance on the *correctness*
    indicator, which is the quantity `f`'s independence assumption is about:

        rho = (observed pairwise agreement − expected under independence)
              / (1 − expected under independence)

    0 means configurations err independently — a cohort of N is N opinions.
    1 means they err together — a cohort of N is one opinion, N times, and the
    variance reduction the design pays a cohort for does not exist.
    """
    truth = {i.id: i.truth for i in items}
    by_item: Dict[str, List[int]] = {}
    for (cfg, item_id), vote in res.votes.items():
        by_item.setdefault(item_id, []).append(int(vote == truth[item_id]))

    obs, exp = [], []
    for correct in by_item.values():
        if len(correct) < 2:
            continue
        pairs = list(itertools.combinations(correct, 2))
        obs.append(statistics.fmean(1 if a == b else 0 for a, b in pairs))
        p = statistics.fmean(correct)
        exp.append(p * p + (1 - p) * (1 - p))
    if not obs:
        return float("nan")
    o, e = statistics.fmean(obs), statistics.fmean(exp)
    return 0.0 if e >= 1.0 else (o - e) / (1 - e)


def rho_is_usable(res: Result, min_configs: int = 8, min_items: int = 100) -> bool:
    """`rho` is badly biased at small rater counts and will read NEGATIVE on a
    handful of configurations even when errors are strongly shared — the
    per-item expectation is estimated from the same few votes it is compared
    against. Do not report it below roughly 8 configurations and 100 items."""
    cfgs = {c for c, _ in res.votes}
    items = {i for _, i in res.votes}
    return len(cfgs) >= min_configs and len(items) >= min_items


def report(res: Result, items: Sequence[Item]) -> None:
    print(f"votes {len(res.votes)}   errors {len(res.errors)}")
    print("\nprior, by difficulty band:")
    for b, (p, n) in sorted(prior_by_band(res, items).items()):
        print(f"    {b:>10}  {p:.4f}   (n={n})")
    r = rho(res, items)
    ok = rho_is_usable(res)
    print(f"\nrho (intra-item correlation of error): {r:.4f}"
          f"{'' if ok else '   <-- UNUSABLE: too few configs/items, see rho_is_usable'}")
    print("    0 -> a cohort of N is N opinions")
    print("    1 -> a cohort of N is one opinion sampled N times (P1-4 / O4)")
    print("\nFeed both into simulation/v3/correlated.py.")
