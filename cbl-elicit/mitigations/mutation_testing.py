"""Gap 4 mitigation: Specification mutation testing.

Automatically generates mutants of a CBL specification and checks whether
the test suite detects them. If a mutant passes all tests, the test suite
has a coverage gap.

Mutation operators:
  M1: Flip a guard predicate (negate a comparison operator)
  M2: Swap a transition target (change to a different valid mode)
  M3: Remove an output assignment (drop a SetAction)
  M4: Flip a boolean literal in a guard (true ↔ false)
  M5: Change a numeric literal in a guard (e.g., threshold ± 1)

This module operates on the AST, not on text. It produces mutant ASTs
that can be lowered and tested through the normal pipeline.
"""

from __future__ import annotations

import copy
import re
from dataclasses import dataclass, field
from typing import Callable

from . import ast_nodes as ast

_SAFE_IDENT_RE = re.compile(r"^[a-zA-Z_][a-zA-Z0-9_]*$")


def _validate_identifiers(spec: ast.Specification) -> bool:
    """Return True if all identifiers in spec are safe for code generation."""
    names: list[str] = []
    for a in spec.assumes:
        names.extend(a.names)
    for d in spec.definitions:
        names.append(d.name)
    for c in spec.constants:
        names.append(c.name)
    for g in spec.guarantees:
        names.append(g.name)
    for v in spec.variables:
        names.append(v.name)
    for m in spec.modes:
        names.append(m.name)
        if m.entry_actions:
            for action in m.entry_actions:
                if isinstance(
                    action,
                    (
                        ast.SetAction,
                        ast.HoldAction,
                        ast.IncrementAction,
                        ast.ResetAction,
                    ),
                ):
                    names.append(action.var)
        for rule in m.rules:
            for action in rule.actions:
                if isinstance(
                    action,
                    (
                        ast.SetAction,
                        ast.HoldAction,
                        ast.IncrementAction,
                        ast.ResetAction,
                    ),
                ):
                    names.append(action.var)
            if hasattr(rule, "transition") and rule.transition is not None:
                names.append(rule.transition.target)
        if m.otherwise:
            for action in m.otherwise.actions:
                if isinstance(
                    action,
                    (
                        ast.SetAction,
                        ast.HoldAction,
                        ast.IncrementAction,
                        ast.ResetAction,
                    ),
                ):
                    names.append(action.var)
            if m.otherwise.transition is not None:
                names.append(m.otherwise.transition.target)
    return all(_SAFE_IDENT_RE.match(n) for n in names if n)


@dataclass(frozen=True, slots=True)
class Mutant:
    """A mutated specification with metadata."""

    operator: str  # "M1", "M2", etc.
    description: str  # human-readable description
    location: str  # mode name, rule index
    spec: ast.Specification  # the mutated specification


@dataclass
class MutationReport:
    """Results of running the test suite against all mutants."""

    total_mutants: int = 0
    killed: int = 0  # detected by tests (different output or exception)
    survived: int = 0  # not detected (same output as original)
    errors: int = 0  # mutant caused an error (crashed)
    survivors: list[Mutant] = field(default_factory=list)

    @property
    def mutation_score(self) -> float:
        """Fraction of mutants killed (higher is better)."""
        if self.total_mutants == 0:
            return 1.0
        return self.killed / self.total_mutants

    @property
    def summary(self) -> str:
        return (
            f"Mutation score: {self.killed}/{self.total_mutants} "
            f"({self.mutation_score * 100:.0f}%). "
            f"Killed: {self.killed}, Survived: {self.survived}, "
            f"Errors: {self.errors}"
        )


# ---------------------------------------------------------------------------
# Mutation operators
# ---------------------------------------------------------------------------


def generate_mutants(spec: ast.Specification) -> list[Mutant]:
    """Generate all mutants for a specification.

    Applies each mutation operator at every applicable location.
    """
    mutants: list[Mutant] = []
    mutants.extend(_m1_flip_comparison(spec))
    mutants.extend(_m2_swap_transition(spec))
    mutants.extend(_m3_remove_assignment(spec))
    mutants.extend(_m4_flip_boolean(spec))
    mutants.extend(_m5_perturb_numeric(spec))
    return mutants


