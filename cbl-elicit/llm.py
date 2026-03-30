"""LLM extractors for CBL fact extraction (Layer 1).

Concrete implementations of session.LLMExtractor for OpenAI and Anthropic APIs.
Supports optional agent injection: domain and pipeline agents whose instructions
are appended to the system prompt to shape LLM behavior.
"""

from __future__ import annotations

import json
import logging
import os
import re
import time
from pathlib import Path

from .session import LLMExtractor

logger = logging.getLogger(__name__)

_PROMPTS_DIR = Path(__file__).parent / "prompts"
_SCHEMA_DIR = Path(__file__).parent / "schema"
_DEFAULT_AGENTS_DIR = Path(__file__).parent.parent / ".github" / "agents"


def _load_prompt(name: str) -> str:
    return (_PROMPTS_DIR / f"{name}.txt").read_text()


def _load_schema_text() -> str:
    return (_SCHEMA_DIR / "extracted_facts.schema.json").read_text()


# ---------------------------------------------------------------------------
# Agent loading
# ---------------------------------------------------------------------------

_FRONTMATTER_RE = re.compile(r"\A---\s*\n.*?\n---\s*\n", re.DOTALL)

_MAX_RETRY_ATTEMPTS = 5
_RETRY_BASE_DELAY = 5.0  # seconds; doubles on each attempt


def _is_rate_limit_error(exc: Exception) -> bool:
    """Return True if [exc] is an API rate-limit error from any supported backend.

    Uses class-name and message inspection rather than importing SDK-specific
    exception types so that cbl-elicit can support multiple backends (OpenAI,
    Anthropic, etc.) without hard-coupling to any one SDK version.
    """
    name = type(exc).__name__
    return "RateLimit" in name or "rate_limit" in str(exc).lower()


def _call_with_retry(fn) -> dict:
    """Call [fn()] with exponential backoff on rate-limit errors.

    Args:
        fn: Zero-argument callable that performs one LLM API call and returns a dict.

    Returns:
        The dict returned by [fn] on success.

    Raises:
        The last exception if all retry attempts are exhausted or if the error
        is not a rate-limit error.
    """
    for attempt in range(_MAX_RETRY_ATTEMPTS):
        try:
            return fn()
        except Exception as exc:
            if _is_rate_limit_error(exc) and attempt < _MAX_RETRY_ATTEMPTS - 1:
                delay = _RETRY_BASE_DELAY * (2**attempt)
                logger.warning(
                    "Rate limit encountered; retrying in %.0fs (attempt %d/%d)",
                    delay,
                    attempt + 1,
                    _MAX_RETRY_ATTEMPTS,
                )
                time.sleep(delay)
            else:
                raise
    raise RuntimeError(
        "_call_with_retry: exhausted all retry attempts"
    )  # defensive; unreachable


def _strip_frontmatter(text: str) -> str:
    """Remove YAML frontmatter from an .agent.md file."""
    return _FRONTMATTER_RE.sub("", text).strip()


def load_agent(name: str, agents_dir: Path | None = None) -> str:
    """Load an agent's instructions from its .agent.md file.

    Args:
        name: Agent name (e.g., 'domain-fdi', 'requirements-analyst').
        agents_dir: Directory containing .agent.md files.
                    Defaults to .github/agents/ in repo root.

    Returns:
        Agent instructions (markdown body, frontmatter stripped).
    """
    d = agents_dir or _DEFAULT_AGENTS_DIR
    path = d / f"{name}.agent.md"
    if not path.is_file():
        raise FileNotFoundError(f"Agent not found: {path}")
    text = path.read_text()
    body = _strip_frontmatter(text)
    logger.info("Loaded agent '%s' (%d chars)", name, len(body))
    return body


def _build_system_prompt(
    base_prompt: str,
    schema_text: str,
    agent_names: list[str] | None = None,
    agents_dir: Path | None = None,
) -> str:
    """Assemble the full system prompt: base + agents + schema."""
    parts = [base_prompt]

    if agent_names:
        for name in agent_names:
            body = load_agent(name, agents_dir)
            parts.append(f"\n\n## Agent: {name}\n\n{body}")

    parts.append("\n\nJSON Schema for reference:\n" + schema_text)
    return "".join(parts)


def _parse_json_response(text: str) -> dict:
    """Extract JSON from an LLM response, stripping markdown fences if present."""
    text = text.strip()
    # Strip markdown code fences
    if text.startswith("```"):
        # Remove opening fence (with optional language tag)
        first_newline = text.index("\n")
        text = text[first_newline + 1 :]
        # Remove closing fence
        if text.endswith("```"):
            text = text[:-3].rstrip()
    return json.loads(text)


def _format_diagnostics(diagnostics: list[dict]) -> str:
    lines = []
    for d in diagnostics:
        sev = d.get("severity", "info").upper()
        code = d.get("code", "?")
        msg = d.get("message", "")
        lines.append(f"[{sev}] {code}: {msg}")
    return "\n".join(lines) if lines else "(none)"


