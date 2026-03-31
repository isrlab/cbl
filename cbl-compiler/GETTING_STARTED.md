# Getting Started with CBL Compiler (OCaml)

## Prerequisites

### Install OCaml and opam

**macOS (Homebrew)**:
```bash
brew install opam
opam init
eval $(opam env)
```

**Ubuntu/Debian**:
```bash
sudo apt install opam
opam init
eval $(opam env)
```

**General**: See https://ocaml.org/docs/install.html

### Set up OCaml 4.14+ (recommended)
```bash
opam switch create 4.14.1
eval $(opam env)
```

## Installation

### 1. Install Dependencies
```bash
cd cbl-compiler
opam install . --deps-only
```

This will install:
- `dune` (build system)
- `menhir` (parser generator)
- `yojson` (JSON library)
- `ppx_deriving` (code generation for show/yojson)

### 2. Build the Compiler
```bash
dune build
```

Or use the Makefile:
```bash
make build
```

The compiled binary will be at: `_build/default/bin/cblc.exe`

### 3. (Optional) Install System-Wide
```bash
dune install
```

Now `cblc` command will be in your PATH.

## Quick Start

### Check a Specification
```bash
./_build/default/bin/cblc.exe check examples/traffic_basic.cbl
```

Expected output:
```
✓ Specification is well-posed
```

### Compile to JSON IR
```bash
./_build/default/bin/cblc.exe compile examples/traffic_basic.cbl -o traffic.json
```

Expected output:
```
✓ Compiled examples/traffic_basic.cbl → traffic.json
```

### View the JSON IR
```bash
cat traffic.json | jq .  # requires jq for pretty-printing
```

## Development Workflow

### Auto-rebuild on Changes
```bash
make watch
```

or

```bash
dune build --watch
```

### Run Tests
```bash
make test
```

### Format Code
```bash
make fmt
```

## Project Structure

```
cbl-compiler/
├── bin/
│   ├── cblc.ml      # Main entry point
│   └── dune         # Executable build config
├── lib/
│   ├── ast.ml       # AST type definitions
│   ├── lexer.mll    # Lexer (ocamllex)
│   ├── parser.mly   # Parser (menhir)
│   ├── checker.ml   # Well-posedness checker
│   ├── json_emit.ml # JSON IR emission
│   └── dune         # Library build config
├── examples/
│   └── traffic_basic.cbl
├── dune-project     # Project metadata
├── Makefile         # Convenience targets
└── README.md        # This file
```

## Usage Examples

### Parse and Show AST
```bash
cblc parse examples/traffic_basic.cbl
```

### Check for Well-Posedness Errors
```bash
# This will fail if specification is not well-posed
cblc check bad_example.cbl
echo $?  # Non-zero exit code on error
```

### Pipeline Integration

**User/LLM writes spec.cbl** → **OCaml compiler** → **.json IR** → **MATLAB backend**

```bash
# Compile spec.cbl (assuming you have it ready)
cblc compile spec.cbl -o spec.json

# MATLAB reads JSON and builds Stateflow
matlab -batch "build_from_json('spec.json')"
```

## Troubleshooting

### "command not found: cblc"
- Make sure `_build/default/bin/cblc.exe` exists
- Or use full path: `./_build/default/bin/cblc.exe`
- Or run `dune install` to install system-wide

### "cannot find package..."
- Run `opam install . --deps-only` again
- Check `opam list` to see installed packages

### Parse errors
- Check CBL syntax against `../CBL/cbl_language.md`
- Use `cblc parse` to see where parsing fails
- Enable debug output: `OCAMLRUNPARAM=b cblc parse file.cbl`

### Build errors after changes
```bash
dune clean
dune build
```

## Next Steps

1. **Read the paper**: `../docs/cbl_overview.tex`
2. **Study examples**: `../CBL/prototype/examples/*.cbl`
3. **Language reference**: `../CBL/cbl_language.md`
4. **Compiler spec**: `../CBL/cbl_compiler.md`
5. **Implementation notes**: `IMPLEMENTATION.md`

## Contributing

See `IMPLEMENTATION.md` for architecture details and TODO items.
