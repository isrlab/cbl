(** nlp_bridge.ml — Layer 3: ingest verdict.json committed facts into AST.

    Converts the JSON committed_facts structure into Ast.spec,
    validates via Checker, and emits canonical CBL text. *)

open Ast

(* ------------------------------------------------------------------ *)
(*  JSON accessors                                                     *)
(* ------------------------------------------------------------------ *)

let member key json =
  match json with
  | `Assoc pairs -> (
      match List.assoc_opt key pairs with
      | Some v -> Ok v
      | None -> Error (Printf.sprintf "Missing key '%s'" key))
  | _ -> Error (Printf.sprintf "Expected object for key '%s'" key)

let to_string_exn = function
  | `String s -> Ok s
  | `Null -> Error "Expected string, got null"
  | j -> Error (Printf.sprintf "Expected string, got %s" (Yojson.Safe.to_string j))

let _to_int_exn = function
  | `Int i -> Ok i
  | `Float f -> Ok (int_of_float f)
  | j -> Error (Printf.sprintf "Expected int, got %s" (Yojson.Safe.to_string j))

let _to_float_exn = function
  | `Float f -> Ok f
  | `Int i -> Ok (float_of_int i)
  | j -> Error (Printf.sprintf "Expected float, got %s" (Yojson.Safe.to_string j))

let to_list_exn = function
  | `List l -> Ok l
  | `Null -> Error "Expected list, got null"
  | j -> Error (Printf.sprintf "Expected list, got %s" (Yojson.Safe.to_string j))

let ( let* ) = Result.bind

(* ------------------------------------------------------------------ *)
(*  Identifier validation                                              *)
(* ------------------------------------------------------------------ *)

(** Valid CBL identifier: starts with a letter, contains only letters,
    digits, and underscores. *)
let is_ident_char c =
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
  (c >= '0' && c <= '9') || c = '_'

let is_alpha c =
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')

let validate_ident (name : string) : (string, string) result =
  if String.length name = 0 then Error "Empty identifier"
  else if not (is_alpha name.[0]) then
    Error (Printf.sprintf "Invalid identifier: '%s' (must start with a letter)" name)
  else if not (String.to_seq name |> Seq.for_all is_ident_char) then
    Error (Printf.sprintf "Invalid identifier: '%s' (illegal characters)" name)
  else Ok name

(* ------------------------------------------------------------------ *)
(*  Type parsing                                                       *)
(* ------------------------------------------------------------------ *)

let parse_int_bound s =
  if s = "-inf" || s = "inf" then Ok None
  else match int_of_string_opt s with
       | Some i -> Ok (Some i)
       | None -> Error (Printf.sprintf "Invalid integer bound: %s" s)

let parse_float_bound s =
  if s = "-inf" || s = "inf" then Ok None
  else match float_of_string_opt s with
       | Some f -> Ok (Some f)
       | None -> Error (Printf.sprintf "Invalid float bound: %s" s)

(** Find ".." substring, returning index of first dot *)
let find_dotdot s =
  let len = String.length s in
  let rec scan i =
    if i >= len - 1 then None
    else if s.[i] = '.' && s.[i + 1] = '.' then Some i
    else scan (i + 1)
  in
  scan 0

(** Parse a CBL type string into Ast.cbl_type *)
let parse_type (s : string) : (cbl_type, string) result =
  let s = String.trim s in
  if s = "boolean" then Ok TBool
  else if s = "integer" then Ok (TInt (None, None))
  else if s = "real" then Ok (TReal (None, None))
  else if String.length s > 8 && String.sub s 0 8 = "integer[" && s.[String.length s - 1] = ']' then begin
    let inner = String.sub s 8 (String.length s - 9) in
    match String.split_on_char '.' inner with
    | [lo_s; ""; hi_s] ->
        let* lo = parse_int_bound lo_s in
        let* hi = parse_int_bound hi_s in
        Ok (TInt (lo, hi))
    | _ -> Error (Printf.sprintf "Invalid integer range: %s" s)
  end
  else if String.length s > 5 && String.sub s 0 5 = "real[" && s.[String.length s - 1] = ']' then begin
    let inner = String.sub s 5 (String.length s - 6) in
    match find_dotdot inner with
    | Some idx ->
        let lo_s = String.sub inner 0 idx in
        let hi_s = String.sub inner (idx + 2) (String.length inner - idx - 2) in
        let* lo = parse_float_bound lo_s in
        let* hi = parse_float_bound hi_s in
        Ok (TReal (lo, hi))
    | None -> Error (Printf.sprintf "Invalid real range (no '..' separator): %s" s)
  end
  else if String.length s >= 2 && s.[0] = '{' && s.[String.length s - 1] = '}' then begin
    let inner = String.sub s 1 (String.length s - 2) in
    let members = String.split_on_char ',' inner
      |> List.map String.trim
      |> List.filter (fun x -> x <> "") in
    if members = [] then Error "Empty enum type"
    else
      let rec validate_members ms =
        match ms with
        | [] -> Ok (TEnum members)
        | m :: rest -> (
            match validate_ident m with
            | Ok _ -> validate_members rest
            | Error msg -> Error (Printf.sprintf "Invalid enum member: %s" msg))
      in
      validate_members members
  end
  else Error (Printf.sprintf "Unknown type: %s" s)

(* ------------------------------------------------------------------ *)
(*  Expression parsing from JSON                                       *)
(* ------------------------------------------------------------------ *)

(** Parse a JSON expression value into Ast.expr *)
let rec parse_expr (json : Yojson.Safe.t) : (expr, string) result =
  match json with
  | `Int i -> Ok (EInt i)
  | `Float f -> Ok (EReal f)
  | `Bool b -> Ok (EBool b)
  | `String "true" -> Ok (EBool true)
  | `String "false" -> Ok (EBool false)
  | `String s -> Ok (EVar s)
  | `Assoc pairs -> begin
      match List.assoc_opt "kind" pairs with
      | Some (`String "var") ->
          let* name = member "name" json in
          let* name_s = to_string_exn name in
          Ok (EVar name_s)
      | Some (`String "int") ->
          let* v = member "value" json in
          (match v with
           | `Int i -> Ok (EInt i)
           | `Float f -> Ok (EInt (int_of_float f))
           | _ -> Error "Invalid int value")
      | Some (`String "real") ->
          let* v = member "value" json in
          (match v with
           | `Float f -> Ok (EReal f)
           | `Int i -> Ok (EReal (float_of_int i))
           | _ -> Error "Invalid real value")
      | Some (`String "bool") ->
          let* v = member "value" json in
          (match v with
           | `Bool b -> Ok (EBool b)
           | _ -> Error "Invalid bool value")
      | Some (`String "string") ->
          let* v = member "value" json in
          let* s = to_string_exn v in
          Ok (EVar s)
      | Some (`String "binop") ->
          let* op_json = member "op" json in
          let* op_s = to_string_exn op_json in
          let* left_j = member "lhs" json in
          let* right_j = member "rhs" json in
          let* left = parse_expr left_j in
          let* right = parse_expr right_j in
          let* op = parse_binop op_s in
          Ok (EBinop (op, left, right))
      | Some (`String "unop") ->
          let* op_json = member "op" json in
          let* op_s = to_string_exn op_json in
          let key = if List.mem_assoc "operand" pairs then "operand" else "arg" in
          let* arg_j = member key json in
          let* arg = parse_expr arg_j in
          let* op = parse_unop op_s in
          Ok (EUnop (op, arg))
      | Some (`String "average") ->
          let key = if List.mem_assoc "operands" pairs then "operands" else "args" in
          let* args_j = member key json in
          let* args_l = to_list_exn args_j in
          let* args = parse_expr_list args_l in
          Ok (EAverage args)
      | Some (`String "median") ->
          let key = if List.mem_assoc "operands" pairs then "operands" else "args" in
          let* args_j = member key json in
          let* args_l = to_list_exn args_j in
          let* args = parse_expr_list args_l in
          Ok (EMedian args)
      | _ ->
          Error (Printf.sprintf "Unknown expression kind: %s"
                   (Yojson.Safe.to_string json))
    end
  | _ -> Error (Printf.sprintf "Invalid expression: %s"
                  (Yojson.Safe.to_string json))

