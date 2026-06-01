"""Normalize LLM-extracted facts into the canonical JSON format expected by the reasoner.

LLMs may produce shorthand representations that differ from the canonical
format that `cblc reason` can parse. This module converts shorthand forms into
the full canonical structure before facts are passed to the reasoner.

Known shorthand patterns:
  - Guard predicates: {"is_true": "x"} → {"kind": "is_true", "expr": {"kind": "var", "name": "x"}}
  - Action values: "yellow" → {"kind": "string", "value": "yellow"}
  - Action values: false → {"kind": "bool", "value": false}
  - Action values: 42 → {"kind": "int", "value": 42}
  - Action values: 3.14 → {"kind": "real", "value": 3.14}
"""

from __future__ import annotations


def normalize_facts(facts: dict) -> dict:
    """Normalize extracted facts into the canonical reasoner-compatible format."""
    # Sanitize system_name to a valid identifier
    _sanitize_system_name(facts)

    for mode in facts.get("modes", []):
        if not isinstance(mode, dict):
            continue
        for action in mode.get("entry_actions", []):
            if isinstance(action, dict):
                _normalize_action(action)
        for trans in mode.get("transitions", []):
            if not isinstance(trans, dict):
                continue
            _normalize_guard(trans)
            for action in trans.get("actions", []):
                if isinstance(action, dict):
                    _normalize_action(action)
    return facts


def _sanitize_system_name(facts: dict) -> None:
    """Convert system_name to a valid identifier (PascalCase, no spaces)."""
    import re

    sn = facts.get("system_name")
    if not sn:
        return

    if isinstance(sn, dict):
        val = sn.get("value", "")
    else:
        val = str(sn)

    if not val or re.match(r"^[A-Za-z_]\w*$", val):
        return  # already valid

    # "Traffic Light Controller" → "TrafficLightController"
    sanitized = "".join(w.capitalize() for w in re.split(r"[\s_-]+", val) if w)
    if not sanitized:
        return

    if isinstance(sn, dict):
        sn["value"] = sanitized
    else:
        facts["system_name"] = sanitized


def _normalize_guard(trans: dict) -> None:
    """Normalize guard predicates in a transition."""
    guard = trans.get("guard")
    if not isinstance(guard, dict):
        return

    # Guard may be wrapped: {"value": {...}, "provenance": "..."}
    inner = guard.get("value", guard)
    if not isinstance(inner, dict):
        return

    when_pred = inner.get("when")
    if when_pred is None:
        return

    if isinstance(when_pred, dict) and "kind" not in when_pred:
        inner["when"] = _normalize_predicate(when_pred)


def _normalize_predicate(pred: dict) -> dict:
    """Convert shorthand predicate to canonical {kind, ...} form."""
    # {"is_true": "varname"} → {"kind": "is_true", "expr": {"kind": "var", "name": "varname"}}
    for pred_kind in ("is_true", "is_false"):
        if pred_kind in pred:
            val = pred[pred_kind]
            return {
                "kind": pred_kind,
                "expr": _wrap_as_expr(val),
            }

    # {"equals": {"lhs": ..., "rhs": ...}} or {"equals": [lhs, rhs]}
    for pred_kind in ("equals", "exceeds", "is_below"):
        if pred_kind in pred:
            val = pred[pred_kind]
            if isinstance(val, dict):
                return {
                    "kind": pred_kind,
                    "lhs": _wrap_as_expr(val.get("lhs")),
                    "rhs": _wrap_as_expr(val.get("rhs")),
                }

    # {"not": {...pred...}}
    if "not" in pred:
        return {"kind": "not", "operand": _normalize_predicate(pred["not"])}

    # {"and": {"left": ..., "right": ...}}
    for logic_kind in ("and", "or"):
        if logic_kind in pred:
            val = pred[logic_kind]
            if isinstance(val, dict):
                return {
                    "kind": logic_kind,
                    "left": _normalize_predicate(val.get("left", {})),
                    "right": _normalize_predicate(val.get("right", {})),
                }

    # {"for_n_cycles": {"n": N, "base": {...}}}
    if "for_n_cycles" in pred:
        val = pred["for_n_cycles"]
        if isinstance(val, dict):
            return {
                "kind": "for_n_cycles",
                "n": _wrap_as_expr(val.get("n")),
                "base": _normalize_predicate(val.get("base", {})),
            }

    # Already canonical or unrecognized — return as-is
    return pred


def _normalize_action(action: dict) -> None:
    """Normalize action value fields to canonical expr format."""
    if "value" in action:
        action["value"] = _wrap_as_expr(action["value"], context="action")


def _wrap_as_expr(val, context: str = "predicate") -> dict:
    """Wrap a plain value as a canonical expression object.

    Args:
        val: The value to wrap.
        context: Either "predicate" (bare strings are variable refs)
                 or "action" (bare strings are string literals, e.g. enum values).
    """
    if isinstance(val, dict) and "kind" in val:
        return val  # already canonical
    if isinstance(val, bool):
        return {"kind": "bool", "value": val}
    if isinstance(val, int):
        return {"kind": "int", "value": val}
    if isinstance(val, float):
        return {"kind": "real", "value": val}
    if isinstance(val, str):
        if context == "action":
            return {"kind": "string", "value": val}
        return {"kind": "var", "name": val}
    return val if isinstance(val, dict) else {"kind": "var", "name": str(val)}
