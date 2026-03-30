%% bridge.pl — JSON I/O and utility predicates for the CBL Prolog reasoning engine.
%%
%% Handles:
%%   - Reading extracted_facts.json and asserting Prolog facts
%%   - Serializing verdict.json from Prolog query results
%%   - Utility predicates (atom_edit_distance/3)

:- module(bridge, [
    load_facts/1,
    emit_verdict/1,
    atom_edit_distance/3,
    clear_facts/0
]).

:- use_module(library(json)).
:- use_module(library(lists)).
:- use_module(library(apply)).

%% ---------------------------------------------------------------------------
%%  Dynamic fact database (asserted from JSON)
%% ---------------------------------------------------------------------------

:- discontiguous bridge:assume/3.
:- discontiguous bridge:constant/4.
:- discontiguous bridge:guarantee/3.
:- discontiguous bridge:guarantee_default/3.
:- discontiguous bridge:variable/4.
:- discontiguous bridge:definition/3.
:- discontiguous bridge:mode/2.
:- discontiguous bridge:initial_mode/2.
:- discontiguous bridge:mode_invariant/3.
:- discontiguous bridge:entry_action/3.
:- discontiguous bridge:always_invariant/2.
:- discontiguous bridge:transition/6.
:- discontiguous bridge:open_question/5.
:- discontiguous bridge:system_name/2.

:- dynamic assume/3.            % assume(Name, Type, Provenance)
:- dynamic constant/4.          % constant(Name, Type, Value, Provenance)
:- dynamic guarantee/3.         % guarantee(Name, Type, Provenance)
:- dynamic guarantee_default/3. % guarantee_default(Name, Default, Provenance)
:- dynamic variable/4.          % variable(Name, Type, Initial, Provenance)
:- dynamic definition/3.        % definition(Name, Body, Provenance)
:- dynamic mode/2.              % mode(Name, Provenance)
:- dynamic initial_mode/2.      % initial_mode(Name, Provenance)
:- dynamic mode_invariant/3.    % mode_invariant(ModeName, Predicate, Provenance)
:- dynamic entry_action/3.      % entry_action(ModeName, Actions, Provenance)
:- dynamic always_invariant/2.  % always_invariant(Predicate, Provenance)
:- dynamic transition/6.        % transition(Mode, Idx, Guard, Actions, Target, Provenance)
:- dynamic open_question/5.     % open_question(Id, Text, RelatesTo, Category, Options)
:- dynamic system_name/2.       % system_name(Name, Provenance)

%% clear_facts/0: Retract all dynamic facts.
clear_facts :-
    retractall(assume(_, _, _)),
    retractall(constant(_, _, _, _)),
    retractall(guarantee(_, _, _)),
    retractall(guarantee_default(_, _, _)),
    retractall(variable(_, _, _, _)),
    retractall(definition(_, _, _)),
    retractall(mode(_, _)),
    retractall(initial_mode(_, _)),
    retractall(mode_invariant(_, _, _)),
    retractall(entry_action(_, _, _)),
    retractall(always_invariant(_, _)),
    retractall(transition(_, _, _, _, _, _)),
    retractall(open_question(_, _, _, _, _)),
    retractall(system_name(_, _)).

%% ---------------------------------------------------------------------------
%%  JSON Ingestion: load_facts/1
%% ---------------------------------------------------------------------------

valid_provenance(user_stated).
valid_provenance(user_confirmed).
valid_provenance(llm_inferred).
valid_provenance(rule_derived).
valid_provenance(rule_derived_pending).
valid_provenance(default_assumed).
valid_provenance(user_rejected).

provenance_atom(ProvStr, Prov) :-
    (   string(ProvStr),
        atom_string(Prov, ProvStr),
        valid_provenance(Prov)
    ->  true
    ;   throw(error(invalid_provenance(ProvStr), _))
    ).

validate_schema_version(Dict) :-
    (   get_dict(schema_version, Dict, Ver),
        string(Ver),
        Ver = "0.1"
    ->  true
    ;   throw(error(invalid_schema_version, _))
    ).

validate_provenance_attestation(Dict) :-
    (   get_dict(provenance_attested, Dict, Attested),
        Attested == true
    ->  true
    ;   throw(error(untrusted_provenance, _))
    ).

%% load_facts(+File): Read extracted_facts.json and assert all facts.
load_facts(File) :-
    clear_facts,
    setup_call_cleanup(
        open(File, read, Stream, [encoding(utf8)]),
        json_read_dict(Stream, Dict, [tag(json)]),
        close(Stream)
    ),
    validate_schema_version(Dict),
    validate_provenance_attestation(Dict),
    assert_system_name(Dict),
    assert_assumes(Dict),
    assert_constants(Dict),
    assert_guarantees(Dict),
    assert_variables(Dict),
    assert_definitions(Dict),
    assert_always_invariants(Dict),
    assert_initial_mode(Dict),
    assert_modes(Dict),
    assert_open_questions(Dict).

%% --- System name ---
assert_system_name(Dict) :-
    (   get_dict(system_name, Dict, SN)
    ->  get_tagged_value(SN, Name, Prov),
        assertz(system_name(Name, Prov))
    ;   true
    ).

%% --- Assumes ---
assert_assumes(Dict) :-
    (   get_dict(assumes, Dict, List)
    ->  maplist(assert_one_assume, List)
    ;   true
    ).

assert_one_assume(A) :-
    get_tagged_value(A.name, Name, _NameProv),
    get_tagged_value(A.atype, TypeStr, _TypeProv),
    provenance_from_dict(A, Prov),
    atom_string(NameAtom, Name),
    atom_string(TypeAtom, TypeStr),
    assertz(assume(NameAtom, TypeAtom, Prov)).

