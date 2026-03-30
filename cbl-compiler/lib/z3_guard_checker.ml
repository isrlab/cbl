(** Z3-backed guard exclusivity (WP-1) and completeness (WP-2) checking.

    WP-1  Guard exclusivity: for every pair of GWhen guards in a mode,
          check satisfiability of (g_i AND g_j AND context_constraints).
          SAT means overlap: both guards can fire simultaneously.

    WP-2  Guard completeness: for modes without GOtherwise, check
          satisfiability of NOT(g_1 OR ... OR g_n AND context_constraints).
          SAT means there is an input combination that no guard handles.

    Non-classical predicates (PForNCycles, PDeviates, PAgrees, PForFewerCycles)
    are abstracted as fresh opaque booleans (conservative over-approximation:
    may produce false "possible overlap" warnings but never misses a real overlap).
    PIsOneOf is similarly abstracted pending proper enum-sort tracking.
*)

open Ast

(** Severity levels for Z3 diagnostics. *)
type severity = Error | Warning | Info

(** A diagnostic produced by the Z3 guard checker. *)
type diagnostic = {
  severity : severity;
  code : string;         (** "Z3-WP1" (exclusivity) or "Z3-WP2" (completeness). *)
  mode_name : string;
  message : string;
  counterexample : string;  (** Variable assignments as "x = v; y = w", empty if unavailable. *)
}

(** Internal Z3 translation context. *)
type z3_ctx = {
  vars : (string * Z3.Expr.expr) list;
  (** Maps CBL identifier names to their Z3 constant expressions. *)
  constraints : Z3.Expr.expr list;
  (** Accumulated range and type constraints (e.g. 0 <= x <= 100). *)
  definitions : (string * predicate) list;
  (** Inline definitions available for expansion during guard translation. *)
  zctx : Z3.context;
}

let make_empty_ctx () =
  let zctx = Z3.mk_context [] in
  { vars = []; constraints = []; definitions = []; zctx }

let add_var ctx name sort =
  let v = Z3.Expr.mk_const_s ctx.zctx name sort in
  { ctx with vars = (name, v) :: ctx.vars }

let add_constraint ctx c =
  { ctx with constraints = c :: ctx.constraints }

(** Register one CBL-typed identifier into the translation context. *)
let add_typed ctx name (ty : cbl_type) =
  let zctx = ctx.zctx in
  match ty with
  | TBool ->
      add_var ctx name (Z3.Boolean.mk_sort zctx)
  | TInt (lo, hi) ->
      let ctx = add_var ctx name (Z3.Arithmetic.Integer.mk_sort zctx) in
      let v = List.assoc name ctx.vars in
      let ctx = match lo with
        | Some l ->
            add_constraint ctx
              (Z3.Arithmetic.mk_ge zctx v
                 (Z3.Arithmetic.Integer.mk_numeral_i zctx l))
        | None -> ctx in
      (match hi with
       | Some h ->
           add_constraint ctx
             (Z3.Arithmetic.mk_le zctx v
                (Z3.Arithmetic.Integer.mk_numeral_i zctx h))
       | None -> ctx)
  | TReal (lo, hi) ->
      let ctx = add_var ctx name (Z3.Arithmetic.Real.mk_sort zctx) in
      let v = List.assoc name ctx.vars in
      let ctx = match lo with
        | Some l ->
            add_constraint ctx
              (Z3.Arithmetic.mk_ge zctx v
                 (Z3.Arithmetic.Real.mk_numeral_s zctx (string_of_float l)))
        | None -> ctx in
      (match hi with
       | Some h ->
           add_constraint ctx
             (Z3.Arithmetic.mk_le zctx v
                (Z3.Arithmetic.Real.mk_numeral_s zctx (string_of_float h)))
       | None -> ctx)
  | TEnum _ ->
      (* Enum variables are translated as uninterpreted integer tokens.
         PIsOneOf guards are abstracted as opaque booleans (conservative). *)
      add_var ctx name (Z3.Arithmetic.Integer.mk_sort zctx)

