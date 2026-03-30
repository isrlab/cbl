(* Simple tests for CBL compiler *)

open Cbl_lib

let test_parse_traffic () =
  let open Ast in
  let spec =
    {
      system_name = "TrafficSignal";
      assumes = [];
      definitions = [];
      constants =
        [
          { name = "RED_CYCLES"; ctype = TInt (Some 1, Some 100); value = EInt 60; loc = None };
        ];
      guarantees =
        [
          {
            name = "light";
            gtype = TEnum ["red"; "green"; "yellow"];
            default = None;
            loc = None;
          };
        ];
      variables = [];
      always_invariants = [];
      initial_mode = "red";
      modes =
        [
          {
            name = "red";
            entry_actions = None;
            invariants = [];
            transitions =
              [
                {
                  guard = GWhen (PForNCycles (EInt 60, PTrue));
                  actions = [ASet ("light", EVar "green")];
                  target = TTransition "green";
                  loc = None;
                };
                {
                  guard = GOtherwise;
                  actions = [ASet ("light", EVar "red")];
                  target = TRemain;
                  loc = None;
                };
              ];
            loc = None;
          };
          {
            name = "green";
            entry_actions = None;
            invariants = [];
            transitions =
              [
                {
                  guard = GWhen (PForNCycles (EInt 45, PTrue));
                  actions = [ASet ("light", EVar "red")];
                  target = TTransition "red";
                  loc = None;
                };
                {
                  guard = GOtherwise;
                  actions = [ASet ("light", EVar "green")];
                  target = TRemain;
                  loc = None;
                };
              ];
            loc = None;
          };
        ];
      loc = None;
    }
  in
  let result = Checker.check spec in
  assert (result.Checker.errors = []);
  print_endline "✓ test_parse_traffic passed"

let test_predicate_roundtrip () =
  (* F-107: Integration test exercising equals, exceeds, is_below, binop,
     not, for_n_cycles, and/or through the Prolog-shaped JSON → nlp_bridge path. *)
  let json_str =
    let ic = open_in "predicate_roundtrip.json" in
    Fun.protect ~finally:(fun () -> close_in ic)
      (fun () -> let n = in_channel_length ic in really_input_string ic n)
  in
  let json = Yojson.Safe.from_string json_str in
  match Nlp_bridge.ingest_facts json with
  | Error errs ->
      List.iter (fun e -> Printf.eprintf "  ingest error: %s\n" e) errs;
      failwith "test_predicate_roundtrip: ingest_facts failed"
  | Ok spec ->
      assert (spec.system_name = "PredicateRoundtrip");
      assert (List.length spec.modes = 3);
      (* Run the checker to confirm no crashes; ignore Z3 overlap diagnostics
         since this fixture is designed to exercise predicate parsing, not
         guard well-posedness. *)
      let result = Checker.check spec in
      let non_z3_errors = List.filter (fun e ->
        match e with Checker.Z3Error _ -> false | _ -> true
      ) result.Checker.errors in
      if non_z3_errors <> [] then begin
        List.iter (fun e -> Printf.eprintf "  checker error: %s\n" (Checker.show_error e)) non_z3_errors;
        failwith "test_predicate_roundtrip: checker found non-Z3 errors"
      end;
      print_endline "✓ test_predicate_roundtrip passed"

let test_ingest_rejects_invalid_initial () =
  let json_str =
    {|{
  "schema_version": "0.1",
  "status": "pass",
  "diagnostics": [],
  "repairs": [],
  "questions": [],
  "committed_facts": {
    "schema_version": "0.1",
    "system_name": "BadInitial",
    "assumes": [],
    "definitions": [],
    "constants": [],
    "guarantees": [],
    "variables": [
      {"name": "v", "vtype": "integer", "initial": {"kind": "bogus"}, "provenance": "user_stated"}
    ],
    "always_invariants": [],
    "modes": [
      {"name": "M", "entry_actions": [], "invariants": [], "transitions": [], "provenance": "user_stated"}
    ],
    "initial_mode": {"value": "M", "provenance": "user_stated"}
  },
  "pending_facts": {}
}|}
  in
  let json = Yojson.Safe.from_string json_str in
  match Nlp_bridge.ingest_facts json with
  | Ok _ -> failwith "test_ingest_rejects_invalid_initial: expected failure"
  | Error _ -> print_endline "✓ test_ingest_rejects_invalid_initial passed"