and parse_expr_list (js : Yojson.Safe.t list) : (expr list, string) result =
  List.fold_right (fun j acc ->
    let* rest = acc in
    let* e = parse_expr j in
    Ok (e :: rest)
  ) js (Ok [])

and parse_binop (s : string) : (binop, string) result =
  match s with
  | "+" | "add" -> Ok Add  | "-" | "sub" -> Ok Sub
  | "*" | "mul" -> Ok Mul  | "/" | "div" -> Ok Div
  | "<" | "lt"  -> Ok Lt   | ">" | "gt"  -> Ok Gt
  | "<=" | "le" -> Ok Le   | ">=" | "ge" -> Ok Ge
  | "=" | "eq"  -> Ok Eq   | "!=" | "ne" -> Ok Ne
  | "and"       -> Ok And  | "or"        -> Ok Or
  | _ -> Error (Printf.sprintf "Unknown binop: %s" s)

and parse_unop (s : string) : (unop, string) result =
  match s with
  | "not" -> Ok Not | "neg" | "-" -> Ok Neg
  | _ -> Error (Printf.sprintf "Unknown unop: %s" s)

(* ------------------------------------------------------------------ *)
(*  Predicate parsing from JSON                                        *)
(* ------------------------------------------------------------------ *)

let rec parse_predicate (json : Yojson.Safe.t) : (predicate, string) result =
  match json with
  | `Bool true -> Ok PTrue
  | `Bool false -> Ok PFalse
  | `Assoc pairs -> begin
      match List.assoc_opt "kind" pairs with
      | Some (`String "is_true") ->
          let* e_j = member "expr" json in
          let* e = parse_expr e_j in
          Ok (PIsTrue e)
      | Some (`String "is_false") ->
          let* e_j = member "expr" json in
          let* e = parse_expr e_j in
          Ok (PIsFalse e)
      | Some (`String "equals") ->
          let* l = member "lhs" json in let* r = member "rhs" json in
          let* le = parse_expr l in let* re = parse_expr r in
          Ok (PEquals (le, re))
      | Some (`String "exceeds") ->
          let* l = member "lhs" json in let* r = member "rhs" json in
          let* le = parse_expr l in let* re = parse_expr r in
          Ok (PExceeds (le, re))
      | Some (`String "is_below") ->
          let* l = member "lhs" json in let* r = member "rhs" json in
          let* le = parse_expr l in let* re = parse_expr r in
          Ok (PIsBelow (le, re))
      | Some (`String "deviates") ->
          let* v = member "value" json in let* ve = parse_expr v in
          let* refs_j = member "references" json in
          let* refs_l = to_list_exn refs_j in
          let* refs = parse_expr_list refs_l in
          let* t = member "threshold" json in let* te = parse_expr t in
          Ok (PDeviates (ve, refs, te))
      | Some (`String "agrees") ->
          let* v = member "value" json in let* ve = parse_expr v in
          let* refs_j = member "references" json in
          let* refs_l = to_list_exn refs_j in
          let* refs = parse_expr_list refs_l in
          let* t = member "threshold" json in let* te = parse_expr t in
          Ok (PAgrees (ve, refs, te))
      | Some (`String "is_one_of") ->
          let* e_j = member "expr" json in let* e = parse_expr e_j in
          let* members_j = member "members" json in
          let* members_l = to_list_exn members_j in
          let* members = List.fold_right (fun j acc ->
            let* rest = acc in
            let* s = to_string_exn j in
            Ok (s :: rest)
          ) members_l (Ok []) in
          Ok (PIsOneOf (e, members))
      | Some (`String "for_n_cycles") ->
          let* n_j = member "n" json in let* ne = parse_expr n_j in
          let* p_j = member "base" json in let* pe = parse_predicate p_j in
          Ok (PForNCycles (ne, pe))
      | Some (`String "for_fewer") ->
          let* n_j = member "n" json in let* ne = parse_expr n_j in
          let* p_j = member "base" json in let* pe = parse_predicate p_j in
          Ok (PForFewerCycles (ne, pe))
      | Some (`String "and") ->
          let* l = member "left" json in let* r = member "right" json in
          let* lp = parse_predicate l in let* rp = parse_predicate r in
          Ok (PAnd (lp, rp))
      | Some (`String "or") ->
          let* l = member "left" json in let* r = member "right" json in
          let* lp = parse_predicate l in let* rp = parse_predicate r in
          Ok (POr (lp, rp))
      | Some (`String "not") ->
          let* p_j = member "operand" json in
          let* p = parse_predicate p_j in
          Ok (PNot p)
      | Some (`String "ref") ->
          let* name_j = member "name" json in
          let* name_s = to_string_exn name_j in
          Ok (PExpr (EVar name_s))
      | Some (`String "expr") ->
          let* e_j = member "expr" json in
          let* e = parse_expr e_j in
          Ok (PExpr e)
      | Some (`String "true") -> Ok PTrue
      | Some (`String "false") -> Ok PFalse
      | _ -> Error (Printf.sprintf "Unknown predicate kind: %s"
                      (Yojson.Safe.to_string json))
    end
  | _ -> Error (Printf.sprintf "Invalid predicate: %s"
                  (Yojson.Safe.to_string json))

