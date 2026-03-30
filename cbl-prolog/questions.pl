%% questions.pl — Question generation for the CBL Prolog reasoning engine.
%%
%% Merges open questions from LLM output with repair-generated questions.
%% Produces generated_question/1 terms consumed by bridge:emit_verdict.

:- module(questions, [
    generated_question/1
]).

:- use_module(bridge).
:- use_module(consistency).
:- use_module(repair).

%% generated_question(-Q): Q is question(Id, Text, RelatesTo, Category, Options).

%% Pass through open questions from the LLM extraction.
generated_question(question(Id, Text, Rel, Cat, Opts)) :-
    bridge:open_question(Id, Text, Rel, Cat, Opts).

%% Generate questions from repair proposals that involve asking the user.
generated_question(question(Id, Text, Rel, Cat, Opts)) :-
    repair:repair_proposal(repair(_, ask_user(_, question(Id, Text, Rel, Cat, Opts)), _)).
