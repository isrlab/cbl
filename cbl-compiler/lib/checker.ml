(** Well-posedness checker for CBL specifications *)

open Ast

(** Error types *)
type error =
  | UndeclaredIdentifier of string * string  (* name, context *)
  | TypeMismatch of string * cbl_type * cbl_type  (* context, expected, got *)
  | InvalidActionTarget of string * string  (* name, context *)
  | GuardOverlap of string * guard * guard  (* mode, guard1, guard2 *)
  | GuardIncomplete of string  (* mode *)
  | ActionTotalityViolation of string * string list  (* mode, missing variables *)
  | DuplicateDeclaration of string * string  (* name, kind *)
  | InvalidInitialMode of string  (* mode name *)
  | UnreachableMode of string  (* mode name *)
  | InvalidTransitionTarget of string * string  (* from mode, target *)
  | Z3Error of string * string * string  (* diagnostic code, mode name, message *)
[@@deriving show]

(** Warning types *)
type warning =
  | UnusedConstant of string
  | UnusedVariable of string
  | UnusedDefinition of string
  | Z3Warning of string
[@@deriving show]

(** Result type for checking *)
type check_result = {
  errors : error list;
  warnings : warning list;
}

(** Symbol table for name resolution and type checking.
    Uses nested 2-tuples so that List.assoc_opt works correctly. *)
type symbol_table = {
  assumes : (string * cbl_type) list;
  definitions : (string * predicate) list;
  constants : (string * (cbl_type * expr)) list;
  guarantees : (string * (cbl_type * expr option)) list;
  variables : (string * (cbl_type * expr option)) list;
  modes : string list;
}

(** Build symbol table from spec *)
let build_symbol_table (spec : spec) : symbol_table =
  let assume_types = List.map (fun (a : assumption) -> (a.name, a.atype)) spec.assumes in
  let def_bindings = List.map (fun (d : definition) -> (d.name, d.body)) spec.definitions in
  let const_bindings = List.map (fun (c : constant) -> (c.name, (c.ctype, c.value))) spec.constants in
  let guar_bindings = List.map (fun (g : guarantee) -> (g.name, (g.gtype, g.default))) spec.guarantees in
  let var_bindings = List.map (fun (v : variable) -> (v.name, (v.vtype, v.initial))) spec.variables in
  let mode_names = List.map (fun (m : mode) -> m.name) spec.modes in
  {
    assumes = assume_types;
    definitions = def_bindings;
    constants = const_bindings;
    guarantees = guar_bindings;
    variables = var_bindings;
    modes = mode_names;
  }

(** Check for duplicate declarations *)
let check_duplicates (spec : spec) : error list =
  let all_names = 
    (List.map (fun (a : assumption) -> (a.name, "assumption")) spec.assumes) @
    (List.map (fun (d : definition) -> (d.name, "definition")) spec.definitions) @
    (List.map (fun (c : constant) -> (c.name, "constant")) spec.constants) @
    (List.map (fun (g : guarantee) -> (g.name, "guarantee")) spec.guarantees) @
    (List.map (fun (v : variable) -> (v.name, "variable")) spec.variables) @
    (List.map (fun (m : mode) -> (m.name, "mode")) spec.modes)
  in
  let rec find_dups seen = function
    | [] -> []
    | (name, kind) :: rest ->
        if List.mem_assoc name seen then
          DuplicateDeclaration (name, kind) :: find_dups seen rest
        else
          find_dups ((name, kind) :: seen) rest
  in
  find_dups [] all_names

(** Type inference for expressions *)
let rec infer_type (symtab : symbol_table) (e : expr) : (cbl_type, error) result =
  match e with
  | EInt _ -> Ok (TInt (None, None))
  | EReal _ -> Ok (TReal (None, None))
  | EBool _ -> Ok TBool
  | EVar name -> (
      match List.assoc_opt name symtab.assumes with
      | Some t -> Ok t
      | None -> (
          match List.assoc_opt name symtab.constants with
          | Some (t, _) -> Ok t
          | None -> (
              match List.assoc_opt name symtab.guarantees with
              | Some (t, _) -> Ok t
              | None -> (
                  match List.assoc_opt name symtab.variables with
                  | Some (t, _) -> Ok t
                  | None -> Error (UndeclaredIdentifier (name, "expression"))
                )
            )
        )
    )
  | EBinop (op, e1, e2) -> (
      match infer_type symtab e1, infer_type symtab e2 with
      | Ok t1, Ok t2 -> (
          match op, t1, t2 with
          | (Add | Sub | Mul | Div), (TInt _ | TReal _), (TInt _ | TReal _) ->
            Ok (match t1, t2 with
              | TReal _, _ | _, TReal _ -> TReal (None, None)
              | _ -> TInt (None, None))
          | (Lt | Gt | Le | Ge | Eq | Ne), _, _ -> Ok TBool
          | (And | Or), TBool, TBool -> Ok TBool
          | _ -> Error (TypeMismatch ("binary operator", t1, t2))
        )
      | Error e, _ | _, Error e -> Error e
    )
  | EUnop (Not, e) -> (
      match infer_type symtab e with
      | Ok TBool -> Ok TBool
      | Ok t -> Error (TypeMismatch ("unary not", TBool, t))
      | Error e -> Error e
    )
  | EUnop (Neg, e) -> infer_type symtab e
  | EAverage _ | EMedian _ -> Ok (TReal (None, None))