(* ------------------------------------------------------------------ *)
(*  Guard parsing                                                      *)
(* ------------------------------------------------------------------ *)

let parse_guard (json : Yojson.Safe.t) : (guard, string) result =
  match json with
  | `Assoc pairs -> begin
      match List.assoc_opt "otherwise" pairs with
      | Some (`Bool true) -> Ok GOtherwise
      | _ ->
          let* when_j = member "when" json in
          let* pred = parse_predicate when_j in
          Ok (GWhen pred)
    end
  | _ -> Error "Invalid guard"

(* ------------------------------------------------------------------ *)
(*  Action parsing                                                     *)
(* ------------------------------------------------------------------ *)

let parse_action (json : Yojson.Safe.t) : (action, string) result =
  let* kind_j = member "kind" json in
  let* kind = to_string_exn kind_j in
  let* name_j = member "name" json in
  let* name = to_string_exn name_j in
  match kind with
  | "set" ->
      let* val_j = member "value" json in
      let* value = parse_expr val_j in
      Ok (ASet (name, value))
  | "hold"      -> Ok (AHold name)
  | "increment" -> Ok (AIncrement name)
  | "reset"     -> Ok (AReset name)
  | _ -> Error (Printf.sprintf "Unknown action kind: %s" kind)

let parse_action_list (json : Yojson.Safe.t) : (action list, string) result =
  let* items = to_list_exn json in
  List.fold_right (fun j acc ->
    let* rest = acc in
    let* a = parse_action j in
    Ok (a :: rest)
  ) items (Ok [])

(* ------------------------------------------------------------------ *)
(*  Target parsing                                                     *)
(* ------------------------------------------------------------------ *)

let parse_target (json : Yojson.Safe.t) : (target, string) result =
  match json with
  | `Assoc pairs -> begin
      match List.assoc_opt "remain" pairs with
      | Some (`Bool true) -> Ok TRemain
      | _ ->
          let* to_j = member "transition_to" json in
          let* name = to_string_exn to_j in
          Ok (TTransition name)
    end
  | _ -> Error "Invalid target"

(* ------------------------------------------------------------------ *)
(*  Default action parsing                                             *)
(* ------------------------------------------------------------------ *)

let rec parse_default ?(depth=0) (json : Yojson.Safe.t) : (expr option, string) result =
  if depth > 3 then Error "Default nesting depth exceeded"
  else match json with
  | `Null -> Ok None
  | `Assoc pairs -> begin
      (* Handle provenanced wrapper: {"value": {...}, "provenance": "..."} *)
      match List.assoc_opt "value" pairs with
      | Some inner when List.mem_assoc "provenance" pairs ->
          parse_default ~depth:(depth+1) inner  (* unwrap and recurse *)
      | _ ->
          (* Direct default: {"kind": "hold"} or {"kind": "value", "value": ...} *)
          match List.assoc_opt "kind" pairs with
          | Some (`String "hold") -> Ok (Some (EVar "__hold__"))
          | Some (`String "value") ->
              let* v_j = member "value" (json) in
              let* e = parse_expr v_j in
              Ok (Some e)
          | _ -> Error "Invalid default action"
    end
  | _ -> Error "Invalid default"

