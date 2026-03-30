"""Gap 4 mitigation: Requirements-to-test traceability.

Ensures every requirement ID has at least one test scenario that exercises it.
The traceability matrix is built from test annotations and checked for
surjectivity (every requirement has a test).

Test scenarios carry ``requirement_ids`` annotations. This checker verifies
that the mapping from requirements to tests is complete.
"""

from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True, slots=True)
class TestScenario:
    """A test scenario with requirement traceability annotations."""

    name: str
    description: str
    requirement_ids: list[str]  # e.g. ["R1", "R3", "R7"]
    inputs: list[dict[str, object]]
    expected_outputs: list[dict[str, object]] | None = None


@dataclass(frozen=True, slots=True)
class TraceabilityGap:
    """A requirement with no test coverage."""

    requirement_id: str
    severity: str = "warning"

    @property
    def message(self) -> str:
        return f"Requirement '{self.requirement_id}' has no test scenario."


@dataclass
class TestTraceabilityReport:
    """Report on requirements-to-test coverage."""

    total_requirements: int = 0
    covered_requirements: int = 0
    gaps: list[TraceabilityGap] = field(default_factory=list)
    coverage_matrix: dict[str, list[str]] = field(
        default_factory=dict
    )  # req_id → [test_names]

    @property
    def coverage_ratio(self) -> float:
        if self.total_requirements == 0:
            return 1.0
        return self.covered_requirements / self.total_requirements

    @property
    def summary(self) -> str:
        return (
            f"Test coverage: {self.covered_requirements}/{self.total_requirements} "
            f"requirements ({self.coverage_ratio * 100:.0f}%). "
            f"{len(self.gaps)} gap(s)."
        )


def check_test_traceability(
    requirement_ids: list[str],
    test_scenarios: list[TestScenario],
) -> TestTraceabilityReport:
    """Check that every requirement has at least one test scenario.

    Args:
        requirement_ids: List of all requirement identifiers.
        test_scenarios: List of test scenarios with requirement annotations.

    Returns:
        TestTraceabilityReport with coverage analysis.
    """
    report = TestTraceabilityReport(total_requirements=len(requirement_ids))

    # Build coverage matrix
    for req_id in requirement_ids:
        report.coverage_matrix[req_id] = []

    for scenario in test_scenarios:
        for req_id in scenario.requirement_ids:
            if req_id in report.coverage_matrix:
                report.coverage_matrix[req_id].append(scenario.name)

    # Check surjectivity
    for req_id in requirement_ids:
        tests = report.coverage_matrix.get(req_id, [])
        if tests:
            report.covered_requirements += 1
        else:
            report.gaps.append(TraceabilityGap(requirement_id=req_id))

    return report


def extract_requirement_ids(nl_text: str) -> list[str]:
    """Extract requirement IDs from natural-language text.

    Recognizes patterns like:
    - R1, R2, R3 (numbered requirements)
    - REQ-001, REQ-002
    - [R1], [R2]
    - Requirement 1, Requirement 2

    Args:
        nl_text: The requirements text.

    Returns:
        List of unique requirement IDs found.
    """
    import re

    ids: list[str] = []
    seen: set[str] = set()

    # Pattern: R<number> or REQ-<number>
    for match in re.finditer(r"\b(R(?:EQ)?[-_]?\d+)\b", nl_text, re.IGNORECASE):
        rid = match.group(1).upper()
        if rid not in seen:
            ids.append(rid)
            seen.add(rid)

    # Pattern: Requirement <number>
    for match in re.finditer(r"\bRequirement\s+(\d+)\b", nl_text, re.IGNORECASE):
        rid = f"R{match.group(1)}"
        if rid not in seen:
            ids.append(rid)
            seen.add(rid)

    # Pattern: [R<number>]
    for match in re.finditer(r"\[([Rr]\d+)\]", nl_text):
        rid = match.group(1).upper()
        if rid not in seen:
            ids.append(rid)
            seen.add(rid)

    return ids