(** Check action totality: every guarantee without a default must be
    explicitly assigned (set/hold/increment/reset) in each transition of the
    mode.  This is checked per-transition rather than per-mode because CBL
    semantics require deterministic output on every cycle. *)
let check_action_totality (symtab : symbol_table) (mode : mode) : error list =
  let guaranteed_vars = List.filter_map (fun (name, (_ty, default)) ->
    if default = None then Some name else None
  ) symtab.guarantees in
  let check_transition (trans : transition) =
    let assigned = List.filter_map (function
      | ASet (name, _) | AHold name | AIncrement name | AReset name -> Some name
    ) trans.actions in
    let missing = List.filter (fun v -> not (List.mem v assigned)) guaranteed_vars in
    if missing = [] then []
    else [ActionTotalityViolation (mode.name, missing)]
  in
  List.concat_map check_transition mode.transitions

let type_compatible (expected : cbl_type) (got : cbl_type) : bool =
  match expected, got with
  | TBool, TBool -> true
  | TInt _, TInt _ -> true
  | TReal _, TReal _ -> true
  | TReal _, TInt _ -> true
  | TEnum members_a, TEnum members_b -> members_a = members_b
  | _ -> false

let enum_member_ok (expected : cbl_type) (value : expr) : bool =
  match expected, value with
  | TEnum members, EVar name -> List.mem name members
  | _ -> false

let check_action_types (symtab : symbol_table) (spec : spec) : error list =
  let expected_type name =
    match List.assoc_opt name symtab.guarantees with
    | Some (t, _) -> Some t
    | None -> (
        match List.assoc_opt name symtab.variables with
        | Some (t, _) -> Some t
        | None -> None
      )
  in
  let is_numeric = function
    | TInt _ | TReal _ -> true
    | _ -> false
  in
  let check_actions context actions =
    List.filter_map (function
      | ASet (name, value) -> (
          match expected_type name with
          | Some expected ->
              if enum_member_ok expected value then None
              else (
                match infer_type symtab value with
                | Ok got ->
                    if type_compatible expected got then None
                    else Some (TypeMismatch (context ^ " assignment to " ^ name, expected, got))
                | Error e -> Some e
              )
          | None -> None
        )
      | AIncrement name | AReset name -> (
          match expected_type name with
          | Some expected ->
              if is_numeric expected then None
              else Some (TypeMismatch (context ^ " numeric op on " ^ name, TInt (None, None), expected))
          | None -> None
        )
      | AHold _ -> None
    ) actions
  in
  List.concat_map (fun (mode : mode) ->
    let entry_errors =
      match mode.entry_actions with
      | None | Some [] -> []
      | Some actions -> check_actions ("entry action in mode '" ^ mode.name ^ "'") actions
    in
    let transition_errors =
      List.concat_map (fun (trans : transition) ->
        check_actions ("transition in mode '" ^ mode.name ^ "'") trans.actions
      ) mode.transitions
    in
    entry_errors @ transition_errors
  ) spec.modes

let check_declaration_types (symtab : symbol_table) (spec : spec) : error list =
  let check_expr context expected expr =
    if enum_member_ok expected expr then []
    else
      match infer_type symtab expr with
      | Ok got ->
          if type_compatible expected got then []
          else [TypeMismatch (context, expected, got)]
      | Error e -> [e]
  in
  let const_errors =
    List.concat_map (fun (c : constant) ->
      check_expr ("constant '" ^ c.name ^ "'") c.ctype c.value
    ) spec.constants
  in
  let var_errors =
    List.concat_map (fun (v : variable) ->
      match v.initial with
      | None -> []
      | Some (EVar "__hold__") -> []
      | Some expr ->
          check_expr ("initial value for variable '" ^ v.name ^ "'") v.vtype expr
    ) spec.variables
  in
  let guar_errors =
    List.concat_map (fun (g : guarantee) ->
      match g.default with
      | None -> []
      | Some (EVar "__hold__") -> []
      | Some expr ->
          check_expr ("default for guarantee '" ^ g.name ^ "'") g.gtype expr
    ) spec.guarantees
  in
  const_errors @ var_errors @ guar_errors

