"""Gap 5 mitigation: Pattern justification checker.

Domain agents recommend canonical patterns (e.g., triple-sensor voting,
FDI mode lattice). Each recommendation must cite which requirements justify
the pattern element. This checker validates that:

1. Every pattern recommendation has at least one requirement citation.
2. Cited requirement IDs actually exist in the requirements.
3. The citation is plausible (the requirement text mentions relevant terms).
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field


@dataclass(frozen=True, slots=True)
class PatternRecommendation:
    """A domain agent's pattern recommendation with justification."""

    pattern_element: str  # e.g., "triple_sensor_voting", "persistence_threshold"
    description: str  # human-readable description of the pattern
    requirement_citations: list[str]  # e.g., ["R3", "R7"]
    justification: str  # free-text explanation of why this pattern applies


@dataclass(frozen=True, slots=True)
class JustificationDiagnostic:
    """A diagnostic from pattern justification checking."""

    severity: str  # "error", "warning"
    code: str  # "JUST-1" through "JUST-3"
    message: str
    pattern_element: str = ""


# Diagnostic codes:
# JUST-1: Pattern recommendation has no requirement citation
# JUST-2: Cited requirement ID not found in requirements
# JUST-3: Citation plausibility check failed (requirement doesn't mention relevant terms)


def check_justifications(
    recommendations: list[PatternRecommendation],
    requirement_ids: set[str],
    requirements_text: str,
) -> list[JustificationDiagnostic]:
    """Validate pattern justification citations.

    Args:
        recommendations: Pattern recommendations from the domain agent.
        requirement_ids: Set of valid requirement IDs.
        requirements_text: Original requirements text for plausibility checking.

    Returns:
        List of justification diagnostics.
    """
    ds: list[JustificationDiagnostic] = []

    for rec in recommendations:
        # JUST-1: No citations
        if not rec.requirement_citations:
            ds.append(
                JustificationDiagnostic(
                    severity="warning",
                    code="JUST-1",
                    message=(
                        f"Pattern '{rec.pattern_element}' has no "
                        f"requirement citation."
                    ),
                    pattern_element=rec.pattern_element,
                )
            )
            continue

        for cited_id in rec.requirement_citations:
            # JUST-2: Invalid citation
            if cited_id not in requirement_ids:
                ds.append(
                    JustificationDiagnostic(
                        severity="error",
                        code="JUST-2",
                        message=(
                            f"Pattern '{rec.pattern_element}' cites "
                            f"requirement '{cited_id}' which does not exist."
                        ),
                        pattern_element=rec.pattern_element,
                    )
                )
                continue

            # JUST-3: Plausibility check
            if not _check_plausibility(
                rec.pattern_element, cited_id, requirements_text
            ):
                ds.append(
                    JustificationDiagnostic(
                        severity="warning",
                        code="JUST-3",
                        message=(
                            f"Pattern '{rec.pattern_element}' cites requirement "
                            f"'{cited_id}', but the requirement text does not "
                            f"mention terms related to this pattern."
                        ),
                        pattern_element=rec.pattern_element,
                    )
                )

    return ds


# ---------------------------------------------------------------------------
# Pattern-specific keyword sets for plausibility checking
# ---------------------------------------------------------------------------

_PATTERN_KEYWORDS: dict[str, set[str]] = {
    "triple_sensor": {"sensor", "triple", "redundant", "three", "voting"},
    "voting": {"vote", "voting", "majority", "consensus", "agreement"},
    "persistence": {
        "persist",
        "persistence",
        "consecutive",
        "cycles",
        "sustained",
        "duration",
    },
    "threshold": {"threshold", "bound", "limit", "tolerance", "margin"},
    "isolation": {"isolat", "fault", "fail", "degrade", "exclude"},
    "recovery": {"recover", "restore", "return", "reset", "healthy"},
    "degraded": {"degrade", "fallback", "reduced", "backup", "partial"},
    "median": {"median", "middle", "center"},
    "average": {"average", "mean"},
    "deviation": {"deviat", "disagree", "differ", "diverge", "outlier"},
    "agreement": {"agree", "match", "consistent", "close", "within"},
}


def _check_plausibility(
    pattern_element: str,
    requirement_id: str,
    requirements_text: str,
) -> bool:
    """Check if a requirement plausibly justifies a pattern element.

    Uses keyword matching: the requirement text (near the cited ID)
    should contain terms related to the pattern.
    """
    # Find the text near the requirement ID
    req_context = _extract_requirement_context(requirement_id, requirements_text)
    if not req_context:
        return True  # cannot check; assume plausible

    context_lower = req_context.lower()

    # Find matching keyword sets for this pattern element
    relevant_keywords: set[str] = set()
    pattern_lower = pattern_element.lower()
    for pattern_key, keywords in _PATTERN_KEYWORDS.items():
        if pattern_key in pattern_lower:
            relevant_keywords.update(keywords)

    if not relevant_keywords:
        return True  # no keywords to check; assume plausible

    # Check if any relevant keyword appears in the requirement context
    for keyword in relevant_keywords:
        if keyword in context_lower:
            return True

    return False


def _extract_requirement_context(
    requirement_id: str,
    requirements_text: str,
    window: int = 200,
) -> str:
    """Extract text around a requirement ID in the requirements document.

    Returns up to ``window`` characters before and after the ID.
    """
    # Find the requirement ID in the text
    pattern = re.escape(requirement_id)
    match = re.search(pattern, requirements_text, re.IGNORECASE)
    if not match:
        return ""

    start = max(0, match.start() - window)
    end = min(len(requirements_text), match.end() + window)
    return requirements_text[start:end]