%% --- Constants ---
assert_constants(Dict) :-
    (   get_dict(constants, Dict, List)
    ->  maplist(assert_one_constant, List)
    ;   true
    ).

assert_one_constant(C) :-
    get_tagged_value(C.name, Name, _),
    get_tagged_value(C.ctype, TypeStr, _),
    get_tagged_value(C.cvalue, Value, _),
    provenance_from_dict(C, Prov),
    atom_string(NameAtom, Name),
    atom_string(TypeAtom, TypeStr),
    normalize_value(Value, NormVal),
    assertz(constant(NameAtom, TypeAtom, NormVal, Prov)).

%% --- Guarantees ---
assert_guarantees(Dict) :-
    (   get_dict(guarantees, Dict, List)
    ->  maplist(assert_one_guarantee, List)
    ;   true
    ).

assert_one_guarantee(G) :-
    get_tagged_value(G.name, Name, _),
    get_tagged_value(G.gtype, TypeStr, _),
    provenance_from_dict(G, Prov),
    atom_string(NameAtom, Name),
    atom_string(TypeAtom, TypeStr),
    assertz(guarantee(NameAtom, TypeAtom, Prov)),
    (   get_dict(default, G, DefObj),
        DefObj \= null
    ->  get_tagged_value(DefObj, DefVal, DefProv),
        parse_default(DefVal, Default),
        assertz(guarantee_default(NameAtom, Default, DefProv))
    ;   true
    ).

parse_default(Dict, hold) :-
    is_dict(Dict),
    get_dict(kind, Dict, "hold"), !.
parse_default(Dict, value(V)) :-
    is_dict(Dict),
    get_dict(kind, Dict, "value"),
    get_dict(value, Dict, V), !.
parse_default(V, value(V)).

%% --- Variables ---
assert_variables(Dict) :-
    (   get_dict(variables, Dict, List)
    ->  maplist(assert_one_variable, List)
    ;   true
    ).

assert_one_variable(V) :-
    get_tagged_value(V.name, Name, _),
    get_tagged_value(V.vtype, TypeStr, _),
    provenance_from_dict(V, Prov),
    atom_string(NameAtom, Name),
    atom_string(TypeAtom, TypeStr),
    (   get_dict(initial, V, InitObj),
        InitObj \= null
    ->  get_tagged_value(InitObj, InitVal, _),
        normalize_value(InitVal, Init)
    ;   Init = none
    ),
    assertz(variable(NameAtom, TypeAtom, Init, Prov)).

%% --- Definitions ---
assert_definitions(Dict) :-
    (   get_dict(definitions, Dict, List)
    ->  maplist(assert_one_definition, List)
    ;   true
    ).

assert_one_definition(D) :-
    get_tagged_value(D.name, Name, _),
    get_tagged_value(D.body, BodyJson, _),
    provenance_from_dict(D, Prov),
    atom_string(NameAtom, Name),
    json_to_predicate(BodyJson, Body),
    assertz(definition(NameAtom, Body, Prov)).

%% --- Always invariants ---
assert_always_invariants(Dict) :-
    (   get_dict(always_invariants, Dict, List)
    ->  maplist(assert_one_always_inv, List)
    ;   true
    ).

assert_one_always_inv(Inv) :-
    get_tagged_value(Inv.predicate, PredJson, Prov),
    json_to_predicate(PredJson, Pred),
    assertz(always_invariant(Pred, Prov)).

%% --- Initial mode ---
assert_initial_mode(Dict) :-
    (   get_dict(initial_mode, Dict, IM)
    ->  get_tagged_value(IM, Name, Prov),
        atom_string(NameAtom, Name),
        assertz(initial_mode(NameAtom, Prov))
    ;   true
    ).

%% --- Modes ---
assert_modes(Dict) :-
    (   get_dict(modes, Dict, List)
    ->  maplist(assert_one_mode, List)
    ;   true
    ).

assert_one_mode(M) :-
    get_tagged_value(M.name, Name, NameProv),
    atom_string(NameAtom, Name),
    assertz(mode(NameAtom, NameProv)),
    %% Entry actions
    (   get_dict(entry_actions, M, EAs), EAs \= []
    ->  maplist(json_to_action, EAs, Actions),
        entry_actions_provenance(EAs, EAProv),
        assertz(entry_action(NameAtom, Actions, EAProv))
    ;   true
    ),
    %% Invariants
    (   get_dict(invariants, M, Invs)
    ->  maplist(assert_mode_invariant(NameAtom), Invs)
    ;   true
    ),
    %% Transitions
    (   get_dict(transitions, M, Trans)
    ->  assert_transitions(NameAtom, Trans, 1)
    ;   true
    ).

assert_mode_invariant(ModeName, Inv) :-
    get_tagged_value(Inv.predicate, PredJson, Prov),
    json_to_predicate(PredJson, Pred),
    assertz(mode_invariant(ModeName, Pred, Prov)).

assert_transitions(_, [], _).
assert_transitions(ModeName, [T|Ts], Idx) :-
    assert_one_transition(ModeName, Idx, T),
    NextIdx is Idx + 1,
    assert_transitions(ModeName, Ts, NextIdx).

assert_one_transition(ModeName, Idx, T) :-
    %% Guard
    get_tagged_value(T.guard, GuardJson, _),
    json_to_guard(GuardJson, Guard),
    %% Actions
    get_dict(actions, T, ActionsJson),
    maplist(json_to_action, ActionsJson, Actions),
    %% Target
    get_tagged_value(T.target, TargetJson, _),
    json_to_target(TargetJson, Target),
    %% Provenance (least trusted across guard, target, actions)
    transition_provenance(T, Prov),
    assertz(transition(ModeName, Idx, Guard, Actions, Target, Prov)).

