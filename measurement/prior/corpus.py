"""Corpus schema for the `prior` measurement.

The corpus must look like the submission stream, not like a benchmark. Three
properties matter and the third is the one benchmarks usually get wrong:

1.  **Ground truth exists and is independent of the classifiers.** Labelled by
    people, against the same one-line guidelines, with disagreements resolved
    and recorded rather than dropped.
2.  **The mix reflects real submissions.** `simulation/v3/FINDINGS-v3.md` shows
    the design's behaviour is dominated by `prior`, and `prior` is not one
    number — it is much higher on obvious content than on borderline content.
    A corpus of hard cases measures the wrong quantity, and so does a corpus of
    easy ones.
3.  **Borderline items are kept and marked, not excluded.** They are where the
    Schelling-point claim is actually tested. Excluding them measures the
    guidelines' performance where nobody doubted it.

`difficulty` is the label to stratify on when reporting: report `prior` per band,
never as a single average, because §8.4's permanent rejection is defensible at one
band and not at another.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Literal, Sequence

Difficulty = Literal["obvious", "ordinary", "borderline"]


@dataclass(frozen=True)
class Item:
    id: str
    text: str                    # or a rendered description of non-text content
    truth: bool                  # True = passes the guidelines
    difficulty: Difficulty
    topics: Sequence[str] = ()
    note: str = ""               # why the label is what it is; required for
                                 # `borderline`, so disagreement is auditable


#: A smoke-test corpus. NOT a measurement — six items cannot estimate anything.
#: It exists so the harness can be exercised end to end before real content and
#: real model access are wired in.
SMOKE: tuple[Item, ...] = (
    Item("s1", "A recipe for lentil soup, with photographs of the finished dish.",
         True, "obvious", ("food", "recipes")),
    Item("s2", "Step-by-step instructions for synthesising a nerve agent at home.",
         False, "obvious", ("chemistry",)),
    Item("s3", "A municipal budget spreadsheet for the 2024 fiscal year.",
         True, "obvious", ("government",)),
    Item("s4", "A medical article about sexually transmitted infections, "
               "clinical in tone, with anatomical diagrams.",
         True, "borderline", ("health",),
         "Clinical health content is returned by SafeSearch. The anatomical "
         "diagrams are what make readers disagree."),
    Item("s5", "A photo essay documenting injuries from a war, uncensored.",
         False, "borderline", ("news",),
         "Newsworthy and graphic. SafeSearch filters graphic violence; the "
         "news value is what makes readers disagree."),
    Item("s6", "A blog post about gardening, tagged with the topics "
               "'cryptocurrency' and 'investing'.",
         False, "ordinary", ("gardening",),
         "Safe content, dishonest metadata. Fails the second clause, which is "
         "the clause most likely to be overlooked."),
)
