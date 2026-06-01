# Checker errors → English questions

When `cblc check` reports an error, do not show it. The error is a decision the user has not made yet, or a mismatch between what they said and what got recorded. Convert it to a question and ask them.

Each entry below: the error message pattern (what `cblc` prints), the *meaning* (why the checker rejected it), and the *question* (what to ask).

## Parser / lexer

### `Error: Parse error at line N, column M`
**Meaning.** The spec file is malformed — you wrote something that isn't CBL. This is your bug, not the user's.
**Action.** Do not ask the user. Re-read [.claude/rules/cbl.md](../../../rules/cbl.md), find what you wrote that's outside the vocabulary, and fix it silently.

### `Error: Lexical error: <msg>`
**Same as above.** Your bug.

## Structure

### `Invalid initial mode 'X' (not declared)`
**Meaning.** `Initial Mode: X` references a mode that isn't defined.
**Question (if user picked the name).** "You said the controller starts in [X], but I haven't captured [X] as a mode yet. Should I add it, or did you mean one of: [list existing modes]?"
**Silent fix (if it's your typo).** Just fix it.

### `Mode 'X' is unreachable`
**Meaning.** No `transition to X` from any other mode (and X is not the initial mode).
**Question.** "We defined a mode [X], but nothing in the spec moves the controller into it. Either it should be reachable from somewhere, or it shouldn't exist. Which is it?"

### `Invalid transition target 'Y' from mode 'X'`
**Meaning.** A rule in mode X says `transition to Y`, but Y isn't a declared mode.
**Question.** "In [X], one rule transitions to [Y], which isn't a mode I've recorded. Did you mean [closest existing mode name], or is [Y] a new mode I should add?"

### `Duplicate declaration of <kind> 'X'`
**Meaning.** Two `Assumes`/`Guarantees`/`Variables`/`Constants`/`Modes` with the same name.
**Question.** "We've used the name [X] twice — once as a [kind1] and once as a [kind2]. Are these the same thing? If so, which one should I keep?"

## Identifiers and types

### `Undeclared identifier 'X' in <context>`
**Meaning.** A guard, action, or expression references a name that isn't in `Assumes`, `Constants`, `Guarantees`, `Variables`, or `Definitions`.
**Question.** "You mentioned [X] when describing [context]. Where does [X] come from — is it a signal the controller reads, an output it produces, or a constant?"

### `Type mismatch in <context>: expected <T1>, got <T2>`
**Meaning.** E.g. comparing a boolean to an integer, or assigning an enum value to a numeric variable.
**Question.** "I've recorded [name] as a [T1], but the way you described [context] treats it as a [T2]. Which is right?"

### `Invalid action target 'X' in <context>`
**Meaning.** An action tries to modify something it can't — typically `increment` or `reset` on a `Guarantee`, or `set` on an `Assume`.
**Question (for increment/reset on guarantee).** "You wanted [X] to count up. Counters live as internal variables — should [X] be one, and the visible output derived from it?"
**Question (for set on assume).** "We listed [X] as a signal the controller reads. But you said it gets set — is it actually an output, or is something upstream setting it?"

## Guards

### `Overlapping guards in mode X`
**Meaning.** Two `When` clauses in mode X can be true simultaneously. CBL requires guard exclusivity (no fall-through, no first-match).
**Question.** "In mode [X], there are two conditions that could both fire at once: [paraphrase guard 1] and [paraphrase guard 2]. When both are true, which one wins? Should the second one only fire when the first doesn't apply?"
*Concrete restructuring suggestion.* "We could say: rule 1 is [G1], rule 2 is [G2 and not G1]. Does that match what you meant?"

### `Incomplete guards in mode X (no Otherwise clause)`
**Meaning.** Mode X doesn't have a final `Otherwise, shall …`.
**Question.** "In [X], we've covered: [list guards in English]. If none of those conditions hold this cycle, what does the controller do? Stay in [X] and keep outputs the same, or something else?"

## Actions

### `Action totality violated in mode X: missing assignments for a, b, c`
**Meaning.** A `shall` block doesn't `set` every guarantee, and those guarantees don't have a `[default:]`.
**Question (if the missing outputs naturally hold).** "In [X], when [paraphrase the rule], we didn't say what [a, b, c] should be. Do they stay the same as last cycle? If yes, I can make 'stays the same' their default behaviour so we don't have to mention them in every rule."
**Question (if they take a specific value).** "In [X], when [paraphrase the rule], what should [a] be? And [b]? And [c]?"

## Reasoning (Z3) diagnostics

### `[<code>] Mode 'X': <msg>`
**Meaning.** Z3 found a logical issue with guards in mode X — typically unreachable rules or invariant violations.
**Action.** Read the message, identify the rule/invariant involved, and ask the user about the specific contradiction in English. Examples:

- **Unreachable rule.** "In [X], you have a rule that fires when [paraphrase]. But given the earlier guards, that condition can never actually be true. Did you mean to weaken one of the earlier guards, or should this rule be removed?"
- **Invariant violated.** "You said as an always-rule that [paraphrase invariant]. But in mode [X], the rule that fires when [paraphrase guard] sets [output] to [value], which breaks that. Which one should give?"

## Warnings (do not block)

### `Unused constant 'X'` / `Unused variable 'X'` / `Unused definition 'X'`
**Meaning.** Declared but never referenced.
**Action.** Probably leftover from earlier drafting. Either drop it silently, or — if the user introduced it explicitly — ask: "We talked about [X] earlier but it doesn't end up in any rule. Should I drop it, or is there a rule we haven't gotten to yet?"

---

When in doubt, the question to ask is the one that surfaces the *decision the user has not made*. The error tells you which decision; this table just translates the jargon.
