%{
open Ast

let loc_of_pos startpos = {
  line = startpos.Lexing.pos_lnum;
  col = startpos.Lexing.pos_cnum - startpos.Lexing.pos_bol;
}
%}

(* Terminals *)
%token <int> INT
%token <float> REAL
%token <string> IDENT

(* Keywords *)
%token SYSTEM ASSUMES DEFINITIONS CONSTANTS GUARANTEES VARIABLES
%token ALWAYS INITIAL MODE WHEN OTHERWISE SHALL
%token SET TO HOLD INCREMENT RESET TRANSITION REMAIN IN
%token ON ENTRY INVARIANT IS TRUE FALSE
%token TYPE_BOOLEAN TYPE_INTEGER TYPE_REAL SIGNAL
%token AND OR NOT FOR CONSECUTIVE CYCLES FEWER THAN
%token DEVIATES FROM BEYOND AGREES WITH WITHIN OF ONE
%token EXCEEDS BELOW EQUALS AVERAGE MEDIAN MEANS DEFAULT

(* Punctuation *)
%token COLON COMMA DOT LBRACE RBRACE LBRACKET RBRACKET LPAREN RPAREN
%token EQ PLUS MINUS STAR SLASH LT GT LE GE EQEQ NE DOTDOT INFINITY

%token EOF

(* Precedence and associativity *)
%left OR
%left AND
%nonassoc NOT
%left LT GT LE GE EQEQ NE
%left PLUS MINUS
%left STAR SLASH
%nonassoc UMINUS

%start <Ast.spec> specification

%%

(* ------------------------------------------------------------------ *)
(*  Top-level specification                                           *)
(* ------------------------------------------------------------------ *)

specification:
  | SYSTEM name = IDENT
    assumes_opt = assumes_section?
    defs_opt = definitions_section?
    consts_opt = constants_section?
    guarantees = guarantees_section
    vars_opt = variables_section?
    always_opt = always_section?
    INITIAL MODE COLON initial = IDENT
    modes = mode+
    EOF
    {
      {
        system_name = name;
        assumes = Option.value ~default:[] assumes_opt;
        definitions = Option.value ~default:[] defs_opt;
        constants = Option.value ~default:[] consts_opt;
        guarantees = guarantees;
        variables = Option.value ~default:[] vars_opt;
        always_invariants = Option.value ~default:[] always_opt;
        initial_mode = initial;
        modes = modes;
        loc = Some (loc_of_pos $startpos);
      }
    }

(* ------------------------------------------------------------------ *)
(*  Sections                                                          *)
(* ------------------------------------------------------------------ *)

assumes_section:
  | ASSUMES COLON assumes = assumption+ { assumes }

assumption:
  | name = IDENT IS atype = assume_type_decl
    { { name; atype; loc = None } }
  | name = IDENT
    { { name; atype = TBool; loc = None } }

assume_type_decl:
  | IDENT TYPE_BOOLEAN SIGNAL { TBool }
  | IDENT TYPE_INTEGER SIGNAL { TInt (None, None) }
  | IDENT TYPE_INTEGER SIGNAL LBRACKET lo = int_bound DOTDOT hi = int_bound RBRACKET
    { TInt (Some lo, Some hi) }
  | IDENT TYPE_REAL SIGNAL { TReal (None, None) }
  | IDENT TYPE_REAL SIGNAL LBRACKET lo = float_bound DOTDOT hi = float_bound RBRACKET
    { TReal (Some lo, Some hi) }

definitions_section:
  | DEFINITIONS COLON defs = definition+ { defs }

definition:
  | name = IDENT MEANS body = compound_predicate
    { { name; body; loc = None } }

constants_section:
  | CONSTANTS COLON consts = constant_decl+ { consts }

constant_decl:
  | name = IDENT COLON ctype = cbl_type EQ value = expr
    { { name; ctype; value; loc = None } }

guarantees_section:
  | GUARANTEES COLON guarantees = guarantee_decl+ { guarantees }

guarantee_decl:
  | name = IDENT COLON gtype = cbl_type default_opt = default_annotation?
    { { name; gtype; default = default_opt; loc = None } }