def _m1_flip_comparison(spec: ast.Specification) -> list[Mutant]:
    """M1: Flip comparison operators in guards (< ↔ >=, <= ↔ >, == ↔ !=)."""
    _FLIP_MAP = {
        "<": ">=",
        ">": "<=",
        "<=": ">",
        ">=": "<",
        "==": "!=",
        "!=": "==",
    }
    mutants: list[Mutant] = []

    for mi, mode in enumerate(spec.modes):
        for ri, rule in enumerate(mode.rules):
            comparisons = _find_comparisons(rule.guard)
            for ci, (comp, path) in enumerate(comparisons):
                if comp.op not in _FLIP_MAP:
                    continue
                new_op = _FLIP_MAP[comp.op]
                new_guard = _replace_comparison(rule.guard, path, new_op)
                new_rule = ast.Rule(
                    guard=new_guard,
                    timing=rule.timing,
                    actions=rule.actions,
                    transition=rule.transition,
                )
                new_rules = list(mode.rules)
                new_rules[ri] = new_rule
                new_mode = ast.Mode(
                    name=mode.name,
                    entry_actions=mode.entry_actions,
                    invariants=mode.invariants,
                    rules=tuple(new_rules),
                    otherwise=mode.otherwise,
                    counter_updates=mode.counter_updates,
                )
                new_modes = list(spec.modes)
                new_modes[mi] = new_mode
                new_spec = ast.Specification(
                    name=spec.name,
                    assumes=spec.assumes,
                    definitions=spec.definitions,
                    constants=spec.constants,
                    guarantees=spec.guarantees,
                    variables=spec.variables,
                    always_invariants=spec.always_invariants,
                    initial_mode=spec.initial_mode,
                    modes=tuple(new_modes),
                )
                mutants.append(
                    Mutant(
                        operator="M1",
                        description=f"Flip {comp.op} → {new_op} in guard",
                        location=f"Mode {mode.name}, Rule {ri}, Comparison {ci}",
                        spec=new_spec,
                    )
                )

    return mutants


def _m2_swap_transition(spec: ast.Specification) -> list[Mutant]:
    """M2: Swap transition targets to different valid modes."""
    mode_names = [m.name for m in spec.modes]
    mutants: list[Mutant] = []

    for mi, mode in enumerate(spec.modes):
        for ri, rule in enumerate(mode.rules):
            if rule.transition is None:
                continue
            for alt_name in mode_names:
                if alt_name == rule.transition.target:
                    continue
                new_trans = ast.Transition(
                    target=alt_name,
                    is_remain=False,
                )
                new_rule = ast.Rule(
                    guard=rule.guard,
                    timing=rule.timing,
                    actions=rule.actions,
                    transition=new_trans,
                )
                new_rules = list(mode.rules)
                new_rules[ri] = new_rule
                new_mode = ast.Mode(
                    name=mode.name,
                    entry_actions=mode.entry_actions,
                    invariants=mode.invariants,
                    rules=tuple(new_rules),
                    otherwise=mode.otherwise,
                    counter_updates=mode.counter_updates,
                )
                new_modes = list(spec.modes)
                new_modes[mi] = new_mode
                new_spec = ast.Specification(
                    name=spec.name,
                    assumes=spec.assumes,
                    definitions=spec.definitions,
                    constants=spec.constants,
                    guarantees=spec.guarantees,
                    variables=spec.variables,
                    always_invariants=spec.always_invariants,
                    initial_mode=spec.initial_mode,
                    modes=tuple(new_modes),
                )
                mutants.append(
                    Mutant(
                        operator="M2",
                        description=(
                            f"Swap transition " f"{rule.transition.target} → {alt_name}"
                        ),
                        location=f"Mode {mode.name}, Rule {ri}",
                        spec=new_spec,
                    )
                )

    return mutants


