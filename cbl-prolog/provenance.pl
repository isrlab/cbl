%% provenance.pl — Transitive provenance tracking (§4.6).
%%
%% Computes derived provenance from premise provenances.

:- module(provenance, [
    derive_provenance/2,
    weakest_provenance/2,
    provenance_rank/2
]).

%% Provenance lattice: user_stated > user_confirmed > default_assumed > llm_inferred.
provenance_rank(user_stated, 4).
provenance_rank(user_confirmed, 3).
provenance_rank(default_assumed, 2).
provenance_rank(rule_derived, 3).      % treated as user_confirmed rank
provenance_rank(llm_inferred, 1).
provenance_rank(unknown, 0).

weakest_provenance([], rule_derived).
weakest_provenance([P|Ps], Result) :-
    weakest_provenance(Ps, Rest),
    provenance_rank(P, Rp),
    provenance_rank(Rest, Rr),
    (Rp =< Rr -> Result = P ; Result = Rest).

%% A derived fact whose weakest premise is llm_inferred gets rule_derived_pending.
derive_provenance(Premises, rule_derived_pending) :-
    weakest_provenance(Premises, W),
    provenance_rank(W, R),
    R =< 1, !.
derive_provenance(_, rule_derived).
