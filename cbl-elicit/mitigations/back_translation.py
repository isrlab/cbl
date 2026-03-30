"""Gap 1 mitigation: Back-translation gate.

After the pipeline produces a .cbl specification, a separate LLM pass renders
it back to plain English. The engineer sees original requirements side-by-side
with the back-translated specification. Discrepancies surface hallucinated or
missing facts.

This module provides:
  1. A deterministic CBL-to-English renderer (no LLM, structural only).
  2. An LLM-based back-translator interface (pluggable, like LLMExtractor).
  3. A comparison report generator.
"""

from __future__ import annotations

from dataclasses import dataclass


# ---------------------------------------------------------------------------
# Comparison report
# ---------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class BackTranslationReport:
    """Result of comparing original requirements with back-translated spec."""

    original_text: str
    back_translated_text: str
    structural_summary: str  # deterministic CBL → English rendering
    discrepancies: list[str]  # identified mismatches
    coverage_notes: list[str]  # requirements not reflected in spec


# ---------------------------------------------------------------------------
# Deterministic CBL → English renderer (no LLM needed)
# ---------------------------------------------------------------------------


def render_cbl_to_english(cbl_text: str) -> str:
    """Render a CBL specification into structured English prose.

    This is a deterministic, template-based renderer. It does not use an LLM.
    The output is suitable for engineer review: each CBL construct is
    translated to a plain-English sentence.

    Args:
        cbl_text: The .cbl specification text.

    Returns:
        Structured English rendering of the specification.
    """
    lines = cbl_text.strip().split("\n")
    sections: list[str] = []
    current_section = ""
    current_content: list[str] = []

    for line in lines:
        stripped = line.strip()

        # Section headers
        if stripped.startswith("System"):
            system_name = stripped.replace("System", "").strip()
            sections.append(
                f"This specification defines a system called '{system_name}'."
            )
            continue

        if stripped.startswith("Assumes"):
            if current_content:
                sections.append(_render_section(current_section, current_content))
                current_content = []
            current_section = "assumes"
            continue

        if stripped.startswith("Definitions"):
            if current_content:
                sections.append(_render_section(current_section, current_content))
                current_content = []
            current_section = "definitions"
            continue

        if stripped.startswith("Constants"):
            if current_content:
                sections.append(_render_section(current_section, current_content))
                current_content = []
            current_section = "constants"
            continue

        if stripped.startswith("Guarantees"):
            if current_content:
                sections.append(_render_section(current_section, current_content))
                current_content = []
            current_section = "guarantees"
            continue

        if stripped.startswith("Variables"):
            if current_content:
                sections.append(_render_section(current_section, current_content))
                current_content = []
            current_section = "variables"
            continue

        if stripped.startswith("Always"):
            if current_content:
                sections.append(_render_section(current_section, current_content))
                current_content = []
            current_section = "always"
            continue

        if stripped.startswith("Initially in"):
            mode_name = stripped.replace("Initially in", "").strip()
            sections.append(f"The system starts in mode '{mode_name}'.")
            continue

        if stripped.startswith("Mode"):
            if current_content:
                sections.append(_render_section(current_section, current_content))
                current_content = []
            current_section = (
                f"mode:{stripped.split()[1] if len(stripped.split()) > 1 else '?'}"
            )
            continue

        if stripped:
            current_content.append(stripped)

    if current_content:
        sections.append(_render_section(current_section, current_content))

    return "\n\n".join(sections)


def _render_section(section: str, content: list[str]) -> str:
    """Render a section's content as English prose."""
    if section == "assumes":
        rendered = ["The system assumes the following inputs:"]
        for line in content:
            rendered.append(f"  - {_render_assume(line)}")
        return "\n".join(rendered)

    if section == "guarantees":
        rendered = ["The system guarantees the following outputs:"]
        for line in content:
            rendered.append(f"  - {_render_guarantee(line)}")
        return "\n".join(rendered)

    if section == "constants":
        rendered = ["The system defines the following constants:"]
        for line in content:
            rendered.append(f"  - {_render_constant(line)}")
        return "\n".join(rendered)

    if section == "variables":
        rendered = ["The system uses the following internal variables:"]
        for line in content:
            rendered.append(f"  - {_render_variable(line)}")
        return "\n".join(rendered)

    if section == "definitions":
        rendered = ["The system defines the following conditions:"]
        for line in content:
            rendered.append(f"  - {line}")
        return "\n".join(rendered)

    if section == "always":
        rendered = ["The following must always hold:"]
        for line in content:
            rendered.append(f"  - {line}")
        return "\n".join(rendered)

    if section.startswith("mode:"):
        mode_name = section.split(":", 1)[1]
        return _render_mode(mode_name, content)

    return "\n".join(content)