default_annotation:
  | LBRACKET DEFAULT COLON HOLD RBRACKET { EVar "__hold__" }
  | LBRACKET DEFAULT COLON value = expr RBRACKET { value }

variables_section:
  | VARIABLES COLON vars = variable_decl+ { vars }

variable_decl:
  | name = IDENT COLON vtype = cbl_type initial_opt = initial_value?
    { { name; vtype; initial = initial_opt; loc = None } }

initial_value:
  | EQ value = expr { value }

always_section:
  | ALWAYS COLON invs = compound_predicate+ { invs }

(* ------------------------------------------------------------------ *)
(*  Modes and transitions                                             *)
(* ------------------------------------------------------------------ *)

mode:
  | MODE name = IDENT COLON
    entry_opt = entry_section?
    invs = invariant_section?
    trans = transition+
    {
      {
        name;
        entry_actions = entry_opt;
        invariants = Option.value ~default:[] invs;
        transitions = trans;
        loc = None;
      }
    }

entry_section:
  | ON ENTRY COLON actions = action+ { actions }

invariant_section:
  | INVARIANT COLON invs = compound_predicate+ { invs }

(*
 * Transition rule.
 *
 * CBL syntax:
 *   When <guard>,
 *   shall <action>, <action>, ..., <target>.
 *
 * The comma between the last action and the target is the same token
 * as the comma between actions.  We avoid the COMMA shift-reduce
 * conflict by collecting actions and target in a right-recursive
 * helper (shall_body) instead of separated_nonempty_list.
 *)
transition:
  | g = guard COMMA SHALL body = shall_body DOT
    {
      let (acts, tgt) = body in
      { guard = g; actions = acts; target = tgt; loc = None }
    }

(*
 * Right-recursive: collects actions, terminates on target.
 * target starts with TRANSITION or REMAIN, which are disjoint
 * from action starts (SET, HOLD, INCREMENT, RESET).
 *)
shall_body:
  | tgt = target
    { ([], tgt) }
  | act = action COMMA rest = shall_body
    { let (acts, tgt) = rest in (act :: acts, tgt) }

guard:
  | WHEN pred = compound_predicate { GWhen pred }
  | OTHERWISE { GOtherwise }