(* ------------------------------------------------------------------ *)
(*  Fact ingestion: JSON -> Ast.spec                                   *)
(* ------------------------------------------------------------------ *)

(** Main ingestion function.
    Reads the "committed_facts" section from verdict.json. *)
let ingest_facts (json : Yojson.Safe.t) : (spec, string list) result =
  let errs = ref [] in
  let err msg = errs := msg :: !errs in

  let expected_schema = "0.1" in

  let committed_provenance = function
    | "user_stated"
    | "user_confirmed"
    | "rule_derived"
    | "default_assumed" -> true
    | _ -> false
  in

  let check_committed_provenance context json =
    match member "provenance" json with
    | Ok (`String s) ->
        if not (committed_provenance s) then
          err (Printf.sprintf "%s has uncommitted provenance '%s'" context s)
    | Ok _ -> err (Printf.sprintf "%s has invalid provenance" context)
    | Error _ -> err (Printf.sprintf "%s missing provenance" context)
  in

  let verdict_schema =
    match member "schema_version" json with
    | Ok (`String s) -> s
    | Ok _ -> err "Invalid verdict schema_version"; ""
    | Error _ -> err "Missing verdict schema_version"; "" in

  if verdict_schema <> "" && verdict_schema <> expected_schema then
    err (Printf.sprintf "Unsupported verdict schema_version '%s'" verdict_schema);

  let pending_value_has_content v =
    match v with
    | `Null -> false
    | `List l -> l <> []
    | `Assoc pairs -> pairs <> []
    | `String s -> s <> ""
    | _ -> true
  in

  let pending_has_content pf =
    match pf with
    | `Assoc pairs ->
        List.exists (fun (k, v) ->
          k <> "schema_version" && pending_value_has_content v
        ) pairs
    | _ -> false
  in

  let status =
    match member "status" json with
    | Ok (`String s) -> s
    | Ok _ -> err "Invalid verdict status"; ""
    | Error _ -> err "Missing verdict status"; "" in

  if status <> "" && status <> "pass" then
    err (Printf.sprintf "Verdict status is '%s'" status);

  let diagnostics =
    match member "diagnostics" json with
    | Ok j -> (
        match to_list_exn j with
        | Ok items -> items
        | Error _ -> err "Invalid diagnostics"; [])
    | Error _ -> err "Missing diagnostics"; []
  in

  List.iter (fun d ->
    (match member "severity" d with
     | Ok (`String "error") | Ok (`String "warning") -> ()
     | Ok (`String s) -> err (Printf.sprintf "Invalid diagnostic severity '%s'" s)
     | _ -> err "Invalid diagnostic entry");
    (match member "code" d with
     | Ok (`String _) -> ()
     | _ -> err "Diagnostic missing code");
    (match member "message" d with
     | Ok (`String _) -> ()
     | _ -> err "Diagnostic missing message");
    (match member "location" d with
     | Ok (`Assoc _) -> ()
     | _ -> err "Diagnostic missing location")
  ) diagnostics;

  let require_list_field name =
    match member name json with
    | Ok j -> (
        match to_list_exn j with
        | Ok _ -> ()
        | Error _ -> err (Printf.sprintf "Invalid %s" name))
    | Error _ -> err (Printf.sprintf "Missing %s" name)
  in

  require_list_field "repairs";
  require_list_field "questions";

  let has_error_diag =
    List.exists (fun d ->
      match member "severity" d with
      | Ok (`String "error") -> true
      | _ -> false
    ) diagnostics
  in

  if has_error_diag then
    err "Verdict diagnostics contain error severity";

  let pending =
    match member "pending_facts" json with
    | Ok v -> v
    | Error _ -> err "Missing pending_facts"; `Assoc []
  in

  (match pending with
   | `Assoc _ -> ()
   | _ -> err "Invalid pending_facts (expected object)");

  if pending_has_content pending then
    err "pending_facts is not empty";

  (* Extract committed_facts *)
  let cf = match member "committed_facts" json with
    | Ok v -> v
    | Error _ ->
        err "Missing required 'committed_facts' in verdict JSON";
        `Assoc [] in

  let cf_schema =
    match member "schema_version" cf with
    | Ok (`String s) -> s
    | Ok _ -> err "Invalid committed_facts schema_version"; ""
    | Error _ -> err "Missing committed_facts schema_version"; "" in

  if cf_schema <> "" && cf_schema <> expected_schema then
    err (Printf.sprintf "Unsupported committed_facts schema_version '%s'" cf_schema);

  (* System name *)
  let system_name =
    match member "system_name" cf with
    | Ok (`String s) when s <> "" -> s
    | Ok (`String _) -> err "system_name is empty"; "Unnamed"
    | Ok `Null -> err "system_name is null"; "Unnamed"
    | _ -> err "Missing system_name"; "Unnamed" in

  (* Assumes *)
  let assumes =
    match member "assumes" cf with
    | Ok j -> (
        match to_list_exn j with
        | Ok items ->
            List.filter_map (fun item ->
              match member "name" item, member "atype" item with
              | Ok name_j, Ok atype_j -> (
                  match to_string_exn name_j, to_string_exn atype_j with
                  | Ok name, Ok atype_s -> (
                      check_committed_provenance ("assume '" ^ name ^ "'") item;
                      match parse_type atype_s with
                      | Ok atype -> Some { name; atype; loc = None }
                      | Error msg -> err msg; None)
                  | _ -> err "Invalid assume name/type"; None)
              | _ -> err "Assume missing name or atype"; None
            ) items
        | Error msg -> err msg; [])
    | Error _ -> [] in

  (* Constants *)
  let constants =
    match member "constants" cf with
    | Ok j -> (
        match to_list_exn j with
        | Ok items ->
            List.filter_map (fun item ->
              match member "name" item, member "ctype" item, member "cvalue" item with
              | Ok name_j, Ok ctype_j, Ok cvalue_j -> (
                  match to_string_exn name_j, to_string_exn ctype_j with
                  | Ok name, Ok ctype_s -> (
              check_committed_provenance ("constant '" ^ name ^ "'") item;
                      match parse_type ctype_s, parse_expr cvalue_j with
                      | Ok ctype, Ok value -> Some { name; ctype; value; loc = None }
                      | Error msg, _ | _, Error msg -> err msg; None)
                  | _ -> err "Invalid constant name/type"; None)
              | _ -> err "Constant missing name, ctype, or cvalue"; None
            ) items
        | Error msg -> err msg; [])
    | Error _ -> [] in

  (* Guarantees *)
  let guarantees =
    match member "guarantees" cf with
    | Ok j -> (
        match to_list_exn j with
        | Ok items ->
            List.filter_map (fun item ->
              match member "name" item, member "gtype" item with
              | Ok name_j, Ok gtype_j -> (
                  match to_string_exn name_j, to_string_exn gtype_j with
                  | Ok name, Ok gtype_s -> (
                      check_committed_provenance ("guarantee '" ^ name ^ "'") item;
                      let default_result =
                        match member "default" item with
                        | Ok d ->
                            (match d with
                             | `Assoc _ ->
                                 check_committed_provenance
                                   ("default for guarantee '" ^ name ^ "'") d
                             | _ -> ());
                            parse_default d
                        | Error _ -> Ok None in
                      match parse_type gtype_s, default_result with
                      | Ok gtype, Ok default ->
                          Some { name; gtype; default; loc = None }
                      | Error msg, _ | _, Error msg -> err msg; None)
                  | _ -> err "Invalid guarantee name/type"; None)
              | _ -> err "Guarantee missing name or gtype"; None
            ) items
        | Error msg -> err msg; [])
    | Error _ -> [] in

  (* Variables *)
  let variables =
    match member "variables" cf with
    | Ok j -> (
        match to_list_exn j with
        | Ok items ->
            List.filter_map (fun item ->
              match member "name" item, member "vtype" item with
              | Ok name_j, Ok vtype_j -> (
                  match to_string_exn name_j, to_string_exn vtype_j with
                  | Ok name, Ok vtype_s -> (
                      check_committed_provenance ("variable '" ^ name ^ "'") item;
                      let initial =
                        match member "initial" item with
                        | Ok v -> (
                            match parse_expr v with
                            | Ok e -> Some e
                            | Error msg -> err msg; None)
                        | Error _ -> None in
                      match parse_type vtype_s with
                      | Ok vtype -> Some { name; vtype; initial; loc = None }
                      | Error msg -> err msg; None)
                  | _ -> err "Invalid variable name/type"; None)
              | _ -> err "Variable missing name or vtype"; None
            ) items
        | Error msg -> err msg; [])
    | Error _ -> [] in

  (* Definitions *)
  let definitions =
    match member "definitions" cf with
    | Ok j -> (
        match to_list_exn j with
        | Ok items ->
            List.filter_map (fun item ->
              match member "name" item, member "body" item with
              | Ok name_j, Ok body_j -> (
                  match to_string_exn name_j, parse_predicate body_j with
                  | Ok name, Ok body ->
                      check_committed_provenance ("definition '" ^ name ^ "'") item;
                      Some { name; body; loc = None }
                  | Error msg, _ | _, Error msg -> err msg; None)
              | _ -> err "Definition missing name or body"; None
            ) items
        | Error msg -> err msg; [])
    | Error _ -> [] in

  (* Always invariants *)
  let always_invariants =
    match member "always_invariants" cf with
    | Ok j -> (
        match to_list_exn j with
        | Ok items ->
            List.filter_map (fun item ->
              match member "predicate" item with
              | Ok pred_j -> (
                  match parse_predicate pred_j with
                  | Ok pred ->
                      check_committed_provenance "always_invariant" item;
                      Some pred
                  | Error msg -> err msg; None)
              | Error msg -> err msg; None
            ) items
        | Error msg -> err msg; [])
    | Error _ -> [] in

  (* Initial mode *)
  let initial_mode =
    match member "initial_mode" cf with
    | Ok (`String s) ->
      err "initial_mode missing provenance"; s
    | Ok (`Assoc _ as j) -> (
      check_committed_provenance "initial_mode" j;
      match member "value" j with
      | Ok (`String s) -> s
      | _ -> err "Invalid initial_mode value"; "")
    | Ok `Null -> err "No initial mode"; ""
    | _ -> err "Invalid initial_mode"; "" in

  (* Modes *)
  let modes =
    match member "modes" cf with
    | Ok j -> (
        match to_list_exn j with
        | Ok items ->
            List.filter_map (fun item ->
              match member "name" item with
              | Ok name_j -> (
                  match to_string_exn name_j with
                  | Ok name ->
                    check_committed_provenance ("mode '" ^ name ^ "'") item;
                      (* Entry actions *)
                      let entry_actions =
                        match member "entry_actions" item with
                        | Ok ea_j -> (
                            match parse_action_list ea_j with
                            | Ok [] -> None
                            | Ok acts -> Some acts
                            | Error msg -> err msg; None)
                        | Error _ -> None in
                      (* Invariants *)
                      let invariants =
                        match member "invariants" item with
                        | Ok inv_j -> (
                            match to_list_exn inv_j with
                            | Ok items ->
                                List.filter_map (fun iv ->
                                  match member "predicate" iv with
                                  | Ok p_j -> (
                                      match parse_predicate p_j with
                                      | Ok p -> Some p
                                      | Error msg -> err msg; None)
                                  | Error _ -> None
                                ) items
                            | Error msg -> err msg; [])
                        | Error _ -> [] in
                      (* Transitions *)
                      let transitions =
                        match member "transitions" item with
                        | Ok tr_j -> (
                            match to_list_exn tr_j with
                            | Ok items ->
                                List.filter_map (fun tr ->
                                  match member "guard" tr, member "actions" tr, member "target" tr with
                                  | Ok g_j, Ok a_j, Ok t_j -> (
                                      match parse_guard g_j, parse_action_list a_j, parse_target t_j with
                                      | Ok guard, Ok actions, Ok target ->
                                          Some { guard; actions; target; loc = None }
                                      | Error msg, _, _ | _, Error msg, _ | _, _, Error msg ->
                                          err msg; None)
                                  | _ -> err "Transition missing guard, actions, or target"; None
                                ) items
                            | Error msg -> err msg; [])
                        | Error _ -> [] in
                      Some { name; entry_actions; invariants; transitions; loc = None }
                  | Error msg -> err msg; None)
              | Error msg -> err msg; None
            ) items
        | Error msg -> err msg; [])
    | Error _ -> [] in

  (* Validate all identifiers against CBL lexical grammar *)
  let validate_name kind n =
    match validate_ident n with
    | Ok _ -> ()
    | Error msg -> err (Printf.sprintf "%s: %s" kind msg)
  in
  validate_name "system_name" system_name;
  List.iter (fun (a : assumption) -> validate_name "assume" a.name) assumes;
  List.iter (fun (c : constant) -> validate_name "constant" c.name) constants;
  List.iter (fun (g : guarantee) -> validate_name "guarantee" g.name) guarantees;
  List.iter (fun (v : variable) -> validate_name "variable" v.name) variables;
  List.iter (fun (d : definition) -> validate_name "definition" d.name) definitions;
  List.iter (fun (m : mode) -> validate_name "mode" m.name) modes;

  if !errs <> [] then Error (List.rev !errs)
  else Ok {
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

(* ------------------------------------------------------------------ *)
(*  Validation gate                                                    *)
(* ------------------------------------------------------------------ *)

let validate (spec : spec) : Checker.check_result =
  Checker.check spec

(* ------------------------------------------------------------------ *)
(*  CBL emission                                                       *)
(* ------------------------------------------------------------------ *)

let float_to_str f =
  let s = string_of_float f in
  if s <> "" && s.[String.length s - 1] = '.' then s ^ "0"
  else if not (String.contains s '.') then s ^ ".0"
  else s

let type_to_string = function
  | TBool -> "boolean"
  | TInt (None, None) -> "integer"
  | TInt (lo, hi) ->
      Printf.sprintf "integer[%s..%s]"
        (match lo with Some i -> string_of_int i | None -> "-inf")
        (match hi with Some i -> string_of_int i | None -> "inf")
  | TReal (None, None) -> "real"
  | TReal (lo, hi) ->
      Printf.sprintf "real[%s..%s]"
        (match lo with Some f -> float_to_str f | None -> "-inf")
        (match hi with Some f -> float_to_str f | None -> "inf")
  | TEnum members -> "{" ^ String.concat ", " members ^ "}"

let rec expr_to_string = function
  | EInt i -> string_of_int i
  | EReal f -> float_to_str f
  | EBool b -> if b then "true" else "false"
  | EVar s -> s
  | EBinop (op, l, r) ->
      Printf.sprintf "(%s %s %s)" (expr_to_string l) (binop_str op) (expr_to_string r)
  | EUnop (op, e) ->
      Printf.sprintf "%s(%s)" (unop_str op) (expr_to_string e)
  | EAverage es ->
      Printf.sprintf "average(%s)" (String.concat ", " (List.map expr_to_string es))
  | EMedian es ->
      Printf.sprintf "median(%s)" (String.concat ", " (List.map expr_to_string es))

and binop_str = function
  | Add -> "+" | Sub -> "-" | Mul -> "*" | Div -> "/"
  | Lt -> "<" | Gt -> ">" | Le -> "<=" | Ge -> ">="
  | Eq -> "=" | Ne -> "!=" | And -> "and" | Or -> "or"

and unop_str = function
  | Not -> "not " | Neg -> "-"

let rec predicate_to_string = function
  | PTrue -> "true"
  | PFalse -> "false"
  | PExpr e -> expr_to_string e
  | PIsTrue e -> Printf.sprintf "%s is true" (expr_to_string e)
  | PIsFalse e -> Printf.sprintf "%s is false" (expr_to_string e)
  | PEquals (l, r) -> Printf.sprintf "%s equals %s" (expr_to_string l) (expr_to_string r)
  | PExceeds (l, r) -> Printf.sprintf "%s exceeds %s" (expr_to_string l) (expr_to_string r)
  | PIsBelow (l, r) -> Printf.sprintf "%s is below %s" (expr_to_string l) (expr_to_string r)
  | PDeviates (v, refs, t) ->
      Printf.sprintf "%s deviates from %s by more than %s"
        (expr_to_string v) (expr_list_str refs) (expr_to_string t)
  | PAgrees (v, refs, t) ->
      Printf.sprintf "%s agrees with %s within %s"
        (expr_to_string v) (expr_list_str refs) (expr_to_string t)
  | PIsOneOf (e, members) ->
      Printf.sprintf "%s is one of {%s}" (expr_to_string e) (String.concat ", " members)
  | PForNCycles (n, p) ->
      Printf.sprintf "%s for %s consecutive cycles" (predicate_to_string p) (expr_to_string n)
  | PForFewerCycles (n, p) ->
      Printf.sprintf "%s for fewer than %s consecutive cycles" (predicate_to_string p) (expr_to_string n)
  | PAnd (l, r) -> Printf.sprintf "%s and %s" (predicate_to_string l) (predicate_to_string r)
  | POr (l, r) -> Printf.sprintf "%s or %s" (predicate_to_string l) (predicate_to_string r)
  | PNot p -> Printf.sprintf "not (%s)" (predicate_to_string p)

and expr_list_str es =
  match es with
  | [e] -> expr_to_string e
  | _ -> String.concat ", " (List.map expr_to_string es)

let guard_to_string = function
  | GWhen pred -> Printf.sprintf "When %s" (predicate_to_string pred)
  | GOtherwise -> "Otherwise"

let action_to_string = function
  | ASet (name, expr) -> Printf.sprintf "set %s to %s" name (expr_to_string expr)
  | AHold name -> Printf.sprintf "hold %s" name
  | AIncrement name -> Printf.sprintf "increment %s" name
  | AReset name -> Printf.sprintf "reset %s" name

let target_to_string = function
  | TTransition mode -> Printf.sprintf "transition to %s" mode
  | TRemain -> "remain in current"

(** Emit a type for the assumes section: "a <type> signal" *)
let assume_type_to_string = function
  | TBool -> "a boolean signal"
  | TInt (None, None) -> "an integer signal"
  | TInt (lo, hi) ->
      Printf.sprintf "an integer signal [%s..%s]"
        (match lo with Some i -> string_of_int i | None -> "inf")
        (match hi with Some i -> string_of_int i | None -> "inf")
  | TReal (None, None) -> "a real signal"
  | TReal (lo, hi) ->
      Printf.sprintf "a real signal [%s..%s]"
        (match lo with Some f -> float_to_str f | None -> "inf")
        (match hi with Some f -> float_to_str f | None -> "inf")
  | TEnum members -> "one of {" ^ String.concat ", " members ^ "}"

(** Emit default annotation: [default: hold] or [default: <value>] *)
let default_to_string = function
  | None -> ""
  | Some (EVar "__hold__") -> " [default: hold]"
  | Some e -> Printf.sprintf " [default: %s]" (expr_to_string e)

(** Emit canonical CBL text from AST.
    Follows the parser grammar in parser.mly for round-trip fidelity. *)
let emit_cbl (spec : spec) : string =
  let buf = Buffer.create 4096 in
  let p fmt = Printf.ksprintf (fun s -> Buffer.add_string buf s; Buffer.add_char buf '\n') fmt in

  (* System declaration *)
  p "System %s" spec.system_name;
  p "";

  (* Assumes: *)
  if spec.assumes <> [] then begin
    p "Assumes:";
    List.iter (fun (a : assumption) ->
      p "  %s is %s" a.name (assume_type_to_string a.atype)
    ) spec.assumes;
    p ""
  end;

  (* Definitions: *)
  if spec.definitions <> [] then begin
    p "Definitions:";
    List.iter (fun (d : definition) ->
      p "  %s means %s" d.name (predicate_to_string d.body)
    ) spec.definitions;
    p ""
  end;

  (* Constants: *)
  if spec.constants <> [] then begin
    p "Constants:";
    List.iter (fun (c : constant) ->
      p "  %s : %s = %s" c.name (type_to_string c.ctype) (expr_to_string c.value)
    ) spec.constants;
    p ""
  end;

  (* Guarantees: *)
  p "Guarantees:";
  List.iter (fun (g : guarantee) ->
    p "  %s : %s%s" g.name (type_to_string g.gtype) (default_to_string g.default)
  ) spec.guarantees;
  p "";

  (* Variables: *)
  if spec.variables <> [] then begin
    p "Variables:";
    List.iter (fun (v : variable) ->
      let init_str = match v.initial with
        | None -> ""
        | Some e -> Printf.sprintf " = %s" (expr_to_string e)
      in
      p "  %s : %s%s" v.name (type_to_string v.vtype) init_str
    ) spec.variables;
    p ""
  end;

  (* Always: *)
  if spec.always_invariants <> [] then begin
    p "Always:";
    List.iter (fun inv ->
      p "  %s" (predicate_to_string inv)
    ) spec.always_invariants;
    p ""
  end;

  (* Initial Mode: *)
  p "Initial Mode: %s" spec.initial_mode;
  p "";

  (* Mode blocks *)
  List.iter (fun (m : mode) ->
    p "Mode %s:" m.name;
    (* On entry: *)
    (match m.entry_actions with
     | Some actions when actions <> [] ->
         p "  On entry:";
         List.iter (fun a -> p "    %s" (action_to_string a)) actions
     | _ -> ());
    (* Invariant: *)
    if m.invariants <> [] then begin
      p "  Invariant:";
      List.iter (fun inv ->
        p "    %s" (predicate_to_string inv)
      ) m.invariants
    end;
    (* Transitions: When <pred>, shall <actions>, <target>. *)
    List.iter (fun (t : transition) ->
      let guard_s = guard_to_string t.guard in
      let action_strs = List.map action_to_string t.actions in
      let target_s = target_to_string t.target in
      let body = String.concat ", " (action_strs @ [target_s]) in
      p "  %s, shall %s." guard_s body
    ) m.transitions;
    p ""
  ) spec.modes;

  Buffer.contents buf

(* ------------------------------------------------------------------ *)
(*  Diagnostic JSON output                                             *)
(* ------------------------------------------------------------------ *)

let error_to_json (e : Checker.error) : Yojson.Safe.t =
  let open Checker in
  match e with
  | UndeclaredIdentifier (name, ctx) ->
      `Assoc [
        ("severity", `String "error"); ("code", `String "undeclared_ref");
        ("message", `String (Printf.sprintf "Undeclared identifier '%s' in %s" name ctx));
        ("location", `Assoc [("kind", `String "reference"); ("name", `String name); ("transition_idx", `Null)])]
  | TypeMismatch (ctx, expected, got) ->
      `Assoc [
        ("severity", `String "error"); ("code", `String "type_mismatch");
        ("message", `String (Printf.sprintf "Type mismatch in %s: expected %s, got %s"
                               ctx (show_cbl_type expected) (show_cbl_type got)));
        ("location", `Assoc [("kind", `String "expr"); ("name", `String ctx); ("transition_idx", `Null)])]
  | InvalidActionTarget (name, ctx) ->
      `Assoc [
        ("severity", `String "error"); ("code", `String "invalid_action_target");
        ("message", `String (Printf.sprintf "Invalid action target '%s' in %s" name ctx));
        ("location", `Assoc [("kind", `String "action"); ("name", `String name); ("transition_idx", `Null)])]
  | GuardOverlap (mode, _, _) ->
      `Assoc [
        ("severity", `String "error"); ("code", `String "guard_overlap");
        ("message", `String (Printf.sprintf "Overlapping guards in mode %s" mode));
        ("location", `Assoc [("kind", `String "mode"); ("name", `String mode); ("transition_idx", `Null)])]
  | GuardIncomplete mode ->
      `Assoc [
        ("severity", `String "error"); ("code", `String "guard_incomplete");
        ("message", `String (Printf.sprintf "Incomplete guards in mode %s" mode));
        ("location", `Assoc [("kind", `String "mode"); ("name", `String mode); ("transition_idx", `Null)])]
  | ActionTotalityViolation (mode, missing) ->
      `Assoc [
        ("severity", `String "error"); ("code", `String "missing_assignment");
        ("message", `String (Printf.sprintf "Missing assignments in mode %s: %s" mode (String.concat ", " missing)));
        ("location", `Assoc [("kind", `String "mode"); ("name", `String mode); ("transition_idx", `Null)])]
  | DuplicateDeclaration (name, kind) ->
      `Assoc [
        ("severity", `String "error"); ("code", `String "duplicate");
        ("message", `String (Printf.sprintf "Duplicate %s '%s'" kind name));
        ("location", `Assoc [("kind", `String kind); ("name", `String name); ("transition_idx", `Null)])]
  | InvalidInitialMode name ->
      `Assoc [
        ("severity", `String "error"); ("code", `String "invalid_initial");
        ("message", `String (Printf.sprintf "Invalid initial mode '%s'" name));
        ("location", `Assoc [("kind", `String "mode"); ("name", `String name); ("transition_idx", `Null)])]
  | UnreachableMode name ->
      `Assoc [
        ("severity", `String "error"); ("code", `String "unreachable_mode");
        ("message", `String (Printf.sprintf "Unreachable mode '%s'" name));
        ("location", `Assoc [("kind", `String "mode"); ("name", `String name); ("transition_idx", `Null)])]
  | InvalidTransitionTarget (from_mode, target) ->
      `Assoc [
        ("severity", `String "error"); ("code", `String "invalid_target");
        ("message", `String (Printf.sprintf "Invalid target '%s' from mode '%s'" target from_mode));
        ("location", `Assoc [("kind", `String "mode"); ("name", `String from_mode); ("transition_idx", `Null)])]
  | Z3Error (code, mode_name, msg) ->
      `Assoc [
        ("severity", `String "error"); ("code", `String code);
        ("message", `String msg);
        ("location", `Assoc [("kind", `String "mode"); ("name", `String mode_name); ("transition_idx", `Null)])]

let warning_to_json (w : Checker.warning) : Yojson.Safe.t =
  let open Checker in
  match w with
  | UnusedConstant name ->
      `Assoc [("severity", `String "warning"); ("code", `String "unused");
              ("message", `String (Printf.sprintf "Unused constant '%s'" name));
              ("location", `Assoc [("kind", `String "constant"); ("name", `String name); ("transition_idx", `Null)])]
  | UnusedVariable name ->
      `Assoc [("severity", `String "warning"); ("code", `String "unused");
              ("message", `String (Printf.sprintf "Unused variable '%s'" name));
              ("location", `Assoc [("kind", `String "variable"); ("name", `String name); ("transition_idx", `Null)])]
  | UnusedDefinition name ->
      `Assoc [("severity", `String "warning"); ("code", `String "unused");
              ("message", `String (Printf.sprintf "Unused definition '%s'" name));
              ("location", `Assoc [("kind", `String "definition"); ("name", `String name); ("transition_idx", `Null)])]
  | Z3Warning msg ->
      `Assoc [("severity", `String "warning"); ("code", `String "z3");
              ("message", `String msg);
              ("location", `Assoc [("kind", `String "z3"); ("name", `String ""); ("transition_idx", `Null)])]

let diagnostics_to_json (result : Checker.check_result) : Yojson.Safe.t =
  let error_jsons = List.map error_to_json result.errors in
  let warning_jsons = List.map warning_to_json result.warnings in
  `List (error_jsons @ warning_jsons)
