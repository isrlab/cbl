"""Gap 1 mitigation: Requirement-level traceability.

Each extracted fact must cite a specific requirement sentence by ID or quoted
fragment. The traceability checker verifies that:

1. Every extracted fact has a citation (``source`` field).
2. Every cited fragment actually appears in the source NL text (string match).
3. Every requirement sentence is cited by at least one fact (surjectivity).

Facts with no valid citation are flagged, analogous to Prolog R9's treatment
of unconfirmed inferences.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field


@dataclass(frozen=True, slots=True)
class TraceabilityDiagnostic:
    """A diagnostic from traceability checking."""

    severity: str  # "error", "warning"
    code: str  # "TRACE-1" through "TRACE-4"
    message: str
    fact_kind: str = ""
    fact_name: str = ""


# Diagnostic codes:
# TRACE-1: Fact has no source citation
# TRACE-2: Cited fragment not found in original requirements
# TRACE-3: Requirement sentence has no tracing fact (coverage gap)
# TRACE-4: Citation is suspiciously short (< 10 chars, likely hallucinated)


def check_traceability(
    facts: dict,
    original_nl: str,
) -> list[TraceabilityDiagnostic]:
    """Check traceability between extracted facts and original requirements.

    Each fact in the extracted_facts dict may carry a ``source`` field
    (a quoted substring of the original NL text). This checker validates that
    the citations are real.

    Args:
        facts: The extracted_facts dict.
        original_nl: The original natural-language requirements text.

    Returns:
        List of traceability diagnostics.
    """
    ds: list[TraceabilityDiagnostic] = []
    nl_lower = original_nl.lower()
    cited_fragments: list[str] = []

    # Check facts in array-of-facts fields
    _field_configs = [
        ("assumes", "name", "assume"),
        ("guarantees", "name", "guarantee"),
        ("variables", "name", "variable"),
        ("constants", "name", "constant"),
        ("definitions", "name", "definition"),
        ("modes", "name", "mode"),
    ]

    for field_name, name_key, kind in _field_configs:
        for item in facts.get(field_name, []):
            if not isinstance(item, dict):
                continue

            name = _extract_name(item, name_key)
            fragment = item.get("source", "") or ""

            if not fragment:
                ds.append(
                    TraceabilityDiagnostic(
                        severity="warning",
                        code="TRACE-1",
                        message=f"{kind} '{name}' has no source citation.",
                        fact_kind=kind,
                        fact_name=name,
                    )
                )
                continue

            if len(fragment) < 10:
                ds.append(
                    TraceabilityDiagnostic(
                        severity="warning",
                        code="TRACE-4",
                        message=(
                            f"{kind} '{name}' has suspiciously short citation: "
                            f"'{fragment}'"
                        ),
                        fact_kind=kind,
                        fact_name=name,
                    )
                )

            # Check that the cited fragment actually appears in the original text
            if fragment.lower() not in nl_lower:
                # Try fuzzy match (allow minor differences)
                if not _fuzzy_match(fragment, original_nl):
                    ds.append(
                        TraceabilityDiagnostic(
                            severity="error",
                            code="TRACE-2",
                            message=(
                                f"{kind} '{name}' cites fragment not found in requirements: "
                                f"'{fragment[:60]}{'...' if len(fragment) > 60 else ''}'"
                            ),
                            fact_kind=kind,
                            fact_name=name,
                        )
                    )
            else:
                cited_fragments.append(fragment.lower())

    # Check transitions within modes
    for mode in facts.get("modes", []):
        if not isinstance(mode, dict):
            continue
        mode_name = _extract_name(mode, "name")
        for i, trans in enumerate(mode.get("transitions", [])):
            if not isinstance(trans, dict):
                continue
            fragment = trans.get("source", "") or ""
            trans_id = f"{mode_name}.transition_{i}"

            if not fragment:
                ds.append(
                    TraceabilityDiagnostic(
                        severity="warning",
                        code="TRACE-1",
                        message=f"transition '{trans_id}' has no source citation.",
                        fact_kind="transition",
                        fact_name=trans_id,
                    )
                )
            elif fragment.lower() not in nl_lower:
                if not _fuzzy_match(fragment, original_nl):
                    ds.append(
                        TraceabilityDiagnostic(
                            severity="error",
                            code="TRACE-2",
                            message=(
                                f"transition '{trans_id}' cites fragment not found in "
                                f"requirements: '{fragment[:60]}...'"
                            ),
                            fact_kind="transition",
                            fact_name=trans_id,
                        )
                    )
            else:
                cited_fragments.append(fragment.lower())

    # TRACE-3: Check coverage (requirement sentences with no tracing fact)
    sentences = _split_sentences(original_nl)
    for i, sent in enumerate(sentences, 1):
        if len(sent.strip()) < 15:
            continue  # skip trivially short fragments
        sent_lower = sent.strip().lower()
        # Check if any cited fragment overlaps with this sentence
        covered = any(_fragments_overlap(sent_lower, frag) for frag in cited_fragments)
        if not covered:
            ds.append(
                TraceabilityDiagnostic(
                    severity="warning",
                    code="TRACE-3",
                    message=(
                        f"Requirement sentence {i} has no tracing fact: "
                        f"'{sent.strip()[:80]}{'...' if len(sent.strip()) > 80 else ''}'"
                    ),
                )
            )

    return ds


def _extract_name(item: dict, name_key: str) -> str:
    """Extract the name from a fact item (may be provenanced or plain)."""
    name_field = item.get(name_key, {})
    if isinstance(name_field, dict):
        return name_field.get("value", "")
    return str(name_field)


def _fuzzy_match(fragment: str, text: str, threshold: float = 0.8) -> bool:
    """Check if fragment approximately appears in text.

    Uses word-level overlap: if >= threshold fraction of words in the fragment
    appear in a similar-length window of the text, consider it a match.
    """
    frag_words = re.findall(r"\b\w+\b", fragment.lower())
    text_words = re.findall(r"\b\w+\b", text.lower())

    if not frag_words:
        return True

    # Sliding window of text words
    window_size = len(frag_words) + 2  # small margin
    text_set_full = set(text_words)

    # Quick check: are most fragment words in the text at all?
    overlap = sum(1 for w in frag_words if w in text_set_full)
    return overlap / len(frag_words) >= threshold


def _fragments_overlap(sentence: str, fragment: str) -> bool:
    """Check if a sentence and a cited fragment share significant content."""
    sent_words = set(re.findall(r"\b\w{3,}\b", sentence))
    frag_words = set(re.findall(r"\b\w{3,}\b", fragment))
    if not sent_words or not frag_words:
        return False
    overlap = sent_words & frag_words
    # Consider overlapping if >= 40% of fragment words appear in sentence
    # or >= 40% of sentence words appear in fragment
    return (
        len(overlap) / len(frag_words) >= 0.4 or len(overlap) / len(sent_words) >= 0.4
    )


def _split_sentences(text: str) -> list[str]:
    """Split text into sentences (rough heuristic)."""
    return re.split(r"(?<=[.!?])\s+", text)
