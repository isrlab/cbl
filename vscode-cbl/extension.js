const vscode = require("vscode");
const { execFile } = require("child_process");
const path = require("path");

let diagnostics;

function activate(context) {
  diagnostics = vscode.languages.createDiagnosticCollection("cbl");
  context.subscriptions.push(diagnostics);

  context.subscriptions.push(
    vscode.workspace.onDidSaveTextDocument((doc) => {
      if (doc.languageId === "cbl" && getConfig().checkOnSave) {
        runCheck(doc);
      }
    }),
    vscode.workspace.onDidOpenTextDocument((doc) => {
      if (doc.languageId === "cbl") runCheck(doc);
    }),
    vscode.workspace.onDidCloseTextDocument((doc) => {
      diagnostics.delete(doc.uri);
    })
  );

  vscode.workspace.textDocuments.forEach((doc) => {
    if (doc.languageId === "cbl") runCheck(doc);
  });
}

function deactivate() {
  if (diagnostics) diagnostics.dispose();
}

function getConfig() {
  const cfg = vscode.workspace.getConfiguration("cbl");
  return {
    cblcPath: cfg.get("cblcPath", "cblc"),
    checkOnSave: cfg.get("checkOnSave", true),
  };
}

function runCheck(doc) {
  const { cblcPath } = getConfig();
  const file = doc.uri.fsPath;
  const cwd = path.dirname(file);

  execFile(cblcPath, ["check", file], { cwd }, (err, stdout, stderr) => {
    const combined = (stdout || "") + "\n" + (stderr || "");

    if (err && err.code === "ENOENT") {
      diagnostics.set(doc.uri, [
        new vscode.Diagnostic(
          new vscode.Range(0, 0, 0, 0),
          `cblc not found at '${cblcPath}'. Set cbl.cblcPath in settings.`,
          vscode.DiagnosticSeverity.Warning
        ),
      ]);
      return;
    }

    diagnostics.set(doc.uri, parseDiagnostics(combined, doc));
  });
}

function parseDiagnostics(output, doc) {
  const result = [];
  const lines = output.split(/\r?\n/);

  const parseRe = /^Error:\s+Parse error at line (\d+), column (\d+)/;
  const lexRe = /^Error:\s+Lexical error:\s*(.*)$/;
  const modeRe = /\bmode\s+'?([A-Za-z_][A-Za-z0-9_]*)'?/i;

  let block = null; // "errors" | "warnings" | null

  for (const line of lines) {
    const parseMatch = line.match(parseRe);
    if (parseMatch) {
      const ln = Math.max(0, parseInt(parseMatch[1], 10) - 1);
      const col = Math.max(0, parseInt(parseMatch[2], 10) - 1);
      result.push(
        new vscode.Diagnostic(
          rangeAt(doc, ln, col),
          line.replace(/^Error:\s*/, ""),
          vscode.DiagnosticSeverity.Error
        )
      );
      continue;
    }

    const lexMatch = line.match(lexRe);
    if (lexMatch) {
      result.push(
        new vscode.Diagnostic(
          rangeAt(doc, 0, 0),
          `Lexical error: ${lexMatch[1]}`,
          vscode.DiagnosticSeverity.Error
        )
      );
      continue;
    }

    if (/^Errors:\s*$/.test(line)) { block = "errors"; continue; }
    if (/^Warnings:\s*$/.test(line)) { block = "warnings"; continue; }

    if (block && /^\s{2}\S/.test(line)) {
      const msg = line.trim();
      const sev =
        block === "errors"
          ? vscode.DiagnosticSeverity.Error
          : vscode.DiagnosticSeverity.Warning;
      const modeMatch = msg.match(modeRe);
      const range = modeMatch
        ? locateMode(doc, modeMatch[1]) || rangeAt(doc, 0, 0)
        : rangeAt(doc, 0, 0);
      result.push(new vscode.Diagnostic(range, msg, sev));
      continue;
    }

    if (line.trim() === "") block = null;
  }

  return result;
}

function rangeAt(doc, line, col) {
  const lineText = line < doc.lineCount ? doc.lineAt(line).text : "";
  const end = Math.min(lineText.length, col + 1);
  return new vscode.Range(line, col, line, Math.max(col, end));
}

function locateMode(doc, name) {
  const re = new RegExp(`^\\s*Mode\\s+${name}\\s*:`);
  for (let i = 0; i < doc.lineCount; i++) {
    const t = doc.lineAt(i).text;
    if (re.test(t)) {
      const start = t.indexOf(name);
      return new vscode.Range(i, start, i, start + name.length);
    }
  }
  return null;
}

module.exports = { activate, deactivate };
