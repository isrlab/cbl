---
name: cbl-explain
description: "Produce a plain-English summary of a CBL specification for a stakeholder, certifier, or domain expert who should not read CBL syntax. Use when the user asks to explain, summarise, describe, or walk through a .cbl file — or to share what a controller does with someone who isn't a CBL author."
---

# CBL Explain

This skill takes a `.cbl` file and produces an English description of the controller's behaviour. The reader of the output never sees CBL syntax.

This is the inverse of [cbl-elicit](../cbl-elicit/SKILL.md): elicit hides CBL during authoring; explain hides CBL during review.

## When to use this skill

- "Explain this spec" / "what does this controller do?"
- "Summarise traffic_light.cbl"
- "I need to send this to legal / a certifier / a domain expert — can you describe it without the syntax?"
- Read-back at the end of a `cbl-elicit` session (the elicit skill calls this implicitly in its Phase 6).

Do **not** use this skill to:

- Edit a spec (edit the file directly using [.claude/rules/cbl.md](../../rules/cbl.md)).
- Run formal checks (use `cblc check` / `cblc reason` directly).
- Generate tests (deferred to a future `cbl-propagate` skill).

## Pre-flight: run `cblc check` first

Before explaining anything, run `cblc check <file>.cbl`. Three outcomes:

1. **`✓ Specification is well-posed`** — proceed.
2. **Parse error** — the file is malformed CBL. Tell the user: "The spec file has a syntax error and I can't read it confidently. Want to fix it first?" Do not guess.
3. **Semantic errors** (totality, exclusivity, completeness, etc.) — the spec is structurally invalid. Say: "This spec doesn't pass the well-posedness checker — explaining it could be misleading because the behaviour isn't fully defined." Offer to either (a) explain the parts that are clear, marking the gaps, or (b) run `cbl-elicit` to fix the spec first.

Warnings (unused constants, etc.) are fine — ignore them.

## Output structure

Produce four sections, in this order. Adjust depth by audience (see below).

### 1. One-line summary

A single sentence: what the controller does, full stop. The reader who only reads this line should know what the system is.

> The traffic light controller cycles between green, yellow, and red phases on a fixed timer, and raises the walk signal during red.

### 2. What it watches and what it controls

Two short lists, in English, no types or syntax.

> **Watches:** whether the cycle timer has expired; whether a pedestrian has requested a walk.
>
> **Controls:** the light colour (one of red, yellow, green); whether the walk signal is on.

If there are `Constants:` worth knowing, mention them in a sentence: "The full cycle is 30 ticks long."

### 3. How it behaves

For each mode, an English paragraph describing what the controller does while in that mode. Walk through the rules in order. Use this template:

> **In the [mode name] phase**, the light is [whatever it sets]. [Paraphrase the `Otherwise` action — that's the "steady state" for this mode.] [Paraphrase each `When … shall …` rule as: "When [guard], it [action], then moves to [next mode]."]

Start with the **initial mode** and follow `transition to` references so the reader walks the lifecycle in natural order, not declaration order.

If a guarantee is held by default (`[default: hold]`) or has a default value, mention it once in section 2, not in every rule.

### 4. Rules that always hold (invariants)

If the spec has an `Always:` block, paraphrase each invariant as an English sentence:

> Regardless of mode: the light and the walk signal never both indicate "go" at the same time.

If there's no `Always:` block, omit this section.

### Optional: anything notable

Surface anything a reviewer should pay attention to:

- A mode that only has a self-loop (`remain in current` in every rule) — the controller gets stuck there.
- A guard that's unusually complex — paraphrase carefully and ask the reader to confirm intent.
- A `Definition` (named predicate) that bundles a non-obvious condition — explain the underlying logic.

Skip this section if nothing notable.

## Audience modes

By default produce all four sections. If the user names an audience, calibrate:

- **Executive** — section 1 only, plus a one-paragraph version of section 3 ("Roughly: it cycles green → yellow → red with the walk signal during red.").
- **Stakeholder / product** — sections 1–3, skip 4 unless invariants are intuitive.
- **Certifier / domain reviewer** — all four sections; be precise about every guard and action; do not summarise away conditions. This audience needs to be able to trust that nothing was paraphrased into ambiguity.

If the user doesn't specify, ask once: "Who is this for?" Then default to stakeholder depth if they don't answer.

## Translation cheat sheet

Paraphrase CBL into English with these mappings. Do not translate literally — rephrase for readability.

### Guards → English

| CBL | English |
|-----|---------|
| `x is true` | "when x" or "if x" |
| `x is false` | "when x isn't / not" |
| `x equals v` | "when x is v" |
| `x is one of {a, b}` | "when x is either a or b" |
| `x exceeds B` | "when x goes above B" / "once x crosses B" |
| `x is below B` | "when x drops below B" / "while x is under B" |
| `cond for N consecutive cycles` | "after cond has held for N cycles" |
| `cond for fewer than N consecutive cycles` | "before cond has held for N cycles" |
| `A and B` | "when A *and* B" — keep both; don't drop conjuncts |
| `A or B` | "when either A or B" |
| `not A` | "when A is not the case" |

### Actions → English

| CBL | English |
|-----|---------|
| `set x to v` | "x becomes v" / "the controller emits v on x" |
| `set x to expr` (with `+`/`-`) | "x is set to [paraphrased expression]" |
| `hold x` | "x is left unchanged" |
| `increment x` | "x ticks up by one" |
| `reset x` | "x is reset to its initial value" |
| `transition to M` | "and moves to the [M] phase" |
| `remain in current` | "and stays in this phase" |

### Mode names

If the mode name is descriptive (`Warming`, `Idle`, `EmergencyStop`), use it as-is, lowercased, often as "the [name] phase". If it's opaque (`M1`, `S3`), refer to it as "phase M1" and don't pretend it has meaning.

## Style rules

1. **No CBL syntax in the output.** No backticks around `set` or `When`. No `[default: hold]`. If the user wants the syntax, they will ask.
2. **Domain vocabulary.** Use the names the spec uses for signals and modes — they were presumably chosen by a domain person. Don't invent new ones.
3. **Active voice for actions.** "The controller raises the walk signal" not "The walk signal shall be set to true".
4. **Walk the lifecycle, not the file.** Order modes by reachability from the initial mode, not by declaration order.
5. **No editorialising.** Don't say "this seems weird" or "this is unusual" unless flagging something in the optional section. The job is to describe, not critique.
6. **No padding.** If a mode does one thing and exits cleanly, one sentence covers it. Don't pad to make sections look balanced.

## Showing the spec on request

If the user says "show me the actual CBL" or "what does that look like in syntax", then show the relevant section as a code block and continue. Returning to syntax-free mode afterward is fine.

## Examples

### Minimal — a stakeholder summary of `traffic_light.cbl`

> **What it does.** A traffic light controller that cycles through green, yellow, and red phases on a 30-tick timer, and turns on the walk signal during the red phase.
>
> **Watches:** whether the cycle timer has expired; whether a pedestrian has requested a walk.
>
> **Controls:** the light colour (green, yellow, or red); the walk signal (on/off).
>
> **How it behaves.**
>
> The light starts in the **green** phase. It stays green until the cycle timer expires, at which point it turns yellow, switches off the walk signal, and moves to the yellow phase.
>
> In the **yellow** phase, the light stays yellow until the timer expires, then turns red, switches the walk signal on, and moves to the red phase.
>
> In the **red** phase, the light stays red and the walk signal stays on until the timer expires, at which point the light turns green, the walk signal switches off, and the cycle returns to green.

### Executive-mode version

> A 30-tick traffic-light controller that cycles green → yellow → red, with the walk signal active during red.

## Reference

- [CBL language rule](../../rules/cbl.md) — vocabulary and section semantics.
- [cbl-elicit skill](../cbl-elicit/SKILL.md) — authoring counterpart; calls into this skill for read-back.