def _render_assume(line: str) -> str:
    """Render an assume declaration as English."""
    # "sensor1 : real[0.0, 100.0]" → "Input 'sensor1' is a real number between 0.0 and 100.0"
    if ":" in line:
        name, type_part = line.split(":", 1)
        name = name.strip()
        type_part = type_part.strip()
        return f"Input '{name}' has type {_render_type(type_part)}"
    return f"Input: {line}"


def _render_guarantee(line: str) -> str:
    """Render a guarantee declaration as English."""
    if ":" in line:
        parts = line.split(":", 1)
        name = parts[0].strip()
        rest = parts[1].strip()
        return f"Output '{name}' has type {_render_type(rest)}"
    return f"Output: {line}"


def _render_constant(line: str) -> str:
    """Render a constant declaration as English."""
    if ":" in line and "=" in line:
        parts = line.split(":")
        name = parts[0].strip()
        rest = ":".join(parts[1:])
        if "=" in rest:
            type_part, val_part = rest.split("=", 1)
            return f"Constant '{name}' is {_render_type(type_part.strip())} with value {val_part.strip()}"
    return f"Constant: {line}"


def _render_variable(line: str) -> str:
    """Render a variable declaration as English."""
    if ":" in line:
        parts = line.split(":", 1)
        name = parts[0].strip()
        type_part = parts[1].strip()
        return f"Variable '{name}' has type {_render_type(type_part)}"
    return f"Variable: {line}"


def _render_type(type_str: str) -> str:
    """Render a type annotation as English."""
    ts = type_str.strip()
    if ts.startswith("boolean"):
        return "boolean (true/false)"
    if ts.startswith("integer"):
        if "[" in ts:
            return f"an integer in the range {ts[ts.index('['):]}"
        return "an integer"
    if ts.startswith("real"):
        if "[" in ts:
            return f"a real number in the range {ts[ts.index('['):]}"
        return "a real number"
    if ts.startswith("{") and ts.endswith("}"):
        values = ts[1:-1].split(",")
        values = [v.strip() for v in values]
        return f"one of {{{', '.join(values)}}}"
    return ts


def _render_mode(mode_name: str, content: list[str]) -> str:
    """Render a mode block as English."""
    rendered = [f"In mode '{mode_name}':"]
    in_rule = False
    rule_num = 0

    for line in content:
        if line.startswith("When") or line.startswith("If"):
            in_rule = True
            rule_num += 1
            rendered.append(f"  Rule {rule_num}: {line}")
        elif line.startswith("Otherwise"):
            rendered.append(f"  Default: {line}")
        elif line.startswith("set ") or line.startswith("hold "):
            rendered.append(f"    Then {line}")
        elif line.startswith("transition to") or line.startswith("remain"):
            rendered.append(f"    And {line}")
        elif line.startswith("on entry"):
            rendered.append(f"  On entering this mode: {line}")
        else:
            rendered.append(f"  {line}")

    return "\n".join(rendered)


# ---------------------------------------------------------------------------
# LLM-based back-translator (pluggable interface)
# ---------------------------------------------------------------------------


class BackTranslator:
    """Interface for LLM-based back-translation.

    Subclass and override back_translate() for your LLM backend.
    The default implementation uses the deterministic renderer only.
    """

    def back_translate(self, cbl_text: str) -> str:
        """Translate a CBL specification back to natural language.

        Override this to use an LLM for richer back-translation.
        The default returns the deterministic structural rendering.
        """
        return render_cbl_to_english(cbl_text)


# ---------------------------------------------------------------------------
# Comparison: original ↔ back-translated
# ---------------------------------------------------------------------------


