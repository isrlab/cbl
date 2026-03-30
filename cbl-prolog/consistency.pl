%% consistency.pl — R1-R14 consistency rules for the CBL Prolog reasoning engine.
%%
%% Operates on dynamic facts asserted by bridge.pl.
%% Produces error/1 and warning/1 terms.

:- module(consistency, [
    error/1,
    warning/1,
    declared/2,
    referenced_in/2,
    provenance_of/3,
    guard_refs/2,
    action_refs/2,
    pred_refs/2,
    expr_refs/2
]).

:- use_module(library(lists)).
:- use_module(bridge).

:- discontiguous error/1.
:- discontiguous warning/1.

%% ---------------------------------------------------------------------------
%%  R1. Every mode must have at least one transition.
%% ---------------------------------------------------------------------------
error(empty_mode(M)) :-
    bridge:mode(M, _),
    \+ bridge:transition(M, _, _, _, _, _).

%% ---------------------------------------------------------------------------
%%  R2. Guard completeness: every mode needs an Otherwise clause.
%%      (Syntactic totality analysis for complementary guard pairs
%%       is not implemented in v0.1.)
%% ---------------------------------------------------------------------------
error(guard_incomplete(M)) :-
    bridge:mode(M, _),
    \+ error(empty_mode(M)),
    \+ bridge:transition(M, _, otherwise, _, _, _).

%% ---------------------------------------------------------------------------
%%  R3. Action totality: every transition must assign all guarantees
%%      without a default annotation.
%% ---------------------------------------------------------------------------
error(missing_assignment(M, Idx, G)) :-
    bridge:transition(M, Idx, _, Actions, _, _),
    bridge:guarantee(G, _, _),
    \+ bridge:guarantee_default(G, _, _),
    \+ member(set(G, _), Actions),
    \+ member(hold(G), Actions),
    \+ member(increment(G), Actions),
    \+ member(reset(G), Actions).

%% ---------------------------------------------------------------------------
%%  R4. Transition target must reference a declared mode.
%% ---------------------------------------------------------------------------
error(invalid_target(M, Idx, Target)) :-
    bridge:transition(M, Idx, _, _, transition_to(Target), _),
    \+ bridge:mode(Target, _).

%% ---------------------------------------------------------------------------
%%  R5. Initial mode must be declared.
%% ---------------------------------------------------------------------------
error(invalid_initial(M)) :-
    bridge:initial_mode(M, _),
    \+ bridge:mode(M, _).

%% ---------------------------------------------------------------------------
%%  R5b. An initial mode must exist.
%% ---------------------------------------------------------------------------
error(no_initial_mode) :-
    \+ bridge:initial_mode(_, _).

%% ---------------------------------------------------------------------------
%%  R6. No duplicate declarations across namespaces.
%% ---------------------------------------------------------------------------
error(duplicate(Name, Kind1, Kind2)) :-
    declared(Name, Kind1),
    declared(Name, Kind2),
    Kind1 @< Kind2.

declared(N, assume)    :- bridge:assume(N, _, _).
declared(N, constant)  :- bridge:constant(N, _, _, _).
declared(N, guarantee) :- bridge:guarantee(N, _, _).
declared(N, variable)  :- bridge:variable(N, _, _, _).
declared(N, mode)      :- bridge:mode(N, _).
declared(N, definition):- bridge:definition(N, _, _).

%% ---------------------------------------------------------------------------
%%  R7. Every name referenced in a guard, action, or predicate must be declared.
%% ---------------------------------------------------------------------------
error(undeclared_ref(Name, Context)) :-
    referenced_in(Name, Context),
    \+ declared(Name, _).

referenced_in(Name, transition(M, Idx)) :-
    bridge:transition(M, Idx, Guard, Actions, _, _),
    (guard_refs(Guard, Name) ; action_refs(Actions, Name)).

referenced_in(Name, entry_action(M)) :-
    bridge:entry_action(M, Actions, _),
    action_refs(Actions, Name).