let test_ingest_rejects_invalid_enum_member () =
  let json_str =
    {|{
  "schema_version": "0.1",
  "status": "pass",
  "diagnostics": [],
  "repairs": [],
  "questions": [],
  "committed_facts": {
    "schema_version": "0.1",
    "system_name": "BadEnum",
    "assumes": [],
    "definitions": [],
    "constants": [],
    "guarantees": [
      {"name": "g", "gtype": "{ok, bad-name}", "provenance": "user_stated"}
    ],
    "variables": [],
    "always_invariants": [],
    "modes": [
      {"name": "M", "entry_actions": [], "invariants": [], "transitions": [], "provenance": "user_stated"}
    ],
    "initial_mode": {"value": "M", "provenance": "user_stated"}
  },
  "pending_facts": {}
}|}
  in
  let json = Yojson.Safe.from_string json_str in
  match Nlp_bridge.ingest_facts json with
  | Ok _ -> failwith "test_ingest_rejects_invalid_enum_member: expected failure"
  | Error _ -> print_endline "✓ test_ingest_rejects_invalid_enum_member passed"

let test_ingest_rejects_pending_facts () =
  let json_str =
    {|{
  "schema_version": "0.1",
  "status": "pass",
  "diagnostics": [],
  "repairs": [],
  "questions": [],
  "committed_facts": {
    "schema_version": "0.1",
    "system_name": "PendingFacts",
    "assumes": [],
    "definitions": [],
    "constants": [],
    "guarantees": [],
    "variables": [],
    "always_invariants": [],
    "modes": [
      {"name": "M", "entry_actions": [], "invariants": [], "transitions": [], "provenance": "user_stated"}
    ],
    "initial_mode": {"value": "M", "provenance": "user_stated"}
  },
  "pending_facts": {
    "schema_version": "0.1",
    "modes": [
      {"name": "P", "entry_actions": [], "invariants": [], "transitions": []}
    ]
  }
}|}
  in
  let json = Yojson.Safe.from_string json_str in
  match Nlp_bridge.ingest_facts json with
  | Ok _ -> failwith "test_ingest_rejects_pending_facts: expected failure"
  | Error _ -> print_endline "✓ test_ingest_rejects_pending_facts passed"

let test_ingest_rejects_invalid_pending_type () =
  let json_str =
    {|{
  "schema_version": "0.1",
  "status": "pass",
  "diagnostics": [],
  "repairs": [],
  "questions": [],
  "committed_facts": {
    "schema_version": "0.1",
    "system_name": "PendingType",
    "assumes": [],
    "definitions": [],
    "constants": [],
    "guarantees": [],
    "variables": [],
    "always_invariants": [],
    "modes": [
      {"name": "M", "entry_actions": [], "invariants": [], "transitions": [], "provenance": "user_stated"}
    ],
    "initial_mode": {"value": "M", "provenance": "user_stated"}
  },
  "pending_facts": null
}|}
  in
  let json = Yojson.Safe.from_string json_str in
  match Nlp_bridge.ingest_facts json with
  | Ok _ -> failwith "test_ingest_rejects_invalid_pending_type: expected failure"
  | Error _ -> print_endline "✓ test_ingest_rejects_invalid_pending_type passed"