(** Build a Z3 context from all declarations in a CBL specification. *)
let build_context (spec : spec) : z3_ctx =
  let ctx = make_empty_ctx () in
  let ctx = List.fold_left (fun c (a : assumption) ->
    add_typed c a.name a.atype) ctx spec.assumes in
  let ctx = List.fold_left (fun c (g : guarantee) ->
    add_typed c g.name g.gtype) ctx spec.guarantees in
  let ctx = List.fold_left (fun c (v : variable) ->
    add_typed c v.name v.vtype) ctx spec.variables in
  let ctx = List.fold_left (fun c (k : constant) ->
    let c = add_typed c k.name k.ctype in
    match List.assoc_opt k.name c.vars with
    | None -> c
    | Some zv ->
        let zctx = c.zctx in
        (match k.value with
         | EInt i ->
             add_constraint c
               (Z3.Boolean.mk_eq zctx zv
                  (Z3.Arithmetic.Integer.mk_numeral_i zctx i))
         | EReal f ->
             add_constraint c
               (Z3.Boolean.mk_eq zctx zv
                  (Z3.Arithmetic.Real.mk_numeral_s zctx (string_of_float f)))
         | EBool b ->
             add_constraint c
               (Z3.Boolean.mk_eq zctx zv
                  (if b then Z3.Boolean.mk_true zctx
                   else Z3.Boolean.mk_false zctx))
         | _ -> c)
  ) ctx spec.constants in
  (* Populate inline definitions so pred_to_z3 can expand them. *)
  let ctx = { ctx with definitions =
    List.map (fun (d : definition) -> (d.name, d.body)) spec.definitions } in
  ctx

(** Counter for fresh opaque variable names.
    Module-level ref, reset to 0 at the start of each [check_spec] call.
    Single-threaded use only; thread through [z3_ctx] if concurrent access
    is ever needed. *)
let opaque_counter = ref 0

let fresh_bool zctx =
  incr opaque_counter;
  Z3.Expr.mk_const_s zctx
    (Printf.sprintf "_op%d" !opaque_counter)
    (Z3.Boolean.mk_sort zctx)

(** Translate a CBL expression to a Z3 expression.
    Returns [None] if the expression cannot be translated. *)
let rec expr_to_z3 (ctx : z3_ctx) (e : expr) : Z3.Expr.expr option =
  let zctx = ctx.zctx in
  match e with
  | EBool b ->
      Some (if b then Z3.Boolean.mk_true zctx else Z3.Boolean.mk_false zctx)
  | EInt i ->
      Some (Z3.Arithmetic.Integer.mk_numeral_i zctx i)
  | EReal f ->
      Some (Z3.Arithmetic.Real.mk_numeral_s zctx (string_of_float f))
  | EVar name ->
      List.assoc_opt name ctx.vars
  | EBinop (op, a, b) ->
      (match expr_to_z3 ctx a, expr_to_z3 ctx b with
       | Some za, Some zb ->
           (match op with
            | Add -> Some (Z3.Arithmetic.mk_add zctx [za; zb])
            | Sub -> Some (Z3.Arithmetic.mk_sub zctx [za; zb])
            | Mul -> Some (Z3.Arithmetic.mk_mul zctx [za; zb])
            | Div -> Some (Z3.Arithmetic.mk_div zctx za zb)
            | Lt  -> Some (Z3.Arithmetic.mk_lt zctx za zb)
            | Gt  -> Some (Z3.Arithmetic.mk_gt zctx za zb)
            | Le  -> Some (Z3.Arithmetic.mk_le zctx za zb)
            | Ge  -> Some (Z3.Arithmetic.mk_ge zctx za zb)
            | Eq  -> Some (Z3.Boolean.mk_eq zctx za zb)
            | Ne  -> Some (Z3.Boolean.mk_not zctx (Z3.Boolean.mk_eq zctx za zb))
            | And -> Some (Z3.Boolean.mk_and zctx [za; zb])
            | Or  -> Some (Z3.Boolean.mk_or zctx [za; zb]))
       | _ -> None)
  | EUnop (op, a) ->
      (match expr_to_z3 ctx a with
       | Some za ->
           (match op with
            | Not -> Some (Z3.Boolean.mk_not zctx za)
            | Neg -> Some (Z3.Arithmetic.mk_unary_minus zctx za))
       | None -> None)
  | EAverage _ | EMedian _ ->
      (* Aggregate: abstract as an unconstrained real variable. *)
      incr opaque_counter;
      Some (Z3.Expr.mk_const_s zctx
              (Printf.sprintf "_agg%d" !opaque_counter)
              (Z3.Arithmetic.Real.mk_sort zctx))