(** Collect all name references in a predicate *)
let rec pred_names (p : predicate) : string list =
  match p with
  | PTrue | PFalse -> []
  | PExpr e | PIsTrue e | PIsFalse e -> expr_names e
  | PEquals (a, b) | PExceeds (a, b) | PIsBelow (a, b) ->
      expr_names a @ expr_names b
  | PDeviates (v, refs, t) | PAgrees (v, refs, t) ->
      expr_names v @ List.concat_map expr_names refs @ expr_names t
  | PIsOneOf (e, _) -> expr_names e
  | PForNCycles (n, inner) | PForFewerCycles (n, inner) ->
      expr_names n @ pred_names inner
  | PAnd (a, b) | POr (a, b) -> pred_names a @ pred_names b
  | PNot inner -> pred_names inner

and expr_names (e : expr) : string list =
  match e with
  | EBool _ | EInt _ | EReal _ -> []
  | EVar name -> [name]
  | EBinop (_, a, b) -> expr_names a @ expr_names b
  | EUnop (_, a) -> expr_names a
  | EAverage es | EMedian es -> List.concat_map expr_names es

(** Check that all names referenced in invariants and always-invariants are declared *)
let check_invariant_refs (spec : spec) (symtab : symbol_table) : error list =
  let all_declared =
    List.map fst symtab.assumes @
    List.map fst symtab.definitions @
    List.map fst symtab.constants @
    List.map (fun (n, _) -> n) symtab.guarantees @
    List.map (fun (n, _) -> n) symtab.variables
  in
  let check_pred context p =
    List.filter_map (fun name ->
      if List.mem name all_declared then None
      else Some (UndeclaredIdentifier (name, context))
    ) (pred_names p)
  in
  let always_errors =
    List.concat_map (check_pred "always invariant") spec.always_invariants
  in
  let mode_errors =
    List.concat_map (fun (mode : mode) ->
      List.concat_map
        (check_pred (Printf.sprintf "invariant in mode '%s'" mode.name))
        mode.invariants
    ) spec.modes
  in
  always_errors @ mode_errors

(** Check that all names referenced in guards and actions are declared *)
let check_guard_action_refs (spec : spec) (symtab : symbol_table) : error list =
  let all_declared =
    List.map fst symtab.assumes @
    List.map fst symtab.definitions @
    List.map fst symtab.constants @
    List.map (fun (n, _) -> n) symtab.guarantees @
    List.map (fun (n, _) -> n) symtab.variables
  in
  (* Collect enum member names as valid identifiers *)
  let enum_members =
    let collect_enum_members (_name, ty) = match ty with
      | TEnum members -> members
      | _ -> []
    in
    List.concat_map collect_enum_members symtab.assumes @
    List.concat_map (fun (_, (ty, _)) -> match ty with TEnum m -> m | _ -> []) symtab.guarantees @
    List.concat_map (fun (_, (ty, _)) -> match ty with TEnum m -> m | _ -> []) symtab.variables @
    List.concat_map (fun (_, (ty, _)) -> match ty with TEnum m -> m | _ -> []) symtab.constants
  in
  let assignable =
    List.map (fun (n, _) -> n) symtab.guarantees @
    List.map (fun (n, _) -> n) symtab.variables
  in
  let all_valid = all_declared @ enum_members in
  let entry_errors = List.concat_map (fun (mode : mode) ->
    match mode.entry_actions with
    | None | Some [] -> []
    | Some actions ->
        let expr_refs = List.concat_map (function
          | ASet (_, e) -> expr_names e
          | AHold _ | AIncrement _ | AReset _ -> []
        ) actions in
        let target_names = List.filter_map (function
          | ASet (name, _) | AHold name | AIncrement name | AReset name -> Some name
        ) actions in
        let expr_errors = List.filter_map (fun name ->
          if List.mem name all_valid then None
          else Some (UndeclaredIdentifier (name,
            Printf.sprintf "entry action in mode '%s'" mode.name))
        ) expr_refs in
        let target_errors = List.filter_map (fun name ->
          if List.mem name assignable then None
          else Some (InvalidActionTarget (name,
            Printf.sprintf "entry action in mode '%s'" mode.name))
        ) target_names in
        expr_errors @ target_errors
  ) spec.modes in
  let transition_errors = List.concat_map (fun (mode : mode) ->
    List.concat_map (fun (trans : transition) ->
      let guard_refs = match trans.guard with
        | GWhen p -> pred_names p
        | GOtherwise -> []
      in
      let action_expr_refs = List.concat_map (function
        | ASet (_, e) -> expr_names e
        | AHold _ | AIncrement _ | AReset _ -> []
      ) trans.actions in
      let action_target_names = List.filter_map (function
        | ASet (name, _) | AHold name | AIncrement name | AReset name -> Some name
      ) trans.actions in
      let guard_errors = List.filter_map (fun name ->
        if List.mem name all_valid then None
        else Some (UndeclaredIdentifier (name,
          Printf.sprintf "guard/action in mode '%s'" mode.name))
      ) guard_refs in
      let expr_errors = List.filter_map (fun name ->
        if List.mem name all_valid then None
        else Some (UndeclaredIdentifier (name,
          Printf.sprintf "guard/action in mode '%s'" mode.name))
      ) action_expr_refs in
      let target_errors = List.filter_map (fun name ->
        if List.mem name assignable then None
        else Some (InvalidActionTarget (name,
          Printf.sprintf "guard/action in mode '%s'" mode.name))
      ) action_target_names in
      guard_errors @ expr_errors @ target_errors
    ) mode.transitions
  ) spec.modes in
  entry_errors @ transition_errors