let test_action_type_mismatch () =
  let json_str =
    {|{
  "schema_version": "0.1",
  "status": "pass",
  "diagnostics": [],
  "repairs": [],
  "questions": [],
  "committed_facts": {
    "schema_version": "0.1",
    "system_name": "TypeMismatch",
    "assumes": [],
    "definitions": [],
    "constants": [],
    "guarantees": [
      {"name": "g", "gtype": "boolean", "provenance": "user_stated"}
    ],
    "variables": [],
    "always_invariants": [],
    "modes": [
      {
        "name": "M",
        "entry_actions": [],
        "invariants": [],
        "transitions": [
          {
            "guard": {"otherwise": true},
            "actions": [
              {"kind": "set", "name": "g", "value": {"kind": "int", "value": 1}}
            ],
            "target": {"remain": true}
          }
        ],
        "provenance": "user_stated"
      }
    ],
    "initial_mode": {"value": "M", "provenance": "user_stated"}
  },
  "pending_facts": {}
}|}
  in
  let json = Yojson.Safe.from_string json_str in
  match Nlp_bridge.ingest_facts json with
  | Error errs ->
      List.iter (fun e -> Printf.eprintf "  ingest error: %s\n" e) errs;
      failwith "test_action_type_mismatch: ingest_facts failed"
  | Ok spec ->
      let result = Checker.check spec in
      let has_type_mismatch = List.exists (function
        | Checker.TypeMismatch _ -> true
        | _ -> false
      ) result.Checker.errors in
      if not has_type_mismatch then
        failwith "test_action_type_mismatch: expected TypeMismatch error";
      print_endline "✓ test_action_type_mismatch passed"

let test_declaration_type_mismatch () =
  let json_str =
    {|{
  "schema_version": "0.1",
  "status": "pass",
  "diagnostics": [],
  "repairs": [],
  "questions": [],
  "committed_facts": {
    "schema_version": "0.1",
    "system_name": "DeclTypeMismatch",
    "assumes": [],
    "definitions": [],
    "constants": [
      {"name": "C", "ctype": "boolean", "cvalue": {"kind": "int", "value": 1}, "provenance": "user_stated"}
    ],
    "guarantees": [
      {
        "name": "g",
        "gtype": "integer",
        "provenance": "user_stated",
        "default": {"value": {"kind": "value", "value": {"kind": "bool", "value": true}}, "provenance": "default_assumed"}
      }
    ],
    "variables": [
      {"name": "v", "vtype": "real", "initial": {"kind": "int", "value": 5}, "provenance": "user_stated"}
    ],
    "always_invariants": [],
    "modes": [
      {"name": "M", "entry_actions": [], "invariants": [], "transitions": [], "provenance": "user_stated"}
    ],
    "initial_mode": {"value": "M", "provenance": "user_stated"}
  },
  "pending_facts": {}
}|}
  in
  let json = Yojson.Safe.from_string json_str in
  match Nlp_bridge.ingest_facts json with
  | Error errs ->
      List.iter (fun e -> Printf.eprintf "  ingest error: %s\n" e) errs;
      failwith "test_declaration_type_mismatch: ingest_facts failed"
  | Ok spec ->
      let result = Checker.check spec in
      let has_type_mismatch = List.exists (function
        | Checker.TypeMismatch _ -> true
        | _ -> false
      ) result.Checker.errors in
      if not has_type_mismatch then
        failwith "test_declaration_type_mismatch: expected TypeMismatch error";
      print_endline "✓ test_declaration_type_mismatch passed"

let test_rejects_uncommitted_provenance () =
  let json_str =
    {|{
  "schema_version": "0.1",
  "status": "pass",
  "diagnostics": [],
  "repairs": [],
  "questions": [],
  "committed_facts": {
    "schema_version": "0.1",
    "system_name": "BadProv",
    "assumes": [
      {"name": "x", "atype": "boolean", "provenance": "llm_inferred"}
    ],
    "definitions": [],
    "constants": [],
    "guarantees": [],
    "variables": [],
    "always_invariants": [],
    "modes": [
      {"name": "M", "entry_actions": [], "invariants": [], "transitions": [], "provenance": "user_stated"}
    ],
    "initial_mode": {"value": "M", "provenance": "user_stated"}
  },
  "pending_facts": {}
}|}
  in
  let json = Yojson.Safe.from_string json_str in
  match Nlp_bridge.ingest_facts json with
  | Ok _ -> failwith "test_rejects_uncommitted_provenance: expected failure"
  | Error _ -> print_endline "✓ test_rejects_uncommitted_provenance passed"

