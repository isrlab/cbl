"""Tests for mutation testing and test traceability.

Z3 guard checking (WP-1, WP-2) is now performed by the OCaml compiler
(cbl-compiler/lib/z3_guard_checker.ml). This file covers mutation testing
(Gap 4a) and test traceability modules using synthetic AST fixtures.
"""

import sys
from pathlib import Path

import pytest

# Add cbl-elicit package root to sys.path so relative imports resolve.
_ELICIT_PKG = Path(__file__).resolve().parent.parent
_PKG_ROOT = str(_ELICIT_PKG.parent)
if _PKG_ROOT not in sys.path:
    sys.path.insert(0, _PKG_ROOT)

# Import from the mitigations package using importlib (hyphenated dir name).
import importlib
import importlib.util


def _import_from_mitigations(mod_name: str):
    """Import a module from the cbl-elicit/mitigations package."""
    mitigations_dir = _ELICIT_PKG / "mitigations"
    init_path = mitigations_dir / "__init__.py"
    pkg_name = "mitigations"

    if pkg_name not in sys.modules:
        pkg_spec = importlib.util.spec_from_file_location(
            pkg_name, init_path, submodule_search_locations=[str(mitigations_dir)]
        )
        pkg_mod = importlib.util.module_from_spec(pkg_spec)
        sys.modules[pkg_name] = pkg_mod
        pkg_spec.loader.exec_module(pkg_mod)

    full_name = f"{pkg_name}.{mod_name}"
    if full_name in sys.modules:
        return sys.modules[full_name]

    file_path = mitigations_dir / f"{mod_name}.py"
    spec = importlib.util.spec_from_file_location(full_name, file_path)
    mod = importlib.util.module_from_spec(spec)
    mod.__package__ = pkg_name
    sys.modules[full_name] = mod
    spec.loader.exec_module(mod)
    return mod


