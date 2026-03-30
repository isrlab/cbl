"""CBL elicitation CLI entry point.

Usage:
    python -m cbl_elicit --input requirements.txt --output spec.cbl
    python -m cbl_elicit --facts extracted_facts.json --output spec.cbl
"""

from __future__ import annotations

import argparse
import logging
import sys
from pathlib import Path

from .config import load_config
from .session import (
    BatchEngineerInterface,
    EngineerInterface,
    Session,
    StubExtractor,
)


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="cbl_elicit",
        description="CBL elicitation: NL requirements → verified spec.cbl",
    )
    parser.add_argument(
        "--input",
        type=Path,
        help="Natural-language requirements file",
    )
    parser.add_argument(
        "--facts",
        type=Path,
        help="Pre-made extracted_facts.json (skip LLM, test Prolog+OCaml)",
    )
    parser.add_argument(
        "--output",
        "-o",
        type=Path,
        required=True,
        help="Output path for spec.cbl",
    )
    parser.add_argument(
        "--max-iterations",
        type=int,
        default=None,
        help="Maximum elicitation iterations (default: 10)",
    )
    parser.add_argument(
        "--batch",
        action="store_true",
        help="Non-interactive: auto-accept repairs, skip questions",
    )
    parser.add_argument(
        "--swipl",
        default=None,
        help="Path to SWI-Prolog executable",
    )
    parser.add_argument(
        "--cblc",
        default=None,
        help="Path to cblc executable",
    )
    parser.add_argument(
        "--work-dir",
        type=Path,
        default=None,
        help="Working directory for intermediate files",
    )
    parser.add_argument(
        "--verbose",
        "-v",
        action="store_true",
        help="Enable debug logging",
    )
    parser.add_argument(
        "--provider",
        choices=["openai", "anthropic"],
        default="openai",
        help="LLM provider for --input mode (default: openai)",
    )
    parser.add_argument(
        "--agents",
        type=str,
        default=None,
        help="Comma-separated agent names to inject into LLM prompts "
        "(e.g., domain-fdi,requirements-analyst). "
        "Default: from cbl.toml [agents] or none.",
    )
    parser.add_argument(
        "--agents-dir",
        type=Path,
        default=None,
        help="Directory containing .agent.md files (default: .github/agents/)",
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=None,
        help="Path to cbl.toml config file (default: ./cbl.toml)",
    )
    args = parser.parse_args()

    # Load config file, then let CLI args override
    cfg = load_config(args.config)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s: %(message)s",
    )

    if not args.input and not args.facts:
        parser.error("Provide --input (NL text) or --facts (extracted_facts.json)")

    # Build extractor
    if args.facts:
        if not args.facts.exists():
            print(f"Error: {args.facts} not found", file=sys.stderr)
            return 1
        extractor = StubExtractor(args.facts)
        nl_text = ""
    else:
        if not args.input.exists():
            print(f"Error: {args.input} not found", file=sys.stderr)
            return 1
        nl_text = args.input.read_text()
        # Resolve agent list: CLI --agents overrides cbl.toml [agents]
        agent_names = None
        if args.agents:
            agent_names = [a.strip() for a in args.agents.split(",") if a.strip()]
        elif cfg.agents:
            agent_names = cfg.agents
        agents_dir = args.agents_dir

        # LLM extractor: try to import from llm module
        try:
            if args.provider == "anthropic":
                from .llm import AnthropicExtractor

                extractor = AnthropicExtractor(
                    agents=agent_names, agents_dir=agents_dir
                )
            else:
                from .llm import OpenAIExtractor

                extractor = OpenAIExtractor(agents=agent_names, agents_dir=agents_dir)
        except ModuleNotFoundError as e:
            if "openai" in str(e) or "anthropic" in str(e):
                print(
                    "Error: LLM extraction requires the openai or anthropic package.\n"
                    "Install with: pip install openai\n"
                    "Or use --facts to skip LLM and provide extracted_facts.json directly.",
                    file=sys.stderr,
                )
            else:
                print(f"Error: Could not import LLM module: {e}", file=sys.stderr)
            return 1
        except ImportError as e:
            print(f"Error: LLM import failed: {e}", file=sys.stderr)
            return 1

    # Build engineer interface
    engineer = BatchEngineerInterface() if args.batch else EngineerInterface()

    # Run session — CLI args override config file values
    max_iter = (
        args.max_iterations
        if args.max_iterations is not None
        else cfg.session.max_iterations
    )
    swipl = args.swipl if args.swipl is not None else cfg.tools.swipl
    cblc = args.cblc if args.cblc is not None else cfg.tools.cblc

    session = Session(
        extractor,
        engineer=engineer,
        max_iterations=max_iter,
        schema_retries=cfg.session.schema_retries,
        stall_threshold=cfg.session.stall_threshold,
        swipl=swipl,
        cblc=cblc,
        work_dir=args.work_dir,
        enable_back_translation=cfg.mitigations.back_translation,
        enable_traceability=cfg.mitigations.traceability,
        enable_dual_extraction=cfg.mitigations.dual_extraction,
    )

    result = session.run(nl_text, args.output)

    if result.success:
        print(f"✓ {result.output_path} ({result.iterations} iteration(s))")
        return 0
    else:
        print(f"✗ {result.reason}", file=sys.stderr)
        if result.final_diagnostics:
            print(
                f"  {len(result.final_diagnostics)} unresolved diagnostic(s)",
                file=sys.stderr,
            )
        if result.unresolved_questions:
            print(
                f"  {len(result.unresolved_questions)} unanswered question(s)",
                file=sys.stderr,
            )
        return 1


if __name__ == "__main__":
    sys.exit(main())