let test_entry_action_type_mismatch () =
  let json_str =
    {|{
  "schema_version": "0.1",
  "status": "pass",
  "diagnostics": [],
  "repairs": [],
  "questions": [],
  "committed_facts": {
    "schema_version": "0.1",
    "system_name": "EntryActionMismatch",
    "assumes": [],
    "definitions": [],
    "constants": [],
    "guarantees": [],
    "variables": [
      {"name": "v", "vtype": "integer", "provenance": "user_stated"}
    ],
    "always_invariants": [],
    "modes": [
      {
        "name": "M",
        "entry_actions": [
          {"kind": "set", "name": "v", "value": {"kind": "bool", "value": true}}
        ],
        "invariants": [],
        "transitions": [],
        "provenance": "user_stated"
      }
    ],
    "initial_mode": {"value": "M", "provenance": "user_stated"}
  },
  "pending_facts": {}
}|}
  in
  let json = Yojson.Safe.from_string json_str in
  match Nlp_bridge.ingest_facts json with
  | Error errs ->
      List.iter (fun e -> Printf.eprintf "  ingest error: %s\n" e) errs;
      failwith "test_entry_action_type_mismatch: ingest_facts failed"
  | Ok spec ->
      let result = Checker.check spec in
      let has_type_mismatch = List.exists (function
        | Checker.TypeMismatch _ -> true
        | _ -> false
      ) result.Checker.errors in
      if not has_type_mismatch then
        failwith "test_entry_action_type_mismatch: expected TypeMismatch error";
      print_endline "✓ test_entry_action_type_mismatch passed"

let test_invalid_action_target () =
  let json_str =
    {|{
  "schema_version": "0.1",
  "status": "pass",
  "diagnostics": [],
  "repairs": [],
  "questions": [],
  "committed_facts": {
    "schema_version": "0.1",
    "system_name": "BadTarget",
    "assumes": [],
    "definitions": [],
    "constants": [
      {"name": "C", "ctype": "integer", "cvalue": 1, "provenance": "user_stated"}
    ],
    "guarantees": [],
    "variables": [],
    "always_invariants": [],
    "modes": [
      {
        "name": "M",
        "entry_actions": [],
        "invariants": [],
        "transitions": [
          {
            "guard": {"otherwise": true},
            "actions": [
              {"kind": "set", "name": "C", "value": {"kind": "int", "value": 2}}
            ],
            "target": {"remain": true}
          }
        ],
        "provenance": "user_stated"
      }
    ],
    "initial_mode": {"value": "M", "provenance": "user_stated"}
  },
  "pending_facts": {}
}|}
  in
  let json = Yojson.Safe.from_string json_str in
  match Nlp_bridge.ingest_facts json with
  | Error errs ->
      List.iter (fun e -> Printf.eprintf "  ingest error: %s\n" e) errs;
      failwith "test_invalid_action_target: ingest_facts failed"
  | Ok spec ->
      let result = Checker.check spec in
      let invalid_target_count = List.fold_left (fun acc -> function
        | Checker.InvalidActionTarget _ -> acc + 1
        | _ -> acc
      ) 0 result.Checker.errors in
      let has_invalid_target = List.exists (function
        | Checker.InvalidActionTarget _ -> true
        | _ -> false
      ) result.Checker.errors in
      if not has_invalid_target then
        failwith "test_invalid_action_target: expected InvalidActionTarget error";
      if invalid_target_count <> 1 then
        failwith "test_invalid_action_target: expected exactly one InvalidActionTarget error";
      print_endline "✓ test_invalid_action_target passed"

let () =
  test_parse_traffic ();
  test_predicate_roundtrip ();
  test_ingest_rejects_invalid_initial ();
  test_ingest_rejects_invalid_enum_member ();
  test_ingest_rejects_pending_facts ();
  test_ingest_rejects_invalid_pending_type ();
  test_action_type_mismatch ();
  test_declaration_type_mismatch ();
  test_rejects_uncommitted_provenance ();
  test_entry_action_type_mismatch ();
  test_invalid_action_target ();
  print_endline "All tests passed!"