def _m3_remove_assignment(spec: ast.Specification) -> list[Mutant]:
    """M3: Remove one output assignment (SetAction) from a rule."""
    mutants: list[Mutant] = []

    for mi, mode in enumerate(spec.modes):
        for ri, rule in enumerate(mode.rules):
            set_indices = [
                i for i, a in enumerate(rule.actions) if isinstance(a, ast.SetAction)
            ]
            for ai in set_indices:
                new_actions = list(rule.actions)
                removed = new_actions.pop(ai)
                new_rule = ast.Rule(
                    guard=rule.guard,
                    timing=rule.timing,
                    actions=tuple(new_actions),
                    transition=rule.transition,
                )
                new_rules = list(mode.rules)
                new_rules[ri] = new_rule
                new_mode = ast.Mode(
                    name=mode.name,
                    entry_actions=mode.entry_actions,
                    invariants=mode.invariants,
                    rules=tuple(new_rules),
                    otherwise=mode.otherwise,
                    counter_updates=mode.counter_updates,
                )
                new_modes = list(spec.modes)
                new_modes[mi] = new_mode
                new_spec = ast.Specification(
                    name=spec.name,
                    assumes=spec.assumes,
                    definitions=spec.definitions,
                    constants=spec.constants,
                    guarantees=spec.guarantees,
                    variables=spec.variables,
                    always_invariants=spec.always_invariants,
                    initial_mode=spec.initial_mode,
                    modes=tuple(new_modes),
                )
                mutants.append(
                    Mutant(
                        operator="M3",
                        description=f"Remove assignment to '{removed.var}'",
                        location=f"Mode {mode.name}, Rule {ri}, Action {ai}",
                        spec=new_spec,
                    )
                )

    return mutants


def _m4_flip_boolean(spec: ast.Specification) -> list[Mutant]:
    """M4: Flip boolean literals in guards (true ↔ false)."""
    mutants: list[Mutant] = []

    for mi, mode in enumerate(spec.modes):
        for ri, rule in enumerate(mode.rules):
            bool_preds = _find_boolean_preds(rule.guard)
            for bi, (pred, path) in enumerate(bool_preds):
                new_guard = _replace_boolean_pred(rule.guard, path, not pred.value)
                new_rule = ast.Rule(
                    guard=new_guard,
                    timing=rule.timing,
                    actions=rule.actions,
                    transition=rule.transition,
                )
                new_rules = list(mode.rules)
                new_rules[ri] = new_rule
                new_mode = ast.Mode(
                    name=mode.name,
                    entry_actions=mode.entry_actions,
                    invariants=mode.invariants,
                    rules=tuple(new_rules),
                    otherwise=mode.otherwise,
                    counter_updates=mode.counter_updates,
                )
                new_modes = list(spec.modes)
                new_modes[mi] = new_mode
                new_spec = ast.Specification(
                    name=spec.name,
                    assumes=spec.assumes,
                    definitions=spec.definitions,
                    constants=spec.constants,
                    guarantees=spec.guarantees,
                    variables=spec.variables,
                    always_invariants=spec.always_invariants,
                    initial_mode=spec.initial_mode,
                    modes=tuple(new_modes),
                )
                mutants.append(
                    Mutant(
                        operator="M4",
                        description=(
                            f"Flip boolean '{pred.var}' "
                            f"{pred.value} → {not pred.value}"
                        ),
                        location=f"Mode {mode.name}, Rule {ri}, BoolPred {bi}",
                        spec=new_spec,
                    )
                )

    return mutants


