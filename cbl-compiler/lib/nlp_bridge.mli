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