def compare_requirements(
    original_nl: str,
    cbl_text: str,
    back_translator: BackTranslator | None = None,
) -> BackTranslationReport:
    """Compare original requirements with the back-translated specification.

    Produces a report identifying:
    - Structural summary (deterministic CBL → English)
    - Discrepancies between original and back-translated text
    - Requirements not reflected in the specification

    Args:
        original_nl: The original natural-language requirements.
        cbl_text: The generated .cbl specification text.
        back_translator: Optional LLM-based back-translator.

    Returns:
        BackTranslationReport with comparison results.
    """
    if back_translator is None:
        back_translator = BackTranslator()

    structural_summary = render_cbl_to_english(cbl_text)
    back_translated = back_translator.back_translate(cbl_text)

    discrepancies = _find_discrepancies(original_nl, structural_summary)
    coverage = _check_requirement_coverage(original_nl, structural_summary)

    return BackTranslationReport(
        original_text=original_nl,
        back_translated_text=back_translated,
        structural_summary=structural_summary,
        discrepancies=discrepancies,
        coverage_notes=coverage,
    )


def _find_discrepancies(original: str, rendered: str) -> list[str]:
    """Find potential discrepancies between original requirements and rendered spec.

    Uses keyword matching to identify concepts in the original that do not
    appear in the rendered specification. This is a conservative heuristic;
    it may flag false positives but should not miss real gaps.
    """
    import re

    discrepancies: list[str] = []

    # Extract significant words from original (nouns, adjectives, verbs)
    # Skip common stop words
    stop_words = {
        "the",
        "a",
        "an",
        "is",
        "are",
        "was",
        "were",
        "be",
        "been",
        "being",
        "have",
        "has",
        "had",
        "do",
        "does",
        "did",
        "will",
        "would",
        "shall",
        "should",
        "may",
        "might",
        "can",
        "could",
        "must",
        "need",
        "to",
        "of",
        "in",
        "for",
        "on",
        "with",
        "at",
        "by",
        "from",
        "as",
        "into",
        "through",
        "during",
        "before",
        "after",
        "above",
        "below",
        "between",
        "and",
        "but",
        "or",
        "not",
        "no",
        "nor",
        "if",
        "then",
        "else",
        "when",
        "where",
        "how",
        "all",
        "each",
        "every",
        "both",
        "few",
        "more",
        "most",
        "other",
        "some",
        "such",
        "than",
        "too",
        "very",
        "just",
        "also",
        "it",
        "its",
        "this",
        "that",
        "these",
        "those",
        "i",
        "we",
        "you",
        "he",
        "she",
        "they",
        "them",
        "their",
        "our",
        "your",
        "my",
    }

    orig_words = set(re.findall(r"\b\w+\b", original.lower())) - stop_words
    rendered_words = set(re.findall(r"\b\w+\b", rendered.lower())) - stop_words

    # Words in original but not in rendered may indicate missing concepts
    missing = orig_words - rendered_words
    # Filter to significant words (length > 3 to skip noise)
    significant_missing = {w for w in missing if len(w) > 3}

    if significant_missing:
        discrepancies.append(
            f"Concepts in requirements not found in specification: "
            f"{', '.join(sorted(significant_missing)[:10])}"
        )

    return discrepancies


def _check_requirement_coverage(original: str, rendered: str) -> list[str]:
    """Check which requirement sentences have coverage in the specification.

    Splits original into sentences and checks if key terms from each
    sentence appear in the rendered specification.
    """
    import re

    notes: list[str] = []
    # Split into sentences (rough heuristic)
    sentences = re.split(r"[.!?]+", original)
    rendered_lower = rendered.lower()

    for i, sent in enumerate(sentences, 1):
        sent = sent.strip()
        if len(sent) < 10:
            continue  # skip trivially short fragments

        # Extract significant words from this sentence
        words = set(re.findall(r"\b\w{4,}\b", sent.lower()))
        if not words:
            continue

        # Check how many appear in the rendered spec
        found = sum(1 for w in words if w in rendered_lower)
        coverage = found / len(words) if words else 0

        if coverage < 0.3:
            notes.append(
                f"Requirement sentence {i} may not be covered: "
                f"'{sent[:80]}{'...' if len(sent) > 80 else ''}'"
            )

    return notes