(** Check that TInt and TReal range bounds are consistent (lo <= hi) *)
let check_type_bounds (spec : spec) : error list =
  let check_type name kind ty =
    match ty with
    | TInt (Some lo, Some hi) when lo > hi ->
        [TypeMismatch (
          Printf.sprintf "%s '%s': lower bound %d > upper bound %d" kind name lo hi,
          TInt (Some lo, Some hi),
          TInt (Some lo, Some hi))]
    | TReal (Some lo, Some hi) when lo > hi ->
        [TypeMismatch (
          Printf.sprintf "%s '%s': lower bound %g > upper bound %g" kind name lo hi,
          TReal (Some lo, Some hi),
          TReal (Some lo, Some hi))]
    | _ -> []
  in
  List.concat [
    List.concat_map (fun (a : assumption) -> check_type a.name "assumption" a.atype) spec.assumes;
    List.concat_map (fun (g : guarantee) -> check_type g.name "guarantee" g.gtype) spec.guarantees;
    List.concat_map (fun (v : variable) -> check_type v.name "variable" v.vtype) spec.variables;
    List.concat_map (fun (c : constant) -> check_type c.name "constant" c.ctype) spec.constants;
  ]

(** Convert a Z3 diagnostic to a checker error, or None for warnings/info. *)
let z3_diag_to_error (d : Z3_guard_checker.diagnostic) : error option =
  match d.severity with
  | Z3_guard_checker.Error ->
      let msg =
        if d.counterexample = "" then d.message
        else d.message ^ " Counterexample: " ^ d.counterexample
      in
      Some (Z3Error (d.code, d.mode_name, msg))
  | Z3_guard_checker.Warning | Z3_guard_checker.Info -> None

(** Convert a Z3 diagnostic to a checker warning string, or None for errors. *)
let z3_diag_to_warning (d : Z3_guard_checker.diagnostic) : string option =
  match d.severity with
  | Z3_guard_checker.Error -> None
  | Z3_guard_checker.Warning | Z3_guard_checker.Info ->
      Some (Printf.sprintf "[%s] Mode '%s': %s" d.code d.mode_name d.message)

(** Check that initial mode exists *)
let check_initial_mode (spec : spec) (symtab : symbol_table) : error list =
  if List.mem spec.initial_mode symtab.modes then []
  else [InvalidInitialMode spec.initial_mode]

(** Check that all transition targets are valid modes *)
let check_transition_targets (spec : spec) (symtab : symbol_table) : error list =
  List.concat_map (fun (mode : mode) ->
    List.filter_map (fun (trans : transition) ->
      match trans.target with
      | TTransition target ->
          if List.mem target symtab.modes then None
          else Some (InvalidTransitionTarget (mode.name, target))
      | TRemain -> None
    ) mode.transitions
  ) spec.modes

