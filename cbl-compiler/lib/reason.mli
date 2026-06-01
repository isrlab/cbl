(** reason.ml — merged Layer 2 reasoning engine.

    Replaces the SWI-Prolog reasoning engine (cbl-prolog). Reads the flat
    [extracted_facts.json] (every value tagged with provenance), runs the
    consistency rules and well-posedness checker, partitions facts into
    committed/pending by provenance, generates repairs and questions, and
    writes [verdict.json].

    Built incrementally (verifier-merge plan). Steps landed so far:
      1. scaffold + CLI subcommand + differential-test harness
      2. provenance-aware ingestion of extracted_facts.json (this file) *)

open Ast

(** One of the seven provenance tags (extracted_facts.schema.json). *)
type provenance = string

(** Provenance of a single named declaration, keyed by [kind] and [pname].
    Kinds mirror cbl-prolog's provenance_of/3: assume, constant, guarantee,
    guarantee_default, variable, definition, mode, transition (pname =
    "Mode_Idx"), entry_action (pname = mode), mode_invariant (pname = mode),
    always_invariant (pname = "global"), initial_mode, system_name. *)
type prov_entry = { kind : string; pname : string; provenance : provenance }

(** An LLM-proposed clarification question, passed through to the verdict. *)
type question = {
  qid : string;
  text : string;
  relates_to : string;
  category : string;
  options : string list;
}

(** Result of ingesting extracted_facts.json: the provenance-free AST plus a
    side table of per-fact provenance and the pass-through questions. *)
type ingested = {
  spec : spec;
  provs : prov_entry list;
  questions : question list;
}

(** Ingest a parsed extracted_facts.json document. Assumes the caller has
    already enforced the schema_version / provenance_attested gate. Returns
    [Error] with accumulated messages if any fact is malformed. *)
val ingest : Yojson.Safe.t -> (ingested, string list) result

(** A verdict diagnostic. *)
type diagnostic = {
  severity : string;  (** "error" | "warning" *)
  code : string;
  message : string;
  loc_kind : string;
  loc_name : string;
  loc_idx : int option;
}

val diagnostic_to_json : diagnostic -> Yojson.Safe.t

(** {2 Serializers (AST -> Prolog-shaped facts JSON)}

    Inverses of [Nlp_bridge]'s parsers. Output is re-ingestible by
    {!Nlp_bridge.ingest_facts}; used to emit the verdict's committed/pending
    fact partitions and the structured repair actions. *)

val type_to_string : cbl_type -> string
val expr_to_json : expr -> Yojson.Safe.t
val predicate_to_json : predicate -> Yojson.Safe.t
val action_to_json : action -> Yojson.Safe.t
val guard_to_json : guard -> Yojson.Safe.t
val target_to_json : target -> Yojson.Safe.t

(** Serialize a (sub)spec to a fact_partition object; [prov_of kind name]
    supplies each fact's provenance string. *)
val fact_partition_json : (string -> string -> provenance) -> spec -> Yojson.Safe.t

(** Provenance of a fact, or "llm_inferred" if absent from the table. *)
val prov_lookup : ingested -> string -> string -> provenance

(** Partition the ingested spec into (committed, pending) sub-specs by
    provenance (cbl-prolog build_fact_partition). A mode is committed only if
    its own provenance is committed and none of its transitions, invariants or
    entry actions is uncommitted. *)
val partition : ingested -> spec * spec

(** A proposed repair (cbl-prolog repair.pl). [for_diagnostic] reproduces
    Prolog's term printing (e.g. "unconfirmed(n_fault,constant)"), which
    session.py greps to track confirmations. *)
type repair = {
  for_diagnostic : string;
  action : Yojson.Safe.t;
  requires_confirmation : bool;
}

val repair_to_json : repair -> Yojson.Safe.t

(** Generate repairs from the spec's syntactic conditions and the reasoning
    diagnostics (ask_user repairs). *)
val repairs : ingested -> diagnostic list -> repair list

(** Verdict questions: pass-through open questions plus questions derived from
    the confirmation/value diagnostics (cbl-prolog questions.pl). *)
val questions_json : ingested -> diagnostic list -> Yojson.Safe.t list

(** Assemble the full verdict JSON (status, diagnostics, repairs, questions,
    committed/pending facts) and the process exit code (0 = pass, 1 = fail or
    incomplete). *)
val verdict : ingested -> Yojson.Safe.t * int

(** Consistency rules not covered by {!Checker.check}: R1 (empty mode),
    R5b (no initial mode declared), R13 (unused declaration), and the
    provenance rules R8/R9/R9b. *)
val reasoning_diagnostics : ingested -> diagnostic list

(** Run the reasoning engine: read extracted_facts JSON from [input],
    write verdict JSON to [output]. Returns the process exit code,
    matching cbl-prolog/run.pl: 0 = pass, 1 = fail/incomplete, 2 = error. *)
val run : input:string -> output:string -> int
