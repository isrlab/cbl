"""Gap 3 mitigation: Orchestrator-controlled provenance.

The LLM must not set provenance tags. Instead, the session orchestrator
assigns provenance based on interaction history:

  - user_stated:   engineer typed it or provided it in the original requirements
  - user_confirmed: engineer explicitly confirmed an LLM proposal
  - llm_inferred:  LLM proposed it, not yet confirmed by engineer
  - default_assumed: system default (e.g., initial values)
  - rule_derived:  Prolog derived it from confirmed facts
  - rule_derived_pending: Prolog derived it from unconfirmed facts

The orchestrator maintains an audit log: a timestamped, append-only record
of every fact, its source, and confirmation status. This log is deterministic
(no LLM involvement) and can be inspected post-hoc.
"""

from __future__ import annotations

import json
import time
from dataclasses import dataclass, field
from pathlib import Path


# ---------------------------------------------------------------------------
# Audit log entry
# ---------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class AuditEntry:
    """One entry in the provenance audit log."""

    timestamp: float
    iteration: int
    fact_kind: str  # "mode", "guarantee", "assume", "transition", etc.
    fact_name: str  # name or identifier of the fact
    source: str  # "user_input", "llm_response:<response_id>", "prolog_repair"
    provenance: str  # assigned provenance tag
    confirmed: bool  # whether engineer has confirmed this fact
    detail: str = ""  # optional detail (e.g., original NL fragment)


# ---------------------------------------------------------------------------
# Provenance audit log
# ---------------------------------------------------------------------------


class ProvenanceAuditLog:
    """Append-only audit log for provenance tracking.

    Records the source and confirmation status of every extracted fact.
    The log itself is deterministic; no LLM-generated content enters it.
    """

    def __init__(self):
        self._entries: list[AuditEntry] = []

    @property
    def entries(self) -> list[AuditEntry]:
        return list(self._entries)

    def record(
        self,
        iteration: int,
        fact_kind: str,
        fact_name: str,
        source: str,
        provenance: str,
        confirmed: bool = False,
        detail: str = "",
    ) -> AuditEntry:
        entry = AuditEntry(
            timestamp=time.time(),
            iteration=iteration,
            fact_kind=fact_kind,
            fact_name=fact_name,
            source=source,
            provenance=provenance,
            confirmed=confirmed,
            detail=detail,
        )
        self._entries.append(entry)
        return entry

    def confirm(self, fact_kind: str, fact_name: str, iteration: int) -> None:
        """Record that the engineer confirmed a previously inferred fact."""
        self.record(
            iteration=iteration,
            fact_kind=fact_kind,
            fact_name=fact_name,
            source="engineer_confirmation",
            provenance="user_confirmed",
            confirmed=True,
        )

    def save(self, path: Path) -> None:
        """Save the audit log to a JSON file."""
        entries = [
            {
                "timestamp": e.timestamp,
                "iteration": e.iteration,
                "fact_kind": e.fact_kind,
                "fact_name": e.fact_name,
                "source": e.source,
                "provenance": e.provenance,
                "confirmed": e.confirmed,
                "detail": e.detail,
            }
            for e in self._entries
        ]
        path.write_text(json.dumps(entries, indent=2))

    def load(self, path: Path) -> None:
        """Load a previously saved audit log."""
        data = json.loads(path.read_text())
        if not isinstance(data, list):
            raise ValueError(
                f"Audit log must be a JSON array, got {type(data).__name__}"
            )
        for i, item in enumerate(data):
            if not isinstance(item, dict):
                raise ValueError(f"Audit log entry {i} is not an object")
            try:
                self._entries.append(AuditEntry(**item))
            except TypeError as exc:
                raise ValueError(f"Audit log entry {i}: {exc}") from exc

    def confirmed_facts(self) -> set[tuple[str, str]]:
        """Return set of (fact_kind, fact_name) pairs that have been confirmed."""
        confirmed = set()
        for e in self._entries:
            if e.confirmed or e.provenance in ("user_stated", "user_confirmed"):
                confirmed.add((e.fact_kind, e.fact_name))
        return confirmed


