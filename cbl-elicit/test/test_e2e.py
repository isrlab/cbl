"""End-to-end test: extracted_facts → Prolog → OCaml → spec.cbl"""

import importlib.util
import json
import logging
import sys
from pathlib import Path

import pytest

# ---------------------------------------------------------------------------
# Module bootstrap: import session.py without requiring an installed package
# ---------------------------------------------------------------------------
_ELICIT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_ELICIT_ROOT))

_mod_path = _ELICIT_ROOT / "session.py"
_spec = importlib.util.spec_from_file_location(
    "cbl_session", _mod_path, submodule_search_locations=[]
)
_mod = importlib.util.module_from_spec(_spec)
_mod.__package__ = "cbl_session"
sys.modules["cbl_session"] = _mod
_spec.loader.exec_module(_mod)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_CBLC_PATH = (
    Path(__file__).resolve().parent.parent.parent
    / "cbl-compiler"
    / "_build"
    / "install"
    / "default"
    / "bin"
    / "cblc"
)

_FACTS_PATH = Path(__file__).parent / "traffic_extracted.json"


def _cblc_available() -> bool:
    return _CBLC_PATH.exists()


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


@pytest.mark.skipif(not _FACTS_PATH.exists(), reason="traffic_extracted.json missing")
@pytest.mark.skipif(not _cblc_available(), reason="cblc binary not built")
def test_e2e_traffic(tmp_path, caplog):
    """Full pipeline: StubExtractor → Prolog → OCaml → spec.cbl"""
    # NL text must contain the fact names so that enforce_provenance assigns
    # user_stated (not llm_inferred), allowing compilation without confirmations.
    nl_text = (
        "The 'TrafficLight' controller starts in mode Green. "
        "It reads input 'timer_expired' and 'pedestrian_request'. "
        "Constant 'cycle_time' is 30 seconds. "
        "It guarantees 'light_color' and 'walk_signal'. "
        "Modes are mode Green, mode Yellow, mode Red."
    )

    with caplog.at_level(logging.INFO):
        output_path = tmp_path / "traffic.cbl"

        extractor = _mod.StubExtractor(_FACTS_PATH)
        engineer = _mod.BatchEngineerInterface()

        session = _mod.Session(
            extractor,
            engineer=engineer,
            max_iterations=5,
            swipl="swipl",
            cblc=str(_CBLC_PATH),
            work_dir=tmp_path,
        )

        result = session.run(nl_text, output_path)

    assert result.success, (
        f"E2E pipeline failed after {result.iterations} iteration(s). "
        f"Reason: {result.reason}. "
        f"Diagnostics: {json.dumps(result.final_diagnostics, indent=2)}"
    )
    assert result.cbl_text, "Pipeline succeeded but produced no CBL output"
    assert output_path.exists(), "Pipeline succeeded but output file was not written"