(* ------------------------------------------------------------------ *)
(*  Predicates                                                        *)
(*                                                                    *)
(*  Split into compound (AND/OR/NOT connectives) and atomic forms.    *)
(*  This avoids reduce-reduce conflicts between predicate and expr.   *)
(*  TRUE/FALSE as standalone tokens are NOT parsed as predicates;     *)
(*  instead, the timing predicate form "true for N consecutive        *)
(*  cycles" is handled as a distinct production.                      *)
(* ------------------------------------------------------------------ *)

compound_predicate:
  | p1 = compound_predicate OR p2 = and_predicate
    { POr (p1, p2) }
  | p = and_predicate
    { p }

and_predicate:
  | p1 = and_predicate AND p2 = atomic_predicate
    { PAnd (p1, p2) }
  | NOT p = atomic_predicate
    { PNot p }
  | p = atomic_predicate
    { p }

atomic_predicate:
  (* Timing predicates *)
  | TRUE FOR n = cycle_count CONSECUTIVE CYCLES
    { PForNCycles (n, PTrue) }
  | e = simple_expr IS TRUE FOR n = cycle_count CONSECUTIVE CYCLES
    { PForNCycles (n, PIsTrue e) }
  | TRUE FOR FEWER THAN n = cycle_count CONSECUTIVE CYCLES
    { PForFewerCycles (n, PTrue) }
  | e = simple_expr IS TRUE FOR FEWER THAN n = cycle_count CONSECUTIVE CYCLES
    { PForFewerCycles (n, PIsTrue e) }

  (* Boolean predicates *)
  | e = simple_expr IS TRUE   { PIsTrue e }
  | e = simple_expr IS FALSE  { PIsFalse e }

  (* Comparison predicates *)
  | e1 = simple_expr EQUALS e2 = simple_expr
    { PEquals (e1, e2) }
  | e1 = simple_expr EXCEEDS e2 = simple_expr
    { PExceeds (e1, e2) }
  | e1 = simple_expr IS BELOW e2 = simple_expr
    { PIsBelow (e1, e2) }

  (* Set predicates *)
  | e = simple_expr DEVIATES FROM refs = simple_expr_list BEYOND thresh = simple_expr
    { PDeviates (e, refs, thresh) }
  | e = simple_expr AGREES WITH refs = simple_expr_list WITHIN thresh = simple_expr
    { PAgrees (e, refs, thresh) }
  | e = simple_expr IS ONE OF LBRACE members = ident_list RBRACE
    { PIsOneOf (e, members) }

  (* Parenthesized compound predicate *)
  | LPAREN p = compound_predicate RPAREN { p }

  (* Fallback: bare expression (e.g., a definition name) *)
  | e = simple_expr { PExpr e }

(* cycle_count: integer literal or constant name *)
cycle_count:
  | n = INT   { EInt n }
  | v = IDENT { EVar v }

(* ------------------------------------------------------------------ *)
(*  Actions                                                           *)
(* ------------------------------------------------------------------ *)

action:
  | SET name = IDENT TO value = expr { ASet (name, value) }
  | HOLD name = IDENT               { AHold name }
  | INCREMENT name = IDENT          { AIncrement name }
  | RESET name = IDENT              { AReset name }

target:
  | TRANSITION TO name = IDENT { TTransition name }
  | REMAIN IN _name = IDENT    { TRemain }

(* ------------------------------------------------------------------ *)
(*  Types                                                             *)
(* ------------------------------------------------------------------ *)

cbl_type:
  | TYPE_BOOLEAN { TBool }
  | TYPE_INTEGER { TInt (None, None) }
  | TYPE_INTEGER LBRACKET lo = int_bound DOTDOT hi = int_bound RPAREN
    { TInt (Some lo, Some hi) }
  | TYPE_INTEGER LBRACKET lo = int_bound DOTDOT hi = int_bound RBRACKET
    { TInt (Some lo, Some hi) }
  | TYPE_REAL { TReal (None, None) }
  | TYPE_REAL LBRACKET lo = float_bound DOTDOT hi = float_bound RBRACKET
    { TReal (Some lo, Some hi) }
  | LBRACE members = ident_list RBRACE { TEnum members }

int_bound:
  | n = INT       { n }
  | MINUS n = INT { - n }
  | INFINITY      { max_int }

float_bound:
  | r = REAL        { r }
  | n = INT         { float_of_int n }
  | MINUS r = REAL  { -. r }
  | MINUS n = INT   { -. (float_of_int n) }
  | INFINITY        { infinity }
  | MINUS INFINITY  { neg_infinity }

(* ------------------------------------------------------------------ *)
(*  Expressions                                                       *)
(*                                                                    *)
(*  Two levels: simple_expr (atoms, no operators) and expr (full      *)
(*  arithmetic).  simple_expr is used inside predicates so that       *)
(*  IS TRUE, EXCEEDS, EQUALS, etc. bind tighter than arithmetic.     *)
(* ------------------------------------------------------------------ *)

expr:
  | e = arith_expr { e }

arith_expr:
  | e1 = arith_expr PLUS e2 = arith_expr  { EBinop (Add, e1, e2) }
  | e1 = arith_expr MINUS e2 = arith_expr { EBinop (Sub, e1, e2) }
  | e1 = arith_expr STAR e2 = arith_expr  { EBinop (Mul, e1, e2) }
  | e1 = arith_expr SLASH e2 = arith_expr { EBinop (Div, e1, e2) }
  | MINUS e = arith_expr %prec UMINUS     { EUnop (Neg, e) }
  | e = simple_expr                        { e }

simple_expr:
  | n = INT                          { EInt n }
  | r = REAL                         { EReal r }
  | TRUE                             { EBool true }
  | FALSE                            { EBool false }
  | v = IDENT                        { EVar v }
  | LPAREN e = expr RPAREN           { e }
  | AVERAGE OF exprs = simple_expr_list { EAverage exprs }
  | MEDIAN OF exprs = simple_expr_list  { EMedian exprs }

simple_expr_list:
  | exprs = separated_nonempty_list(AND, simple_expr) { exprs }

ident_list:
  | idents = separated_nonempty_list(COMMA, IDENT) { idents }
