%% run.pl — Entry point for the CBL Prolog reasoning engine.
%%
%% Usage:
%%   swipl -g main -t halt cbl-prolog/run.pl -- --input FILE --output FILE
%%
%% Exit codes:
%%   0 = pass
%%   1 = fail or incomplete
%%   2 = schema/runtime error

:- use_module(bridge).
:- use_module(consistency).
:- use_module(repair).
:- use_module(questions).
:- use_module(provenance).

main :-
    catch(
        run_main(ExitCode),
        Error,
        (   print_message(error, Error),
            halt(2)
        )
    ),
    halt(ExitCode).

run_main(ExitCode) :-
    parse_args(InputFile, OutputFile),
    bridge:load_facts(InputFile),
    bridge:emit_verdict(OutputFile),
    %% Determine exit code from verdict status
    findall(E, consistency:error(E), Errors),
    (   Errors \= []
    ->  ExitCode = 1
    ;   findall(W, consistency:warning(W), Warnings),
        (   member(unconfirmed(_, _), Warnings)
        ->  ExitCode = 1
        ;   member(unconfirmed_default(_), Warnings)
        ->  ExitCode = 1
        ;   member(unknown_value(_), Warnings)
        ->  ExitCode = 1
        ;   ExitCode = 0
        )
    ).

%% parse_args(-InputFile, -OutputFile)
%% Parse command-line arguments: --input FILE --output FILE
parse_args(Input, Output) :-
    current_prolog_flag(argv, Argv),
    parse_arg_list(Argv, Input, Output),
    (   var(Input)
    ->  throw(error(missing_argument('--input'), _))
    ;   true
    ),
    (   var(Output)
    ->  throw(error(missing_argument('--output'), _))
    ;   true
    ).

parse_arg_list([], _, _).
parse_arg_list(['--input', File | Rest], File, Output) :-
    !, parse_arg_list(Rest, _, Output).
parse_arg_list(['--output', File | Rest], Input, File) :-
    !, parse_arg_list(Rest, Input, _).
parse_arg_list([_ | Rest], Input, Output) :-
    parse_arg_list(Rest, Input, Output).
