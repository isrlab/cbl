(** reason.ml — merged Layer 2 reasoning engine (replaces cbl-prolog).

    Step 2: provenance-aware ingestion of extracted_facts.json. Later steps
    add rules, partitioning, repairs, questions and status determination; for
    now [run] still emits a stub verdict after ingesting. *)

open Ast

let exit_error = 2  (* read/schema/attestation error; matches cbl-prolog run.pl *)

type provenance = string

type prov_entry = { kind : string; pname : string; provenance : provenance }

type question = {
  qid : string;
  text : string;
  relates_to : string;
  category : string;
  options : string list;
}

type ingested = {
  spec : spec;
  provs : prov_entry list;
  questions : question list;
}

(* ------------------------------------------------------------------ *)
(*  Small JSON accessors (option-based)                                *)
(* ------------------------------------------------------------------ *)

let field key = function
  | `Assoc pairs -> List.assoc_opt key pairs
  | _ -> None

let as_list = function `List l -> l | _ -> []
let as_string = function `String s -> Some s | _ -> None

(* (value, provenance) from a provenanced field; a bare value -> llm_inferred,
   mirroring cbl-prolog bridge.pl:get_tagged_value. *)
let tagged (json : Yojson.Safe.t) : Yojson.Safe.t * provenance =
  match json with
  | `Assoc pairs -> (
      match List.assoc_opt "value" pairs, List.assoc_opt "provenance" pairs with
      | Some v, Some (`String p) -> (v, p)
      | _ -> (json, "llm_inferred"))
  | _ -> (json, "llm_inferred")

(* Combine provenance of parts: llm_inferred dominates, then user_confirmed,
   user_stated, rule_derived, default_assumed (bridge.pl:combine_provenance). *)
let combine_provenance (ps : provenance list) : provenance =
  if List.mem "llm_inferred" ps then "llm_inferred"
  else if List.mem "user_confirmed" ps then "user_confirmed"
  else if List.mem "user_stated" ps then "user_stated"
  else if List.mem "rule_derived" ps then "rule_derived"
  else if List.mem "default_assumed" ps then "default_assumed"
  else "llm_inferred"

let action_prov item =
  match field "provenance" item with Some (`String p) -> p | _ -> "llm_inferred"

(* ------------------------------------------------------------------ *)
(*  Ingestion: extracted_facts.json -> (spec, prov table, questions)   *)
(* ------------------------------------------------------------------ *)

let ingest (json : Yojson.Safe.t) : (ingested, string list) result =
  let errs = ref [] in
  let err m = errs := m :: !errs in
  let provs = ref [] in
  let add_prov kind pname provenance =
    provs := { kind; pname; provenance } :: !provs
  in

  let list_field key = match field key json with Some j -> as_list j | None -> [] in

  (* Extract a provenanced string field -> (value, provenance). *)
  let prov_string obj key =
    match field key obj with
    | None -> None
    | Some j -> (
        let v, p = tagged j in
        match as_string v with
        | Some s -> Some (s, p)
        | None -> err (Printf.sprintf "%s: expected a string value" key); None)
  in

  (* Extract a provenanced CBL type field -> cbl_type. *)
  let prov_type obj key ctx =
    match field key obj with
    | None -> err (Printf.sprintf "%s: missing %s" ctx key); None
    | Some j -> (
        let v, _ = tagged j in
        match as_string v with
        | Some ts -> (
            match Nlp_bridge.parse_type ts with
            | Ok t -> Some t
            | Error m -> err m; None)
        | None -> err (Printf.sprintf "%s: %s is not a string" ctx key); None)
  in

  (* System name (optional). *)
  let system_name =
    match prov_string json "system_name" with
    | Some (s, p) -> add_prov "system_name" s p; s
    | None -> "Unnamed"
  in

  (* Assumes. *)
  let assumes =
    List.filter_map (fun item ->
      match prov_string item "name" with
      | None -> err "assume: missing name"; None
      | Some (nm, nprov) -> (
          match prov_type item "atype" (Printf.sprintf "assume '%s'" nm) with
          | Some atype -> add_prov "assume" nm nprov; Some { name = nm; atype; loc = None }
          | None -> None))
      (list_field "assumes")
  in

  (* Constants. *)
  let constants =
    List.filter_map (fun item ->
      match prov_string item "name" with
      | None -> err "constant: missing name"; None
      | Some (nm, nprov) ->
          let ctype = prov_type item "ctype" (Printf.sprintf "constant '%s'" nm) in
          let value =
            match field "cvalue" item with
            | None -> err (Printf.sprintf "constant '%s': missing cvalue" nm); None
            | Some j -> (
                let v, _ = tagged j in
                match Nlp_bridge.parse_expr v with
                | Ok e -> Some e
                | Error m -> err m; None)
          in
          (match ctype, value with
           | Some ctype, Some value ->
               add_prov "constant" nm nprov;
               Some { name = nm; ctype; value; loc = None }
           | _ -> None))
      (list_field "constants")
  in

  (* Guarantees (with optional default annotation). *)
  let guarantees =
    List.filter_map (fun item ->
      match prov_string item "name" with
      | None -> err "guarantee: missing name"; None
      | Some (nm, nprov) ->
          let gtype = prov_type item "gtype" (Printf.sprintf "guarantee '%s'" nm) in
          let default =
            match field "default" item with
            | None -> Ok None
            | Some dj ->
                (* Record default provenance (R9b) when the default is present
                   and its inner value is non-null. *)
                (match dj with
                 | `Assoc pairs -> (
                     match List.assoc_opt "provenance" pairs with
                     | Some (`String dp) -> (
                         match List.assoc_opt "value" pairs with
                         | Some `Null | None -> ()
                         | Some _ -> add_prov "guarantee_default" nm dp)
                     | _ -> ())
                 | _ -> ());
                Nlp_bridge.parse_default dj
          in
          (match gtype, default with
           | Some gtype, Ok default ->
               add_prov "guarantee" nm nprov;
               Some { name = nm; gtype; default; loc = None }
           | _, Error m -> err m; None
           | None, _ -> None))
      (list_field "guarantees")
  in

  (* Variables. *)
  let variables =
    List.filter_map (fun item ->
      match prov_string item "name" with
      | None -> err "variable: missing name"; None
      | Some (nm, nprov) ->
          let vtype = prov_type item "vtype" (Printf.sprintf "variable '%s'" nm) in
          let initial =
            match field "initial" item with
            | None -> None
            | Some j -> (
                let v, _ = tagged j in
                match v with
                | `Null -> None
                | _ -> (
                    match Nlp_bridge.parse_expr v with
                    | Ok e -> Some e
                    | Error m -> err m; None))
          in
          (match vtype with
           | Some vtype -> add_prov "variable" nm nprov; Some { name = nm; vtype; initial; loc = None }
           | None -> None))
      (list_field "variables")
  in

  (* Definitions. *)
  let definitions =
    List.filter_map (fun item ->
      match prov_string item "name" with
      | None -> err "definition: missing name"; None
      | Some (nm, nprov) -> (
          match field "body" item with
          | None -> err (Printf.sprintf "definition '%s': missing body" nm); None
          | Some j -> (
              let v, _ = tagged j in
              match Nlp_bridge.parse_predicate v with
              | Ok body -> add_prov "definition" nm nprov; Some { name = nm; body; loc = None }
              | Error m -> err m; None)))
      (list_field "definitions")
  in

  (* Always invariants (keyed "global" in the prov table). *)
  let always_invariants =
    List.filter_map (fun item ->
      match field "predicate" item with
      | None -> err "always_invariant: missing predicate"; None
      | Some j -> (
          let v, p = tagged j in
          match Nlp_bridge.parse_predicate v with
          | Ok pred -> add_prov "always_invariant" "global" p; Some pred
          | Error m -> err m; None))
      (list_field "always_invariants")
  in

  (* Initial mode (R5b reports its absence later; do not error here). *)
  let initial_mode =
    match field "initial_mode" json with
    | None -> ""
    | Some j -> (
        let v, p = tagged j in
        match as_string v with
        | Some s -> add_prov "initial_mode" s p; s
        | None -> err "initial_mode: expected a string value"; "")
  in

  (* Modes (entry actions, invariants, transitions). *)
  let parse_mode item =
    match prov_string item "name" with
    | None -> err "mode: missing name"; None
    | Some (nm, nprov) ->
        add_prov "mode" nm nprov;
        let entry_actions =
          match field "entry_actions" item with
          | None -> None
          | Some ea_j -> (
              match as_list ea_j with
              | [] -> None
              | ea_items -> (
                  match Nlp_bridge.parse_action_list ea_j with
                  | Ok acts ->
                      add_prov "entry_action" nm
                        (combine_provenance (List.map action_prov ea_items));
                      Some acts
                  | Error m -> err m; None))
        in
        let invariants =
          List.filter_map (fun iv ->
            match field "predicate" iv with
            | None -> None
            | Some j -> (
                let v, p = tagged j in
                match Nlp_bridge.parse_predicate v with
                | Ok pred -> add_prov "mode_invariant" nm p; Some pred
                | Error m -> err m; None))
            (match field "invariants" item with Some j -> as_list j | None -> [])
        in
        let transitions =
          let items = match field "transitions" item with Some j -> as_list j | None -> [] in
          List.mapi (fun i tr -> (i + 1, tr)) items
          |> List.filter_map (fun (idx, tr) ->
              let guard =
                match field "guard" tr with
                | None -> err (Printf.sprintf "mode '%s' transition %d: missing guard" nm idx); None
                | Some gj -> (
                    let gv, gp = tagged gj in
                    match Nlp_bridge.parse_guard gv with
                    | Ok g -> Some (g, gp)
                    | Error m -> err m; None)
              in
              let actions_json = field "actions" tr in
              let action_provs =
                match actions_json with Some aj -> List.map action_prov (as_list aj) | None -> []
              in
              let actions =
                match actions_json with
                | None -> Some []
                | Some aj -> (
                    match Nlp_bridge.parse_action_list aj with
                    | Ok a -> Some a
                    | Error m -> err m; None)
              in
              let target =
                match field "target" tr with
                | None -> err (Printf.sprintf "mode '%s' transition %d: missing target" nm idx); None
                | Some tj -> (
                    let tv, tp = tagged tj in
                    match Nlp_bridge.parse_target tv with
                    | Ok t -> Some (t, tp)
                    | Error m -> err m; None)
              in
              match guard, actions, target with
              | Some (guard, gp), Some actions, Some (target, tp) ->
                  add_prov "transition" (Printf.sprintf "%s_%d" nm idx)
                    (combine_provenance ([ gp; tp ] @ action_provs));
                  Some { guard; actions; target; loc = None }
              | _ -> None)
        in
        Some { name = nm; entry_actions; invariants; transitions; loc = None }
  in
  let modes = List.filter_map parse_mode (list_field "modes") in

  (* Open questions (passed through to the verdict). *)
  let questions =
    List.filter_map (fun q ->
      let s key = Option.bind (field key q) as_string in
      match s "question_id", s "text", s "relates_to", s "category" with
      | Some qid, Some text, Some relates_to, Some category ->
          let options =
            match field "suggested_options" q with
            | Some j -> List.filter_map as_string (as_list j)
            | None -> []
          in
          Some { qid; text; relates_to; category; options }
      | _ -> None)
      (list_field "open_questions")
  in

  let spec =
    {
      system_name;
      assumes;
      definitions;
      constants;
      guarantees;
      variables;
      always_invariants;
      initial_mode;
      modes;
      loc = None;
    }
  in
  if !errs <> [] then Error (List.rev !errs)
  else Ok { spec; provs = List.rev !provs; questions }

(* ------------------------------------------------------------------ *)
(*  Serializers: AST -> Prolog-shaped facts JSON                       *)
(*  Inverses of nlp_bridge's parsers; output is re-ingestible by       *)
(*  Nlp_bridge.ingest_facts (the round-trip test enforces this).       *)
(* ------------------------------------------------------------------ *)

let binop_str = function
  | Add -> "+" | Sub -> "-" | Mul -> "*" | Div -> "/"
  | Lt -> "<" | Gt -> ">" | Le -> "<=" | Ge -> ">="
  | Eq -> "=" | Ne -> "!=" | And -> "and" | Or -> "or"

let unop_str = function Not -> "not" | Neg -> "neg"

let float_str f =
  let s = string_of_float f in
  if s <> "" && s.[String.length s - 1] = '.' then s ^ "0" else s

let type_to_string (t : cbl_type) : string =
  match t with
  | TBool -> "boolean"
  | TInt (None, None) -> "integer"
  | TInt (lo, hi) ->
      Printf.sprintf "integer[%s..%s]"
        (match lo with Some i -> string_of_int i | None -> "-inf")
        (match hi with Some i -> string_of_int i | None -> "inf")
  | TReal (None, None) -> "real"
  | TReal (lo, hi) ->
      Printf.sprintf "real[%s..%s]"
        (match lo with Some f -> float_str f | None -> "-inf")
        (match hi with Some f -> float_str f | None -> "inf")
  | TEnum members -> "{" ^ String.concat ", " members ^ "}"

let rec expr_to_json (e : expr) : Yojson.Safe.t =
  match e with
  | EInt i -> `Assoc [ ("kind", `String "int"); ("value", `Int i) ]
  | EReal f -> `Assoc [ ("kind", `String "real"); ("value", `Float f) ]
  | EBool b -> `Assoc [ ("kind", `String "bool"); ("value", `Bool b) ]
  | EVar n -> `Assoc [ ("kind", `String "var"); ("name", `String n) ]
  | EBinop (op, l, r) ->
      `Assoc [ ("kind", `String "binop"); ("op", `String (binop_str op));
               ("lhs", expr_to_json l); ("rhs", expr_to_json r) ]
  | EUnop (op, e) ->
      `Assoc [ ("kind", `String "unop"); ("op", `String (unop_str op));
               ("operand", expr_to_json e) ]
  | EAverage es -> `Assoc [ ("kind", `String "average"); ("operands", `List (List.map expr_to_json es)) ]
  | EMedian es -> `Assoc [ ("kind", `String "median"); ("operands", `List (List.map expr_to_json es)) ]

let rec predicate_to_json (p : predicate) : Yojson.Safe.t =
  match p with
  | PTrue -> `Assoc [ ("kind", `String "true") ]
  | PFalse -> `Assoc [ ("kind", `String "false") ]
  | PExpr e -> `Assoc [ ("kind", `String "expr"); ("expr", expr_to_json e) ]
  | PIsTrue e -> `Assoc [ ("kind", `String "is_true"); ("expr", expr_to_json e) ]
  | PIsFalse e -> `Assoc [ ("kind", `String "is_false"); ("expr", expr_to_json e) ]
  | PEquals (l, r) -> `Assoc [ ("kind", `String "equals"); ("lhs", expr_to_json l); ("rhs", expr_to_json r) ]
  | PExceeds (l, r) -> `Assoc [ ("kind", `String "exceeds"); ("lhs", expr_to_json l); ("rhs", expr_to_json r) ]
  | PIsBelow (l, r) -> `Assoc [ ("kind", `String "is_below"); ("lhs", expr_to_json l); ("rhs", expr_to_json r) ]
  | PDeviates (v, refs, t) ->
      `Assoc [ ("kind", `String "deviates"); ("value", expr_to_json v);
               ("references", `List (List.map expr_to_json refs)); ("threshold", expr_to_json t) ]
  | PAgrees (v, refs, t) ->
      `Assoc [ ("kind", `String "agrees"); ("value", expr_to_json v);
               ("references", `List (List.map expr_to_json refs)); ("threshold", expr_to_json t) ]
  | PIsOneOf (e, members) ->
      `Assoc [ ("kind", `String "is_one_of"); ("expr", expr_to_json e);
               ("members", `List (List.map (fun m -> `String m) members)) ]
  | PForNCycles (n, base) ->
      `Assoc [ ("kind", `String "for_n_cycles"); ("n", expr_to_json n); ("base", predicate_to_json base) ]
  | PForFewerCycles (n, base) ->
      `Assoc [ ("kind", `String "for_fewer"); ("n", expr_to_json n); ("base", predicate_to_json base) ]
  | PAnd (l, r) -> `Assoc [ ("kind", `String "and"); ("left", predicate_to_json l); ("right", predicate_to_json r) ]
  | POr (l, r) -> `Assoc [ ("kind", `String "or"); ("left", predicate_to_json l); ("right", predicate_to_json r) ]
  | PNot p -> `Assoc [ ("kind", `String "not"); ("operand", predicate_to_json p) ]