(** Translate a CBL predicate to a Z3 boolean expression.
    Returns [None] if the predicate cannot be translated. *)
and pred_to_z3 ?(expanding=[]) (ctx : z3_ctx) (p : predicate) : Z3.Expr.expr option =
  let zctx = ctx.zctx in
  match p with
  | PTrue  -> Some (Z3.Boolean.mk_true zctx)
  | PFalse -> Some (Z3.Boolean.mk_false zctx)
  | PExpr (EVar name) when List.mem_assoc name ctx.definitions ->
      if List.mem name expanding then
        Some (fresh_bool zctx)  (* cycle detected: conservative abstraction *)
      else
        pred_to_z3 ~expanding:(name :: expanding) ctx (List.assoc name ctx.definitions)
  | PExpr e     -> expr_to_z3 ctx e
  | PIsTrue e   -> expr_to_z3 ctx e
  | PIsFalse e  ->
      (match expr_to_z3 ctx e with
       | Some z -> Some (Z3.Boolean.mk_not zctx z)
       | None -> None)
  | PEquals (a, b) ->
      (match expr_to_z3 ctx a, expr_to_z3 ctx b with
       | Some za, Some zb -> Some (Z3.Boolean.mk_eq zctx za zb)
       | _ -> None)
  | PExceeds (a, b) ->
      (match expr_to_z3 ctx a, expr_to_z3 ctx b with
       | Some za, Some zb -> Some (Z3.Arithmetic.mk_gt zctx za zb)
       | _ -> None)
  | PIsBelow (a, b) ->
      (match expr_to_z3 ctx a, expr_to_z3 ctx b with
       | Some za, Some zb -> Some (Z3.Arithmetic.mk_lt zctx za zb)
       | _ -> None)
  | PAnd (a, b) ->
      (match pred_to_z3 ctx a, pred_to_z3 ctx b with
       | Some za, Some zb -> Some (Z3.Boolean.mk_and zctx [za; zb])
       | _ -> None)
  | POr (a, b) ->
      (match pred_to_z3 ctx a, pred_to_z3 ctx b with
       | Some za, Some zb -> Some (Z3.Boolean.mk_or zctx [za; zb])
       | _ -> None)
  | PNot inner ->
      (match pred_to_z3 ctx inner with
       | Some z -> Some (Z3.Boolean.mk_not zctx z)
       | None -> None)
  (* Non-classical predicates: abstract as fresh unconstrained booleans.
     This is sound but conservative: may emit false WP-1 warnings when
     two modes' guards differ only in a temporal predicate. *)
  | PForNCycles _ | PForFewerCycles _ | PDeviates _ | PAgrees _ | PIsOneOf _ ->
      Some (fresh_bool zctx)

(** Format a Z3 model as "x = v; y = w" for error messages. *)
let format_model (m : Z3.Model.model) : string =
  let decls = Z3.Model.get_const_decls m in
  let parts = List.filter_map (fun d ->
    let n = Z3.Symbol.to_string (Z3.FuncDecl.get_name d) in
    if String.length n > 0 && n.[0] = '_' then None
    else
      match Z3.Model.get_const_interp m d with
      | Some v -> Some (n ^ " = " ^ Z3.Expr.to_string v)
      | None -> None
  ) decls in
  String.concat "; " (List.sort compare parts)

(** Invoke Z3 on a list of constraints. *)
let solve (zctx : Z3.context) (assertions : Z3.Expr.expr list) =
  let solver = Z3.Solver.mk_solver zctx None in
  Z3.Solver.add solver assertions;
  match Z3.Solver.check solver [] with
  | Z3.Solver.SATISFIABLE   -> `Sat (Z3.Solver.get_model solver)
  | Z3.Solver.UNSATISFIABLE -> `Unsat
  | Z3.Solver.UNKNOWN       -> `Unknown

(** WP-1: Check that no two GWhen guards in [mode] can fire simultaneously. *)
let check_exclusivity (ctx : z3_ctx) (mode : mode) : diagnostic list =
  let guards = List.filter_map (fun (t : transition) ->
    match t.guard with
    | GWhen p -> Some p
    | GOtherwise -> None
  ) mode.transitions in
  let n = List.length guards in
  if n < 2 then []
  else begin
    let arr = Array.of_list guards in
    let ds = ref [] in
    for i = 0 to n - 2 do
      for j = i + 1 to n - 1 do
        match pred_to_z3 ctx arr.(i), pred_to_z3 ctx arr.(j) with
        | None, _ | _, None ->
            ds := { severity = Info; code = "Z3-WP1"; mode_name = mode.name;
                    message = Printf.sprintf
                      "Rules %d and %d: guard could not be translated; exclusivity check skipped."
                      (i + 1) (j + 1);
                    counterexample = "" } :: !ds
        | Some zi, Some zj ->
            (match solve ctx.zctx (ctx.constraints @ [zi; zj]) with
             | `Sat (Some m) ->
                 ds := { severity = Error; code = "Z3-WP1"; mode_name = mode.name;
                         message = Printf.sprintf
                           "Rules %d and %d have overlapping guards." (i + 1) (j + 1);
                         counterexample = format_model m } :: !ds
             | `Sat None ->
                 ds := { severity = Error; code = "Z3-WP1"; mode_name = mode.name;
                         message = Printf.sprintf
                           "Rules %d and %d have overlapping guards." (i + 1) (j + 1);
                         counterexample = "" } :: !ds
             | `Unknown ->
                 ds := { severity = Error; code = "Z3-WP1"; mode_name = mode.name;
                         message = Printf.sprintf
                           "Rules %d and %d: Z3 could not determine guard exclusivity."
                           (i + 1) (j + 1);
                         counterexample = "" } :: !ds
             | `Unsat -> ())
      done
    done;
    !ds
  end

(** WP-2: Check that the GWhen guards (collectively) cover every possible input
    for modes that have no GOtherwise fallback. *)
let check_completeness (ctx : z3_ctx) (mode : mode) : diagnostic list =
  let has_otherwise = List.exists
    (fun (t : transition) -> t.guard = GOtherwise)
    mode.transitions in
  if has_otherwise then []
  else begin
    let z3_guards = List.filter_map (fun (t : transition) ->
      match t.guard with
      | GWhen p -> pred_to_z3 ctx p
      | GOtherwise -> None
    ) mode.transitions in
    if z3_guards = [] then
      [{ severity = Error; code = "Z3-WP2"; mode_name = mode.name;
         message = "Mode has no guards and no Otherwise clause.";
         counterexample = "" }]
    else begin
      let disjunction = Z3.Boolean.mk_or ctx.zctx z3_guards in
      let negated = Z3.Boolean.mk_not ctx.zctx disjunction in
      match solve ctx.zctx (ctx.constraints @ [negated]) with
      | `Sat (Some m) ->
          [{ severity = Error; code = "Z3-WP2"; mode_name = mode.name;
             message = "Guards are incomplete: there exists an input covered by no guard.";
             counterexample = format_model m }]
      | `Sat None ->
          [{ severity = Error; code = "Z3-WP2"; mode_name = mode.name;
             message = "Guards are incomplete: there exists an input covered by no guard.";
             counterexample = "" }]
      | `Unknown ->
          [{ severity = Error; code = "Z3-WP2"; mode_name = mode.name;
             message = "Z3 could not determine guard completeness.";
             counterexample = "" }]
      | `Unsat -> []
    end
  end

(** Public entry point: check all modes in [spec] for WP-1 and WP-2.
    Returns diagnostics ordered by mode, then by rule index. *)
let check_spec (spec : spec) : diagnostic list =
  opaque_counter := 0;
  let ctx = build_context spec in
  (* Add always_invariants as hard constraints so the Z3 solver operates
     over the invariant-restricted input space, preventing false WP-2
     "incomplete guards" positives when always clauses narrow the domain. *)
  let ctx = List.fold_left (fun c p ->
    match pred_to_z3 c p with
    | Some z -> add_constraint c z
    | None -> c
  ) ctx spec.always_invariants in
  List.concat_map (fun mode ->
    check_exclusivity ctx mode @ check_completeness ctx mode
  ) spec.modes