def _m5_perturb_numeric(spec: ast.Specification) -> list[Mutant]:
    """M5: Perturb numeric literals in comparison guards (value ± 1)."""
    mutants: list[Mutant] = []

    for mi, mode in enumerate(spec.modes):
        for ri, rule in enumerate(mode.rules):
            comparisons = _find_comparisons(rule.guard)
            for ci, (comp, path) in enumerate(comparisons):
                # Perturb right-hand side if it's a literal
                if isinstance(comp.right, ast.Literal) and isinstance(
                    comp.right.value, (int, float)
                ):
                    for delta in (-1, 1):
                        new_val = comp.right.value + delta
                        new_right = ast.Literal(value=new_val)
                        new_comp = ast.ComparisonPred(
                            left=comp.left,
                            op=comp.op,
                            right=new_right,
                        )
                        new_guard = _replace_comparison_node(rule.guard, path, new_comp)
                        new_rule = ast.Rule(
                            guard=new_guard,
                            timing=rule.timing,
                            actions=rule.actions,
                            transition=rule.transition,
                        )
                        new_rules = list(mode.rules)
                        new_rules[ri] = new_rule
                        new_mode = ast.Mode(
                            name=mode.name,
                            entry_actions=mode.entry_actions,
                            invariants=mode.invariants,
                            rules=tuple(new_rules),
                            otherwise=mode.otherwise,
                            counter_updates=mode.counter_updates,
                        )
                        new_modes = list(spec.modes)
                        new_modes[mi] = new_mode
                        new_spec = ast.Specification(
                            name=spec.name,
                            assumes=spec.assumes,
                            definitions=spec.definitions,
                            constants=spec.constants,
                            guarantees=spec.guarantees,
                            variables=spec.variables,
                            always_invariants=spec.always_invariants,
                            initial_mode=spec.initial_mode,
                            modes=tuple(new_modes),
                        )
                        mutants.append(
                            Mutant(
                                operator="M5",
                                description=(
                                    f"Perturb literal "
                                    f"{comp.right.value} → {new_val}"
                                ),
                                location=f"Mode {mode.name}, Rule {ri}, Comparison {ci}",
                                spec=new_spec,
                            )
                        )

    return mutants


# ---------------------------------------------------------------------------
# Run mutation testing
# ---------------------------------------------------------------------------


def run_mutation_testing(
    spec: ast.Specification,
    test_inputs: list[dict[str, object]],
    reference_trace: list[dict[str, object]],
    lowering_fn: Callable,
    ir_fn: Callable,
    emit_fn: Callable,
    class_name: str,
) -> MutationReport:
    """Run the test suite against all mutants and compare traces.

    Args:
        spec: The original specification AST.
        test_inputs: Sequence of input dicts for each step.
        reference_trace: Expected output dicts for each step.
        lowering_fn: lower(spec) → lowered_spec
        ir_fn: to_dict(lowered_spec) → dict
        emit_fn: emit(ir_dict) → Python source string
        class_name: Name of the class in the emitted Python.

    Returns:
        MutationReport with results.
    """
    mutants = generate_mutants(spec)
    report = MutationReport(total_mutants=len(mutants))

    if not _validate_identifiers(spec):
        raise ValueError("Specification contains unsafe identifiers; refusing to exec")

    for mutant in mutants:
        if not _validate_identifiers(mutant.spec):
            report.errors += 1
            report.killed += 1
            continue
        try:
            lowered = lowering_fn(mutant.spec)
            ir = ir_fn(lowered)
            source = emit_fn(ir)

            ns: dict = {}
            exec(source, ns)  # noqa: S102
            instance = ns[class_name]()

            # Run the test inputs and collect trace
            mutant_trace = []
            for inp in test_inputs:
                out = instance.step(inp)
                mutant_trace.append(out)

            # Compare with reference trace
            if mutant_trace == reference_trace:
                report.survived += 1
                report.survivors.append(mutant)
            else:
                report.killed += 1

        except Exception:
            report.errors += 1
            report.killed += 1  # errors also count as killed

    return report


# ---------------------------------------------------------------------------
# Guard traversal helpers
# ---------------------------------------------------------------------------


def _find_comparisons(
    guard: ast.GuardExpr, path: tuple = ()
) -> list[tuple[ast.ComparisonPred, tuple]]:
    """Find all ComparisonPred nodes in a guard with their path."""
    results: list[tuple[ast.ComparisonPred, tuple]] = []

    if isinstance(guard, ast.ComparisonPred):
        results.append((guard, path))
    elif isinstance(guard, ast.GuardAnd):
        results.extend(_find_comparisons(guard.left, path + ("left",)))
        results.extend(_find_comparisons(guard.right, path + ("right",)))
    elif isinstance(guard, ast.GuardOr):
        results.extend(_find_comparisons(guard.left, path + ("left",)))
        results.extend(_find_comparisons(guard.right, path + ("right",)))
    elif isinstance(guard, ast.GuardNot):
        results.extend(_find_comparisons(guard.operand, path + ("operand",)))

    return results


