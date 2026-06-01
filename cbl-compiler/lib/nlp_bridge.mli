(** nlp_bridge.mli — Interface between Prolog verdict and OCaml compiler.

    Layer 3 of the NLP-to-CBL pipeline. Ingests committed facts from
    verdict.json, validates them, and emits canonical CBL text. *)

open Ast

(** Ingest committed facts from verdict.json into a typed AST.
    Reads the "committed_facts" section of the verdict JSON.
    Returns Ok spec if all facts are well-typed and complete.
    Returns Error with diagnostics if any fact fails validation. *)
val ingest_facts : Yojson.Safe.t -> (spec, string list) result

(** Run the full well-posedness checker on the constructed AST.
    This is the final acceptance gate before CBL emission. *)
val validate : spec -> Checker.check_result

(** Emit canonical CBL text from a validated AST.
    Only called after validate returns zero errors. *)
val emit_cbl : spec -> string

(** Produce structured diagnostic JSON from checker errors.
    Fed back to Prolog or LLM for the next repair iteration. *)
val diagnostics_to_json : Checker.check_result -> Yojson.Safe.t

(** {2 Shared term parsers}

    The Prolog-shaped JSON term encoding (expr/predicate/guard/action/target
    and CBL type strings) is shared between committed-facts ingestion (above)
    and the merged reasoning engine ([Reason]). These are exposed so [Reason]
    can ingest extracted_facts.json without duplicating ~250 lines of parsing. *)

val parse_type : string -> (cbl_type, string) result
val parse_expr : Yojson.Safe.t -> (expr, string) result
val parse_predicate : Yojson.Safe.t -> (predicate, string) result
val parse_guard : Yojson.Safe.t -> (guard, string) result
val parse_action_list : Yojson.Safe.t -> (action list, string) result
val parse_target : Yojson.Safe.t -> (target, string) result
val parse_default : ?depth:int -> Yojson.Safe.t -> (expr option, string) result