# ---------------------------------------------------------------------------
# Provenance enforcer
# ---------------------------------------------------------------------------


# Facts that are structurally part of the schema but not domain-specific
_STRUCTURAL_FIELDS = {"schema_version"}

# Valid provenance tags (must match extracted_facts.schema.json)
_VALID_PROVENANCE = {
    "user_stated",
    "user_confirmed",
    "llm_inferred",
    "rule_derived",
    "rule_derived_pending",
    "default_assumed",
    "user_rejected",
}


def enforce_provenance(
    facts: dict,
    user_fragments: set[str],
    confirmed_facts: set[tuple[str, str]],
    iteration: int,
    audit_log: ProvenanceAuditLog,
    response_id: str = "",
) -> dict:
    """Rewrite provenance tags based on orchestrator-controlled rules.

    The LLM's self-assigned provenance tags are OVERRIDDEN:

    1. Facts whose names appear in user_fragments get ``user_stated``.
    2. Facts in confirmed_facts get ``user_confirmed``.
    3. All other facts get ``llm_inferred`` (forcing R9 to flag them).

    Args:
        facts: The extracted_facts dict (modified in place and returned).
        user_fragments: Set of fact names the user explicitly provided.
        confirmed_facts: Set of (kind, name) pairs confirmed by engineer.
        iteration: Current iteration number.
        audit_log: The provenance audit log to record changes.
        response_id: Identifier for the LLM response (for audit trail).

    Returns:
        The modified facts dict with corrected provenance tags.
    """
    source = f"llm_response:{response_id}" if response_id else "llm_response"

    # Process provenanced scalar fields
    for key in ("system_name", "initial_mode"):
        if key in facts and isinstance(facts[key], dict) and "value" in facts[key]:
            name = facts[key]["value"]
            prov = _determine_provenance(key, name, user_fragments, confirmed_facts)
            facts[key]["provenance"] = prov
            audit_log.record(iteration, key, str(name), source, prov)

    # Process array-of-facts fields
    _field_configs = [
        ("assumes", "name", "assume"),
        ("guarantees", "name", "guarantee"),
        ("variables", "name", "variable"),
        ("constants", "name", "constant"),
        ("definitions", "name", "definition"),
        ("always_invariants", "predicate", "always_invariant"),
    ]

    for field_name, name_key, kind in _field_configs:
        if field_name not in facts:
            continue
        for idx, item in enumerate(facts[field_name], start=1):
            if not isinstance(item, dict):
                continue
            # Extract the name (may be provenanced or plain)
            if field_name == "always_invariants":
                name = "global"
            else:
                name_field = item.get(name_key, {})
                if isinstance(name_field, dict):
                    name = name_field.get("value", "")
                else:
                    name = str(name_field)

            prov = _determine_provenance(kind, name, user_fragments, confirmed_facts)

            if field_name == "always_invariants":
                pred_field = item.get("predicate")
                if isinstance(pred_field, dict) and "provenance" in pred_field:
                    pred_field["provenance"] = prov

            # Set provenance on the name field if it's provenanced
            if field_name != "always_invariants":
                if isinstance(name_field, dict) and "provenance" in name_field:
                    name_field["provenance"] = prov

            # Set provenance on nested provenanced fields
            for nested_key in (
                "atype",
                "gtype",
                "vtype",
                "ctype",
                "cvalue",
                "body",
                "default",
                "constraint",
                "initial",
            ):
                nested = item.get(nested_key)
                if isinstance(nested, dict) and "provenance" in nested:
                    nested["provenance"] = prov

            audit_log.record(iteration, kind, name, source, prov)

    # Process modes (deeper structure)
    for mode in facts.get("modes", []):
        if not isinstance(mode, dict):
            continue
        mode_name_field = mode.get("name", {})
        if isinstance(mode_name_field, dict):
            mode_name = mode_name_field.get("value", "")
        else:
            mode_name = str(mode_name_field)

        prov = _determine_provenance("mode", mode_name, user_fragments, confirmed_facts)

        if isinstance(mode_name_field, dict) and "provenance" in mode_name_field:
            mode_name_field["provenance"] = prov

        audit_log.record(iteration, "mode", mode_name, source, prov)

        # Override provenance on entry actions (confirmations keyed by mode name)
        for action in mode.get("entry_actions", []):
            if not isinstance(action, dict):
                continue
            a_prov = (
                "user_confirmed"
                if ("entry_action", mode_name) in confirmed_facts
                else "llm_inferred"
            )
            action["provenance"] = a_prov
            audit_log.record(iteration, "entry_action", mode_name, source, a_prov)

        # Process transitions within each mode
        # IDs use Mode_Idx format (1-based) to match Prolog's provenance_of/3.
        for i, trans in enumerate(mode.get("transitions", [])):
            if not isinstance(trans, dict):
                continue
            trans_id = f"{mode_name}_{i + 1}"
            t_prov = _determine_provenance(
                "transition", trans_id, user_fragments, confirmed_facts
            )
            # Override guard provenance
            guard = trans.get("guard")
            if isinstance(guard, dict) and "provenance" in guard:
                guard["provenance"] = t_prov
            # Override target provenance
            target = trans.get("target")
            if isinstance(target, dict) and "provenance" in target:
                target["provenance"] = t_prov
            # Override action provenance
            for action in trans.get("actions", []):
                if not isinstance(action, dict):
                    continue
                action["provenance"] = t_prov
                audit_log.record(
                    iteration,
                    "action",
                    f"{trans_id}:{action.get('name', '')}",
                    source,
                    t_prov,
                )
            audit_log.record(iteration, "transition", trans_id, source, t_prov)

        # Override provenance on mode invariants (inherit mode provenance)
        for inv in mode.get("invariants", []):
            if not isinstance(inv, dict):
                continue
            pred_field = inv.get("predicate")
            if isinstance(pred_field, dict) and "provenance" in pred_field:
                pred_field["provenance"] = prov
            audit_log.record(iteration, "mode_invariant", mode_name, source, prov)

    # Process open_questions (always llm_inferred)
    for q in facts.get("open_questions", []):
        if isinstance(q, dict):
            q_id = q.get("question_id", "")
            audit_log.record(iteration, "question", q_id, source, "llm_inferred")

    # Mark that provenance tags were rewritten by the orchestrator.
    facts["provenance_attested"] = True

    return facts


