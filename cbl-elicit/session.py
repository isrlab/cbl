"""CBL elicitation session orchestrator.

Three-layer architecture:
  Layer 1 (LLM):    NL requirements → extracted_facts.json
  Layer 2 (Prolog): extracted_facts.json → verdict.json
  Layer 3 (OCaml):  verdict.json → spec.cbl

The session orchestrator manages the iteration protocol (§6 of the
NLP-CBL interface contract), calling SWI-Prolog and cblc as subprocesses
with JSON files as the interchange format.
"""

from __future__ import annotations

import json
import logging
import re
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path

import jsonschema

from .mitigations.provenance_control import (
    ProvenanceAuditLog,
    enforce_provenance,
    extract_user_fragments,
)
from .mitigations.back_translation import (
    BackTranslationReport,
    BackTranslator,
    compare_requirements,
)
from .mitigations.traceability import (
    TraceabilityDiagnostic,
    check_traceability,
)
from .mitigations.dual_extraction import (
    DualExtractionReport,
    diff_extractions,
)
from .mitigations.pattern_justification import (
    JustificationDiagnostic,
    PatternRecommendation,
    check_justifications,
)

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Paths (resolved relative to this file's parent)
# ---------------------------------------------------------------------------

_REPO_ROOT = Path(__file__).resolve().parent.parent
_PROLOG_DIR = _REPO_ROOT / "cbl-prolog"
_SCHEMA_DIR = Path(__file__).resolve().parent / "schema"
_EXTRACTED_SCHEMA = _SCHEMA_DIR / "extracted_facts.schema.json"
_VERDICT_SCHEMA = _SCHEMA_DIR / "verdict.schema.json"

# External tool paths (overridable via environment or constructor)
_DEFAULT_SWIPL = "swipl"
_DEFAULT_CBLC = "cblc"


# ---------------------------------------------------------------------------
# Data classes
# ---------------------------------------------------------------------------


@dataclass
class IterationRecord:
    """Record of one iteration in the elicitation loop."""

    iteration: int
    extracted_facts: dict | None = None
    verdict: dict | None = None
    status: str | None = None
    error_count: int = 0
    warning_count: int = 0
    question_count: int = 0
    stalled: bool = False
    cbl_text: str | None = None


@dataclass
class SessionResult:
    """Final result of an elicitation session."""

    success: bool
    cbl_text: str | None = None
    output_path: Path | None = None
    iterations: int = 0
    final_diagnostics: list[dict] = field(default_factory=list)
    unresolved_questions: list[dict] = field(default_factory=list)
    reason: str = ""
    # Hallucination mitigation reports
    audit_log: ProvenanceAuditLog | None = None
    back_translation: BackTranslationReport | None = None
    traceability_diagnostics: list[TraceabilityDiagnostic] = field(default_factory=list)
    dual_extraction: DualExtractionReport | None = None
    pattern_justification_diagnostics: list[JustificationDiagnostic] = field(
        default_factory=list
    )


# ---------------------------------------------------------------------------
# LLM interface (pluggable)
# ---------------------------------------------------------------------------


class LLMExtractor:
    """Interface for Layer 1: NL → extracted_facts.json.

    Subclass and override extract() and revise() for your LLM backend.
    """

    def extract(self, nl_text: str) -> dict:
        """First extraction: NL requirements → extracted_facts dict."""
        raise NotImplementedError

    def revise(
        self,
        nl_text: str,
        diagnostics: list[dict],
        answers: dict[str, str],
        verdict: dict,
    ) -> dict:
        """Revised extraction incorporating diagnostics and engineer answers."""
        raise NotImplementedError


class StubExtractor(LLMExtractor):
    """Stub extractor that loads a pre-made extracted_facts.json file.

    Useful for testing the Prolog/OCaml layers without an LLM.
    """

    def __init__(self, facts_path: Path):
        self._facts = json.loads(facts_path.read_text())

    def extract(self, nl_text: str) -> dict:
        return self._facts

    def revise(
        self,
        nl_text: str,
        diagnostics: list[dict],
        answers: dict[str, str],
        verdict: dict,
    ) -> dict:
        return self._facts


# ---------------------------------------------------------------------------
# Engineer interaction (pluggable)
# ---------------------------------------------------------------------------


class EngineerInterface:
    """Interface for human-in-the-loop interaction.

    Subclass for GUI, web, or batch modes.
    """

    def present_diagnostics(self, diagnostics: list[dict]) -> None:
        """Display diagnostics to the engineer."""
        for d in diagnostics:
            sev = d.get("severity", "info").upper()
            code = d.get("code", "?")
            msg = d.get("message", "")
            print(f"  [{sev}] {code}: {msg}")

    def present_questions(self, questions: list[dict]) -> dict[str, str]:
        """Present questions and collect answers. Returns {question_id: answer}."""
        answers: dict[str, str] = {}
        for q in questions:
            qid = q.get("question_id", "?")
            text = q.get("text", "")
            options = q.get("suggested_options", [])
            prompt = f"  Q[{qid}]: {text}"
            if options:
                prompt += f" (options: {', '.join(options)})"
            print(prompt)
            ans = input("  > ").strip()
            if ans:
                answers[qid] = ans
        return answers

    def present_repairs(self, repairs: list[dict]) -> list[dict]:
        """Present repairs for confirmation. Returns accepted repairs."""
        accepted = []
        for r in repairs:
            diag = r.get("for_diagnostic", "?")
            action = r.get("action", {})
            needs_conf = r.get("requires_confirmation", True)
            if not needs_conf:
                print(f"  [AUTO] Repair for {diag}: {action}")
                accepted.append(r)
            else:
                print(f"  [CONFIRM] Repair for {diag}: {action}")
                ans = input("  Accept? (y/n) > ").strip().lower()
                if ans in ("y", "yes"):
                    accepted.append(r)
        return accepted

    def report_stall(self, iteration: int, diagnostics: list[dict]) -> bool:
        """Report stall. Returns True to continue, False to abort."""
        print(f"\n  Loop stalled at iteration {iteration}.")
        print(f"  {len(diagnostics)} diagnostic(s) remain unresolved.")
        ans = input("  Continue with manual resolution? (y/n) > ").strip().lower()
        return ans in ("y", "yes")


class BatchEngineerInterface(EngineerInterface):
    """Non-interactive interface: auto-accepts all repairs, skips questions."""

    def present_questions(self, questions: list[dict]) -> dict[str, str]:
        for q in questions:
            logger.info("Skipping question: %s", q.get("text", ""))
        return {}

    def present_repairs(self, repairs: list[dict]) -> list[dict]:
        return repairs  # accept all

    def report_stall(self, iteration: int, diagnostics: list[dict]) -> bool:
        return False  # abort on stall


# ---------------------------------------------------------------------------
# Schema validation
# ---------------------------------------------------------------------------


def _load_schema(path: Path) -> dict:
    return json.loads(path.read_text())


def validate_extracted_facts(facts: dict) -> list[str]:
    """Validate extracted_facts against JSON Schema. Returns error messages."""
    schema = _load_schema(_EXTRACTED_SCHEMA)
    validator = jsonschema.Draft202012Validator(schema)
    return [e.message for e in validator.iter_errors(facts)]


def validate_verdict(verdict: dict) -> list[str]:
    """Validate verdict against JSON Schema. Returns error messages."""
    schema = _load_schema(_VERDICT_SCHEMA)
    validator = jsonschema.Draft202012Validator(schema)
    return [e.message for e in validator.iter_errors(verdict)]


# ---------------------------------------------------------------------------
# Subprocess wrappers
# ---------------------------------------------------------------------------


def run_prolog(
    input_path: Path,
    output_path: Path,
    *,
    swipl: str = _DEFAULT_SWIPL,
    prolog_dir: Path = _PROLOG_DIR,
    timeout: int = 30,
) -> tuple[int, str]:
    """Run the Prolog reasoning engine.

    Returns (exit_code, stderr).
    Exit codes: 0=pass, 1=fail/incomplete, 2=schema error.
    """
    cmd = [
        swipl,
        "-g",
        "main",
        "-t",
        "halt",
        str(prolog_dir / "run.pl"),
        "--",
        "--input",
        str(input_path),
        "--output",
        str(output_path),
    ]
    logger.debug("Running Prolog: %s", " ".join(cmd))
    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=timeout,
        cwd=str(prolog_dir),
    )
    return result.returncode, result.stderr


