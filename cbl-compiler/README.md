# CBL Compiler (OCaml Implementation)

## Overview

OCaml implementation of the CBL (Controlled Behavioral Language) compiler.

**Architecture**:
- **Frontend**: Python or user-written `.cbl` (LLM elicitation is decoupled)
- **Compiler** (this project): OCaml (parse, check, lower) → writes `.json` IR
- **Backend**: MATLAB (Stateflow API) or SCADE → reads `.json`, generates models

## Build

```bash
# Install OCaml and opam first (see https://ocaml.org/docs/install.html)

# Install dependencies
opam install . --deps-only

# Build
dune build

# Run tests
dune test

# Install (optional)
dune install
```

## Usage

```bash
# Check a CBL specification
./_build/default/bin/cblc.exe check examples/traffic_basic.cbl

# Compile to JSON IR
./_build/default/bin/cblc.exe compile examples/traffic_basic.cbl -o traffic.json

# Type check only
./_build/default/bin/cblc.exe typecheck examples/traffic_basic.cbl
```

## Project Structure

```
cbl-compiler/
├── bin/
│   └── cblc.ml          # Main entry point
├── lib/
│   ├── ast.ml           # AST type definitions
│   ├── lexer.mll        # Lexer (ocamllex)
│   ├── parser.mly       # Parser (menhir)
│   ├── checker.ml       # Well-posedness checker
│   ├── json_emit.ml     # JSON IR emission
│   ├── nlp_bridge.ml    # JSON verdict ingestion + provenance gate
│   └── z3_guard_checker.ml  # SMT guard verification
├── test/
│   └── test_basic.ml    # Unit tests
└── examples/
    └── traffic_basic.cbl  # Example specifications
```

## References

- Architecture: `../ARCHITECTURE.md`
- CBL overview paper: `../docs/cbl_overview.tex`
- Implementation notes: `IMPLEMENTATION.md`
