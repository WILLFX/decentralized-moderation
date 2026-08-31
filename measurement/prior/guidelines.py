"""The v1 guidelines, and the prompt a moderator is actually answering.

README §3.6 P5 makes the guidelines one line, deliberately:

    "Would Google SafeSearch return this?"
    plus "the metadata honestly describes the content, and the topics fit."

and README §3.6 states the claim this measurement exists to test:

    "Accuracy comes from the guidelines being a clear Schelling point,
     not from cohort size."

`state-machine-v3.md` §10 and `v2-audit-checklist.md` §5.3 have both carried that
as open for three audits. Everything downstream — `f(a)`, the permanence of
`REJECTED` (§8.4), the reachability of `SUPER_SAFE` (§8.3) — is a function of how
often an independent reader of that line agrees with the ground truth.

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