def run_cblc_ingest(
    verdict_path: Path,
    output_path: Path | None = None,
    *,
    cblc: str = _DEFAULT_CBLC,
    check_only: bool = False,
    timeout: int = 30,
) -> tuple[int, str, str]:
    """Run cblc ingest.

    Returns (exit_code, stdout, stderr).
    Exit codes: 0=success, 1=validation errors, 2=read error.
    """
    cmd = [cblc, "ingest", str(verdict_path)]
    if check_only:
        cmd.append("--check-only")
    elif output_path is not None:
        cmd.extend(["-o", str(output_path)])

    logger.debug("Running cblc: %s", " ".join(cmd))
    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    return result.returncode, result.stdout, result.stderr


# ---------------------------------------------------------------------------
# Session orchestrator
# ---------------------------------------------------------------------------


class Session:
    """Manages the elicitation loop (§6 of the interface contract).

    The loop:
      Step 1:  Engineer provides NL requirements.
      Step 2:  LLM produces extracted_facts.json.
      Step 2a: Validate against JSON Schema (retry up to 3 times).
      Step 3:  Prolog validates → verdict.json.
      Step 4:  Present questions/repairs to engineer.
      Step 5:  Decision boundary (auto-apply or LLM-assisted).
      Step 6:  OCaml ingest → AST.
      Step 7:  OCaml checker validates.
      Step 8:  Emit spec.cbl.
    """

    def __init__(
        self,
        extractor: LLMExtractor,
        *,
        engineer: EngineerInterface | None = None,
        max_iterations: int = 10,
        schema_retries: int = 3,
        stall_threshold: int = 2,
        swipl: str = _DEFAULT_SWIPL,
        cblc: str = _DEFAULT_CBLC,
        work_dir: Path | None = None,
        # Hallucination mitigation options
        enable_back_translation: bool = True,
        enable_traceability: bool = True,
        enable_dual_extraction: bool = False,
        back_translator: BackTranslator | None = None,
    ):
        self.extractor = extractor
        self.engineer = engineer or EngineerInterface()
        self.max_iterations = max_iterations
        self.schema_retries = schema_retries
        self.stall_threshold = stall_threshold
        self.swipl = swipl
        self.cblc = cblc
        self.work_dir = (
            work_dir or Path(tempfile.mkdtemp(prefix="cbl_session_"))
        ).resolve()
        self._owns_work_dir = work_dir is None
        self.records: list[IterationRecord] = []
        # Mitigation state
        self.enable_back_translation = enable_back_translation
        self.enable_traceability = enable_traceability
        self.enable_dual_extraction = enable_dual_extraction
        self.back_translator = back_translator
        self.audit_log = ProvenanceAuditLog()
        self._user_fragments: set[str] = set()
        self._confirmed_facts: set[tuple[str, str]] = set()

    def run(self, nl_text: str, output_path: Path) -> SessionResult:
        """Execute the full elicitation loop.

        Args:
            nl_text: Natural-language requirements text.
            output_path: Where to write the final spec.cbl.

        Returns:
            SessionResult with success status and details.
        """
        try:
            return self._run_loop(nl_text, output_path)
        finally:
            if self._owns_work_dir:
                shutil.rmtree(self.work_dir, ignore_errors=True)

    def _run_loop(self, nl_text: str, output_path: Path) -> SessionResult:
        answers: dict[str, str] = {}

        # Extract user fragments for provenance control (once, up front)
        self._user_fragments = extract_user_fragments(nl_text)

        # Dual extraction (iteration 1 only, if enabled)
        dual_report = None

        for iteration in range(1, self.max_iterations + 1):
            record = IterationRecord(iteration=iteration)
            logger.info("--- Iteration %d ---", iteration)

            # Step 2: LLM extraction (or revision)
            if iteration == 1:
                facts = self._extract_with_retries(nl_text)
                # Dual extraction: run a second extraction and diff
                if self.enable_dual_extraction and facts is not None:
                    facts_b = self._extract_with_retries(nl_text)
                    if facts_b is not None:
                        dual_report = diff_extractions(facts, facts_b)
                        logger.info("Dual extraction: %s", dual_report.summary)
            else:
                prev = self.records[-1]
                facts = self._revise_with_retries(
                    nl_text,
                    prev.verdict,
                    answers,
                )

            if facts is None:
                record.stalled = True
                self.records.append(record)
                return self._fail("Schema validation failed after retries", iteration)

            # Provenance enforcement: override LLM-assigned provenance tags
            facts = enforce_provenance(
                facts,
                self._user_fragments,
                self._confirmed_facts,
                iteration,
                self.audit_log,
            )

            record.extracted_facts = facts

            # Step 3: Prolog reasoning
            verdict = self._run_prolog(facts, iteration)
            if verdict is None:
                record.stalled = True
                self.records.append(record)
                return self._fail("Prolog engine error", iteration)

            record.verdict = verdict
            record.status = verdict.get("status", "fail")
            diagnostics = verdict.get("diagnostics", [])
            repairs = verdict.get("repairs", [])
            questions = verdict.get("questions", [])
            record.error_count = sum(
                1 for d in diagnostics if d.get("severity") == "error"
            )
            record.warning_count = sum(
                1 for d in diagnostics if d.get("severity") == "warning"
            )
            record.question_count = len(questions)

            logger.info(
                "Status: %s | Errors: %d | Warnings: %d | Questions: %d",
                record.status,
                record.error_count,
                record.warning_count,
                record.question_count,
            )

            # Step 3 shortcut: if pass, go to Layer 3
            if record.status == "pass":
                result, ocaml_diags = self._run_ocaml(verdict, output_path, iteration)
                if result is not None:
                    # Run post-success mitigations
                    result = self._apply_success_mitigations(
                        result, nl_text, facts, dual_report
                    )
                    record.cbl_text = result.cbl_text
                    self.records.append(record)
                    return result
                # OCaml checker found errors; merge them into diagnostics
                diagnostics = diagnostics + ocaml_diags
                record.error_count += len(ocaml_diags)
                logger.info(
                    "OCaml checker found %d error(s); continuing loop", len(ocaml_diags)
                )

            # Stall detection
            if self._is_stalled(record):
                record.stalled = True
                self.records.append(record)
                cont = self.engineer.report_stall(iteration, diagnostics)
                if not cont:
                    return self._fail(
                        "Loop stalled",
                        iteration,
                        diagnostics=diagnostics,
                        questions=questions,
                    )

            # Step 4: Present diagnostics, questions, repairs
            if diagnostics:
                self.engineer.present_diagnostics(diagnostics)

            answers = {}
            if questions:
                answers = self.engineer.present_questions(questions)

            if repairs:
                accepted = self.engineer.present_repairs(repairs)
                # Apply accepted repairs by tagging them in answers
                for r in accepted:
                    diag_code = r.get("for_diagnostic", "")
                    answers[f"repair_accept:{diag_code}"] = json.dumps(
                        r.get("action", {})
                    )
                    # Track confirmed facts for provenance.
                    # Prolog emits for_diagnostic as e.g. "unconfirmed(sensor_a,assume)".
                    m = re.match(r"unconfirmed\((\w+),\s*(\w+)\)", diag_code)
                    if m:
                        fact_name, fact_kind = m.group(1), m.group(2)
                        self._confirmed_facts.add((fact_kind, fact_name))
                        self.audit_log.confirm(fact_kind, fact_name, iteration)

            self.records.append(record)

        # Max iterations exhausted
        last = self.records[-1] if self.records else None
        return self._fail(
            f"Maximum iterations ({self.max_iterations}) reached",
            self.max_iterations,
            diagnostics=(
                last.verdict.get("diagnostics", []) if last and last.verdict else []
            ),
            questions=(
                last.verdict.get("questions", []) if last and last.verdict else []
            ),
        )

    # -------------------------------------------------------------------
    # Internal: LLM extraction with schema validation retries
    # -------------------------------------------------------------------

    def _extract_with_retries(self, nl_text: str) -> dict | None:
        """Step 2 + 2a: extract and validate, retrying on schema errors."""
        try:
            facts = self.extractor.extract(nl_text)
        except Exception:
            logger.error("LLM extraction failed", exc_info=True)
            return None
        for attempt in range(1, self.schema_retries + 1):
            errors = validate_extracted_facts(facts)
            if not errors:
                return facts
            logger.warning(
                "Schema validation failed (attempt %d/%d): %s",
                attempt,
                self.schema_retries,
                errors,
            )
            if attempt < self.schema_retries:
                try:
                    facts = self.extractor.revise(
                        nl_text,
                        [
                            {"severity": "error", "code": "schema_error", "message": e}
                            for e in errors
                        ],
                        {},
                        {},
                    )
                except Exception:
                    logger.error("LLM revision failed", exc_info=True)
                    return None
        return None

    def _revise_with_retries(
        self, nl_text: str, verdict: dict, answers: dict[str, str]
    ) -> dict | None:
        """Step 5: revise extraction with diagnostics and answers."""
        diagnostics = verdict.get("diagnostics", [])
        for attempt in range(1, self.schema_retries + 1):
            try:
                facts = self.extractor.revise(nl_text, diagnostics, answers, verdict)
            except Exception:
                logger.error("LLM revision failed", exc_info=True)
                return None
            errors = validate_extracted_facts(facts)
            if not errors:
                return facts
            logger.warning(
                "Schema validation failed on revision (attempt %d/%d): %s",
                attempt,
                self.schema_retries,
                errors,
            )
            # Augment diagnostics with schema errors for next retry
            diagnostics = verdict.get("diagnostics", []) + [
                {"severity": "error", "code": "schema_error", "message": e}
                for e in errors
            ]
        return None

    # -------------------------------------------------------------------
    # Internal: Prolog reasoning
    # -------------------------------------------------------------------

    def _run_prolog(self, facts: dict, iteration: int) -> dict | None:
        """Step 3: run Prolog engine on extracted facts."""
        input_path = self.work_dir / f"extracted_facts_{iteration}.json"
        output_path = self.work_dir / f"verdict_{iteration}.json"

        input_path.write_text(json.dumps(facts, indent=2))

        if output_path.exists():
            try:
                output_path.unlink()
            except OSError as exc:
                logger.warning("Failed to remove stale verdict file: %s", exc)

        start_time = time.time()

        try:
            exit_code, stderr = run_prolog(
                input_path,
                output_path,
                swipl=self.swipl,
            )
        except subprocess.TimeoutExpired:
            logger.error("Prolog timed out on iteration %d", iteration)
            return None
        except OSError as exc:
            logger.error("Prolog invocation failed: %s", exc)
            return None

        if exit_code == 2:
            logger.error("Prolog schema error: %s", stderr)
            return None

        if exit_code not in (0, 1, 2):
            logger.error("Prolog exited with unexpected code %d: %s", exit_code, stderr)
            return None

        if not output_path.exists():
            logger.error("Prolog did not produce verdict: %s", stderr)
            return None

        try:
            if output_path.stat().st_mtime < start_time:
                logger.error("Prolog verdict file is stale: %s", output_path)
                return None
        except OSError as exc:
            logger.error("Failed to stat verdict file: %s", exc)
            return None

        try:
            verdict = json.loads(output_path.read_text())
        except (json.JSONDecodeError, OSError) as exc:
            logger.error("Failed to read verdict file: %s", exc)
            return None

        # Validate verdict schema
        schema_errors = validate_verdict(verdict)
        if schema_errors:
            logger.error("Verdict schema validation failed: %s", schema_errors)
            return None

        return verdict

    # -------------------------------------------------------------------
    # Internal: OCaml ingestion and checking
    # -------------------------------------------------------------------

    def _run_ocaml(
        self, verdict: dict, output_path: Path, iteration: int
    ) -> tuple[SessionResult | None, list[dict]]:
        """Steps 6-8: OCaml ingest, check, emit.

        Returns (SessionResult, []) on success,
                (None, diagnostics) if checker found errors.
        """
        verdict_path = self.work_dir / f"verdict_{iteration}.json"
        if not verdict_path.exists():
            verdict_path.write_text(json.dumps(verdict, indent=2))

        try:
            exit_code, stdout, stderr = run_cblc_ingest(
                verdict_path,
                output_path,
                cblc=self.cblc,
            )
        except subprocess.TimeoutExpired:
            logger.error("cblc timed out on iteration %d", iteration)
            return None, [
                {
                    "severity": "error",
                    "code": "CBLC-TIMEOUT",
                    "message": "cblc timed out",
                }
            ]
        except OSError as exc:
            logger.error("cblc invocation failed: %s", exc)
            return None, [
                {
                    "severity": "error",
                    "code": "CBLC-EXEC",
                    "message": f"cblc invocation failed: {exc}",
                }
            ]

        if exit_code == 0:
            cbl_text = output_path.read_text() if output_path.exists() else None
            if not cbl_text:
                logger.error("cblc produced no output text")
                return None, [
                    {
                        "severity": "error",
                        "code": "EMIT-EMPTY",
                        "message": "Compiler produced empty CBL output",
                    }
                ]
            return (
                SessionResult(
                    success=True,
                    cbl_text=cbl_text,
                    output_path=output_path,
                    iterations=iteration,
                    reason="Specification is well-posed",
                ),
                [],
            )

        # exit_code 1: checker errors; parse them from stdout
        ocaml_diags: list[dict] = []
        if exit_code == 1 and stdout.strip():
            try:
                parsed = json.loads(stdout)
                if isinstance(parsed, list):
                    ocaml_diags = parsed
                elif isinstance(parsed, dict):
                    ocaml_diags = parsed.get("diagnostics", [])
                else:
                    ocaml_diags = []
                logger.info("OCaml checker: %d error(s)", len(ocaml_diags))
            except (json.JSONDecodeError, TypeError, AttributeError):
                logger.warning("Could not parse cblc diagnostics: %s", stdout)

        if exit_code != 0:
            if not ocaml_diags:
                msg = stderr.strip() or stdout.strip() or "cblc ingest failed"
                logger.error("cblc ingest failed (exit %d): %s", exit_code, msg)
                ocaml_diags = [
                    {
                        "severity": "error",
                        "code": "CBLC-EXIT",
                        "message": f"cblc ingest failed (exit {exit_code}): {msg}",
                    }
                ]
            return None, ocaml_diags

        return None, ocaml_diags

    # -------------------------------------------------------------------
    # Internal: Stall detection
    # -------------------------------------------------------------------

    def _is_stalled(self, current: IterationRecord) -> bool:
        """Check if the loop has stalled (no progress in last N consecutive iterations)."""
        if len(self.records) < self.stall_threshold:
            return False
        # Check that error/warning counts are unchanged for the last stall_threshold iterations
        window = self.records[-self.stall_threshold :]
        counts = [(r.error_count, r.warning_count) for r in window]
        current_counts = (current.error_count, current.warning_count)
        all_same = all(c == current_counts for c in counts)
        no_new_questions = current.question_count == 0
        return all_same and no_new_questions

    # -------------------------------------------------------------------
    # Internal: Post-success mitigations
    # -------------------------------------------------------------------

    def _apply_success_mitigations(
        self,
        result: SessionResult,
        nl_text: str,
        facts: dict,
        dual_report: DualExtractionReport | None,
    ) -> SessionResult:
        """Attach hallucination mitigation reports to a successful result."""
        # Back-translation: render CBL → English, compare with original NL
        if self.enable_back_translation and result.cbl_text:
            bt_report = compare_requirements(
                nl_text, result.cbl_text, back_translator=self.back_translator
            )
            result.back_translation = bt_report
            logger.info(
                "Back-translation: %d discrepancy(ies), %d coverage note(s)",
                len(bt_report.discrepancies),
                len(bt_report.coverage_notes),
            )

        # Traceability: check every fact cites a real requirement fragment
        if self.enable_traceability:
            trace_diags = check_traceability(facts, nl_text)
            result.traceability_diagnostics = trace_diags
            logger.info("Traceability: %d diagnostic(s)", len(trace_diags))

        # Attach dual extraction report
        if dual_report is not None:
            result.dual_extraction = dual_report

        # Pattern justification: validate any domain-agent pattern recommendations
        recs_raw = facts.get("pattern_recommendations", [])
        if recs_raw:
            try:
                recs = [PatternRecommendation(**r) for r in recs_raw]
                req_ids = set(re.findall(r"\bR\d+\b|REQ-\d+", nl_text))
                just_diags = check_justifications(recs, req_ids, nl_text)
                result.pattern_justification_diagnostics = just_diags
                logger.info("Pattern justification: %d diagnostic(s)", len(just_diags))
            except (TypeError, KeyError, ValueError):
                logger.warning("Pattern justification check failed", exc_info=True)

        # Attach and persist provenance audit log
        result.audit_log = self.audit_log
        self._save_audit_log()

        return result

    def _save_audit_log(self) -> None:
        """Persist the provenance audit log to work_dir."""
        try:
            self.audit_log.save(self.work_dir / "provenance_audit.json")
        except Exception:
            logger.warning("Failed to save provenance audit log", exc_info=True)

    # -------------------------------------------------------------------
    # Internal: Result helpers
    # -------------------------------------------------------------------

    def _fail(
        self,
        reason: str,
        iteration: int,
        *,
        diagnostics: list[dict] | None = None,
        questions: list[dict] | None = None,
    ) -> SessionResult:
        self._save_audit_log()
        return SessionResult(
            success=False,
            iterations=iteration,
            final_diagnostics=diagnostics or [],
            unresolved_questions=questions or [],
            reason=reason,
            audit_log=self.audit_log,
        )
