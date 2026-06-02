---
name: cbl-elicit
description: "Run a structured discovery session to build a CBL (Controlled Behavioural Language) specification through conversation. Use when the user wants to specify a controller or state machine, capture mode/guard/action logic, define how a system reacts to signals, or describe behaviour they need formalised. The user should never see CBL syntax — they describe behaviour in English; Claude writes and verifies the .cblang file in the background."
---

# CBL Elicitation

This skill guides you through building a CBL specification by conversation. CBL describes a **synchronous Mealy state machine**: one `System` per file, modes with guards and actions, mechanically checked for well-posedness by `cblc`.

The user does not see CBL. They describe their controller in plain English. You translate to CBL silently, run `cblc check`, and convert any failures back into English questions about ambiguities or missing decisions.

If the user explicitly asks to see the spec, show it. Otherwise, keep CBL out of the conversation.

## Routing

| Task | Use |
|------|-----|
| Building a new spec from scratch | this skill |
| Editing an existing `.cblang` file | edit it directly; cite [.claude/rules/cbl.md](../../rules/cbl.md) for syntax |
| Running well-posedness check | `cblc check <file>.cblang` (Bash) |
| Reading the language reference | [.claude/rules/cbl.md](../../rules/cbl.md) |
| Translating checker errors to questions | [references/checker-errors-to-questions.md](references/checker-errors-to-questions.md) |

## What CBL captures (and what it does not)

CBL describes one synchronous controller as a Mealy machine:

- **Inputs** are `Assumes:` (signals the controller reads each cycle).
- **Outputs** are `Guarantees:` (signals the controller emits each cycle).
- **State** is the current `Mode` plus any `Variables:`.
- **Behaviour** is a guarded transition table: in each mode, a list of `When … shall …` rules and a final `Otherwise, shall …`.

CBL does **not** describe: continuous dynamics, message passing, data structures, UI, persistence, or anything that is not "given these inputs this cycle, in this mode, what do I output and which mode do I enter next?". If the user's domain is not a synchronous controller, name that mismatch and stop — do not stretch CBL to fit.

## The hidden-CBL discipline

Three rules govern your output to the user:

1. **Speak the domain, not the IR.** Say "when the timer expires" not `timer_expired is true`. Say "the light stays green" not `set light_color to green`.
2. **Hide the file.** Never paste CBL into the chat unless the user asks. Save it as `<system_name>.cblang` (snake_case) in the working directory and tell the user you've saved it.
3. **Translate every checker error into a question.** A checker failure means a decision the user has not made yet. Surface that decision in English. See [references/checker-errors-to-questions.md](references/checker-errors-to-questions.md).

If the user types "show me the spec", or "what does the CBL look like", show it. Then return to English.

## Elicitation methodology

Run five phases in order. After each phase, write the partial `.cblang` file and run `cblc check`. Any failures become questions for the next phase.

### Phase 1: Scope and signals

**Goal:** Identify one controller, its inputs, and its outputs.

Ask, one question at a time:

1. "In one sentence, what does this controller do?"
2. "What signals does it read each cycle? What's the type of each — boolean, integer, or one of a fixed set of values?"
3. "What does it output each cycle? Same question on types."
4. "Are there fixed numbers it uses — timeouts, thresholds, limits?"

**Outputs to capture in the spec:** `System Name`, `Assumes:` block, `Guarantees:` block, `Constants:` block.

**Watch for:**

- *Continuous signals or differential equations*. CBL is discrete and synchronous. Either discretise ("the temperature reading each cycle") or stop and tell the user.
- *Two outputs that are really one*. "Light colour and walk signal" are two guarantees; "the display state" is probably one.
- *Inputs the user names that are actually internal state*. "Whether we're warming up" is a mode, not an `Assumes`.

### Phase 2: Modes and the happy path

**Goal:** Enumerate operating modes and walk the typical sequence.

Ask:

1. "What modes can this controller be in? What does each one *mean*?"
2. "Which mode does it start in?"
3. "Walk me through a typical run from start. When the system is in [mode X], what makes it move to a different mode?"

**Outputs:** `Initial Mode: <Name>`, one `Mode <Name>:` per mode (rules still empty).

**Watch for:**

