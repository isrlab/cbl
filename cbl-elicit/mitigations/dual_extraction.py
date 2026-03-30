"""Gap 1 mitigation: Dual extraction with structural diff.

Run extraction twice with different system prompts or temperatures.
Structurally diff the two extracted_facts.json outputs:
  - Agreement increases confidence.
  - Disagreements flag items for engineer review.

The diff itself is deterministic (no LLM involvement).
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field


@dataclass(frozen=True, slots=True)
class ExtractionDivergence:
    """A point where two extractions disagree."""

    category: str  # "mode_missing", "transition_different", "guard_different", etc.
    location: str  # where in the facts structure
    extraction_a: str  # value from extraction A
    extraction_b: str  # value from extraction B
    severity: str = "warning"  # "warning" or "error"


@dataclass
class DualExtractionReport:
    """Result of comparing two independent extractions."""

    agreement_score: float  # 0.0 to 1.0
    divergences: list[ExtractionDivergence] = field(default_factory=list)
    agreed_facts: int = 0
    total_facts: int = 0

    @property
    def summary(self) -> str:
        if self.total_facts == 0:
            return "No facts to compare."
        pct = self.agreement_score * 100
        return (
            f"Agreement: {self.agreed_facts}/{self.total_facts} facts "
            f"({pct:.0f}%). {len(self.divergences)} divergence(s)."
        )


def diff_extractions(facts_a: dict, facts_b: dict) -> DualExtractionReport:
    """Structurally diff two extracted_facts dicts.

    Compares:
    - System name
    - Initial mode
    - Assumes (by name)
    - Guarantees (by name, type, default)
    - Variables (by name, type, initial value)
    - Constants (by name, type, value)
    - Definitions (by name, body)
    - Modes (by name, transitions)

    Returns a report with divergences and agreement score.
    """
    divergences: list[ExtractionDivergence] = []
    agreed = 0
    total = 0

    # System name
    total += 1
    name_a = _get_provenanced_value(facts_a.get("system_name", {}))
    name_b = _get_provenanced_value(facts_b.get("system_name", {}))
    if name_a == name_b:
        agreed += 1
    else:
        divergences.append(
            ExtractionDivergence(
                category="system_name",
                location="system_name",
                extraction_a=str(name_a),
                extraction_b=str(name_b),
            )
        )

    # Initial mode
    total += 1
    init_a = _get_provenanced_value(facts_a.get("initial_mode", {}))
    init_b = _get_provenanced_value(facts_b.get("initial_mode", {}))
    if init_a == init_b:
        agreed += 1
    else:
        divergences.append(
            ExtractionDivergence(
                category="initial_mode",
                location="initial_mode",
                extraction_a=str(init_a),
                extraction_b=str(init_b),
            )
        )

    # Array fields: compare by name
    _array_configs = [
        ("assumes", "assume"),
        ("guarantees", "guarantee"),
        ("variables", "variable"),
        ("constants", "constant"),
        ("definitions", "definition"),
    ]

    for field_name, kind in _array_configs:
        items_a = _index_by_name(facts_a.get(field_name, []))
        items_b = _index_by_name(facts_b.get(field_name, []))
        all_names = set(items_a.keys()) | set(items_b.keys())

        for name in sorted(all_names):
            total += 1
            if name not in items_a:
                divergences.append(
                    ExtractionDivergence(
                        category=f"{kind}_missing",
                        location=f"{field_name}.{name}",
                        extraction_a="<absent>",
                        extraction_b=_compact_repr(items_b[name]),
                    )
                )
            elif name not in items_b:
                divergences.append(
                    ExtractionDivergence(
                        category=f"{kind}_missing",
                        location=f"{field_name}.{name}",
                        extraction_a=_compact_repr(items_a[name]),
                        extraction_b="<absent>",
                    )
                )
            else:
                # Both present: compare structurally (ignore provenance)
                clean_a = _strip_provenance(items_a[name])
                clean_b = _strip_provenance(items_b[name])
                if clean_a == clean_b:
                    agreed += 1
                else:
                    divergences.append(
                        ExtractionDivergence(
                            category=f"{kind}_different",
                            location=f"{field_name}.{name}",
                            extraction_a=_compact_repr(items_a[name]),
                            extraction_b=_compact_repr(items_b[name]),
                        )
                    )

    # Modes: compare by name, then compare transitions
    modes_a = _index_by_name(facts_a.get("modes", []))
    modes_b = _index_by_name(facts_b.get("modes", []))
    all_mode_names = set(modes_a.keys()) | set(modes_b.keys())

    for mode_name in sorted(all_mode_names):
        total += 1
        if mode_name not in modes_a:
            divergences.append(
                ExtractionDivergence(
                    category="mode_missing",
                    location=f"modes.{mode_name}",
                    extraction_a="<absent>",
                    extraction_b=f"mode with {len(modes_b[mode_name].get('transitions', []))} transitions",
                )
            )
        elif mode_name not in modes_b:
            divergences.append(
                ExtractionDivergence(
                    category="mode_missing",
                    location=f"modes.{mode_name}",
                    extraction_a=f"mode with {len(modes_a[mode_name].get('transitions', []))} transitions",
                    extraction_b="<absent>",
                )
            )
        else:
            ma = modes_a[mode_name]
            mb = modes_b[mode_name]

            # Compare transition counts
            trans_a = ma.get("transitions", [])
            trans_b = mb.get("transitions", [])

            if len(trans_a) != len(trans_b):
                divergences.append(
                    ExtractionDivergence(
                        category="mode_transition_count",
                        location=f"modes.{mode_name}",
                        extraction_a=f"{len(trans_a)} transitions",
                        extraction_b=f"{len(trans_b)} transitions",
                    )
                )
            else:
                agreed += 1

            # Compare transitions pairwise (by index)
            for i in range(min(len(trans_a), len(trans_b))):
                total += 1
                ta = _strip_provenance(trans_a[i])
                tb = _strip_provenance(trans_b[i])
                if ta == tb:
                    agreed += 1
                else:
                    divergences.append(
                        ExtractionDivergence(
                            category="transition_different",
                            location=f"modes.{mode_name}.transition_{i}",
                            extraction_a=_compact_repr(trans_a[i]),
                            extraction_b=_compact_repr(trans_b[i]),
                        )
                    )

    score = agreed / total if total > 0 else 1.0
    return DualExtractionReport(
        agreement_score=score,
        divergences=divergences,
        agreed_facts=agreed,
        total_facts=total,
    )


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _get_provenanced_value(obj) -> str:
    """Extract the value from a provenanced field or return the string."""
    if isinstance(obj, dict):
        return obj.get("value", "")
    return str(obj)


def _index_by_name(items: list) -> dict[str, dict]:
    """Index a list of fact items by their name field."""
    idx: dict[str, dict] = {}
    for item in items:
        if not isinstance(item, dict):
            continue
        name_field = item.get("name", {})
        if isinstance(name_field, dict):
            name = name_field.get("value", "")
        else:
            name = str(name_field)
        if name:
            idx[name] = item
    return idx


def _strip_provenance(obj):
    """Recursively remove provenance tags for structural comparison."""
    if isinstance(obj, dict):
        return {
            k: _strip_provenance(v)
            for k, v in obj.items()
            if k != "provenance" and k != "source"
        }
    if isinstance(obj, list):
        return [_strip_provenance(item) for item in obj]
    return obj


def _compact_repr(obj) -> str:
    """Compact JSON representation for display."""
    try:
        return json.dumps(obj, separators=(",", ":"))[:120]
    except (TypeError, ValueError):
        return str(obj)[:120]