(** Check for unreachable modes via BFS from initial_mode *)
let check_reachable_modes (spec : spec) (symtab : symbol_table) : error list =
  (* Build adjacency: mode_name -> list of target mode_names *)
  let targets_of (m : mode) =
    List.filter_map (fun (t : transition) ->
      match t.target with
      | TTransition name -> Some name
      | TRemain -> Some m.name
    ) m.transitions
  in
  let mode_map = List.map (fun (m : mode) -> (m.name, m)) spec.modes in
  (* BFS *)
  let visited = Hashtbl.create (List.length spec.modes) in
  let queue = Queue.create () in
  if List.mem spec.initial_mode symtab.modes then begin
    Queue.push spec.initial_mode queue;
    Hashtbl.replace visited spec.initial_mode true
  end;
  while not (Queue.is_empty queue) do
    let cur = Queue.pop queue in
    (match List.assoc_opt cur mode_map with
     | Some m ->
         List.iter (fun tgt ->
           if not (Hashtbl.mem visited tgt) then begin
             Hashtbl.replace visited tgt true;
             Queue.push tgt queue
           end
         ) (targets_of m)
     | None -> ())
  done;
  List.filter_map (fun name ->
    if Hashtbl.mem visited name then None
    else Some (UnreachableMode name)
  ) symtab.modes

(** Main checking function *)
let check (spec : spec) : check_result =
  let symtab = build_symbol_table spec in
  let z3_diags =
    try Z3_guard_checker.check_spec spec
    with exn ->
      [{ Z3_guard_checker.severity = Error; code = "Z3-ERR";
         mode_name = ""; message = "Z3 check failed: " ^ Printexc.to_string exn;
         counterexample = "" }]
  in
  let z3_errors = List.filter_map z3_diag_to_error z3_diags in
  let z3_warnings = List.filter_map (fun d ->
    match z3_diag_to_warning d with
    | Some msg -> Some (Z3Warning msg)
    | None -> None
  ) z3_diags in
  let errors = List.concat [
    check_duplicates spec;
    check_type_bounds spec;
    check_initial_mode spec symtab;
    check_transition_targets spec symtab;
    check_reachable_modes spec symtab;
    List.concat_map (check_action_totality symtab) spec.modes;
    check_action_types symtab spec;
    check_declaration_types symtab spec;
    check_invariant_refs spec symtab;
    check_guard_action_refs spec symtab;
    z3_errors;
  ] in
  { errors; warnings = z3_warnings }

(** Pretty print errors and warnings *)
let string_of_error = function
  | UndeclaredIdentifier (name, ctx) ->
      Printf.sprintf "Undeclared identifier '%s' in %s" name ctx
  | TypeMismatch (ctx, expected, got) ->
      Printf.sprintf "Type mismatch in %s: expected %s, got %s"
        ctx (show_cbl_type expected) (show_cbl_type got)
  | InvalidActionTarget (name, ctx) ->
      Printf.sprintf "Invalid action target '%s' in %s" name ctx
  | GuardOverlap (mode, _g1, _g2) ->
      Printf.sprintf "Overlapping guards in mode %s" mode
  | GuardIncomplete mode ->
      Printf.sprintf "Incomplete guards in mode %s (no Otherwise clause)" mode
  | Z3Error (code, mode, msg) ->
      Printf.sprintf "[%s] Mode '%s': %s" code mode msg
  | ActionTotalityViolation (mode, missing) ->
      Printf.sprintf "Action totality violated in mode %s: missing assignments for %s"
        mode (String.concat ", " missing)
  | DuplicateDeclaration (name, kind) ->
      Printf.sprintf "Duplicate declaration of %s '%s'" kind name
  | InvalidInitialMode name ->
      Printf.sprintf "Invalid initial mode '%s' (not declared)" name
  | UnreachableMode name ->
      Printf.sprintf "Mode '%s' is unreachable" name
  | InvalidTransitionTarget (from_mode, target) ->
      Printf.sprintf "Invalid transition target '%s' from mode '%s'" target from_mode

(** Print check results *)
let string_of_warning = function
  | UnusedConstant name -> Printf.sprintf "Unused constant '%s'" name
  | UnusedVariable name -> Printf.sprintf "Unused variable '%s'" name
  | UnusedDefinition name -> Printf.sprintf "Unused definition '%s'" name
  | Z3Warning msg -> msg

let print_result (result : check_result) : unit =
  if result.errors = [] && result.warnings = [] then
    print_endline "✓ Specification is well-posed"
  else begin
    if result.errors <> [] then begin
      print_endline "Errors:";
      List.iter (fun e -> print_endline ("  " ^ string_of_error e)) result.errors
    end;
    if result.warnings <> [] then begin
      print_endline "Warnings:";
      List.iter (fun w -> print_endline ("  " ^ string_of_warning w)) result.warnings
    end
  end