- *Sub-modes*. "When it's in Warming, it can be either pre-heating or holding". Either flatten (two modes: `Preheating`, `Holding`) or model the inner state as a `Variable`. CBL has no hierarchy.
- *Continuous mode names*. "Most of the time it's just running". Push for the distinct cases.
- *Modes that are never entered*. If the user can't say what moves the system into a mode, it may not exist.

### Phase 3: Guards (one mode at a time)

**Goal:** For each mode, write `When … shall … transition to …` rules and a final `Otherwise`. Guards must be **complete** (every input combination matches something) and **exclusive** (no two match at once).

For each mode, ask:

1. "We're in [mode]. What's the first thing that should make it leave?"
2. "Could that condition be true at the same time as [an earlier condition]? Which one wins?"
3. "If none of those conditions hold, what does it do?" → `Otherwise`

Use the CBL guard vocabulary (do not invent forms):

- `<signal> is true` / `is false`
- `<signal> equals <value>` / `is one of {a, b}`
- `<signal> exceeds <bound>` / `is below <bound>`
- `<signal> ... for N consecutive cycles` / `for fewer than N consecutive cycles`
- Joined by `and`, `or`, `not`

**Watch for:**

- *Overlapping guards*. "When timer expires" and "when timer expires and pedestrian waiting" both match. Either order them (first match wins is not CBL semantics — guards must be exclusive) or restructure ("timer expires and pedestrian waiting" vs "timer expires and no pedestrian").
- *Missing Otherwise*. The checker will reject. Ask: "And if none of those? Stay put, presumably?"
- *Conditions outside the vocabulary*. "When the user double-clicks within 500ms" — translate to a signal the assumptions block introduces (`double_click_pending : boolean`).

### Phase 4: Actions (action totality)

**Goal:** Every `shall` block must `set` every guarantee — unless the guarantee declares a default (`[default: <value>]` or `[default: hold]`).

For each rule in each mode, ask:

1. "When that condition fires, what does each output become?"
2. "Some of these outputs probably don't change in most rules. Should [guarantee X] default to holding its previous value when a rule doesn't mention it? Or default to a specific value?"

The second question is the **action-totality escape valve**. Use it aggressively for outputs that are dominated by a default.

Actions:

- `set <guarantee_or_variable> to <expression>`
- `hold <variable>` (no change this cycle)
- `increment <variable>` / `reset <variable>` (variables only, never guarantees)

**Watch for:**

- *Output never assigned in a mode*. Either add the missing `set`, or give the guarantee a `[default:]`.
- *`increment` on a guarantee*. The checker rejects this. Move the counter to `Variables:` and emit a guarantee derived from it (or just expose the variable as a guarantee directly if appropriate).

### Phase 5: Invariants and edges

**Goal:** Capture system-wide properties and failure modes.

Ask:

1. "Is there anything that must always be true, regardless of mode? (E.g. 'the system never emits a green light and a walk signal at the same time.')"
2. "What if a sensor is stuck or returns garbage? Is that the controller's problem or someone else's?"
3. "Are there any startup or shutdown behaviours we haven't captured?"

Outputs in spec: `Always:` clause (invariants), possibly extra `Assumes` for sensor-validity flags.

**Watch for:**

- *Invariants that are actually rules*. "After the alarm fires, the alarm stays on until reset" is a mode behaviour, not a global invariant.
- *Failure-mode demands that change the contract*. If "stuck sensor" handling adds new modes, fold them in; don't bolt on.

### Phase 6: Verify and confirm

1. Run `cblc check <file>.cblang`.
2. If it fails, take each error and convert it to an English question using the [error → question table](references/checker-errors-to-questions.md). Ask the user. Update the spec. Re-run.
3. When it passes (`✓ Specification is well-posed`), read back a one-paragraph English summary: "Here's what we've specified: a controller called X that watches A, B, C and outputs P, Q. It has modes M1, M2, M3, starting in M1. It moves from M1 to M2 when …, etc."
4. Ask: "Does that match what you intended?"

Do **not** declare the session complete until both (a) the checker passes and (b) the user confirms the English read-back.

## Elicitation principles

### Ask one question at a time

Two questions in one message guarantees the user answers one and the other gets lost.

### Speak the domain

The user's vocabulary, not CBL's. They say "timer runs out", you understand "When `timer_expired is true`". They never see the bracketed form.

### Distinguish controller-level from elsewhere