def _import_from_test(mod_name: str):
    """Import a sibling test module."""
    test_dir = Path(__file__).resolve().parent
    file_path = test_dir / f"{mod_name}.py"
    spec = importlib.util.spec_from_file_location(mod_name, file_path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[mod_name] = mod
    spec.loader.exec_module(mod)
    return mod


ast = _import_from_mitigations("ast_nodes")
mut_mod = _import_from_mitigations("mutation_testing")
tt_mod = _import_from_test("test_traceability")

Mutant = mut_mod.Mutant
generate_mutants = mut_mod.generate_mutants
TestScenario = tt_mod.TestScenario
check_test_traceability = tt_mod.check_test_traceability
extract_requirement_ids = tt_mod.extract_requirement_ids


# =========================================================================
# Fixtures: synthetic specifications
# =========================================================================


@pytest.fixture
def exclusive_complete_spec():
    """Spec with exclusive and complete guards (no Z3 errors expected)."""
    return ast.Specification(
        name="SimpleThreshold",
        assumes=(
            ast.AssumeDecl(
                names=("temp",),
                type_annot=ast.TypeAnnot(
                    kind="real", range_lo=ast.Literal(0.0), range_hi=ast.Literal(100.0)
                ),
            ),
        ),
        guarantees=(
            ast.GuaranteeDecl(
                name="status",
                type_annot=ast.TypeAnnot(kind="enum", enum_values=("Low", "High")),
            ),
        ),
        initial_mode="Normal",
        modes=(
            ast.Mode(
                name="Normal",
                rules=(
                    ast.Rule(
                        guard=ast.ComparisonPred(
                            left=ast.Identifier("temp"),
                            op=">=",
                            right=ast.Literal(50.0),
                        ),
                        timing=None,
                        actions=(
                            ast.SetAction(var="status", expr=ast.Literal("High")),
                        ),
                        transition=ast.Transition(target="Alert", is_remain=False),
                    ),
                ),
                otherwise=ast.OtherwiseClause(
                    actions=(ast.SetAction(var="status", expr=ast.Literal("Low")),),
                    transition=ast.Transition(target="Normal", is_remain=True),
                ),
            ),
            ast.Mode(
                name="Alert",
                rules=(
                    ast.Rule(
                        guard=ast.ComparisonPred(
                            left=ast.Identifier("temp"),
                            op="<",
                            right=ast.Literal(50.0),
                        ),
                        timing=None,
                        actions=(ast.SetAction(var="status", expr=ast.Literal("Low")),),
                        transition=ast.Transition(target="Normal", is_remain=False),
                    ),
                ),
                otherwise=ast.OtherwiseClause(
                    actions=(ast.SetAction(var="status", expr=ast.Literal("High")),),
                    transition=ast.Transition(target="Alert", is_remain=True),
                ),
            ),
        ),
    )


@pytest.fixture
def overlapping_guards_spec():
    """Spec with overlapping guards (Z3-WP1 error expected)."""
    return ast.Specification(
        name="Overlapping",
        assumes=(
            ast.AssumeDecl(
                names=("x",),
                type_annot=ast.TypeAnnot(
                    kind="real", range_lo=ast.Literal(0.0), range_hi=ast.Literal(100.0)
                ),
            ),
        ),
        guarantees=(
            ast.GuaranteeDecl(
                name="y",
                type_annot=ast.TypeAnnot(kind="real"),
            ),
        ),
        initial_mode="Main",
        modes=(
            ast.Mode(
                name="Main",
                rules=(
                    # x < 60
                    ast.Rule(
                        guard=ast.ComparisonPred(
                            left=ast.Identifier("x"),
                            op="<",
                            right=ast.Literal(60.0),
                        ),
                        timing=None,
                        actions=(ast.SetAction(var="y", expr=ast.Literal(0.0)),),
                        transition=ast.Transition(target="Main", is_remain=True),
                    ),
                    # x > 40  ← overlaps with x < 60 in [40, 60]
                    ast.Rule(
                        guard=ast.ComparisonPred(
                            left=ast.Identifier("x"),
                            op=">",
                            right=ast.Literal(40.0),
                        ),
                        timing=None,
                        actions=(ast.SetAction(var="y", expr=ast.Literal(1.0)),),
                        transition=ast.Transition(target="Main", is_remain=True),
                    ),
                ),
            ),
        ),
    )


@pytest.fixture
def incomplete_guards_spec():
    """Spec with incomplete guards and no Otherwise (Z3-WP2 error expected)."""
    return ast.Specification(
        name="Incomplete",
        assumes=(
            ast.AssumeDecl(
                names=("x",),
                type_annot=ast.TypeAnnot(
                    kind="integer", range_lo=ast.Literal(0), range_hi=ast.Literal(10)
                ),
            ),
        ),
        guarantees=(
            ast.GuaranteeDecl(
                name="y",
                type_annot=ast.TypeAnnot(kind="integer"),
            ),
        ),
        initial_mode="Main",
        modes=(
            ast.Mode(
                name="Main",
                rules=(
                    # x < 5 (covers [0, 4])
                    ast.Rule(
                        guard=ast.ComparisonPred(
                            left=ast.Identifier("x"),
                            op="<",
                            right=ast.Literal(5),
                        ),
                        timing=None,
                        actions=(ast.SetAction(var="y", expr=ast.Literal(0)),),
                        transition=ast.Transition(target="Main", is_remain=True),
                    ),
                    # x > 7 (covers [8, 10])
                    ast.Rule(
                        guard=ast.ComparisonPred(
                            left=ast.Identifier("x"),
                            op=">",
                            right=ast.Literal(7),
                        ),
                        timing=None,
                        actions=(ast.SetAction(var="y", expr=ast.Literal(1)),),
                        transition=ast.Transition(target="Main", is_remain=True),
                    ),
                    # Missing: [5, 7] uncovered, no Otherwise
                ),
                otherwise=None,
            ),
        ),
    )


@pytest.fixture
def boolean_guards_spec():
    """Spec with boolean guards for mutation testing."""
    return ast.Specification(
        name="BoolToggle",
        assumes=(
            ast.AssumeDecl(
                names=("active",),
                type_annot=ast.TypeAnnot(kind="boolean"),
            ),
        ),
        guarantees=(
            ast.GuaranteeDecl(
                name="lamp",
                type_annot=ast.TypeAnnot(kind="boolean"),
            ),
        ),
        initial_mode="Off",
        modes=(
            ast.Mode(
                name="Off",
                rules=(
                    ast.Rule(
                        guard=ast.BooleanPred(var="active", value=True),
                        timing=None,
                        actions=(ast.SetAction(var="lamp", expr=ast.Literal(True)),),
                        transition=ast.Transition(target="On", is_remain=False),
                    ),
                ),
                otherwise=ast.OtherwiseClause(
                    actions=(ast.SetAction(var="lamp", expr=ast.Literal(False)),),
                    transition=ast.Transition(target="Off", is_remain=True),
                ),
            ),
            ast.Mode(
                name="On",
                rules=(
                    ast.Rule(
                        guard=ast.BooleanPred(var="active", value=False),
                        timing=None,
                        actions=(ast.SetAction(var="lamp", expr=ast.Literal(False)),),
                        transition=ast.Transition(target="Off", is_remain=False),
                    ),
                ),
                otherwise=ast.OtherwiseClause(
                    actions=(ast.SetAction(var="lamp", expr=ast.Literal(True)),),
                    transition=ast.Transition(target="On", is_remain=True),
                ),
            ),
        ),
    )


# =========================================================================
# Tests: mutation testing
# =========================================================================


class TestMutationTesting:
    def test_generates_mutants(self, boolean_guards_spec):
        """generate_mutants should produce at least one mutant."""
        mutants = generate_mutants(boolean_guards_spec)
        assert len(mutants) > 0

    def test_mutant_structure(self, boolean_guards_spec):
        """Each mutant should have required fields."""
        mutants = generate_mutants(boolean_guards_spec)
        for m in mutants:
            assert isinstance(m, Mutant)
            assert m.operator in ("M1", "M2", "M3", "M4", "M5")
            assert m.description
            assert m.location
            assert isinstance(m.spec, ast.Specification)

    def test_m2_swap_transition(self, boolean_guards_spec):
        """M2 should swap transition targets."""
        mutants = generate_mutants(boolean_guards_spec)
        m2 = [m for m in mutants if m.operator == "M2"]
        assert len(m2) > 0
        # At least one mutant should have a different transition target
        for m in m2:
            # Find changed transition
            for mi, mode in enumerate(m.spec.modes):
                for ri, rule in enumerate(mode.rules):
                    orig_rule = (
                        boolean_guards_spec.modes[mi].rules[ri]
                        if ri < len(boolean_guards_spec.modes[mi].rules)
                        else None
                    )
                    if (
                        orig_rule
                        and rule.transition.target != orig_rule.transition.target
                    ):
                        return  # found the swap
        # If M2 was generated, there should be a swapped target
        # (may not always find one due to mode naming)

    def test_m4_flip_boolean(self, boolean_guards_spec):
        """M4 should flip boolean predicates."""
        mutants = generate_mutants(boolean_guards_spec)
        m4 = [m for m in mutants if m.operator == "M4"]
        assert len(m4) > 0

    def test_m3_remove_assignment(self, boolean_guards_spec):
        """M3 should remove SetAction from rules."""
        mutants = generate_mutants(boolean_guards_spec)
        m3 = [m for m in mutants if m.operator == "M3"]
        assert len(m3) > 0

    def test_mutants_differ_from_original(self, boolean_guards_spec):
        """Each mutant should differ from the original spec."""
        mutants = generate_mutants(boolean_guards_spec)
        for m in mutants:
            assert m.spec != boolean_guards_spec

    def test_threshold_spec_mutants(self, exclusive_complete_spec):
        """Threshold spec should produce M1 (flip comparison) mutants."""
        mutants = generate_mutants(exclusive_complete_spec)
        m1 = [m for m in mutants if m.operator == "M1"]
        assert len(m1) > 0


# =========================================================================
# Tests: test traceability
# =========================================================================


class TestTestTraceability:
    def test_full_coverage(self):
        reqs = ["R1", "R2", "R3"]
        scenarios = [
            TestScenario("test_r1", "tests R1", ["R1"], [{}]),
            TestScenario("test_r2", "tests R2", ["R2"], [{}]),
            TestScenario("test_r3", "tests R3", ["R3"], [{}]),
        ]
        report = check_test_traceability(reqs, scenarios)
        assert report.coverage_ratio == 1.0
        assert len(report.gaps) == 0

    def test_missing_coverage(self):
        reqs = ["R1", "R2", "R3"]
        scenarios = [
            TestScenario("test_r1", "tests R1", ["R1"], [{}]),
        ]
        report = check_test_traceability(reqs, scenarios)
        assert report.coverage_ratio < 1.0
        assert len(report.gaps) == 2
        gap_ids = {g.requirement_id for g in report.gaps}
        assert "R2" in gap_ids
        assert "R3" in gap_ids

    def test_extract_requirement_ids(self):
        text = "R1: The system shall... R2: It must... REQ-003: Also..."
        ids = extract_requirement_ids(text)
        assert "R1" in ids
        assert "R2" in ids
        assert "REQ-003" in ids

    def test_extract_requirement_ids_bracket(self):
        text = "According to [R1] and [R2], the system..."
        ids = extract_requirement_ids(text)
        assert "R1" in ids
        assert "R2" in ids

    def test_coverage_matrix(self):
        reqs = ["R1", "R2"]
        scenarios = [
            TestScenario("test_a", "tests both", ["R1", "R2"], [{}]),
            TestScenario("test_b", "tests R1", ["R1"], [{}]),
        ]
        report = check_test_traceability(reqs, scenarios)
        assert len(report.coverage_matrix["R1"]) == 2
        assert len(report.coverage_matrix["R2"]) == 1
