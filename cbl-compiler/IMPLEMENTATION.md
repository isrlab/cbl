# CBL Compiler Implementation Notes

## Architecture

The compiler is structured in classic phases:

```
.cbl file → Lexer → Parser → AST → Checker → Lowering → JSON IR
```

### 1. Lexer (`lexer.mll`)
- Tokenizes CBL keywords, identifiers, literals
- Handles comments (// and /* */)
- Recognizes special characters (∞ for infinity)

### 2. Parser (`parser.mly`)
- Menhir LR parser
- Builds AST from token stream
- Handles operator precedence
- Error recovery with position information

### 3. AST (`ast.ml`)
- Strongly-typed algebraic data types
- Represents complete CBL specification
- Derives JSON serialization with `ppx_deriving_yojson`
- Structural pattern matching ensures exhaustiveness

### 4. Checker (`checker.ml`)
- **Name resolution**: Build symbol table, check undeclared identifiers
- **Type checking**: Infer and check expression types
- **Well-posedness**:
  - Guard exclusivity (no overlapping guards)
  - Guard completeness (at least one guard fires)
  - Action totality (all guarantees assigned)
  - Valid transitions (targets exist)
- **Duplicate detection**: No name collisions

### 5. JSON Emission (`json_emit.ml`)
- Serialize checked AST to JSON
- MATLAB/SCADE backends read this IR
- Pretty-printed for readability

## Why OCaml?

1. **Type Safety**: Algebraic data types prevent entire bug classes
2. **Pattern Matching**: Exhaustiveness checking catches missing cases at compile time
3. **Mature Tools**: Menhir (parser), ocamllex (lexer), dune (build)
4. **Certification Path**: CompCert lineage, used in safety-critical tools
5. **Clean Integration**: Text-based I/O, no FFI complexity

## TODO for Production

### Parser Enhancements
- [ ] Better error messages with context
- [ ] Error recovery for interactive use
- [ ] Support for Unicode range notation (∞)
- [ ] Comments in AST for documentation preservation

### Checker Completions
- [ ] **Guard overlap detection**: Full SMT-based checking
  - Current: Placeholder only
  - Needed: Z3 integration for satisfiability
- [ ] **Guard completeness**: Prove Boolean cover
  - Current: Only checks for Otherwise clause
  - Needed: Proof that explicit guards cover all inputs
- [ ] **Invariant verification**: Check Always conditions
- [ ] **Reachability analysis**: Detect dead modes
- [ ] **Liveness properties**: Ensure no deadlocks

### Type System
- [ ] Bounded type constraint propagation
- [ ] Subtype checking for integer widening
- [ ] Enum membership validation

### Lowering Passes
- [ ] **Timing predicate expansion**: Synthesize counters
- [ ] **Definition inlining**: Replace names with bodies
- [ ] **Constant substitution**: Replace with literals
- [ ] **Default action expansion**: Insert hold/reset

### Optimizations
- [ ] Dead code elimination
- [ ] Constant folding
- [ ] Guard simplification

### Testing
- [ ] Property-based testing with QuickCheck
- [ ] Round-trip parse/pretty-print
- [ ] Corpus of well-/ill-posed specs
- [ ] Regression suite

### Integration
- [ ] VS Code extension (syntax highlighting, diagnostics)
- [ ] Language server protocol (LSP) support
- [ ] Python API for LLM orchestration (optional; not in core compiler)

## Note on Python Prototype

An earlier Python prototype (Lark parser, Python checker) is no longer maintained. All active development uses the OCaml compiler.

## Comparison to Python Prototype

| Aspect | Python (archived) | OCaml |
|--------|--------|-------|
| Type safety | Runtime | Compile-time |
| Pattern matching | Incomplete | Exhaustive |
| Error handling | Exceptions | Result types |
| Parser | Lark (PEG) | Menhir (LR) |
| AST manipulation | Dicts/classes | ADTs |
| Testing | pytest | OUnit/QCheck |
| Build | pip/poetry | dune/opam |
| Deployment | Python required | Native binary |

## Build Instructions

```bash
# First time setup
opam install . --deps-only

# Build
dune build

# Run tests
dune test

# Install binary
dune install

# Development
make watch  # Auto-rebuild on changes
```

## Example Usage

```bash
# Check specification
cblc check examples/traffic_basic.cbl

# Compile to JSON
cblc compile examples/traffic_basic.cbl -o output.json

# Parse and show AST
cblc parse examples/traffic_basic.cbl
```

## References

- Menhir manual: http://gallium.inria.fr/~fpottier/menhir/
- Dune documentation: https://dune.readthedocs.io/
- Architecture: `../ARCHITECTURE.md`
- CBL overview paper: `../docs/cbl_overview.tex`
