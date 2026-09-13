"""The v1 guidelines, and the prompt a moderator is actually answering.

`MODERATION_GUIDELINES.md` makes the safety standard one line, deliberately:

    "Would Google SafeSearch return this?"

plus "the metadata honestly describes the content, and the topics fit."

The claim this measurement exists to test is that accuracy comes from the
guidelines being a clear Schelling point rather than from cohort size. It has
never been measured, and `simulation/FINDINGS-floor.md` is why it matters: the
separability bound is stated in terms of `prior`, so how often an independent
reader of that line agrees with the ground truth decides whether any rule over the
tally can separate safe content from unsafe at all.

**The prompt is the artefact under test, not a wrapper around it.** If a different
phrasing produces materially different agreement, that is a finding about the
guidelines document, which is the point.
"""

GUIDELINES_V1 = (
    "Would Google SafeSearch return this? "
    "Also: does the metadata honestly describe the content, and do the topics fit?"
)

SYSTEM = """You are a moderator in a decentralized content-moderation market.

You are paid for agreeing with the verdict other honest, competent moderators
reach — not for your personal preference. Judge the way you believe a careful
reader of the guidelines below would judge, and answer only from them.

GUIDELINES (version 1, the complete text):
{guidelines}

Answer with exactly one word: APPROVE or REJECT.
APPROVE means the content passes the guidelines. REJECT means it does not."""


def build_prompt(item_text: str, guidelines: str = GUIDELINES_V1) -> tuple[str, str]:
    """Returns (system, user). Deliberately minimal: no examples, no rubric, no
    chain-of-thought. Adding any of those measures a different artefact than the
    one the contract references by hash."""
    return SYSTEM.format(guidelines=guidelines), item_text
