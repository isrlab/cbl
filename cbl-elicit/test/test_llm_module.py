"""Unit tests for llm.py: prompt loading, JSON parsing, formatting helpers."""

import importlib.util
import json
import sys
from pathlib import Path

import pytest

# ---------------------------------------------------------------------------
# Bootstrap: import llm.py with a mock LLMExtractor base class
# ---------------------------------------------------------------------------
_ELICIT_ROOT = Path(__file__).resolve().parent.parent

# We need session.py loaded first so that llm.py can do 'from .session import LLMExtractor'
# Instead, we patch sys.modules so the relative import resolves.
# Create a minimal fake package.
_pkg_name = "cbl_elicit"
if _pkg_name not in sys.modules:
    import types

    pkg = types.ModuleType(_pkg_name)
    pkg.__path__ = [str(_ELICIT_ROOT)]
    pkg.__file__ = str(_ELICIT_ROOT / "__init__.py")
    sys.modules[_pkg_name] = pkg

# Load session so that the relative import in llm.py can find LLMExtractor
_session_spec = importlib.util.spec_from_file_location(
    f"{_pkg_name}.session",
    _ELICIT_ROOT / "session.py",
)
_session_mod = importlib.util.module_from_spec(_session_spec)
sys.modules[f"{_pkg_name}.session"] = _session_mod
_session_spec.loader.exec_module(_session_mod)

# Now load llm.py
_llm_spec = importlib.util.spec_from_file_location(
    f"{_pkg_name}.llm",
    _ELICIT_ROOT / "llm.py",
)
_llm_mod = importlib.util.module_from_spec(_llm_spec)
sys.modules[f"{_pkg_name}.llm"] = _llm_mod
_llm_spec.loader.exec_module(_llm_mod)

_load_prompt = _llm_mod._load_prompt
_load_schema_text = _llm_mod._load_schema_text
_parse_json_response = _llm_mod._parse_json_response
_format_diagnostics = _llm_mod._format_diagnostics
_format_answers = _llm_mod._format_answers
_strip_frontmatter = _llm_mod._strip_frontmatter
_build_system_prompt = _llm_mod._build_system_prompt
load_agent = _llm_mod.load_agent
OpenAIExtractor = _llm_mod.OpenAIExtractor
AnthropicExtractor = _llm_mod.AnthropicExtractor
LLMExtractor = _session_mod.LLMExtractor

_AGENTS_DIR = _ELICIT_ROOT.parent / ".github" / "agents"


# ---------------------------------------------------------------------------
# Prompt loading
# ---------------------------------------------------------------------------


class TestPromptLoading:
    def test_system_prompt_loads(self):
        p = _load_prompt("system")
        assert len(p) > 100

    def test_extract_prompt_has_placeholder(self):
        p = _load_prompt("extract")
        assert "{nl_text}" in p

    def test_revise_prompt_has_placeholders(self):
        p = _load_prompt("revise")
        assert "{nl_text}" in p
        assert "{diagnostics}" in p
        assert "{answers}" in p
        assert "{verdict_status}" in p

    def test_schema_loads(self):
        s = _load_schema_text()
        assert "schema_version" in s


# ---------------------------------------------------------------------------
# JSON parsing
# ---------------------------------------------------------------------------


class TestJsonParsing:
    def test_plain_json(self):
        assert _parse_json_response('{"a": 1}') == {"a": 1}

    def test_strips_whitespace(self):
        assert _parse_json_response('  \n{"c": 3}\n  ') == {"c": 3}

    def test_strips_markdown_fences(self):
        text = '```json\n{"b": 2}\n```'
        assert _parse_json_response(text) == {"b": 2}

    def test_strips_fences_no_lang_tag(self):
        text = '```\n{"d": 4}\n```'
        assert _parse_json_response(text) == {"d": 4}

    def test_invalid_json_raises(self):
        with pytest.raises(json.JSONDecodeError):
            _parse_json_response("not json")


# ---------------------------------------------------------------------------
# Formatting helpers
# ---------------------------------------------------------------------------


class TestFormatting:
    def test_format_diagnostics(self):
        diags = [{"severity": "error", "code": "R1", "message": "missing state"}]
        result = _format_diagnostics(diags)
        assert "[ERROR] R1: missing state" == result

    def test_format_diagnostics_empty(self):
        assert _format_diagnostics([]) == "(none)"

    def test_format_answers_empty(self):
        assert _format_answers({}) == "(none)"

    def test_format_answers_populated(self):
        result = _format_answers({"q1": "yes", "q2": "42"})
        assert "Q[q1]: yes" in result
        assert "Q[q2]: 42" in result


# ---------------------------------------------------------------------------
# Class hierarchy
# ---------------------------------------------------------------------------


class TestClassHierarchy:
    def test_openai_is_llm_extractor(self):
        assert issubclass(OpenAIExtractor, LLMExtractor)

    def test_anthropic_is_llm_extractor(self):
        assert issubclass(AnthropicExtractor, LLMExtractor)


# ---------------------------------------------------------------------------
# Agent loading
# ---------------------------------------------------------------------------


class TestAgentLoading:
    def test_strip_frontmatter(self):
        text = "---\ndescription: foo\ntools: [read]\n---\nBody content"
        assert _strip_frontmatter(text) == "Body content"

    def test_strip_frontmatter_no_frontmatter(self):
        text = "Just body content"
        assert _strip_frontmatter(text) == "Just body content"

    def test_load_agent_domain_fdi(self):
        body = load_agent("domain-fdi", _AGENTS_DIR)
        assert "FDI" in body or "fault" in body.lower()
        # Frontmatter should be stripped
        assert not body.startswith("---")

    def test_load_agent_requirements_analyst(self):
        body = load_agent("requirements-analyst", _AGENTS_DIR)
        assert "requirements" in body.lower()
        assert not body.startswith("---")

    def test_load_agent_not_found(self):
        with pytest.raises(FileNotFoundError):
            load_agent("nonexistent-agent", _AGENTS_DIR)

    def test_build_system_prompt_no_agents(self):
        prompt = _build_system_prompt("base", "schema")
        assert prompt.startswith("base")
        assert "schema" in prompt
        assert "Agent:" not in prompt

    def test_build_system_prompt_with_agents(self):
        prompt = _build_system_prompt(
            "base",
            "schema",
            agent_names=["domain-fdi"],
            agents_dir=_AGENTS_DIR,
        )
        assert "base" in prompt
        assert "## Agent: domain-fdi" in prompt
        assert "schema" in prompt

    def test_build_system_prompt_multiple_agents(self):
        prompt = _build_system_prompt(
            "base",
            "schema",
            agent_names=["domain-fdi", "requirements-analyst"],
            agents_dir=_AGENTS_DIR,
        )
        assert "## Agent: domain-fdi" in prompt
        assert "## Agent: requirements-analyst" in prompt