%% --- Open questions ---
assert_open_questions(Dict) :-
    (   get_dict(open_questions, Dict, List)
    ->  maplist(assert_one_question, List)
    ;   true
    ).

assert_one_question(Q) :-
    get_dict(question_id, Q, Id),
    get_dict(text, Q, Text),
    get_dict(relates_to, Q, Rel),
    get_dict(category, Q, Cat),
    (   get_dict(suggested_options, Q, Opts)
    ->  true
    ;   Opts = []
    ),
    atom_string(IdAtom, Id),
    atom_string(RelAtom, Rel),
    atom_string(CatAtom, Cat),
    assertz(open_question(IdAtom, Text, RelAtom, CatAtom, Opts)).

%% ---------------------------------------------------------------------------
%%  JSON-to-Prolog Term Converters
%% ---------------------------------------------------------------------------

%% get_tagged_value(+Dict, -Value, -Provenance)
%% Extract value and provenance from a {"value": ..., "provenance": ...} object.
get_tagged_value(Dict, Value, Prov) :-
    is_dict(Dict), !,
    get_dict(value, Dict, RawVal),
    get_dict(provenance, Dict, ProvStr),
    normalize_value(RawVal, Value),
    provenance_atom(ProvStr, Prov).
get_tagged_value(Val, NVal, llm_inferred) :-
    normalize_value(Val, NVal).

normalize_value(Val, Atom) :-
    string(Val), !,
    atom_string(Atom, Val).
normalize_value(Val, Val).

%% provenance_from_dict(+Dict, -Prov)
%% Try to extract a top-level provenance; fall back to first sub-field's provenance.
provenance_from_dict(Dict, Prov) :-
    (   get_dict(provenance, Dict, ProvStr)
    ->  provenance_atom(ProvStr, Prov)
    ;   get_dict(name, Dict, NameDict),
        is_dict(NameDict),
        get_dict(provenance, NameDict, ProvStr)
    ->  provenance_atom(ProvStr, Prov)
    ;   Prov = llm_inferred
    ).

action_provenance(ActionDict, Prov) :-
    (   get_dict(provenance, ActionDict, ProvStr)
    ->  provenance_atom(ProvStr, Prov)
    ;   Prov = llm_inferred
    ).

guard_provenance(T, Prov) :-
    (   get_dict(guard, T, GObj),
        is_dict(GObj),
        get_dict(provenance, GObj, ProvStr)
    ->  provenance_atom(ProvStr, Prov)
    ;   Prov = llm_inferred
    ).

target_provenance(T, Prov) :-
    (   get_dict(target, T, TObj),
        is_dict(TObj),
        get_dict(provenance, TObj, ProvStr)
    ->  provenance_atom(ProvStr, Prov)
    ;   Prov = llm_inferred
    ).

combine_provenance(Provs, Prov) :-
    (   member(llm_inferred, Provs)
    ->  Prov = llm_inferred
    ;   member(user_confirmed, Provs)
    ->  Prov = user_confirmed
    ;   member(user_stated, Provs)
    ->  Prov = user_stated
    ;   member(rule_derived, Provs)
    ->  Prov = rule_derived
    ;   member(default_assumed, Provs)
    ->  Prov = default_assumed
    ;   Prov = llm_inferred
    ).

transition_provenance(T, Prov) :-
    guard_provenance(T, GP),
    target_provenance(T, TP),
    (   get_dict(actions, T, Actions),
        is_list(Actions)
    ->  findall(P, (member(A, Actions), action_provenance(A, P)), AProvs),
        append([GP, TP], AProvs, Provs)
    ;   Provs = [GP, TP]
    ),
    combine_provenance(Provs, Prov).

entry_actions_provenance(EAs, Prov) :-
    findall(P, (member(A, EAs), action_provenance(A, P)), Provs),
    (   member(llm_inferred, Provs)
    ->  Prov = llm_inferred
    ;   member(user_confirmed, Provs)
    ->  Prov = user_confirmed
    ;   member(user_stated, Provs)
    ->  Prov = user_stated
    ;   Prov = llm_inferred
    ).

%% --- Guard conversion ---
json_to_guard(Dict, Guard) :-
    is_dict(Dict),
    (   get_dict(otherwise, Dict, true)
    ->  Guard = otherwise
    ;   get_dict(when, Dict, PredJson)
    ->  json_to_predicate(PredJson, Pred),
        Guard = guard(Pred)
    ;   throw(error(invalid_guard(Dict), _))
    ).

%% --- Target conversion ---
json_to_target(Dict, Target) :-
    is_dict(Dict),
    (   get_dict(transition_to, Dict, ModeStr)
    ->  atom_string(ModeAtom, ModeStr),
        Target = transition_to(ModeAtom)
    ;   get_dict(remain, Dict, true)
    ->  Target = remain
    ;   throw(error(invalid_target(Dict), _))
    ).

%% --- Predicate conversion ---
json_to_predicate(Dict, Pred) :-
    is_dict(Dict),
    get_dict(kind, Dict, KindStr),
    atom_string(Kind, KindStr),
    json_predicate_by_kind(Kind, Dict, Pred).

json_predicate_by_kind(true, _, true).
json_predicate_by_kind(false, _, false).
json_predicate_by_kind(ref, Dict, ref(Name)) :-
    get_dict(name, Dict, NameStr),
    atom_string(Name, NameStr).
json_predicate_by_kind(expr, Dict, expr(E)) :-
    get_dict(expr, Dict, EJson),
    json_to_expr(EJson, E).
