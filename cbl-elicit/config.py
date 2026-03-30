"""Load CBL configuration from cbl.toml with CLI overrides."""

from __future__ import annotations

import tomllib
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class SessionConfig:
    max_iterations: int = 10
    schema_retries: int = 3
    stall_threshold: int = 2


@dataclass
class ToolsConfig:
    swipl: str = "swipl"
    cblc: str = "cblc"


@dataclass
class MitigationsConfig:
    back_translation: bool = True
    traceability: bool = True
    dual_extraction: bool = False


@dataclass
class Config:
    session: SessionConfig = field(default_factory=SessionConfig)
    tools: ToolsConfig = field(default_factory=ToolsConfig)
    mitigations: MitigationsConfig = field(default_factory=MitigationsConfig)
    agents: list[str] = field(default_factory=list)


def load_config(path: Path | None = None) -> Config:
    """Load config from cbl.toml. Returns defaults if file not found."""
    if path is None:
        path = Path("cbl.toml")
    cfg = Config()
    if not path.is_file():
        return cfg
    with open(path, "rb") as f:
        raw = tomllib.load(f)
    if "session" in raw:
        s = raw["session"]
        if "max_iterations" in s:
            cfg.session.max_iterations = max(1, int(s["max_iterations"]))
        if "schema_retries" in s:
            cfg.session.schema_retries = max(1, int(s["schema_retries"]))
        if "stall_threshold" in s:
            cfg.session.stall_threshold = max(1, int(s["stall_threshold"]))
    if "tools" in raw:
        t = raw["tools"]
        if "swipl" in t:
            cfg.tools.swipl = str(t["swipl"])
        if "cblc" in t:
            cfg.tools.cblc = str(t["cblc"])
    if "mitigations" in raw:
        m = raw["mitigations"]
        if "back_translation" in m:
            cfg.mitigations.back_translation = bool(m["back_translation"])
        if "traceability" in m:
            cfg.mitigations.traceability = bool(m["traceability"])
        if "dual_extraction" in m:
            cfg.mitigations.dual_extraction = bool(m["dual_extraction"])
    if "agents" in raw:
        a = raw["agents"]
        if "inject" in a:
            cfg.agents = [str(x) for x in a["inject"]]
    return cfg