def _format_answers(answers: dict[str, str]) -> str:
    if not answers:
        return "(none)"
    lines = []
    for qid, ans in answers.items():
        lines.append(f"Q[{qid}]: {ans}")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# OpenAI-compatible extractor (works with openai SDK)
# ---------------------------------------------------------------------------


class OpenAIExtractor(LLMExtractor):
    """Layer 1 extractor using the OpenAI chat completions API.

    Supports any OpenAI-compatible endpoint (OpenAI, Azure, local).
    Set OPENAI_API_KEY in environment. Optionally set:
      - CBL_LLM_MODEL (default: gpt-4o)
      - CBL_LLM_TEMPERATURE (default: 0.0)
      - OPENAI_BASE_URL (for non-OpenAI endpoints)
    """

    def __init__(
        self,
        model: str | None = None,
        temperature: float | None = None,
        agents: list[str] | None = None,
        agents_dir: Path | None = None,
    ):
        import openai

        self._client = openai.OpenAI()
        self._model = model or os.environ.get("CBL_LLM_MODEL", "gpt-4o")
        self._temperature = (
            temperature
            if temperature is not None
            else float(os.environ.get("CBL_LLM_TEMPERATURE", "0.0"))
        )
        self._extract_template = _load_prompt("extract")
        self._revise_template = _load_prompt("revise")
        self._system_prompt = _build_system_prompt(
            _load_prompt("system"),
            _load_schema_text(),
            agent_names=agents,
            agents_dir=agents_dir,
        )

    def _call(self, user_message: str) -> dict:
        logger.info("Calling %s (temperature=%.1f)", self._model, self._temperature)

        def _do_call() -> dict:
            response = self._client.chat.completions.create(
                model=self._model,
                temperature=self._temperature,
                messages=[
                    {"role": "system", "content": self._system_prompt},
                    {"role": "user", "content": user_message},
                ],
                response_format={"type": "json_object"},
            )
            text = response.choices[0].message.content
            logger.debug("LLM response length: %d chars", len(text))
            return _parse_json_response(text)

        return _call_with_retry(_do_call)

    def extract(self, nl_text: str) -> dict:
        user_msg = self._extract_template.format(nl_text=nl_text)
        return self._call(user_msg)

    def revise(
        self,
        nl_text: str,
        diagnostics: list[dict],
        answers: dict[str, str],
        verdict: dict,
    ) -> dict:
        user_msg = self._revise_template.format(
            nl_text=nl_text,
            diagnostics=_format_diagnostics(diagnostics),
            answers=_format_answers(answers),
            verdict_status=verdict.get("status", "unknown"),
        )
        return self._call(user_msg)


# ---------------------------------------------------------------------------
# Anthropic extractor
# ---------------------------------------------------------------------------


class AnthropicExtractor(LLMExtractor):
    """Layer 1 extractor using the Anthropic messages API.

    Set ANTHROPIC_API_KEY in environment. Optionally set:
      - CBL_LLM_MODEL (default: claude-sonnet-4-20250514)
      - CBL_LLM_TEMPERATURE (default: 0.0)
    """

    def __init__(
        self,
        model: str | None = None,
        temperature: float | None = None,
        agents: list[str] | None = None,
        agents_dir: Path | None = None,
    ):
        import anthropic

        self._client = anthropic.Anthropic()
        self._model = model or os.environ.get(
            "CBL_LLM_MODEL", "claude-sonnet-4-20250514"
        )
        self._temperature = (
            temperature
            if temperature is not None
            else float(os.environ.get("CBL_LLM_TEMPERATURE", "0.0"))
        )
        self._extract_template = _load_prompt("extract")
        self._revise_template = _load_prompt("revise")
        self._system_prompt = _build_system_prompt(
            _load_prompt("system"),
            _load_schema_text(),
            agent_names=agents,
            agents_dir=agents_dir,
        )

    def _call(self, user_message: str) -> dict:
        logger.info("Calling %s (temperature=%.1f)", self._model, self._temperature)

        def _do_call() -> dict:
            response = self._client.messages.create(
                model=self._model,
                max_tokens=8192,
                temperature=self._temperature,
                system=self._system_prompt,
                messages=[{"role": "user", "content": user_message}],
            )
            text = response.content[0].text
            logger.debug("LLM response length: %d chars", len(text))
            return _parse_json_response(text)

        return _call_with_retry(_do_call)

    def extract(self, nl_text: str) -> dict:
        user_msg = self._extract_template.format(nl_text=nl_text)
        return self._call(user_msg)

    def revise(
        self,
        nl_text: str,
        diagnostics: list[dict],
        answers: dict[str, str],
        verdict: dict,
    ) -> dict:
        user_msg = self._revise_template.format(
            nl_text=nl_text,
            diagnostics=_format_diagnostics(diagnostics),
            answers=_format_answers(answers),
            verdict_status=verdict.get("status", "unknown"),
        )
        return self._call(user_msg)