json_predicate_by_kind(is_true, Dict, is_true(E)) :-
    get_dict(expr, Dict, EJson),
    json_to_expr(EJson, E).
json_predicate_by_kind(is_false, Dict, is_false(E)) :-
    get_dict(expr, Dict, EJson),
    json_to_expr(EJson, E).
json_predicate_by_kind(equals, Dict, equals(L, R)) :-
    get_dict(lhs, Dict, LJson), json_to_expr(LJson, L),
    get_dict(rhs, Dict, RJson), json_to_expr(RJson, R).
json_predicate_by_kind(exceeds, Dict, exceeds(L, R)) :-
    get_dict(lhs, Dict, LJson), json_to_expr(LJson, L),
    get_dict(rhs, Dict, RJson), json_to_expr(RJson, R).
json_predicate_by_kind(is_below, Dict, is_below(L, R)) :-
    get_dict(lhs, Dict, LJson), json_to_expr(LJson, L),
    get_dict(rhs, Dict, RJson), json_to_expr(RJson, R).
json_predicate_by_kind(deviates, Dict, deviates(V, Refs, T)) :-
    get_dict(value, Dict, VJson), json_to_expr(VJson, V),
    get_dict(references, Dict, RefList), maplist(json_to_expr, RefList, Refs),
    get_dict(threshold, Dict, TJson), json_to_expr(TJson, T).
json_predicate_by_kind(agrees, Dict, agrees(V, Refs, T)) :-
    get_dict(value, Dict, VJson), json_to_expr(VJson, V),
    get_dict(references, Dict, RefList), maplist(json_to_expr, RefList, Refs),
    get_dict(threshold, Dict, TJson), json_to_expr(TJson, T).
json_predicate_by_kind(is_one_of, Dict, is_one_of(E, Members)) :-
    get_dict(expr, Dict, EJson), json_to_expr(EJson, E),
    get_dict(members, Dict, MList),
    maplist(atom_string_safe, Members, MList).
json_predicate_by_kind(for_n_cycles, Dict, for_n_cycles(N, Base)) :-
    get_dict(n, Dict, NJson), json_to_expr(NJson, N),
    get_dict(base, Dict, BJson), json_to_predicate(BJson, Base).
json_predicate_by_kind(for_fewer, Dict, for_fewer(N, Base)) :-
    get_dict(n, Dict, NJson), json_to_expr(NJson, N),
    get_dict(base, Dict, BJson), json_to_predicate(BJson, Base).
json_predicate_by_kind(and, Dict, and(L, R)) :-
    get_dict(left, Dict, LJson), json_to_predicate(LJson, L),
    get_dict(right, Dict, RJson), json_to_predicate(RJson, R).
json_predicate_by_kind(or, Dict, or(L, R)) :-
    get_dict(left, Dict, LJson), json_to_predicate(LJson, L),
    get_dict(right, Dict, RJson), json_to_predicate(RJson, R).
json_predicate_by_kind(not, Dict, not(P)) :-
    get_dict(operand, Dict, PJson), json_to_predicate(PJson, P).

%% --- Expression conversion ---
json_to_expr(Dict, Expr) :-
    is_dict(Dict),
    get_dict(kind, Dict, KindStr),
    atom_string(Kind, KindStr),
    json_expr_by_kind(Kind, Dict, Expr).

json_expr_by_kind(int, Dict, int(V)) :-
    get_dict(value, Dict, V).
json_expr_by_kind(real, Dict, real(V)) :-
    get_dict(value, Dict, V).
json_expr_by_kind(bool, Dict, bool(V)) :-
    get_dict(value, Dict, V).
json_expr_by_kind(string, Dict, string(V)) :-
    get_dict(value, Dict, VS),
    atom_string(V, VS).
json_expr_by_kind(var, Dict, var(Name)) :-
    get_dict(name, Dict, NameStr),
    atom_string(Name, NameStr).
json_expr_by_kind(binop, Dict, binop(Op, L, R)) :-
    get_dict(op, Dict, OpStr), atom_string(Op, OpStr),
    get_dict(lhs, Dict, LJson), json_to_expr(LJson, L),
    get_dict(rhs, Dict, RJson), json_to_expr(RJson, R).
json_expr_by_kind(unop, Dict, unop(Op, E)) :-
    get_dict(op, Dict, OpStr), atom_string(Op, OpStr),
    get_dict(operand, Dict, EJson), json_to_expr(EJson, E).
json_expr_by_kind(average, Dict, average(Es)) :-
    get_dict(operands, Dict, EList), maplist(json_to_expr, EList, Es).
json_expr_by_kind(median, Dict, median(Es)) :-
    get_dict(operands, Dict, EList), maplist(json_to_expr, EList, Es).

%% --- Action conversion ---
json_to_action(Dict, Action) :-
    is_dict(Dict),
    get_dict(kind, Dict, KindStr),
    atom_string(Kind, KindStr),
    json_action_by_kind(Kind, Dict, Action).

json_action_by_kind(set, Dict, set(Name, Expr)) :-
    get_dict(name, Dict, NameStr), atom_string(Name, NameStr),
    get_dict(value, Dict, ValJson), json_to_expr(ValJson, Expr).
json_action_by_kind(hold, Dict, hold(Name)) :-
    get_dict(name, Dict, NameStr), atom_string(Name, NameStr).
json_action_by_kind(increment, Dict, increment(Name)) :-
    get_dict(name, Dict, NameStr), atom_string(Name, NameStr).
json_action_by_kind(reset, Dict, reset(Name)) :-
    get_dict(name, Dict, NameStr), atom_string(Name, NameStr).

