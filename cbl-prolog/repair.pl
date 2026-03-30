%% repair.pl — Repair rule database for the CBL Prolog reasoning engine.
%%
%% For each error/warning class, proposes minimal repairs.
%% Produces repair_proposal/1 terms consumed by bridge:emit_verdict.

:- module(repair, [
    repair_proposal/1
]).

:- use_module(library(lists)).
:- use_module(library(apply)).
:- use_module(bridge).
:- use_module(consistency).

:- discontiguous repair_proposal/1.

%% repair_proposal(-Repair): Repair is repair(Diagnostic, Action, RequiresConfirmation).

%% --- Incomplete guards: propose adding Otherwise clause ---
repair_proposal(repair(guard_incomplete(M), add_otherwise(M, Actions), true)) :-
    consistency:error(guard_incomplete(M)),
    findall(G, (bridge:guarantee(G, _, _), \+ bridge:guarantee_default(G, _, _)), Gs),
    maplist(hold_action, Gs, Actions).

hold_action(G, hold(G)).

%% --- Missing assignment: propose hold ---
repair_proposal(repair(missing_assignment(M, Idx, G), add_action(M, Idx, hold(G)), true)) :-
    consistency:error(missing_assignment(M, Idx, G)).

%% --- Invalid target: suggest closest mode name ---
repair_proposal(repair(invalid_target(M, Idx, Target), suggest_target(M, Idx, Candidates), true)) :-
    consistency:error(invalid_target(M, Idx, Target)),
    findall(C, (bridge:mode(C, _), bridge:atom_edit_distance(Target, C, D), D =< 3), Candidates),
    Candidates \= [].

%% --- Invalid target: propose adding the mode ---
repair_proposal(repair(invalid_target(M, Idx, Target), add_mode(Target), true)) :-
    consistency:error(invalid_target(M, Idx, Target)),
    \+ bridge:mode(Target, _).

%% --- Empty mode: propose adding a default remain transition ---
%% (Subsumes guard_incomplete since R2 is now conditional on \+ empty_mode)
repair_proposal(repair(empty_mode(M), add_transition(M, otherwise, HoldActions, remain), true)) :-
    consistency:error(empty_mode(M)),
    findall(G, (bridge:guarantee(G, _, _), \+ bridge:guarantee_default(G, _, _)), Gs),
    maplist(hold_action, Gs, HoldActions).

%% --- Unknown constant value: generate question ---
repair_proposal(repair(unknown_value(Name), ask_user(Name, question(
    Id, Text, Name, missing_value, []
)), true)) :-
    consistency:warning(unknown_value(Name)),
    atom_concat('repair_unknown_', Name, Id),
    format(atom(Text), "What value should constant '~w' have?", [Name]).

%% --- Unconfirmed inference: generate confirmation question ---
repair_proposal(repair(unconfirmed(Name, Kind), ask_user(Name, question(
    Id, Text, Name, confirm_inference, ["Yes", "No"]
)), true)) :-
    consistency:warning(unconfirmed(Name, Kind)),
    atom_concat('repair_confirm_', Name, Id),
    format(atom(Text), "The LLM inferred ~w '~w'. Is this correct?", [Kind, Name]).

%% --- Unconfirmed default: generate confirmation question ---
repair_proposal(repair(unconfirmed_default(Name), ask_user(Name, question(
    Id, Text, Name, confirm_default, ["Yes", "No"]
)), true)) :-
    consistency:warning(unconfirmed_default(Name)),
    atom_concat('repair_confirm_default_', Name, Id),
    format(atom(Text), "The LLM inferred a default for guarantee '~w'. Is this correct?", [Name]).

%% --- No initial mode: ask user ---
repair_proposal(repair(no_initial_mode, ask_user(initial_mode, question(
    repair_no_initial_mode, "Which mode should be the initial mode?",
    initial_mode, missing_value, []
)), true)) :-
    consistency:error(no_initial_mode).