| User says | You translate / redirect |
|-----------|--------------------------|
| "The PID loop drives the motor" | "What discrete signal does the PID loop output that this controller reads?" |
| "We send a message to the cloud" | "Is that an output we emit each cycle, or is messaging out of scope?" |
| "There's a database of allowed users" | "Does that affect this controller's per-cycle behaviour, or is it handled before the signal reaches us?" |
| "The UI shows a warning" | "Is the warning a guarantee this controller emits, or downstream of one?" |

### Surface ambiguity by replaying

When the user gives a vague answer, replay it as a concrete instance and ask whether you got it right.

"You said 'when the door is open we should not move'. So: in any mode, if `door_open is true`, the motor stays stopped. Is that the rule even during emergency stop? Even during diagnostic mode?"

This forces the implicit "almost always" assumptions out.

### Use concrete walkthroughs

Don't ask "what are all the modes?" cold. Ask "Walk me through one full cycle. The system just powered on. What's it doing?"

### Iterate willingly

It's normal to discover in Phase 4 that a mode from Phase 2 was wrong. Say so out loud, fix it, re-run the checker.

### Know when to stop

If the controller has 30 modes and 200 guards, the spec is probably wrong — either the abstraction is too low, or this is really several controllers. Suggest splitting.

## Common traps

### The "it's continuous" trap

User describes analog behaviour ("the valve opens smoothly as pressure rises"). CBL only describes discrete decisions. Ask: "Each cycle, the controller picks an output value. What are the distinct output values, and what input regions correspond to each?"

### The "everything is a mode" trap

User wants 15 modes because there are 15 named scenarios. Ask: "Do these scenarios differ in *what the controller does next cycle*, or only in how we describe them to a user?" The latter belongs in documentation, not modes.

### The "guard expressivity" trap

The user wants to say "when the user has been waiting impatiently". The vocabulary doesn't include "impatient". Either:

- Introduce a derived input in `Assumes` ("`user_impatient : boolean`") — a signal someone upstream computes.
- Restructure ("when `wait_time exceeds 30`").

Do not invent new guard syntax.

### The "implicit Otherwise" trap

User says "and if the timer hasn't expired, we just keep going". That "just keep going" is an `Otherwise, shall …` that must enumerate every guarantee's value. Don't accept it as implicit.

### The "default-as-escape-hatch" trap

Don't use `[default: hold]` on every guarantee just to make the checker shut up. A `hold` default is meaningful: it says "this output usually doesn't change". If it changes in every mode, drop the default and write the `set`s explicitly.

### The "two terms" trap

"Sometimes we call it the warning light, sometimes the alarm indicator." Pick one name, use it everywhere. Don't add comments noting both.

## Session structure

**Opening (1–2 turns).** "We're going to specify a controller. I'll ask you a series of questions about what it reads, what it outputs, and how it switches between modes. I'll save the spec to a file and verify it as we go — you'll see English, not the spec syntax."

**Phase 1 (3–5 turns).** Scope and signals. Save partial spec. `cblc check` is expected to fail (no modes yet) — that's fine, don't surface those errors.

**Phase 2 (3–5 turns).** Modes and happy path. `cblc check` will fail on empty rules — fine.

**Phase 3 (one cluster per mode, ~3 turns each).** Guards. From here onward, run `cblc check` after each mode is completed; surface real failures as questions.

**Phase 4 (one cluster per mode, ~2 turns each).** Actions.

**Phase 5 (2–4 turns).** Invariants and edges.

**Phase 6 (1–3 turns).** Verify, read back, confirm.

Total: roughly 20–40 turns for a non-trivial controller. Faster if the user is decisive.

## After elicitation

The artifact is one `.cblang` file that passes `cblc check`. Downstream pipeline steps (`cblc compile`, `cblc reason`) operate on it directly — the user does not need to touch them as part of elicitation.

If the user wants to change the spec later:

- Targeted edits: edit the file directly, citing [.claude/rules/cbl.md](../../rules/cbl.md).
- Substantial new behaviour (new modes, new signals, restructuring): re-enter this skill, starting from Phase 1 with the existing spec loaded as context.

## References

- [CBL language rule](../../rules/cbl.md) — full controlled vocabulary, section order, anti-patterns.
- [Checker errors → English questions](references/checker-errors-to-questions.md) — translation table for every `cblc check` error class.
