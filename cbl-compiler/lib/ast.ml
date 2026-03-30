(** CBL AST type definitions *)

(** Source location for error reporting *)
type loc = {
  line : int;
  col : int;
}
[@@deriving show, yojson]

(** Type annotations *)
type cbl_type =
  | TBool
  | TInt of int option * int option  (* lower bound, upper bound *)
  | TReal of float option * float option
  | TEnum of string list
[@@deriving show, yojson]

(** Binary operators *)
type binop =
  | Add | Sub | Mul | Div
  | Lt | Gt | Le | Ge | Eq | Ne
  | And | Or
[@@deriving show, yojson]

(** Unary operators *)
type unop =
  | Not
  | Neg
[@@deriving show, yojson]

(** Expressions *)
type expr =
  | EInt of int
  | EReal of float
  | EBool of bool
  | EVar of string
  | EBinop of binop * expr * expr
  | EUnop of unop * expr
  | EAverage of expr list
  | EMedian of expr list
[@@deriving show, yojson]

(** Guard predicates *)
type predicate =
  | PTrue
  | PFalse
  | PExpr of expr
  | PIsTrue of expr
  | PIsFalse of expr
  | PEquals of expr * expr
  | PExceeds of expr * expr
  | PIsBelow of expr * expr
  | PDeviates of expr * expr list * expr  (* value, references, threshold *)
  | PAgrees of expr * expr list * expr     (* value, references, threshold *)
  | PIsOneOf of expr * string list         (* value, enum members *)
  | PForNCycles of expr * predicate         (* N (literal or constant), base predicate *)
  | PForFewerCycles of expr * predicate     (* N (literal or constant), base predicate *)
  | PAnd of predicate * predicate
  | POr of predicate * predicate
  | PNot of predicate
[@@deriving show, yojson]

(** Guard with optional timing predicate *)
type guard =
  | GWhen of predicate
  | GOtherwise
[@@deriving show, yojson]

(** Actions in shall blocks *)
type action =
  | ASet of string * expr
  | AHold of string
  | AIncrement of string
  | AReset of string
[@@deriving show, yojson]

(** Transition target *)
type target =
  | TTransition of string  (* mode name *)
  | TRemain
[@@deriving show, yojson]

(** Transition rule *)
type transition = {
  guard : guard;
  actions : action list;
  target : target;
  loc : loc option;
}
[@@deriving show, yojson]

(** Entry actions block *)
type entry_block = action list
[@@deriving show, yojson]

(** Mode definition *)
type mode = {
  name : string;
  entry_actions : entry_block option;
  invariants : predicate list;
  transitions : transition list;
  loc : loc option;
}
[@@deriving show, yojson]

(** Assumption declaration *)
type assumption = {
  name : string;
  atype : cbl_type;
  loc : loc option;
}
[@@deriving show, yojson]

(** Definition (predicate alias) *)
type definition = {
  name : string;
  body : predicate;
  loc : loc option;
}
[@@deriving show, yojson]

(** Constant declaration *)
type constant = {
  name : string;
  ctype : cbl_type;
  value : expr;
  loc : loc option;
}
[@@deriving show, yojson]

(** Guarantee (output) declaration *)
type guarantee = {
  name : string;
  gtype : cbl_type;
  default : expr option;  (* [default: value] or [default: hold] *)
  loc : loc option;
}
[@@deriving show, yojson]

(** Variable declaration *)
type variable = {
  name : string;
  vtype : cbl_type;
  initial : expr option;
  loc : loc option;
}
[@@deriving show, yojson]

(** Complete CBL specification *)
type spec = {
  system_name : string;
  assumes : assumption list;
  definitions : definition list;
  constants : constant list;
  guarantees : guarantee list;
  variables : variable list;
  always_invariants : predicate list;
  initial_mode : string;
  modes : mode list;
  loc : loc option;
}
[@@deriving show, yojson]