def _determine_provenance(
    kind: str,
    name: str,
    user_fragments: set[str],
    confirmed_facts: set[tuple[str, str]],
) -> str:
    """Determine the correct provenance tag for a fact.

    Priority:
    1. If (kind, name) in confirmed_facts → user_confirmed
    2. If name in user_fragments → user_stated
    3. Otherwise → llm_inferred
    """
    if (kind, name) in confirmed_facts:
        return "user_confirmed"
    if name in user_fragments:
        return "user_stated"
    return "llm_inferred"


def extract_user_fragments(nl_text: str) -> set[str]:
    """Extract identifiable name fragments from the user's NL requirements.

    Uses simple heuristics to find likely variable/mode/constant names:
    - Capitalized words or UPPER_CASE tokens
    - Quoted strings
    - Words following "called", "named", "mode", "state", "variable"

    This is intentionally conservative; unrecognized names default to
    llm_inferred, which is the safe choice (triggers R9 warnings).
    """
    import re

    fragments: set[str] = set()

    # Quoted strings (single or double)
    for match in re.finditer(r"""['"]([^'"]+)['"]""", nl_text):
        fragments.add(match.group(1))

    # UPPER_CASE or CamelCase identifiers
    for match in re.finditer(r"\b([A-Z][A-Z0-9_]{2,})\b", nl_text):
        fragments.add(match.group(1))

    # Words following naming patterns: "called X", "named X"
    for match in re.finditer(r"\b(?:called|named)\s+(\w+)", nl_text, re.IGNORECASE):
        fragments.add(match.group(1))

    # Words following "mode X", "state X" (capture the next word)
    for match in re.finditer(r"\b(?:mode|state)\s+(\w+)", nl_text, re.IGNORECASE):
        word = match.group(1)
        # Avoid capturing noise words like "called", "named", "is", etc.
        if word.lower() not in {"called", "named", "is", "are", "the", "a", "an"}:
            fragments.add(word)

    return fragments