%% --- Helper ---
atom_string_safe(Atom, Str) :- atom_string(Atom, Str).

%% ---------------------------------------------------------------------------
%%  Verdict JSON Emission: emit_verdict/1
%% ---------------------------------------------------------------------------

%% emit_verdict(+File): Collect all errors, warnings, repairs, questions
%% and write verdict.json.
emit_verdict(File) :-
    %% Collect from consistency module (loaded externally)
    findall(E, consistency:error(E), Errors),
    findall(W, consistency:warning(W), Warnings),
    findall(R, repair:repair_proposal(R), Repairs),
    findall(Q, questions:generated_question(Q), Questions),
    %% Determine status
    determine_status(Errors, Warnings, Status),
    %% Build diagnostics
    maplist(error_to_diagnostic, Errors, ErrorDiags),
    maplist(warning_to_diagnostic, Warnings, WarningDiags),
    append(ErrorDiags, WarningDiags, Diagnostics),
    %% Build repair actions
    maplist(repair_to_json, Repairs, RepairJsons),
    maplist(question_to_json, Questions, QuestionJsons),
    %% Build committed_facts and pending_facts
    build_fact_partition(CommittedFacts, PendingFacts),
    %% Build verdict dict
    Verdict = json{
        schema_version: "0.1",
        status: Status,
        diagnostics: Diagnostics,
        repairs: RepairJsons,
        questions: QuestionJsons,
        committed_facts: CommittedFacts,
        pending_facts: PendingFacts
    },
    %% Write to file
    setup_call_cleanup(
        open(File, write, Stream, [encoding(utf8)]),
        json_write_dict(Stream, Verdict, [width(80)]),
        close(Stream)
    ).

determine_status(Errors, _, "fail") :-
    Errors \= [], !.
determine_status(_, Warnings, "incomplete") :-
    member(unconfirmed(_, _), Warnings), !.
determine_status(_, Warnings, "incomplete") :-
    member(unconfirmed_default(_), Warnings), !.
determine_status(_, Warnings, "incomplete") :-
    member(unknown_value(_), Warnings), !.
determine_status(_, _, "pass").

%% ---------------------------------------------------------------------------
%%  Fact Partitioning: committed vs pending
%% ---------------------------------------------------------------------------

%% Committed provenance tags
committed_provenance(user_stated).
committed_provenance(user_confirmed).
committed_provenance(rule_derived).
committed_provenance(default_assumed).

%% build_fact_partition(-Committed, -Pending)
build_fact_partition(Committed, Pending) :-
    %% System name
    (   system_name(SN, SNProv)
    ->  (committed_provenance(SNProv) -> CSN = SN, PSN = null ; CSN = null, PSN = SN)
    ;   CSN = null, PSN = null
    ),
    %% Assumes (all have explicit provenance)
    findall(json{name: NA, atype: TA, provenance: PA},
        (assume(N, T, P), atom_string(N, NA), atom_string(T, TA), atom_string(P, PA)),
        AllAssumes),
    partition_by_prov(AllAssumes, CAssumes, PAssumes),
    %% Constants
    findall(json{name: NA, ctype: TA, cvalue: V, provenance: PA},
        (constant(N, T, V, P), atom_string(N, NA), atom_string(T, TA), atom_string(P, PA)),
        AllConstants),
    partition_by_prov(AllConstants, CConstants, PConstants),
    %% Guarantees (include default if present)
    findall(GJson,
        (guarantee(N, T, P),
         atom_string(N, NA), atom_string(T, TA), atom_string(P, PA),
         (   guarantee_default(N, Def, DefP)
         ->  atom_string(DefP, DefPA),
             default_to_json(Def, DefValJson),
             DefJson = json{value: DefValJson, provenance: DefPA}
         ;   DefJson = null
         ),
         GJson = json{name: NA, gtype: TA, provenance: PA, default: DefJson}),
        AllGuarantees),
    partition_by_prov(AllGuarantees, CGuarantees, PGuarantees),
    %% Variables
    findall(json{name: NA, vtype: TA, initial: Init, provenance: PA},
        (variable(N, T, Init, P), atom_string(N, NA), atom_string(T, TA), atom_string(P, PA)),
        AllVariables),
    partition_by_prov(AllVariables, CVariables, PVariables),
    %% Modes (with entry_actions, invariants, transitions)
    findall(MN-ModeJson,
        (mode(MN, MP),
         atom_string(MN, MNA), atom_string(MP, MPA),
         %% Entry actions for this mode
         (   entry_action(MN, EActs, _EAProv)
         ->  maplist(action_to_json, EActs, EAJsons)
         ;   EAJsons = []
         ),
         %% Invariants for this mode
         findall(InvJson,
             (mode_invariant(MN, InvPred, _InvProv),
              predicate_to_json(InvPred, InvPredJson),
              InvJson = json{predicate: InvPredJson}),
             InvJsons),
         %% Transitions for this mode (sorted by Idx)
         findall(Idx-TrJson,
             (transition(MN, Idx, Guard, Actions, Target, _TProv),
              guard_to_json(Guard, GuardJson),
              maplist(action_to_json, Actions, ActJsons),
              target_to_json(Target, TargetJson),
              TrJson = json{guard: GuardJson, actions: ActJsons, target: TargetJson}),
             IdxTrs),
         msort(IdxTrs, SortedIdxTrs),
         pairs_values(SortedIdxTrs, TrJsons),
         ModeJson = json{name: MNA, provenance: MPA,
                         entry_actions: EAJsons,
                         invariants: InvJsons,
                         transitions: TrJsons}),
        AllModePairs),
    partition_mode_pairs(AllModePairs, CModes, PModes),
    %% Initial mode
    (   initial_mode(IM, IMProv)
    ->  atom_string(IM, IMA), atom_string(IMProv, IMPA),
        (committed_provenance(IMProv) -> CIM = json{value: IMA, provenance: IMPA}, PIM = null
        ;   CIM = null, PIM = json{value: IMA, provenance: IMPA})
    ;   CIM = null, PIM = null
    ),
    %% Definitions
    findall(json{name: NA, body: BodyJson, provenance: PA},
        (definition(N, Body, P),
         atom_string(N, NA), atom_string(P, PA),
         predicate_to_json(Body, BodyJson)),
        AllDefinitions),
    partition_by_prov(AllDefinitions, CDefinitions, PDefinitions),
    %% Always invariants
    findall(json{predicate: PredJson, provenance: PA},
        (always_invariant(Pred, P),
         atom_string(P, PA),
         predicate_to_json(Pred, PredJson)),
        AllAlwaysInvariants),
    partition_by_prov(AllAlwaysInvariants, CAlwaysInvariants, PAlwaysInvariants),
    %% Build result dicts
    Committed = json{
        schema_version: "0.1",
        system_name: CSN,
        assumes: CAssumes,
        definitions: CDefinitions,
        constants: CConstants,
        guarantees: CGuarantees,
        variables: CVariables,
        always_invariants: CAlwaysInvariants,
        modes: CModes,
        initial_mode: CIM
    },
    Pending = json{
        schema_version: "0.1",
        system_name: PSN,
        assumes: PAssumes,
        definitions: PDefinitions,
        constants: PConstants,
        guarantees: PGuarantees,
        variables: PVariables,
        always_invariants: PAlwaysInvariants,
        modes: PModes,
        initial_mode: PIM
    }.

