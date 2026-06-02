# CBL Compiler — Known Limitations

User-visible limitations of the current `cblc check`. Each entry describes the
symptom, root cause, severity, current workaround, and a sketch of how it could
be fixed.

---

## L1 — Z3 cannot prove `for N consecutive cycles` and `for fewer than N consecutive cycles` are complementary [FIXED 2026-06-01]

**Resolved by** spec-wide memoization in `z3_guard_checker.ml`: a hash table
mapping `(cycle-count expression, inner predicate)` to a shared opaque
boolean lets `PForNCycles(N, p)` and `PForFewerCycles(N, p)` collapse to one
variable, with `PForFewerCycles` getting its negation. The memo is shared
across all `Always` invariants and all modes — a streak is a property of
the signal's history at a cycle, not of the current mode, so the same
boolean should be used everywhere the predicate appears.

`examples/truck_thermostat.cblang` now verifies with the original timing
predicates intact (door alarm fires after 2 consecutive cycles of door-open,
matching the original elicitation intent).

**Symptom (historical).** Two rules in the same mode whose guards differ only by
switching between `… for N consecutive cycles` and `… for fewer than N
consecutive cycles` were flagged as overlapping:

```
[Z3-WP1] Mode 'M': Rules i and j have overlapping guards. Counterexample: …
```

The reported counterexample omits the timing predicate's value, since the
checker has nothing to say about it.

**Root cause.** The Z3 guard checker abstracts every non-classical predicate
(`PForNCycles`, `PForFewerCycles`, `PDeviates`, `PAgrees`, `PIsOneOf`) as a
fresh opaque boolean and asserts no relationships between them. So
`PForNCycles(N, p)` and `PForFewerCycles(N, p)` look independent to Z3 even
though they're semantically complementary. See
`cbl-compiler/lib/z3_guard_checker.ml:228-232`.

**Severity.** High in practice — this pattern shows up the moment a spec needs
"an event happens iff a condition has held for at least N cycles, and the
controller behaves differently otherwise." First hit during elicitation of
`examples/truck_thermostat.cblang`: the user asked for the alarm to fire only
after the rear door had been open more than 30 s, but the spec wouldn't verify.

**Workaround (no longer needed).** Was: replace timing predicates with immediate
boolean predicates (`x is true` / `x is false`), losing the debounce.