let action_to_json (a : action) : Yojson.Safe.t =
  match a with
  | ASet (n, e) -> `Assoc [ ("kind", `String "set"); ("name", `String n); ("value", expr_to_json e) ]
  | AHold n -> `Assoc [ ("kind", `String "hold"); ("name", `String n) ]
  | AIncrement n -> `Assoc [ ("kind", `String "increment"); ("name", `String n) ]
  | AReset n -> `Assoc [ ("kind", `String "reset"); ("name", `String n) ]

let guard_to_json = function
  | GOtherwise -> `Assoc [ ("otherwise", `Bool true) ]
  | GWhen p -> `Assoc [ ("when", predicate_to_json p) ]

let target_to_json = function
  | TRemain -> `Assoc [ ("remain", `Bool true) ]
  | TTransition m -> `Assoc [ ("transition_to", `String m) ]

(* Serialize a (sub)spec to a fact_partition object. [prov_of kind name]
   supplies the per-fact provenance string. Output matches the committed_facts
   shape consumed by Nlp_bridge.ingest_facts. *)
let fact_partition_json (prov_of : string -> string -> provenance) (s : spec) : Yojson.Safe.t =
  let pstr kind name = `String (prov_of kind name) in
  let assumes =
    List.map (fun (a : assumption) ->
      `Assoc [ ("name", `String a.name); ("atype", `String (type_to_string a.atype));
               ("provenance", pstr "assume" a.name) ]) s.assumes
  in
  let constants =
    List.map (fun (c : constant) ->
      `Assoc [ ("name", `String c.name); ("ctype", `String (type_to_string c.ctype));
               ("cvalue", expr_to_json c.value); ("provenance", pstr "constant" c.name) ]) s.constants
  in
  let guarantees =
    List.map (fun (g : guarantee) ->
      let default =
        match g.default with
        | None -> `Null
        | Some (EVar "__hold__") ->
            `Assoc [ ("value", `Assoc [ ("kind", `String "hold") ]);
                     ("provenance", pstr "guarantee_default" g.name) ]
        | Some e ->
            `Assoc [ ("value", `Assoc [ ("kind", `String "value"); ("value", expr_to_json e) ]);
                     ("provenance", pstr "guarantee_default" g.name) ]
      in
      `Assoc [ ("name", `String g.name); ("gtype", `String (type_to_string g.gtype));
               ("provenance", pstr "guarantee" g.name); ("default", default) ]) s.guarantees
  in
  let variables =
    List.map (fun (v : variable) ->
      let base =
        [ ("name", `String v.name); ("vtype", `String (type_to_string v.vtype));
          ("provenance", pstr "variable" v.name) ]
      in
      let base = match v.initial with Some e -> base @ [ ("initial", expr_to_json e) ] | None -> base in
      `Assoc base) s.variables
  in
  let definitions =
    List.map (fun (d : definition) ->
      `Assoc [ ("name", `String d.name); ("body", predicate_to_json d.body);
               ("provenance", pstr "definition" d.name) ]) s.definitions
  in
  let always_invariants =
    List.map (fun p ->
      `Assoc [ ("predicate", predicate_to_json p); ("provenance", pstr "always_invariant" "global") ])
      s.always_invariants
  in
  let modes =
    List.map (fun (m : mode) ->
      let entry = match m.entry_actions with Some a -> List.map action_to_json a | None -> [] in
      let invs = List.map (fun p -> `Assoc [ ("predicate", predicate_to_json p) ]) m.invariants in
      let trs =
        List.map (fun (t : transition) ->
          `Assoc [ ("guard", guard_to_json t.guard);
                   ("actions", `List (List.map action_to_json t.actions));
                   ("target", target_to_json t.target) ]) m.transitions
      in
      `Assoc [ ("name", `String m.name); ("provenance", pstr "mode" m.name);
               ("entry_actions", `List entry); ("invariants", `List invs);
               ("transitions", `List trs) ]) s.modes
  in
  let initial_mode =
    if s.initial_mode = "" then `Null
    else `Assoc [ ("value", `String s.initial_mode); ("provenance", pstr "initial_mode" s.initial_mode) ]
  in
  `Assoc [
    ("schema_version", `String "0.1");
    ("system_name", if s.system_name = "" then `Null else `String s.system_name);
    ("assumes", `List assumes);
    ("definitions", `List definitions);
    ("constants", `List constants);
    ("guarantees", `List guarantees);
    ("variables", `List variables);
    ("always_invariants", `List always_invariants);
    ("modes", `List modes);
    ("initial_mode", initial_mode);
  ]

(* ------------------------------------------------------------------ *)
(*  Diagnostics: reasoning rules not covered by Checker.check          *)
(* ------------------------------------------------------------------ *)

type diagnostic = {
  severity : string;  (* "error" | "warning" *)
  code : string;
  message : string;
  loc_kind : string;
  loc_name : string;
  loc_idx : int option;
}

let diagnostic_to_json (d : diagnostic) : Yojson.Safe.t =
  `Assoc [
    ("severity", `String d.severity);
    ("code", `String d.code);
    ("message", `String d.message);
    ("location", `Assoc [
      ("kind", `String d.loc_kind);
      ("name", `String d.loc_name);
      ("transition_idx", (match d.loc_idx with Some i -> `Int i | None -> `Null));
    ]);
  ]

(* Names referenced anywhere in guards, actions, entry actions, invariants,
   always-invariants and definition bodies (cbl-prolog referenced_in). A
   `set` LHS counts as a reference, as in Prolog's action_refs. Definition
   references appear as EVar names (nlp_bridge maps {kind:ref} -> PExpr EVar). *)
let action_names = function
  | ASet (n, e) -> n :: Checker.expr_names e
  | AHold n | AIncrement n | AReset n -> [ n ]

let transition_names (t : transition) =
  (match t.guard with GWhen p -> Checker.pred_names p | GOtherwise -> [])
  @ List.concat_map action_names t.actions

let referenced_names (s : spec) : string list =
  List.concat_map (fun (m : mode) ->
    List.concat_map transition_names m.transitions
    @ (match m.entry_actions with Some a -> List.concat_map action_names a | None -> [])
    @ List.concat_map Checker.pred_names m.invariants)
    s.modes
  @ List.concat_map Checker.pred_names s.always_invariants
  @ List.concat_map (fun (d : definition) -> Checker.pred_names d.body) s.definitions

(* Rules that Checker.check does not cover: R1 (empty mode), R5b (no initial
   mode declared) and R13 (unused declaration). R8/R9/R9b (provenance) are
   added here in the next step. *)
let reasoning_diagnostics (ing : ingested) : diagnostic list =
  let s = ing.spec in
  (* R1: every mode must have at least one transition. *)
  let r1 =
    List.filter_map (fun (m : mode) ->
      if m.transitions = [] then
        Some { severity = "error"; code = "empty_mode";
               message = Printf.sprintf "Mode '%s' has no transitions" m.name;
               loc_kind = "mode"; loc_name = m.name; loc_idx = None }
      else None)
      s.modes
  in
  (* R5b: an initial mode must be declared. *)
  let r5b =
    if s.initial_mode = "" then
      [ { severity = "error"; code = "no_initial_mode"; message = "No initial mode declared";
          loc_kind = "spec"; loc_name = ""; loc_idx = None } ]
    else []
  in
  (* R13: a declared name (other than a mode) that is never referenced. *)
  let refs = referenced_names s in
  let declared =
    List.map (fun (a : assumption) -> ("assume", a.name)) s.assumes
    @ List.map (fun (c : constant) -> ("constant", c.name)) s.constants
    @ List.map (fun (g : guarantee) -> ("guarantee", g.name)) s.guarantees
    @ List.map (fun (v : variable) -> ("variable", v.name)) s.variables
    @ List.map (fun (d : definition) -> ("definition", d.name)) s.definitions
  in
  let r13 =
    List.filter_map (fun (kind, name) ->
      if List.mem name refs then None
      else Some { severity = "warning"; code = "unused";
                  message = Printf.sprintf "%s '%s' is declared but never referenced" kind name;
                  loc_kind = kind; loc_name = name; loc_idx = None })
      declared
  in
  (* R8: a constant whose value is unknown blocks compilation. *)
  let r8 =
    List.filter_map (fun (c : constant) ->
      match c.value with
      | EVar "__unknown__" ->
          Some { severity = "warning"; code = "unknown_value";
                 message = Printf.sprintf "Constant '%s' has unknown value" c.name;
                 loc_kind = "constant"; loc_name = c.name; loc_idx = None }
      | _ -> None)
      s.constants
  in
  (* R9: an llm_inferred declaration is unconfirmed. Mirrors the kinds covered
     by cbl-prolog provenance_of/3 (system_name and guarantee_default excluded;
     the latter is R9b). *)
  let r9_kind = function
    | "assume" | "constant" | "guarantee" | "variable" | "mode" | "definition"
    | "transition" | "entry_action" | "mode_invariant" | "always_invariant"
    | "initial_mode" -> true
    | _ -> false
  in
  let r9 =
    List.filter_map (fun (e : prov_entry) ->
      if e.provenance = "llm_inferred" && r9_kind e.kind then
        Some { severity = "warning"; code = "unconfirmed";
               message = Printf.sprintf "LLM inferred %s '%s'" e.kind e.pname;
               loc_kind = e.kind; loc_name = e.pname; loc_idx = None }
      else None)
      ing.provs
  in
  (* R9b: an llm_inferred guarantee default is unconfirmed. *)
  let r9b =
    List.filter_map (fun (e : prov_entry) ->
      if e.kind = "guarantee_default" && e.provenance = "llm_inferred" then
        Some { severity = "warning"; code = "unconfirmed_default";
               message = Printf.sprintf "LLM inferred default for guarantee '%s'" e.pname;
               loc_kind = "guarantee"; loc_name = e.pname; loc_idx = None }
      else None)
      ing.provs
  in
  r1 @ r5b @ r8 @ r9 @ r9b @ r13

(* ------------------------------------------------------------------ *)
(*  Committed / pending partition (cbl-prolog build_fact_partition)    *)
(* ------------------------------------------------------------------ *)

let committed_provenance = function
  | "user_stated" | "user_confirmed" | "rule_derived" | "default_assumed" -> true
  | _ -> false

let prov_lookup (ing : ingested) kind name : provenance =
  match List.find_opt (fun (e : prov_entry) -> e.kind = kind && e.pname = name) ing.provs with
  | Some e -> e.provenance
  | None -> "llm_inferred"

let partition (ing : ingested) : spec * spec =
  let s = ing.spec in
  let dc kind name = committed_provenance (prov_lookup ing kind name) in
  (* A mode is uncommitted if any of its transitions, invariants or entry
     actions is uncommitted (bridge.pl:mode_has_uncommitted). *)
  let mode_uncommitted (m : mode) =
    let trans =
      List.exists (fun i ->
        not (committed_provenance (prov_lookup ing "transition" (Printf.sprintf "%s_%d" m.name i))))
        (List.init (List.length m.transitions) (fun i -> i + 1))
    in
    let entry =
      match m.entry_actions with
      | Some (_ :: _) -> not (committed_provenance (prov_lookup ing "entry_action" m.name))
      | _ -> false
    in
    let inv =
      List.exists (fun (e : prov_entry) ->
        e.kind = "mode_invariant" && e.pname = m.name && not (committed_provenance e.provenance))
        ing.provs
    in
    trans || entry || inv
  in
  let ca, pa = List.partition (fun (a : assumption) -> dc "assume" a.name) s.assumes in
  let cc, pc = List.partition (fun (c : constant) -> dc "constant" c.name) s.constants in
  let cg, pg = List.partition (fun (g : guarantee) -> dc "guarantee" g.name) s.guarantees in
  let cv, pv = List.partition (fun (v : variable) -> dc "variable" v.name) s.variables in
  let cd, pd = List.partition (fun (d : definition) -> dc "definition" d.name) s.definitions in
  (* Always-invariants share the prov-table key "global"; pair them with their
     provenances in declaration order. *)
  let always_provs =
    List.filter_map (fun (e : prov_entry) ->
      if e.kind = "always_invariant" then Some e.provenance else None) ing.provs
  in
  let cai, pai =
    if List.length s.always_invariants = List.length always_provs then
      let pairs = List.combine s.always_invariants always_provs in
      ( List.filter_map (fun (p, pr) -> if committed_provenance pr then Some p else None) pairs,
        List.filter_map (fun (p, pr) -> if committed_provenance pr then None else Some p) pairs )
    else (s.always_invariants, [])
  in
  let cm, pm =
    List.partition (fun (m : mode) ->
      committed_provenance (prov_lookup ing "mode" m.name) && not (mode_uncommitted m))
      s.modes
  in
  let sys_committed = committed_provenance (prov_lookup ing "system_name" s.system_name) in
  let init_committed =
    s.initial_mode <> "" && committed_provenance (prov_lookup ing "initial_mode" s.initial_mode)
  in
  let committed =
    { s with
      system_name = (if sys_committed then s.system_name else "");
      assumes = ca; constants = cc; guarantees = cg; variables = cv; definitions = cd;
      always_invariants = cai; modes = cm;
      initial_mode = (if init_committed then s.initial_mode else "") }
  in
  let pending =
    { s with
      system_name = (if sys_committed then "" else s.system_name);
      assumes = pa; constants = pc; guarantees = pg; variables = pv; definitions = pd;
      always_invariants = pai; modes = pm;
      initial_mode = (if init_committed then "" else s.initial_mode) }
  in
  (committed, pending)

(* ------------------------------------------------------------------ *)
(*  Repairs (cbl-prolog repair.pl)                                     *)
(* ------------------------------------------------------------------ *)

type repair = {
  for_diagnostic : string;
  action : Yojson.Safe.t;
  requires_confirmation : bool;
}

let repair_to_json (r : repair) : Yojson.Safe.t =
  `Assoc [
    ("for_diagnostic", `String r.for_diagnostic);
    ("action", r.action);
    ("provenance", `String "rule_derived");
    ("requires_confirmation", `Bool r.requires_confirmation);
  ]

(* Levenshtein edit distance (bridge.pl:atom_edit_distance), for suggest_target. *)
let levenshtein (a : string) (b : string) : int =
  let la = String.length a and lb = String.length b in
  let d = Array.make_matrix (la + 1) (lb + 1) 0 in
  for i = 0 to la do d.(i).(0) <- i done;
  for j = 0 to lb do d.(0).(j) <- j done;
  for i = 1 to la do
    for j = 1 to lb do
      let cost = if a.[i - 1] = b.[j - 1] then 0 else 1 in
      d.(i).(j) <- min (min (d.(i - 1).(j) + 1) (d.(i).(j - 1) + 1)) (d.(i - 1).(j - 1) + cost)
    done
  done;
  d.(la).(lb)

let action_obj fields = `Assoc fields

(* Repairs are derived from the same syntactic conditions repair.pl uses, so
   they match Prolog regardless of how the well-posedness engine reports the
   underlying error. The for_diagnostic strings reproduce Prolog's term
   printing (no spaces), which session.py greps. ask_user repairs come from the
   reasoning diagnostics (R5b/R8/R9/R9b). *)
let repairs (ing : ingested) (diags : diagnostic list) : repair list =
  let s = ing.spec in
  let mode_names = List.map (fun (m : mode) -> m.name) s.modes in
  let guars_no_default =
    List.filter_map (fun (g : guarantee) -> if g.default = None then Some g.name else None) s.guarantees
  in
  let hold_actions = List.map (fun n -> action_to_json (AHold n)) guars_no_default in
  (* add_otherwise: non-empty mode without an Otherwise clause (R2). *)
  let add_otherwise =
    List.filter_map (fun (m : mode) ->
      if m.transitions <> [] && not (List.exists (fun (t : transition) -> t.guard = GOtherwise) m.transitions) then
        Some { for_diagnostic = Printf.sprintf "guard_incomplete(%s)" m.name;
               action = action_obj [ ("action", `String "add_otherwise"); ("mode", `String m.name);
                                     ("actions", `List hold_actions) ];
               requires_confirmation = true }
      else None)
      s.modes
  in
  (* add_transition: empty mode (R1). *)
  let add_transition =
    List.filter_map (fun (m : mode) ->
      if m.transitions = [] then
        Some { for_diagnostic = Printf.sprintf "empty_mode(%s)" m.name;
               action = action_obj [ ("action", `String "add_transition"); ("mode", `String m.name);
                                     ("guard", guard_to_json GOtherwise); ("actions", `List hold_actions);
                                     ("target", target_to_json TRemain) ];
               requires_confirmation = true }
      else None)
      s.modes
  in
  (* add_action: a guarantee without a default unassigned in a transition (R3). *)
  let add_action =
    List.concat_map (fun (m : mode) ->
      List.concat (List.mapi (fun i (t : transition) ->
        let idx = i + 1 in
        let assigned =
          List.filter_map (function ASet (n, _) | AHold n | AIncrement n | AReset n -> Some n) t.actions
        in
        List.filter_map (fun g ->
          if List.mem g assigned then None
          else Some { for_diagnostic = Printf.sprintf "missing_assignment(%s,%d,%s)" m.name idx g;
                      action = action_obj [ ("action", `String "add_action"); ("mode", `String m.name);
                                            ("transition_idx", `Int idx); ("action_to_add", action_to_json (AHold g)) ];
                      requires_confirmation = true })
          guars_no_default)
        m.transitions))
      s.modes
  in
  (* suggest_target + add_mode: transition target that is not a declared mode (R4). *)
  let invalid_target =
    List.concat_map (fun (m : mode) ->
      List.concat (List.mapi (fun i (t : transition) ->
        let idx = i + 1 in
        match t.target with
        | TTransition tgt when not (List.mem tgt mode_names) ->
            let fd = Printf.sprintf "invalid_target(%s,%d,%s)" m.name idx tgt in
            let candidates = List.filter (fun c -> levenshtein tgt c <= 3) mode_names in
            let suggest =
              if candidates <> [] then
                [ { for_diagnostic = fd;
                    action = action_obj [ ("action", `String "suggest_target"); ("mode", `String m.name);
                                          ("transition_idx", `Int idx);
                                          ("candidates", `List (List.map (fun c -> `String c) candidates)) ];
                    requires_confirmation = true } ]
              else []
            in
            let add_mode =
              { for_diagnostic = fd;
                action = action_obj [ ("action", `String "add_mode"); ("name", `String tgt) ];
                requires_confirmation = true }
            in
            suggest @ [ add_mode ]
        | _ -> [])
        m.transitions))
      s.modes
  in
  (* ask_user: confirmation/value questions from the reasoning diagnostics. *)
  let ask_user name = action_obj [ ("action", `String "ask_user"); ("name", `String name) ] in
  let ask_user_repairs =
    List.filter_map (fun (d : diagnostic) ->
      match d.code with
      | "unconfirmed" ->
          Some { for_diagnostic = Printf.sprintf "unconfirmed(%s,%s)" d.loc_name d.loc_kind;
                 action = ask_user d.loc_name; requires_confirmation = true }
      | "unconfirmed_default" ->
          Some { for_diagnostic = Printf.sprintf "unconfirmed_default(%s)" d.loc_name;
                 action = ask_user d.loc_name; requires_confirmation = true }
      | "unknown_value" ->
          Some { for_diagnostic = Printf.sprintf "unknown_value(%s)" d.loc_name;
                 action = ask_user d.loc_name; requires_confirmation = true }
      | "no_initial_mode" ->
          Some { for_diagnostic = "no_initial_mode"; action = ask_user "initial_mode";
                 requires_confirmation = true }
      | _ -> None)
      diags
  in
  add_otherwise @ add_transition @ add_action @ invalid_target @ ask_user_repairs

(* ------------------------------------------------------------------ *)
(*  Questions (cbl-prolog questions.pl)                                *)
(* ------------------------------------------------------------------ *)

let question_json id text rel cat opts : Yojson.Safe.t =
  `Assoc [
    ("question_id", `String id);
    ("text", `String text);
    ("relates_to", `String rel);
    ("category", `String cat);
    ("suggested_options", `List (List.map (fun s -> `String s) opts));
  ]

(* Pass-through open questions from extraction, plus questions derived from the
   confirmation/value diagnostics. The derived text reproduces repair.pl
   verbatim — session.py greps it to track confirmations. *)
let questions_json (ing : ingested) (diags : diagnostic list) : Yojson.Safe.t list =
  let passthrough =
    List.map (fun (q : question) -> question_json q.qid q.text q.relates_to q.category q.options)
      ing.questions
  in
  let derived =
    List.filter_map (fun (d : diagnostic) ->
      match d.code with
      | "unconfirmed" ->
          Some (question_json (Printf.sprintf "repair_confirm_%s" d.loc_name)
                  (Printf.sprintf "The LLM inferred %s '%s'. Is this correct?" d.loc_kind d.loc_name)
                  d.loc_name "confirm_inference" [ "Yes"; "No" ])
      | "unconfirmed_default" ->
          Some (question_json (Printf.sprintf "repair_confirm_default_%s" d.loc_name)
                  (Printf.sprintf "The LLM inferred a default for guarantee '%s'. Is this correct?" d.loc_name)
                  d.loc_name "confirm_default" [ "Yes"; "No" ])
      | "unknown_value" ->
          Some (question_json (Printf.sprintf "repair_unknown_%s" d.loc_name)
                  (Printf.sprintf "What value should constant '%s' have?" d.loc_name)
                  d.loc_name "missing_value" [])
      | "no_initial_mode" ->
          Some (question_json "repair_no_initial_mode" "Which mode should be the initial mode?"
                  "initial_mode" "missing_value" [])
      | _ -> None)
      diags
  in
  passthrough @ derived

(* ------------------------------------------------------------------ *)
(*  Verdict assembly (cbl-prolog emit_verdict / determine_status)      *)
(* ------------------------------------------------------------------ *)

let verdict (ing : ingested) : Yojson.Safe.t * int =
  let spec = ing.spec in
  let reasoning = reasoning_diagnostics ing in
  (* Well-posedness diagnostics from the existing checker. Drop
     InvalidInitialMode "" — R5b already reports it as no_initial_mode. *)
  let chk = Checker.check spec in
  let chk_errors =
    List.filter (function Checker.InvalidInitialMode "" -> false | _ -> true) chk.Checker.errors
  in
  let chk = { chk with Checker.errors = chk_errors } in
  let checker_diags = match Nlp_bridge.diagnostics_to_json chk with `List l -> l | _ -> [] in
  let reasoning_diags = List.map diagnostic_to_json reasoning in
  let all_diagnostics = checker_diags @ reasoning_diags in
  (* Status (bridge.pl:determine_status). *)
  let has_error =
    chk_errors <> [] || List.exists (fun (d : diagnostic) -> d.severity = "error") reasoning
  in
  let incomplete =
    List.exists (fun (d : diagnostic) ->
      match d.code with "unconfirmed" | "unconfirmed_default" | "unknown_value" -> true | _ -> false)
      reasoning
  in
  let status = if has_error then "fail" else if incomplete then "incomplete" else "pass" in
  let committed, pending = partition ing in
  let prov = prov_lookup ing in
  let repairs_json = List.map repair_to_json (repairs ing reasoning) in
  let v =
    `Assoc [
      ("schema_version", `String "0.1");
      ("status", `String status);
      ("diagnostics", `List all_diagnostics);
      ("repairs", `List repairs_json);
      ("questions", `List (questions_json ing reasoning));
      ("committed_facts", fact_partition_json prov committed);
      ("pending_facts", fact_partition_json prov pending);
    ]
  in
  (v, if status = "pass" then 0 else 1)

let write_verdict (output : string) (v : Yojson.Safe.t) : unit =
  let oc = open_out output in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    output_string oc (Yojson.Safe.pretty_to_string v);
    output_char oc '\n')

let run ~(input : string) ~(output : string) : int =
  match (try Ok (Yojson.Safe.from_file input) with e -> Error (Printexc.to_string e)) with
  | Error msg ->
      Printf.eprintf "reason: cannot read %s: %s\n" input msg;
      exit_error
  | Ok json ->
      (* schema_version + attestation gate (mirrors cbl-prolog bridge.pl). *)
      let schema_ok =
        match field "schema_version" json with Some (`String "0.1") -> true | _ -> false
      in
      let attested =
        match field "provenance_attested" json with Some (`Bool true) -> true | _ -> false
      in
      if not schema_ok then begin
        Printf.eprintf "reason: invalid or missing schema_version (expected \"0.1\")\n";
        exit_error
      end
      else if not attested then begin
        Printf.eprintf "reason: untrusted_provenance (provenance_attested must be true)\n";
        exit_error
      end
      else (
        match ingest json with
        | Error errs ->
            List.iter (fun e -> Printf.eprintf "reason: %s\n" e) errs;
            exit_error
        | Ok ing ->
            let v, code = verdict ing in
            write_verdict output v;
            code)