partition_by_prov(All, Committed, Pending) :-
    include(is_committed, All, Committed),
    exclude(is_committed, All, Pending).

partition_mode_pairs(AllPairs, Committed, Pending) :-
    include(mode_pair_committed, AllPairs, CommittedPairs),
    exclude(mode_pair_committed, AllPairs, PendingPairs),
    pairs_values(CommittedPairs, Committed),
    pairs_values(PendingPairs, Pending).

mode_pair_committed(MN-_) :-
    mode(MN, MP),
    committed_provenance(MP),
    \+ mode_has_uncommitted(MN).

mode_has_uncommitted(MN) :-
    (transition(MN, _, _, _, _, P), \+ committed_provenance(P));
    (mode_invariant(MN, _, P), \+ committed_provenance(P));
    (entry_action(MN, _, P), \+ committed_provenance(P)).

is_committed(Dict) :-
    get_dict(provenance, Dict, ProvStr),
    atom_string(Prov, ProvStr),
    committed_provenance(Prov).

%% default_to_json(+Default, -Json)
default_to_json(hold, json{kind: "hold"}).
default_to_json(value(V), json{kind: "value", value: V}).

%% --- Diagnostic serialization ---
error_to_diagnostic(empty_mode(M), json{
    severity: "error", code: "empty_mode",
    message: Msg,
    location: json{kind: "mode", name: MA, transition_idx: null}
}) :-
    atom_string(M, MA),
    format(atom(Msg), "Mode '~w' has no transitions", [M]).

error_to_diagnostic(guard_incomplete(M), json{
    severity: "error", code: "guard_incomplete",
    message: Msg,
    location: json{kind: "mode", name: MA, transition_idx: null}
}) :-
    atom_string(M, MA),
    format(atom(Msg), "Mode '~w' has no Otherwise clause", [M]).

error_to_diagnostic(missing_assignment(M, Idx, G), json{
    severity: "error", code: "missing_assignment",
    message: Msg,
    location: json{kind: "mode", name: MA, transition_idx: Idx}
}) :-
    atom_string(M, MA),
    format(atom(Msg), "Transition ~w in mode '~w' missing assignment for '~w'", [Idx, M, G]).

error_to_diagnostic(type_mismatch(M, Idx, G, Expected, Got), json{
    severity: "error", code: "type_mismatch",
    message: Msg,
    location: json{kind: "mode", name: MA, transition_idx: Idx}
}) :-
    atom_string(M, MA),
    format(atom(Msg),
           "Type mismatch in mode '~w' transition ~w: guarantee '~w' expects ~w, got ~w",
           [M, Idx, G, Expected, Got]).

error_to_diagnostic(invalid_target(M, Idx, Target), json{
    severity: "error", code: "invalid_target",
    message: Msg,
    location: json{kind: "mode", name: MA, transition_idx: Idx}
}) :-
    atom_string(M, MA),
    format(atom(Msg), "Transition ~w in mode '~w' targets undeclared mode '~w'", [Idx, M, Target]).

error_to_diagnostic(invalid_initial(M), json{
    severity: "error", code: "invalid_initial",
    message: Msg,
    location: json{kind: "initial_mode", name: MA, transition_idx: null}
}) :-
    atom_string(M, MA),
    format(atom(Msg), "Initial mode '~w' is not declared", [M]).

error_to_diagnostic(duplicate(Name, Kind1, Kind2), json{
    severity: "error", code: "duplicate",
    message: Msg,
    location: json{kind: "declaration", name: NA, transition_idx: null}
}) :-
    atom_string(Name, NA),
    format(atom(Msg), "Duplicate declaration '~w' (as ~w and ~w)", [Name, Kind1, Kind2]).

error_to_diagnostic(undeclared_ref(Name, Context), json{
    severity: "error", code: "undeclared_ref",
    message: Msg,
    location: json{kind: "reference", name: NA, transition_idx: null}
}) :-
    atom_string(Name, NA),
    format(atom(Msg), "Undeclared reference '~w' in ~w", [Name, Context]).

