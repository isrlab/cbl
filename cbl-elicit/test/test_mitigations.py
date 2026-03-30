"""Tests for hallucination mitigation modules.

Tests cover:
  - provenance_control: enforce_provenance, audit log, extract_user_fragments
  - back_translation: render_cbl_to_english, compare_requirements
  - traceability: check_traceability with all diagnostic codes
  - dual_extraction: diff_extractions with agreement and divergence cases
  - pattern_justification: check_justifications with all diagnostic codes
"""

import json
import sys
import tempfile
from pathlib import Path

import pytest

# Handle hyphenated package name by inserting parent into path
# and importing modules directly
_ELICIT_ROOT = Path(__file__).resolve().parent.parent

import importlib
import importlib.util


def _import_module(dotted_name: str, file_path: Path):
    """Import a module from an absolute file path."""
    spec = importlib.util.spec_from_file_location(dotted_name, file_path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[dotted_name] = mod
    spec.loader.exec_module(mod)
    return mod


# Import mitigation modules
provenance_mod = _import_module(
    "cbl_elicit.mitigations.provenance_control",
    _ELICIT_ROOT / "mitigations" / "provenance_control.py",
)
back_translation_mod = _import_module(
    "cbl_elicit.mitigations.back_translation",
    _ELICIT_ROOT / "mitigations" / "back_translation.py",
)
traceability_mod = _import_module(
    "cbl_elicit.mitigations.traceability",
    _ELICIT_ROOT / "mitigations" / "traceability.py",
)
dual_extraction_mod = _import_module(
    "cbl_elicit.mitigations.dual_extraction",
    _ELICIT_ROOT / "mitigations" / "dual_extraction.py",
)
pattern_justification_mod = _import_module(
    "cbl_elicit.mitigations.pattern_justification",
    _ELICIT_ROOT / "mitigations" / "pattern_justification.py",
)

ProvenanceAuditLog = provenance_mod.ProvenanceAuditLog
enforce_provenance = provenance_mod.enforce_provenance
extract_user_fragments = provenance_mod.extract_user_fragments

render_cbl_to_english = back_translation_mod.render_cbl_to_english
compare_requirements = back_translation_mod.compare_requirements
BackTranslator = back_translation_mod.BackTranslator

check_traceability = traceability_mod.check_traceability
TraceabilityDiagnostic = traceability_mod.TraceabilityDiagnostic

diff_extractions = dual_extraction_mod.diff_extractions
DualExtractionReport = dual_extraction_mod.DualExtractionReport

check_justifications = pattern_justification_mod.check_justifications
PatternRecommendation = pattern_justification_mod.PatternRecommendation


# =========================================================================
# Fixtures: sample data
# =========================================================================


@pytest.fixture
def sample_facts():
    """Minimal extracted_facts dict for testing."""
    return {
        "system_name": {"value": "TrafficLight", "provenance": "llm_inferred"},
        "initial_mode": {"value": "Red", "provenance": "llm_inferred"},
        "assumes": [
            {
                "name": {"value": "pedestrian_button", "provenance": "llm_inferred"},
                "atype": {"value": "boolean", "provenance": "llm_inferred"},
                "constraint": {
                    "value": "pedestrian_button",
                    "provenance": "llm_inferred",
                },
                "source": "pedestrian button is pressed",
            }
        ],
        "guarantees": [
            {
                "name": {"value": "lamp_color", "provenance": "llm_inferred"},
                "gtype": {
                    "value": "{Red, Yellow, Green}",
                    "provenance": "llm_inferred",
                },
                "source": "the lamp shows red, yellow, or green",
            }
        ],
        "variables": [
            {
                "name": {"value": "timer", "provenance": "llm_inferred"},
                "vtype": {"value": "integer", "provenance": "llm_inferred"},
                "initial": {"value": 0, "provenance": "llm_inferred"},
                "source": "The light starts in red mode.",
            }
        ],
        "constants": [],
        "definitions": [],
        "modes": [
            {
                "name": {"value": "Red", "provenance": "llm_inferred"},
                "source": "the light starts in red mode",
                "entry_actions": [
                    {
                        "kind": "set",
                        "name": "lamp_color",
                        "value": "Red",
                        "provenance": "llm_inferred",
                    }
                ],
                "transitions": [
                    {
                        "guard": {
                            "type": "boolean",
                            "value": "pedestrian_button",
                            "provenance": "llm_inferred",
                        },
                        "actions": [
                            {
                                "kind": "set",
                                "name": "lamp_color",
                                "value": "Green",
                                "provenance": "llm_inferred",
                            }
                        ],
                        "target": {"value": "Green", "provenance": "llm_inferred"},
                        "source": "when the pedestrian button is pressed, switch to green",
                    }
                ],
            },
            {
                "name": {"value": "Green", "provenance": "llm_inferred"},
                "source": "green mode",
                "transitions": [],
            },
        ],
    }


@pytest.fixture
def sample_nl_text():
    return (
        "The traffic light system has a pedestrian button is pressed input. "
        "The lamp shows red, yellow, or green. "
        "The light starts in red mode. "
        "When the pedestrian button is pressed, switch to green."
    )


@pytest.fixture
def sample_cbl_text():
    return """\
System TrafficLight

Assumes
  pedestrian_button : boolean

Guarantees
  lamp_color : {Red, Yellow, Green}

Initially in Red

Mode Red
  When pedestrian_button
    set lamp_color to Green
    transition to Green

Mode Green
  Otherwise
    remain
"""


# =========================================================================
# Tests: provenance_control
# =========================================================================


class TestProvenanceControl:
    def test_extract_user_fragments_quoted(self):
        text = 'The system has inputs called "sensor1" and "pressure".'
        frags = extract_user_fragments(text)
        assert "sensor1" in frags
        assert "pressure" in frags

    def test_extract_user_fragments_uppercase(self):
        text = "The system states are IDLE, ACTIVE, and FAULT."
        frags = extract_user_fragments(text)
        assert "IDLE" in frags
        assert "ACTIVE" in frags
        assert "FAULT" in frags

    def test_extract_user_fragments_named_pattern(self):
        text = "There is a mode called Heating and a state Running."
        frags = extract_user_fragments(text)
        assert "Heating" in frags

    def test_enforce_provenance_user_stated(self, sample_facts):
        """Facts whose names appear in user fragments get user_stated."""
        user_frags = {"TrafficLight", "Red", "pedestrian_button", "timer"}
        confirmed = set()
        log = ProvenanceAuditLog()

        result = enforce_provenance(sample_facts, user_frags, confirmed, 1, log)

        # system_name should be user_stated
        assert result["system_name"]["provenance"] == "user_stated"
        # initial_mode should be user_stated
        assert result["initial_mode"]["provenance"] == "user_stated"
        # assumes.pedestrian_button should be user_stated
        assert result["assumes"][0]["name"]["provenance"] == "user_stated"
        # constraint should be user_stated
        assert result["assumes"][0]["constraint"]["provenance"] == "user_stated"
        # variable initial should be user_stated
        assert result["variables"][0]["initial"]["provenance"] == "user_stated"
        # Mode Red should be user_stated
        assert result["modes"][0]["name"]["provenance"] == "user_stated"
        # Entry action should be independently marked (default llm_inferred)
        assert result["modes"][0]["entry_actions"][0]["provenance"] == "llm_inferred"
        # Transition actions should be overwritten (default llm_inferred)
        assert (
            result["modes"][0]["transitions"][0]["actions"][0]["provenance"]
            == "llm_inferred"
        )
        # Provenance attestation marker should be set
        assert result["provenance_attested"] is True

    def test_enforce_provenance_llm_inferred(self, sample_facts):
        """Facts not in user fragments get llm_inferred."""
        user_frags = set()  # nothing matched
        confirmed = set()
        log = ProvenanceAuditLog()

        result = enforce_provenance(sample_facts, user_frags, confirmed, 1, log)

        assert result["system_name"]["provenance"] == "llm_inferred"
        assert result["initial_mode"]["provenance"] == "llm_inferred"
        assert result["assumes"][0]["constraint"]["provenance"] == "llm_inferred"
        assert result["variables"][0]["initial"]["provenance"] == "llm_inferred"
        assert result["modes"][0]["entry_actions"][0]["provenance"] == "llm_inferred"
        assert (
            result["modes"][0]["transitions"][0]["actions"][0]["provenance"]
            == "llm_inferred"
        )

    def test_enforce_provenance_confirmed(self, sample_facts):
        """Previously confirmed facts get user_confirmed."""
        user_frags = set()
        confirmed = {("mode", "Red"), ("assume", "pedestrian_button")}
        log = ProvenanceAuditLog()

        result = enforce_provenance(sample_facts, user_frags, confirmed, 2, log)

        assert result["modes"][0]["name"]["provenance"] == "user_confirmed"
        assert result["assumes"][0]["name"]["provenance"] == "user_confirmed"

    def test_audit_log_records(self, sample_facts):
        """Audit log should record entries for every processed fact."""
        user_frags = {"TrafficLight"}
        log = ProvenanceAuditLog()

        enforce_provenance(sample_facts, user_frags, set(), 1, log)

        assert len(log.entries) > 0
        # Should have entries for system_name, initial_mode, assumes, guarantees, modes, transitions
        kinds = {e.fact_kind for e in log.entries}
        assert "mode" in kinds

    def test_audit_log_save_load(self, sample_facts):
        """Audit log can be saved and loaded."""
        log = ProvenanceAuditLog()
        log.record(1, "mode", "Red", "llm_response", "user_stated", confirmed=True)

        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "audit.json"
            log.save(path)
            assert path.exists()

            data = json.loads(path.read_text())
            assert len(data) == 1
            assert data[0]["fact_name"] == "Red"

            log2 = ProvenanceAuditLog()
            log2.load(path)
            assert len(log2.entries) == 1
            assert log2.entries[0].fact_name == "Red"

    def test_confirmed_facts_set(self):
        log = ProvenanceAuditLog()
        log.record(1, "mode", "Red", "llm_response", "llm_inferred")
        log.confirm("mode", "Red", 2)

        confirmed = log.confirmed_facts()
        assert ("mode", "Red") in confirmed

    def test_enforce_provenance_invariants(self, sample_facts):
        facts = json.loads(json.dumps(sample_facts))
        facts["always_invariants"] = [
            {
                "predicate": {
                    "value": {"kind": "is_true", "expr": "pedestrian_button"},
                    "provenance": "llm_inferred",
                }
            }
        ]
        log = ProvenanceAuditLog()
        result = enforce_provenance(facts, {"TrafficLight"}, set(), 1, log)
        pred = result["always_invariants"][0]["predicate"]
        assert pred["provenance"] == "llm_inferred"

    def test_enforce_provenance_invariants_confirmed(self, sample_facts):
        facts = json.loads(json.dumps(sample_facts))
        facts["always_invariants"] = [
            {
                "predicate": {
                    "value": {"kind": "is_true", "expr": "pedestrian_button"},
                    "provenance": "llm_inferred",
                }
            }
        ]
        log = ProvenanceAuditLog()
        confirmed = {("always_invariant", "global")}
        result = enforce_provenance(facts, set(), confirmed, 1, log)
        pred = result["always_invariants"][0]["predicate"]
        assert pred["provenance"] == "user_confirmed"


# =========================================================================
# Tests: back_translation
# =========================================================================


class TestBackTranslation:
    def test_render_system_name(self, sample_cbl_text):
        rendered = render_cbl_to_english(sample_cbl_text)
        assert "TrafficLight" in rendered

    def test_render_assumes(self, sample_cbl_text):
        rendered = render_cbl_to_english(sample_cbl_text)
        assert "pedestrian_button" in rendered
        assert "boolean" in rendered.lower() or "true/false" in rendered.lower()

    def test_render_guarantees(self, sample_cbl_text):
        rendered = render_cbl_to_english(sample_cbl_text)
        assert "lamp_color" in rendered

    def test_render_initially(self, sample_cbl_text):
        rendered = render_cbl_to_english(sample_cbl_text)
        assert "Red" in rendered

    def test_render_mode(self, sample_cbl_text):
        rendered = render_cbl_to_english(sample_cbl_text)
        assert "Red" in rendered
        assert "Green" in rendered

    def test_compare_requirements_no_discrepancies(
        self, sample_nl_text, sample_cbl_text
    ):
        report = compare_requirements(sample_nl_text, sample_cbl_text)
        assert report.structural_summary  # not empty
        assert report.original_text == sample_nl_text
        assert report.back_translated_text  # not empty

    def test_compare_requirements_missing_concept(self):
        """If original mentions a concept not in the spec, it should flag it."""
        nl = (
            "The system monitors temperature and humidity with three redundant sensors."
        )
        cbl = "System Simple\n\nAssumes\n  x : boolean\n\nGuarantees\n  y : boolean\n\nInitially in Idle\n\nMode Idle\n  Otherwise\n    remain\n"
        report = compare_requirements(nl, cbl)
        # "temperature", "humidity", "sensors" should appear in discrepancies
        assert len(report.discrepancies) > 0 or len(report.coverage_notes) > 0

    def test_custom_back_translator(self, sample_cbl_text):
        """Custom back-translator is called."""

        class MyTranslator(BackTranslator):
            def back_translate(self, cbl_text):
                return "Custom translation of the specification."

        report = compare_requirements(
            "Some NL text.", sample_cbl_text, back_translator=MyTranslator()
        )
        assert report.back_translated_text == "Custom translation of the specification."


# =========================================================================
# Tests: traceability
# =========================================================================


class TestTraceability:
    def test_all_cited_no_diagnostics(self, sample_facts, sample_nl_text):
        """Facts with valid citations produce no TRACE-1 or TRACE-2."""
        ds = check_traceability(sample_facts, sample_nl_text)
        trace1 = [d for d in ds if d.code == "TRACE-1"]
        trace2 = [d for d in ds if d.code == "TRACE-2"]
        assert len(trace1) == 0
        assert len(trace2) == 0

    def test_missing_citation(self, sample_facts, sample_nl_text):
        """Fact with no source triggers TRACE-1."""
        sample_facts["assumes"][0].pop("source", None)
        ds = check_traceability(sample_facts, sample_nl_text)
        trace1 = [d for d in ds if d.code == "TRACE-1"]
        assert len(trace1) >= 1
        assert "pedestrian_button" in trace1[0].message

    def test_hallucinated_citation(self, sample_facts, sample_nl_text):
        """Fact citing text not in the requirements triggers TRACE-2."""
        sample_facts["assumes"][0][
            "source"
        ] = "the quantum flux capacitor exceeds threshold"
        ds = check_traceability(sample_facts, sample_nl_text)
        trace2 = [d for d in ds if d.code == "TRACE-2"]
        assert len(trace2) >= 1

    def test_short_citation(self, sample_facts, sample_nl_text):
        """Suspiciously short citation triggers TRACE-4."""
        sample_facts["assumes"][0]["source"] = "yes"
        ds = check_traceability(sample_facts, sample_nl_text)
        trace4 = [d for d in ds if d.code == "TRACE-4"]
        assert len(trace4) >= 1

    def test_coverage_gap(self, sample_facts):
        """Requirement sentences with no tracing fact trigger TRACE-3."""
        nl = (
            "The system has an emergency stop mechanism. "
            "The temperature must never exceed 100 degrees. "
            "The pedestrian button is pressed to trigger a change."
        )
        ds = check_traceability(sample_facts, nl)
        trace3 = [d for d in ds if d.code == "TRACE-3"]
        # "emergency stop" and "temperature" sentences should be uncovered
        assert len(trace3) >= 1


# =========================================================================
# Tests: dual_extraction
# =========================================================================


class TestDualExtraction:
    def test_identical_extractions(self, sample_facts):
        """Identical extractions produce 100% agreement."""
        import copy

        facts_b = copy.deepcopy(sample_facts)
        report = diff_extractions(sample_facts, facts_b)
        assert report.agreement_score == 1.0
        assert len(report.divergences) == 0

    def test_different_system_name(self, sample_facts):
        """Different system names produce a divergence."""
        import copy

        facts_b = copy.deepcopy(sample_facts)
        facts_b["system_name"]["value"] = "PedestrianSignal"
        report = diff_extractions(sample_facts, facts_b)
        assert report.agreement_score < 1.0
        cats = [d.category for d in report.divergences]
        assert "system_name" in cats

    def test_missing_mode(self, sample_facts):
        """Missing mode in one extraction produces a divergence."""
        import copy

        facts_b = copy.deepcopy(sample_facts)
        facts_b["modes"] = [facts_b["modes"][0]]  # drop Green
        report = diff_extractions(sample_facts, facts_b)
        assert report.agreement_score < 1.0
        cats = [d.category for d in report.divergences]
        assert "mode_missing" in cats

    def test_different_provenance_ignored(self, sample_facts):
        """Provenance differences should not cause divergence."""
        import copy

        facts_b = copy.deepcopy(sample_facts)
        facts_b["system_name"]["provenance"] = "user_stated"
        report = diff_extractions(sample_facts, facts_b)
        # Provenance is stripped for comparison, so system_name values match
        assert report.agreement_score == 1.0

    def test_summary_format(self, sample_facts):
        import copy

        report = diff_extractions(sample_facts, copy.deepcopy(sample_facts))
        assert "Agreement" in report.summary


# =========================================================================
# Tests: pattern_justification
# =========================================================================


class TestPatternJustification:
    def test_valid_justification(self):
        recs = [
            PatternRecommendation(
                pattern_element="triple_sensor_voting",
                description="Use triple modular redundancy",
                requirement_citations=["R1"],
                justification="R1 requires sensor redundancy",
            )
        ]
        req_ids = {"R1", "R2", "R3"}
        nl = "R1: The system shall use three redundant sensors for voting."
        ds = check_justifications(recs, req_ids, nl)
        # No errors expected (R1 exists, text mentions "sensor" and "voting")
        errors = [d for d in ds if d.severity == "error"]
        assert len(errors) == 0

    def test_no_citation_just1(self):
        recs = [
            PatternRecommendation(
                pattern_element="persistence_threshold",
                description="Add persistence counting",
                requirement_citations=[],
                justification="",
            )
        ]
        ds = check_justifications(recs, {"R1"}, "R1: Some requirement")
        just1 = [d for d in ds if d.code == "JUST-1"]
        assert len(just1) == 1

    def test_invalid_citation_just2(self):
        recs = [
            PatternRecommendation(
                pattern_element="isolation",
                description="Isolate faulty sensor",
                requirement_citations=["R99"],
                justification="R99 requires isolation",
            )
        ]
        ds = check_justifications(recs, {"R1", "R2"}, "R1: Isolate faults")
        just2 = [d for d in ds if d.code == "JUST-2"]
        assert len(just2) == 1

    def test_implausible_citation_just3(self):
        recs = [
            PatternRecommendation(
                pattern_element="triple_sensor_voting",
                description="Use triple modular redundancy",
                requirement_citations=["R1"],
                justification="R1 needs voting",
            )
        ]
        # R1 text has no relevant keywords
        nl = "R1: The system shall display a status LED."
        ds = check_justifications(recs, {"R1"}, nl)
        just3 = [d for d in ds if d.code == "JUST-3"]
        assert len(just3) >= 1


# =========================================================================
# Tests: integration (verify imports work together)
# =========================================================================


class TestIntegration:
    def test_provenance_then_traceability(self, sample_facts, sample_nl_text):
        """Provenance enforcement followed by traceability check."""
        user_frags = extract_user_fragments(sample_nl_text)
        log = ProvenanceAuditLog()
        enforced = enforce_provenance(sample_facts, user_frags, set(), 1, log)
        ds = check_traceability(enforced, sample_nl_text)
        # Should still get valid results (provenance enforcement doesn't remove source)
        assert isinstance(ds, list)