def _find_boolean_preds(
    guard: ast.GuardExpr, path: tuple = ()
) -> list[tuple[ast.BooleanPred, tuple]]:
    """Find all BooleanPred nodes in a guard with their path."""
    results: list[tuple[ast.BooleanPred, tuple]] = []

    if isinstance(guard, ast.BooleanPred):
        results.append((guard, path))
    elif isinstance(guard, ast.GuardAnd):
        results.extend(_find_boolean_preds(guard.left, path + ("left",)))
        results.extend(_find_boolean_preds(guard.right, path + ("right",)))
    elif isinstance(guard, ast.GuardOr):
        results.extend(_find_boolean_preds(guard.left, path + ("left",)))
        results.extend(_find_boolean_preds(guard.right, path + ("right",)))
    elif isinstance(guard, ast.GuardNot):
        results.extend(_find_boolean_preds(guard.operand, path + ("operand",)))

    return results


def _replace_comparison(
    guard: ast.GuardExpr, path: tuple, new_op: str
) -> ast.GuardExpr:
    """Replace a ComparisonPred's operator at the given path."""
    if not path:
        if isinstance(guard, ast.ComparisonPred):
            return ast.ComparisonPred(left=guard.left, op=new_op, right=guard.right)
        return guard

    step = path[0]
    rest = path[1:]

    if isinstance(guard, ast.GuardAnd):
        if step == "left":
            return ast.GuardAnd(
                left=_replace_comparison(guard.left, rest, new_op),
                right=guard.right,
            )
        return ast.GuardAnd(
            left=guard.left,
            right=_replace_comparison(guard.right, rest, new_op),
        )
    if isinstance(guard, ast.GuardOr):
        if step == "left":
            return ast.GuardOr(
                left=_replace_comparison(guard.left, rest, new_op),
                right=guard.right,
            )
        return ast.GuardOr(
            left=guard.left,
            right=_replace_comparison(guard.right, rest, new_op),
        )
    if isinstance(guard, ast.GuardNot):
        return ast.GuardNot(
            operand=_replace_comparison(guard.operand, rest, new_op),
        )

    return guard


def _replace_comparison_node(
    guard: ast.GuardExpr, path: tuple, new_node: ast.ComparisonPred
) -> ast.GuardExpr:
    """Replace a ComparisonPred node at the given path with a new node."""
    if not path:
        return new_node

    step = path[0]
    rest = path[1:]

    if isinstance(guard, ast.GuardAnd):
        if step == "left":
            return ast.GuardAnd(
                left=_replace_comparison_node(guard.left, rest, new_node),
                right=guard.right,
            )
        return ast.GuardAnd(
            left=guard.left,
            right=_replace_comparison_node(guard.right, rest, new_node),
        )
    if isinstance(guard, ast.GuardOr):
        if step == "left":
            return ast.GuardOr(
                left=_replace_comparison_node(guard.left, rest, new_node),
                right=guard.right,
            )
        return ast.GuardOr(
            left=guard.left,
            right=_replace_comparison_node(guard.right, rest, new_node),
        )
    if isinstance(guard, ast.GuardNot):
        return ast.GuardNot(
            operand=_replace_comparison_node(guard.operand, rest, new_node),
        )

    return guard


def _replace_boolean_pred(
    guard: ast.GuardExpr, path: tuple, new_value: bool
) -> ast.GuardExpr:
    """Replace a BooleanPred's value at the given path."""
    if not path:
        if isinstance(guard, ast.BooleanPred):
            return ast.BooleanPred(var=guard.var, value=new_value)
        return guard

    step = path[0]
    rest = path[1:]

    if isinstance(guard, ast.GuardAnd):
        if step == "left":
            return ast.GuardAnd(
                left=_replace_boolean_pred(guard.left, rest, new_value),
                right=guard.right,
            )
        return ast.GuardAnd(
            left=guard.left,
            right=_replace_boolean_pred(guard.right, rest, new_value),
        )
    if isinstance(guard, ast.GuardOr):
        if step == "left":
            return ast.GuardOr(
                left=_replace_boolean_pred(guard.left, rest, new_value),
                right=guard.right,
            )
        return ast.GuardOr(
            left=guard.left,
            right=_replace_boolean_pred(guard.right, rest, new_value),
        )
    if isinstance(guard, ast.GuardNot):
        return ast.GuardNot(
            operand=_replace_boolean_pred(guard.operand, rest, new_value),
        )

    return guard