error_to_diagnostic(no_initial_mode, json{
    severity: "error", code: "no_initial_mode",
    message: "No initial mode declared",
    location: json{kind: "spec", name: "", transition_idx: null}
}).

%% Catch-all for any unhandled error terms
error_to_diagnostic(E, json{
    severity: "error", code: "unknown",
    message: Msg,
    location: json{kind: "unknown", name: "", transition_idx: null}
}) :-
    format(atom(Msg), "~w", [E]).

warning_to_diagnostic(unknown_value(Name), json{
    severity: "warning", code: "unknown_value",
    message: Msg,
    location: json{kind: "constant", name: NA, transition_idx: null}
}) :-
    atom_string(Name, NA),
    format(atom(Msg), "Constant '~w' has unknown value", [Name]).

warning_to_diagnostic(unconfirmed(Name, Kind), json{
    severity: "warning", code: "unconfirmed",
    message: Msg,
    location: json{kind: KA, name: NA, transition_idx: null}
}) :-
    atom_string(Name, NA),
    atom_string(Kind, KA),
    format(atom(Msg), "LLM inferred ~w '~w'", [Kind, Name]).

warning_to_diagnostic(unconfirmed_default(Name), json{
    severity: "warning", code: "unconfirmed_default",
    message: Msg,
    location: json{kind: "guarantee", name: NA, transition_idx: null}
}) :-
    atom_string(Name, NA),
    format(atom(Msg), "LLM inferred default for guarantee '~w'", [Name]).

warning_to_diagnostic(possibly_overlapping_guards(M, I, J), json{
    severity: "warning", code: "overlapping_guards",
    message: Msg,
    location: json{kind: "mode", name: MA, transition_idx: I}
}) :-
    atom_string(M, MA),
    format(atom(Msg), "Guards ~w and ~w in mode '~w' may overlap", [I, J, M]).

warning_to_diagnostic(type_mismatch(M, Idx, G, Expected, Got), json{
    severity: "warning", code: "type_mismatch",
    message: Msg,
    location: json{kind: "mode", name: MA, transition_idx: Idx}
}) :-
    atom_string(M, MA),
    format(atom(Msg), "Type mismatch in mode '~w' transition ~w: guarantee '~w' expects ~w, got ~w",
           [M, Idx, G, Expected, Got]).

warning_to_diagnostic(unreachable_mode(M), json{
    severity: "warning", code: "unreachable_mode",
    message: Msg,
    location: json{kind: "mode", name: MA, transition_idx: null}
}) :-
    atom_string(M, MA),
    format(atom(Msg), "Mode '~w' is unreachable from initial mode", [M]).

warning_to_diagnostic(unused(Name, Kind), json{
    severity: "warning", code: "unused",
    message: Msg,
    location: json{kind: KA, name: NA, transition_idx: null}
}) :-
    atom_string(Name, NA),
    atom_string(Kind, KA),
    format(atom(Msg), "~w '~w' is declared but never referenced", [Kind, Name]).

%% Catch-all
warning_to_diagnostic(W, json{
    severity: "warning", code: "unknown",
    message: Msg,
    location: json{kind: "unknown", name: "", transition_idx: null}
}) :-
    format(atom(Msg), "~w", [W]).

%% --- Repair serialization ---
repair_to_json(repair(Diag, Action, ReqConfirm), json{
    for_diagnostic: DiagStr,
    action: ActionJson,
    provenance: "rule_derived",
    requires_confirmation: ReqConfirm
}) :-
    format(atom(DiagStr), "~w", [Diag]),
    repair_action_to_json(Action, ActionJson).

repair_action_to_json(add_otherwise(M, Actions), json{
    action: "add_otherwise", mode: MA, actions: ActJsons
}) :-
    atom_string(M, MA),
    maplist(action_to_json, Actions, ActJsons).

repair_action_to_json(add_action(M, Idx, Act), json{
    action: "add_action", mode: MA, transition_idx: Idx,
    action_to_add: ActJson
}) :-
    atom_string(M, MA),
    action_to_json(Act, ActJson).

repair_action_to_json(suggest_target(M, Idx, Candidates), json{
    action: "suggest_target", mode: MA, transition_idx: Idx,
    candidates: CandStrs
}) :-
    atom_string(M, MA),
    maplist(atom_string, Candidates, CandStrs).

repair_action_to_json(add_mode(Name), json{
    action: "add_mode", name: NA
}) :-
    atom_string(Name, NA).

repair_action_to_json(add_transition(M, Guard, Actions, Target), json{
    action: "add_transition", mode: MA,
    guard: GuardJson, actions: ActJsons, target: TargetJson
}) :-
    atom_string(M, MA),
    guard_to_json(Guard, GuardJson),
    maplist(action_to_json, Actions, ActJsons),
    target_to_json(Target, TargetJson).

repair_action_to_json(ask_user(Name, _Question), json{
    action: "ask_user", name: NA
}) :-
    atom_string(Name, NA).

%% Catch-all
repair_action_to_json(Action, json{action: "unknown", raw: Str}) :-
    format(atom(Str), "~w", [Action]).

%% --- Action/guard/target to JSON ---
action_to_json(set(Name, Expr), json{kind: "set", name: NA, value: ExprJson}) :-
    atom_string(Name, NA), expr_to_json(Expr, ExprJson).
action_to_json(hold(Name), json{kind: "hold", name: NA}) :-
    atom_string(Name, NA).
action_to_json(increment(Name), json{kind: "increment", name: NA}) :-
    atom_string(Name, NA).
