# vscode-cbl

VS Code language support for CBL (Controlled Behavioral Language).

## Features

- Syntax highlighting for `.cbl` files (sections, modes, rule keywords, guards, actions, types, enums).
- Diagnostics from `cblc check` on save (parse errors, totality violations, guard completeness, etc.).
- Configurable `cblc` path.

## Settings

- `cbl.cblcPath` — path to the `cblc` executable. Default: `cblc` on PATH.
- `cbl.checkOnSave` — run `cblc check` on save. Default: `true`.

For local development, point `cbl.cblcPath` at the dune build artifact:

```
.../cbl-research/cbl-compiler/_build/default/bin/cblc.exe
```

## Run from source

1. Open this folder (`vscode-cbl/`) in VS Code.
2. Press `F5` to launch the Extension Development Host.
3. In the new window, open a `.cbl` file (e.g. `examples/traffic_light.cbl`).

No build step is required — the extension is plain JavaScript with no dependencies.

## Package as `.vsix`

```
npm install -g @vscode/vsce
vsce package
```

## Status

Level 1 (syntax) + Level 2 (diagnostics on save). LSP and full pipeline
integration are planned (see `cbl-planning/`).
