"""CBL Abstract Syntax Tree node definitions.

Every AST node is a frozen dataclass (immutable by default).  Lowering passes
produce *new* trees rather than mutating in place, which simplifies debugging
and makes it safe to keep references to pre-lowered subtrees.

The node hierarchy is designed for the Visitor pattern.  A generic
``ASTVisitor`` base class is provided at the bottom of this module so that
downstream passes (well-posedness checker, code generator) can be added
without modifying the node classes themselves.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Sequence, Union


# ---------------------------------------------------------------------------
# Expressions
# ---------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class Literal:
    """A numeric, boolean, string, or enum literal."""

    value: Union[int, float, bool, str]


@dataclass(frozen=True, slots=True)
class Identifier:
    """A bare name used as an expression (variable or constant reference)."""

    name: str


@dataclass(frozen=True, slots=True)
class BinaryOp:
    """Arithmetic binary operation (``+``, ``-``, ``*``, ``/``, ``<=``, …)."""

    left: Expr
    op: str
    right: Expr


@dataclass(frozen=True, slots=True)
class AverageExpr:
    """``average of X and Y`` or ``average of X, Y, and Z``."""

    args: tuple[Expr, ...]


@dataclass(frozen=True, slots=True)
class MedianExpr:
    """``median of X, Y, and Z``."""

    args: tuple[Expr, ...]


Expr = Union[Literal, Identifier, BinaryOp, AverageExpr, MedianExpr]


# ---------------------------------------------------------------------------
# Guard expressions
# ---------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class GuardOr:
    left: GuardExpr
    right: GuardExpr


@dataclass(frozen=True, slots=True)
class GuardAnd:
    left: GuardExpr
    right: GuardExpr


@dataclass(frozen=True, slots=True)
class GuardNot:
    operand: GuardExpr


@dataclass(frozen=True, slots=True)
class DefinitionRef:
    """Reference to a named definition (expanded in a lowering pass)."""

    name: str


# -- Atomic predicates -------------------------------------------------------


@dataclass(frozen=True, slots=True)
class DeviationPred:
    """``X deviates from Y and Z beyond B``."""

    var: str
    refs: tuple[str, ...]
    bound: str


@dataclass(frozen=True, slots=True)
class AgreementPred:
    """``X agrees with Y within B``."""

    var: str
    ref: str
    bound: str


@dataclass(frozen=True, slots=True)
class ReturnPred:
    """``X returns within threshold of Y and Z``."""

    var: str
    refs: tuple[str, ...]
    bound: str


@dataclass(frozen=True, slots=True)
class ComparisonPred:
    """``X equals Y``, ``X is below Y``, ``X exceeds Y``, ``X <= Y``, etc."""

    left: Expr
    op: str
    right: Expr


@dataclass(frozen=True, slots=True)
class BooleanPred:
    """``X is true`` / ``X is false``."""

    var: str
    value: bool


@dataclass(frozen=True, slots=True)
class MembershipPred:
    """``X is one of {a, b, c}``."""

    var: str
    values: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class NoTwoAgree:
    """``no two sensors agree within B`` (FDI-specific idiom)."""

    bound: str


AtomicPred = Union[
    DeviationPred,
    AgreementPred,
    ReturnPred,
    ComparisonPred,
    BooleanPred,
    MembershipPred,
    NoTwoAgree,
]

GuardExpr = Union[GuardOr, GuardAnd, GuardNot, DefinitionRef, AtomicPred]


# ---------------------------------------------------------------------------
# Timing predicates
# ---------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class TimingPred:
    """``for N consecutive cycles`` or ``for fewer than N consecutive cycles``."""

    cycles: Expr
    fewer_than: bool = False


# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class SetAction:
    var: str
    expr: Expr


@dataclass(frozen=True, slots=True)
class HoldAction:
    var: str


@dataclass(frozen=True, slots=True)
class IncrementAction:
    var: str


@dataclass(frozen=True, slots=True)
class ResetAction:
    var: str


Action = Union[SetAction, HoldAction, IncrementAction, ResetAction]


# ---------------------------------------------------------------------------
# Transitions
# ---------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class Transition:
    target: str
    is_remain: bool


# ---------------------------------------------------------------------------
# Compiler-synthesized nodes (produced by lowering passes)
# ---------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class CounterUpdate:
    """Per-cycle counter logic synthesized from a timing predicate.

    Semantics: each cycle in the declaring mode,
      if base_guard: counter_var += 1
      else:          counter_var := 0
    """

    counter_var: str
    base_guard: GuardExpr


# ---------------------------------------------------------------------------
# Rules
# ---------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class Rule:
    guard: GuardExpr
    timing: TimingPred | None
    actions: tuple[Action, ...]
    transition: Transition


@dataclass(frozen=True, slots=True)
class OtherwiseClause:
    actions: tuple[Action, ...]
    transition: Transition


# ---------------------------------------------------------------------------
# Type annotations
# ---------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class TypeAnnot:
    kind: str  # "boolean", "integer", "real", "enum"
    range_lo: Literal | None = None
    range_hi: Literal | None = None
    lo_inclusive: bool = True
    hi_inclusive: bool = True
    enum_values: tuple[str, ...] | None = None


@dataclass(frozen=True, slots=True)
class DefaultAnnot:
    hold: bool
    value: Literal | None = None


# ---------------------------------------------------------------------------
# Declarations
# ---------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class AssumeDecl:
    """One assume declaration.  English-form has *description* only;
    formal-form has *type_annot* only.  Both carry *names*."""

    names: tuple[str, ...]
    type_annot: TypeAnnot | None = None
    description: str | None = None


@dataclass(frozen=True, slots=True)
class Definition:
    name: str
    guard_expr: GuardExpr


@dataclass(frozen=True, slots=True)
class ConstantDecl:
    name: str
    type_annot: TypeAnnot
    value: Literal


@dataclass(frozen=True, slots=True)
class GuaranteeDecl:
    name: str
    type_annot: TypeAnnot
    initial_value: Literal | None = None
    default_annot: DefaultAnnot | None = None


@dataclass(frozen=True, slots=True)
class VariableDecl:
    name: str
    type_annot: TypeAnnot
    initial_value: Literal | None = None


# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class Mode:
    name: str
    entry_actions: tuple[Action, ...] | None = None
    invariants: tuple[Expr, ...] = ()
    rules: tuple[Rule, ...] = ()
    otherwise: OtherwiseClause | None = None
    counter_updates: tuple[CounterUpdate, ...] = ()


# ---------------------------------------------------------------------------
# Top-level specification
# ---------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class Specification:
    name: str
    assumes: tuple[AssumeDecl, ...]
    definitions: tuple[Definition, ...] = ()
    constants: tuple[ConstantDecl, ...] = ()
    guarantees: tuple[GuaranteeDecl, ...] = ()
    variables: tuple[VariableDecl, ...] = ()
    always_invariants: tuple[Expr, ...] = ()
    initial_mode: str = ""
    modes: tuple[Mode, ...] = ()


# ---------------------------------------------------------------------------
# Visitor base class (for downstream passes)
# ---------------------------------------------------------------------------


class ASTVisitor:
    """Override ``visit_<ClassName>`` methods for nodes you care about.

    Call ``self.visit(node)`` to dispatch; unhandled node types fall through
    to ``generic_visit`` which recurses into child nodes by default.
    """

    def visit(self, node):
        method_name = f"visit_{type(node).__name__}"
        visitor = getattr(self, method_name, self.generic_visit)
        return visitor(node)

    def generic_visit(self, node):
        """Recurse into dataclass fields that are AST nodes or sequences."""
        if hasattr(node, "__dataclass_fields__"):
            for f in node.__dataclass_fields__:
                value = getattr(node, f)
                if isinstance(value, tuple):
                    for item in value:
                        self.visit(item)
                elif hasattr(value, "__dataclass_fields__"):
                    self.visit(value)