action_to_json(reset(Name), json{kind: "reset", name: NA}) :-
    atom_string(Name, NA).

guard_to_json(otherwise, json{otherwise: true}).
guard_to_json(guard(Pred), json{when: PredJson}) :-
    predicate_to_json(Pred, PredJson).

target_to_json(remain, json{remain: true}).
target_to_json(transition_to(M), json{transition_to: MA}) :-
    atom_string(M, MA).

%% --- Predicate to JSON ---
predicate_to_json(true, json{kind: "true"}).
predicate_to_json(false, json{kind: "false"}).
predicate_to_json(ref(N), json{kind: "ref", name: NA}) :-
    atom_string(N, NA).
predicate_to_json(expr(E), json{kind: "expr", expr: EJ}) :-
    expr_to_json(E, EJ).
predicate_to_json(is_true(E), json{kind: "is_true", expr: EJ}) :-
    expr_to_json(E, EJ).
predicate_to_json(is_false(E), json{kind: "is_false", expr: EJ}) :-
    expr_to_json(E, EJ).
predicate_to_json(equals(L, R), json{kind: "equals", lhs: LJ, rhs: RJ}) :-
    expr_to_json(L, LJ), expr_to_json(R, RJ).
predicate_to_json(exceeds(L, R), json{kind: "exceeds", lhs: LJ, rhs: RJ}) :-
    expr_to_json(L, LJ), expr_to_json(R, RJ).
predicate_to_json(is_below(L, R), json{kind: "is_below", lhs: LJ, rhs: RJ}) :-
    expr_to_json(L, LJ), expr_to_json(R, RJ).
predicate_to_json(deviates(V, Refs, T), json{kind: "deviates", value: VJ, references: RJs, threshold: TJ}) :-
    expr_to_json(V, VJ), maplist(expr_to_json, Refs, RJs), expr_to_json(T, TJ).
predicate_to_json(agrees(V, Refs, T), json{kind: "agrees", value: VJ, references: RJs, threshold: TJ}) :-
    expr_to_json(V, VJ), maplist(expr_to_json, Refs, RJs), expr_to_json(T, TJ).
predicate_to_json(is_one_of(E, Ms), json{kind: "is_one_of", expr: EJ, members: MSs}) :-
    expr_to_json(E, EJ), maplist(atom_string, Ms, MSs).
predicate_to_json(for_n_cycles(N, B), json{kind: "for_n_cycles", n: NJ, base: BJ}) :-
    expr_to_json(N, NJ), predicate_to_json(B, BJ).
predicate_to_json(for_fewer(N, B), json{kind: "for_fewer", n: NJ, base: BJ}) :-
    expr_to_json(N, NJ), predicate_to_json(B, BJ).
predicate_to_json(and(L, R), json{kind: "and", left: LJ, right: RJ}) :-
    predicate_to_json(L, LJ), predicate_to_json(R, RJ).
predicate_to_json(or(L, R), json{kind: "or", left: LJ, right: RJ}) :-
    predicate_to_json(L, LJ), predicate_to_json(R, RJ).
predicate_to_json(not(P), json{kind: "not", operand: PJ}) :-
    predicate_to_json(P, PJ).

%% --- Expression to JSON ---
expr_to_json(int(V), json{kind: "int", value: V}).
expr_to_json(real(V), json{kind: "real", value: V}).
expr_to_json(bool(V), json{kind: "bool", value: V}).
expr_to_json(string(V), json{kind: "string", value: VA}) :-
    atom_string(V, VA).
expr_to_json(var(N), json{kind: "var", name: NA}) :-
    atom_string(N, NA).
expr_to_json(binop(Op, L, R), json{kind: "binop", op: OA, lhs: LJ, rhs: RJ}) :-
    atom_string(Op, OA), expr_to_json(L, LJ), expr_to_json(R, RJ).
expr_to_json(unop(Op, E), json{kind: "unop", op: OA, operand: EJ}) :-
    atom_string(Op, OA), expr_to_json(E, EJ).
expr_to_json(average(Es), json{kind: "average", operands: EJs}) :-
    maplist(expr_to_json, Es, EJs).
expr_to_json(median(Es), json{kind: "median", operands: EJs}) :-
    maplist(expr_to_json, Es, EJs).

%% --- Question serialization ---
question_to_json(question(Id, Text, Rel, Cat, Opts), json{
    question_id: IdS, text: Text,
    relates_to: RelS, category: CatS,
    suggested_options: Opts
}) :-
    atom_string(Id, IdS),
    atom_string(Rel, RelS),
    atom_string(Cat, CatS).

%% ---------------------------------------------------------------------------
%%  Utility: atom_edit_distance/3
%% ---------------------------------------------------------------------------

%% atom_edit_distance(+Atom1, +Atom2, -Distance)
%% Compute Levenshtein edit distance between two atoms.
atom_edit_distance(A1, A2, Distance) :-
    atom_codes(A1, Codes1),
    atom_codes(A2, Codes2),
    levenshtein_codes(Codes1, Codes2, Distance).

:- table levenshtein_codes/3.
levenshtein_codes([], Cs, Len) :- length(Cs, Len).
levenshtein_codes(Cs, [], Len) :- length(Cs, Len).
levenshtein_codes([C1|R1], [C2|R2], Dist) :-
    (   C1 =:= C2
    ->  levenshtein_codes(R1, R2, Dist)
    ;   levenshtein_codes(R1, [C2|R2], D1),
        levenshtein_codes([C1|R1], R2, D2),
        levenshtein_codes(R1, R2, D3),
        Min is min(D1, min(D2, D3)),
        Dist is Min + 1
    ).