referenced_in(Name, invariant(M)) :-
    bridge:mode_invariant(M, Pred, _),
    pred_refs(Pred, Name).

referenced_in(Name, always_invariant) :-
    bridge:always_invariant(Pred, _),
    pred_refs(Pred, Name).

referenced_in(Name, definition(D)) :-
    bridge:definition(D, Body, _),
    pred_refs(Body, Name),
    Name \= D.

guard_refs(guard(Pred), Name) :- pred_refs(Pred, Name).
guard_refs(otherwise, _) :- fail.

action_refs(Actions, Name) :-
    member(Act, Actions),
    (   Act = set(Name, _)
    ;   Act = set(_, Expr), expr_refs(Expr, Name)
    ;   Act = hold(Name)
    ;   Act = increment(Name)
    ;   Act = reset(Name)
    ).

pred_refs(var(Name), Name).
pred_refs(is_true(E), Name) :- expr_refs(E, Name).
pred_refs(is_false(E), Name) :- expr_refs(E, Name).
pred_refs(expr(E), Name) :- expr_refs(E, Name).
pred_refs(equals(L, R), Name) :- (expr_refs(L, Name) ; expr_refs(R, Name)).
pred_refs(exceeds(L, R), Name) :- (expr_refs(L, Name) ; expr_refs(R, Name)).
pred_refs(is_below(L, R), Name) :- (expr_refs(L, Name) ; expr_refs(R, Name)).
pred_refs(deviates(V, Refs, T), Name) :-
    (expr_refs(V, Name) ; member(R, Refs), expr_refs(R, Name) ; expr_refs(T, Name)).
pred_refs(agrees(V, Refs, T), Name) :-
    (expr_refs(V, Name) ; member(R, Refs), expr_refs(R, Name) ; expr_refs(T, Name)).
pred_refs(is_one_of(E, _), Name) :- expr_refs(E, Name).
pred_refs(for_n_cycles(N, P), Name) :- (expr_refs(N, Name) ; pred_refs(P, Name)).
pred_refs(for_fewer(N, P), Name) :- (expr_refs(N, Name) ; pred_refs(P, Name)).
pred_refs(and(L, R), Name) :- (pred_refs(L, Name) ; pred_refs(R, Name)).
pred_refs(or(L, R), Name)  :- (pred_refs(L, Name) ; pred_refs(R, Name)).
pred_refs(not(P), Name)    :- pred_refs(P, Name).
pred_refs(ref(DefName), DefName).
pred_refs(true, _)  :- fail.
pred_refs(false, _) :- fail.

expr_refs(var(Name), Name).
expr_refs(binop(_, L, R), Name) :- (expr_refs(L, Name) ; expr_refs(R, Name)).
expr_refs(unop(_, E), Name) :- expr_refs(E, Name).
expr_refs(average(Es), Name) :- member(E, Es), expr_refs(E, Name).
expr_refs(median(Es), Name) :- member(E, Es), expr_refs(E, Name).

%% ---------------------------------------------------------------------------
%%  provenance_of/3: extracts provenance tag for a named declaration.
%% ---------------------------------------------------------------------------
provenance_of(N, assume, P)    :- bridge:assume(N, _, P).
provenance_of(N, constant, P)  :- bridge:constant(N, _, _, P).
provenance_of(N, guarantee, P) :- bridge:guarantee(N, _, P).
provenance_of(N, variable, P)  :- bridge:variable(N, _, _, P).
provenance_of(N, mode, P)      :- bridge:mode(N, P).
provenance_of(N, definition, P):- bridge:definition(N, _, P).

%% Transitions: keyed by Mode_Idx (e.g., idle_0) so each is individually trackable.
provenance_of(TransId, transition, P) :-
    bridge:transition(M, Idx, _, _, _, P),
    format(atom(TransId), "~w_~w", [M, Idx]).

%% Entry actions: keyed by mode name.
provenance_of(ModeName, entry_action, P) :-
    bridge:entry_action(ModeName, _, P).

%% Mode invariants: keyed by mode name.
provenance_of(ModeName, mode_invariant, P) :-
    bridge:mode_invariant(ModeName, _, P).

