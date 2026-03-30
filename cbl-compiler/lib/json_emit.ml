(** JSON IR emission for CBL specifications *)

open Ast

(** Convert AST to JSON using Yojson *)

let json_of_spec (spec : spec) : Yojson.Safe.t =
  spec_to_yojson spec

(** Write spec to JSON file *)
let emit_to_file (spec : spec) (filename : string) : unit =
  let json = json_of_spec spec in
  Yojson.Safe.to_file filename json

(** Convert spec to JSON string *)
let emit_to_string (spec : spec) : string =
  let json = json_of_spec spec in
  Yojson.Safe.to_string json

(** Pretty-print JSON to file *)
let emit_to_file_pretty (spec : spec) (filename : string) : unit =
  let json = json_of_spec spec in
  let oc = open_out filename in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    let s = Yojson.Safe.pretty_to_string json in
    output_string oc s
  )