%% Always-invariants: no natural name; use synthetic marker.
provenance_of(global, always_invariant, P) :-
    bridge:always_invariant(_, P).

%% Initial mode.
provenance_of(N, initial_mode, P) :-
    bridge:initial_mode(N, P).

%% ---------------------------------------------------------------------------
%%  R8. Constants with unknown values block compilation.
%% ---------------------------------------------------------------------------
warning(unknown_value(Name)) :-
    bridge:constant(Name, _, '__unknown__', _).

%% ---------------------------------------------------------------------------
%%  R9. Unconfirmed inferences block compilation.
%% ---------------------------------------------------------------------------
warning(unconfirmed(Name, Kind)) :-
    provenance_of(Name, Kind, llm_inferred).

%% R9b. Guarantee defaults with unconfirmed provenance.
warning(unconfirmed_default(Name)) :-
    bridge:guarantee_default(Name, _, llm_inferred).

%% ---------------------------------------------------------------------------
%%  R10. Guard exclusivity heuristic.
%% ---------------------------------------------------------------------------
warning(possibly_overlapping_guards(M, I, J)) :-
    bridge:transition(M, I, guard(G1), _, _, _),
    bridge:transition(M, J, guard(G2), _, _, _),
    I < J,
    \+ syntactically_exclusive(G1, G2).

syntactically_exclusive(is_true(X), is_false(X)).
syntactically_exclusive(is_false(X), is_true(X)).
syntactically_exclusive(G, not(G)).
syntactically_exclusive(not(G), G).
syntactically_exclusive(equals(X, A), equals(X, B)) :- A \= B.

%% ---------------------------------------------------------------------------
%%  R11. Basic type checking for set actions.
%% ---------------------------------------------------------------------------
error(type_mismatch(M, Idx, G, Expected, Got)) :-
    bridge:transition(M, Idx, _, Actions, _, _),
    member(set(G, Val), Actions),
    bridge:guarantee(G, Expected, _),
    infer_expr_type(Val, Got),
    \+ type_compatible(Expected, Got).

infer_expr_type(int(_), integer).
infer_expr_type(real(_), real).
infer_expr_type(bool(_), boolean).
infer_expr_type(string(V), enum_member(V)).
infer_expr_type(average(_), real).
infer_expr_type(median(_), real).

type_compatible(T, T).
type_compatible(real, integer).
%% Enum type strings from JSON look like "{a, b, c}".
%% We check if the member atom appears in the type string.
type_compatible(TypeAtom, enum_member(V)) :-
    atom(TypeAtom),
    atom_string(TypeAtom, TypeStr),
    parse_enum_members(TypeStr, Members),
    atom_string(V, VS),
    member(VS, Members).

%% Parse "{a, b, c}" into ["a", "b", "c"].
parse_enum_members(TypeStr, Members) :-
    string_concat("{", Rest0, TypeStr),
    string_concat(Body, "}", Rest0), !,
    split_string(Body, ",", " ", Members0),
    exclude(=(""), Members0, Members).
parse_enum_members(_, []).

%% ---------------------------------------------------------------------------
%%  R12. Reachability: warn if a mode is unreachable from the initial mode.
%% ---------------------------------------------------------------------------
warning(unreachable_mode(M)) :-
    bridge:mode(M, _),
    bridge:initial_mode(Init, _),
    M \= Init,
    \+ reachable(Init, M).

:- table reachable/2.
reachable(From, To) :- bridge:transition(From, _, _, _, transition_to(To), _).
reachable(From, To) :- bridge:transition(From, _, _, _, transition_to(Mid), _), reachable(Mid, To).

%% ---------------------------------------------------------------------------
%%  R13. Unused declaration.
%% ---------------------------------------------------------------------------
warning(unused(Name, Kind)) :-
    declared(Name, Kind),
    Kind \= mode,
    \+ referenced_in(Name, _).

%% R14 removed: entry action undeclared references are already caught by R7
%% via referenced_in(Name, entry_action(M)).
