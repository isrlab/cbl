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

let test_reason_ingest () =
  (* Step 2: provenance-aware ingestion of extracted_facts.json. Exercises
     tagged values, declaration provenance (from name), guarantee defaults,
     combined transition provenance, and open-question pass-through. *)
  let json_str =
    {|{
  "schema_version": "0.1",
  "provenance_attested": true,
  "system_name": { "value": "FdiMini", "provenance": "llm_inferred" },
  "assumes": [
    { "name": {"value":"s1","provenance":"user_stated"}, "atype": {"value":"real","provenance":"user_stated"} },
    { "name": {"value":"s2","provenance":"user_stated"}, "atype": {"value":"real","provenance":"user_stated"} }
  ],
  "definitions": [],
  "constants": [
    { "name": {"value":"n_fault","provenance":"llm_inferred"}, "ctype": {"value":"integer","provenance":"llm_inferred"}, "cvalue": {"value":5,"provenance":"user_stated"} }
  ],
  "guarantees": [
    { "name": {"value":"fused_value","provenance":"user_stated"}, "gtype": {"value":"real","provenance":"user_stated"}, "default": {"value":{"kind":"hold"},"provenance":"llm_inferred"} },
    { "name": {"value":"status","provenance":"user_stated"}, "gtype": {"value":"{all_healthy, s1_isolated}","provenance":"llm_inferred"}, "default": null }
  ],
  "variables": [],
  "always_invariants": [],
  "initial_mode": { "value":"all_healthy", "provenance":"llm_inferred" },
  "modes": [
    {
      "name": {"value":"all_healthy","provenance":"llm_inferred"},
      "entry_actions": [],
      "invariants": [],
      "transitions": [
        {
          "guard": {"value":{"otherwise":true},"provenance":"user_stated"},
          "actions": [
            {"kind":"set","name":"fused_value","value":{"kind":"median","operands":[{"kind":"var","name":"s1"},{"kind":"var","name":"s2"}]},"provenance":"user_stated"},
            {"kind":"set","name":"status","value":{"kind":"string","value":"all_healthy"},"provenance":"user_stated"}
          ],
          "target": {"value":{"remain":true},"provenance":"user_stated"}
        }
      ]
    },
    {
      "name": {"value":"s1_isolated","provenance":"llm_inferred"},
      "entry_actions": [],
      "invariants": [],
      "transitions": []
    }
  ],
  "open_questions": [
    {"question_id":"q1","text":"What about s1_isolated?","relates_to":"s1_isolated","category":"missing_transition","suggested_options":["a","b"]}
  ]
}|}
  in
  let json = Yojson.Safe.from_string json_str in
  match Reason.ingest json with
  | Error errs ->
      List.iter (fun e -> Printf.eprintf "  ingest error: %s\n" e) errs;
      failwith "test_reason_ingest: ingest failed"
  | Ok ing ->
      let s = ing.Reason.spec in
      assert (s.Ast.system_name = "FdiMini");
      assert (List.length s.Ast.assumes = 2);
      assert (List.length s.Ast.constants = 1);
      assert (List.length s.Ast.guarantees = 2);
      assert (List.length s.Ast.modes = 2);
      assert (s.Ast.initial_mode = "all_healthy");
      assert (List.length ing.Reason.questions = 1);
      let prov_of kind name =
        match List.find_opt (fun e ->
          e.Reason.kind = kind && e.Reason.pname = name) ing.Reason.provs
        with Some e -> e.Reason.provenance | None -> "<none>"
      in
      assert (prov_of "assume" "s1" = "user_stated");
      assert (prov_of "constant" "n_fault" = "llm_inferred");          (* name provenance *)
      assert (prov_of "guarantee" "status" = "user_stated");           (* name provenance *)
      assert (prov_of "guarantee_default" "fused_value" = "llm_inferred");
      assert (prov_of "guarantee_default" "status" = "<none>");        (* null default: not recorded *)
      assert (prov_of "mode" "s1_isolated" = "llm_inferred");
      assert (prov_of "initial_mode" "all_healthy" = "llm_inferred");
      assert (prov_of "transition" "all_healthy_1" = "user_stated");   (* combined: all user_stated *)
      print_endline "✓ test_reason_ingest passed"

let test_reason_rules () =
  (* Step 3: R1 (empty mode), R5b (no initial mode), R13 (unused). *)
  let has diags code = List.exists (fun d -> d.Reason.code = code) diags in
  let has_named diags code name =
    List.exists (fun d -> d.Reason.code = code && d.Reason.loc_name = name) diags
  in
  (* Case A: empty mode M2; assume y and constant k unused; x and g used. *)
  let case_a =
    {|{
  "schema_version":"0.1","provenance_attested":true,
  "system_name":{"value":"Rules","provenance":"user_stated"},
  "assumes":[
    {"name":{"value":"x","provenance":"user_stated"},"atype":{"value":"boolean","provenance":"user_stated"}},
    {"name":{"value":"y","provenance":"user_stated"},"atype":{"value":"boolean","provenance":"user_stated"}}
  ],
  "definitions":[],
  "constants":[
    {"name":{"value":"k","provenance":"user_stated"},"ctype":{"value":"integer","provenance":"user_stated"},"cvalue":{"value":1,"provenance":"user_stated"}}
  ],
  "guarantees":[
    {"name":{"value":"g","provenance":"user_stated"},"gtype":{"value":"boolean","provenance":"user_stated"},"default":null}
  ],
  "variables":[],"always_invariants":[],
  "initial_mode":{"value":"M1","provenance":"user_stated"},
  "modes":[
    {"name":{"value":"M1","provenance":"user_stated"},"entry_actions":[],"invariants":[],
     "transitions":[
       {"guard":{"value":{"when":{"kind":"is_true","expr":{"kind":"var","name":"x"}}},"provenance":"user_stated"},
        "actions":[{"kind":"set","name":"g","value":{"kind":"bool","value":true},"provenance":"user_stated"}],
        "target":{"value":{"remain":true},"provenance":"user_stated"}}
     ]},
    {"name":{"value":"M2","provenance":"user_stated"},"entry_actions":[],"invariants":[],"transitions":[]}
  ],
  "open_questions":[]
}|}
  in
  (match Reason.ingest (Yojson.Safe.from_string case_a) with
   | Error errs -> List.iter (Printf.eprintf "  %s\n") errs; failwith "test_reason_rules A: ingest failed"
   | Ok ing ->
       let d = Reason.reasoning_diagnostics ing in
       assert (has_named d "empty_mode" "M2");
       assert (has_named d "unused" "y");
       assert (has_named d "unused" "k");
       assert (not (has_named d "unused" "x"));   (* used in guard *)
       assert (not (has_named d "unused" "g"));   (* used as set target *)
       assert (not (has d "no_initial_mode")));
  (* Case B: no initial_mode declared -> R5b. *)
  let case_b =
    {|{
  "schema_version":"0.1","provenance_attested":true,
  "system_name":{"value":"NoInit","provenance":"user_stated"},
  "assumes":[],"definitions":[],"constants":[],"guarantees":[],"variables":[],"always_invariants":[],
  "modes":[
    {"name":{"value":"M","provenance":"user_stated"},"entry_actions":[],"invariants":[],
     "transitions":[{"guard":{"value":{"otherwise":true},"provenance":"user_stated"},"actions":[],"target":{"value":{"remain":true},"provenance":"user_stated"}}]}
  ],
  "open_questions":[]
}|}
  in
  (match Reason.ingest (Yojson.Safe.from_string case_b) with
   | Error errs -> List.iter (Printf.eprintf "  %s\n") errs; failwith "test_reason_rules B: ingest failed"
   | Ok ing ->
       let d = Reason.reasoning_diagnostics ing in
       assert (has d "no_initial_mode");
       assert (not (has d "empty_mode")));   (* M has a transition *)
  print_endline "✓ test_reason_rules passed"

let test_reason_provenance () =
  (* Step 4: R8 (unknown value), R9 (unconfirmed llm_inferred), R9b (default). *)
  let has diags code = List.exists (fun d -> d.Reason.code = code) diags in
  let has_named diags code name =
    List.exists (fun d -> d.Reason.code = code && d.Reason.loc_name = name) diags
  in
  let json =
    {|{
  "schema_version":"0.1","provenance_attested":true,
  "system_name":{"value":"Prov","provenance":"llm_inferred"},
  "assumes":[{"name":{"value":"s1","provenance":"user_stated"},"atype":{"value":"real","provenance":"user_stated"}}],
  "definitions":[],
  "constants":[
    {"name":{"value":"n_fault","provenance":"llm_inferred"},"ctype":{"value":"integer","provenance":"llm_inferred"},"cvalue":{"value":5,"provenance":"user_stated"}},
    {"name":{"value":"unk","provenance":"user_stated"},"ctype":{"value":"integer","provenance":"user_stated"},"cvalue":{"value":"__unknown__","provenance":"user_stated"}}
  ],
  "guarantees":[
    {"name":{"value":"fused_value","provenance":"user_stated"},"gtype":{"value":"real","provenance":"user_stated"},"default":{"value":{"kind":"hold"},"provenance":"llm_inferred"}}
  ],
  "variables":[],"always_invariants":[],
  "initial_mode":{"value":"M","provenance":"user_stated"},
  "modes":[{"name":{"value":"M","provenance":"user_stated"},"entry_actions":[],"invariants":[],
    "transitions":[{"guard":{"value":{"otherwise":true},"provenance":"user_stated"},
      "actions":[{"kind":"set","name":"fused_value","value":{"kind":"var","name":"s1"},"provenance":"user_stated"}],
      "target":{"value":{"remain":true},"provenance":"user_stated"}}]}],
  "open_questions":[]
}|}
  in
  (match Reason.ingest (Yojson.Safe.from_string json) with
   | Error errs -> List.iter (Printf.eprintf "  %s\n") errs; failwith "test_reason_provenance: ingest failed"
   | Ok ing ->
       let d = Reason.reasoning_diagnostics ing in
       assert (has_named d "unconfirmed" "n_fault");          (* R9: llm_inferred constant *)
       assert (has_named d "unknown_value" "unk");            (* R8 *)
       assert (has_named d "unconfirmed_default" "fused_value"); (* R9b *)
       assert (not (has_named d "unconfirmed" "Prov"));       (* system_name excluded from R9 *)
       assert (not (has_named d "unconfirmed" "s1"));         (* user_stated, not flagged *)
       assert (has d "unconfirmed"));
  print_endline "✓ test_reason_provenance passed"

let test_facts_roundtrip () =
  (* Step 5: serialize an AST to committed_facts JSON, re-ingest it through
     nlp_bridge, and confirm the round trip is lossless (same emitted CBL). *)
  let open Ast in
  let spec =
    {
      system_name = "RT";
      assumes = [
        { name = "x"; atype = TBool; loc = None };
        { name = "s1"; atype = TReal (None, None); loc = None };
      ];
      definitions = [ { name = "d"; body = PIsTrue (EVar "x"); loc = None } ];
      constants = [ { name = "k"; ctype = TInt (Some 1, Some 5); value = EInt 3; loc = None } ];
      guarantees = [
        { name = "light"; gtype = TEnum ["red"; "green"]; default = Some (EVar "__hold__"); loc = None };
        { name = "v"; gtype = TReal (None, None); default = None; loc = None };
      ];
      variables = [ { name = "c"; vtype = TInt (Some 0, Some 10); initial = Some (EInt 0); loc = None } ];
      always_invariants = [];
      initial_mode = "M";
      modes = [
        {
          name = "M";
          entry_actions = Some [ ASet ("v", EVar "s1") ];
          invariants = [];
          transitions = [
            { guard = GWhen (PIsTrue (EVar "x"));
              actions = [ ASet ("light", EVar "green"); ASet ("v", EAverage [EVar "s1"; EVar "s1"]) ];
              target = TTransition "M"; loc = None };
            { guard = GOtherwise;
              actions = [ ASet ("light", EVar "red"); AHold "v" ];
              target = TRemain; loc = None };
          ];
          loc = None;
        }
      ];
      loc = None;
    }
  in
  let cf = Reason.fact_partition_json (fun _ _ -> "user_stated") spec in
  let verdict =
    `Assoc [
      ("schema_version", `String "0.1");
      ("status", `String "pass");
      ("diagnostics", `List []);
      ("repairs", `List []);
      ("questions", `List []);
      ("committed_facts", cf);
      ("pending_facts", `Assoc [ ("schema_version", `String "0.1") ]);
    ]
  in
  match Nlp_bridge.ingest_facts verdict with
  | Error errs ->
      List.iter (fun e -> Printf.eprintf "  ingest error: %s\n" e) errs;
      failwith "test_facts_roundtrip: re-ingest failed"
  | Ok spec' ->
      let a = Nlp_bridge.emit_cbl spec and b = Nlp_bridge.emit_cbl spec' in
      if a <> b then begin
        Printf.eprintf "--- original ---\n%s\n--- round-tripped ---\n%s\n" a b;
        failwith "test_facts_roundtrip: CBL differs after round trip"
      end;
      print_endline "✓ test_facts_roundtrip passed"

let test_reason_partition () =
  (* Step 6: committed/pending split. fdi-mini: assumes + guarantees are
     user_stated (committed); constant, modes, initial_mode, system_name are
     llm_inferred (pending). *)
  let json =
    {|{
  "schema_version":"0.1","provenance_attested":true,
  "system_name":{"value":"FdiMini","provenance":"llm_inferred"},
  "assumes":[
    {"name":{"value":"s1","provenance":"user_stated"},"atype":{"value":"real","provenance":"user_stated"}},
    {"name":{"value":"s2","provenance":"user_stated"},"atype":{"value":"real","provenance":"user_stated"}}
  ],
  "definitions":[],
  "constants":[
    {"name":{"value":"n_fault","provenance":"llm_inferred"},"ctype":{"value":"integer","provenance":"llm_inferred"},"cvalue":{"value":5,"provenance":"user_stated"}}
  ],
  "guarantees":[
    {"name":{"value":"fused_value","provenance":"user_stated"},"gtype":{"value":"real","provenance":"user_stated"},"default":{"value":{"kind":"hold"},"provenance":"llm_inferred"}},
    {"name":{"value":"status","provenance":"user_stated"},"gtype":{"value":"{all_healthy, s1_isolated}","provenance":"llm_inferred"},"default":null}
  ],
  "variables":[],"always_invariants":[],
  "initial_mode":{"value":"all_healthy","provenance":"llm_inferred"},
  "modes":[
    {"name":{"value":"all_healthy","provenance":"llm_inferred"},"entry_actions":[],"invariants":[],
     "transitions":[{"guard":{"value":{"otherwise":true},"provenance":"user_stated"},
       "actions":[{"kind":"set","name":"fused_value","value":{"kind":"var","name":"s1"},"provenance":"user_stated"},
                  {"kind":"set","name":"status","value":{"kind":"string","value":"all_healthy"},"provenance":"user_stated"}],
       "target":{"value":{"remain":true},"provenance":"user_stated"}}]},
    {"name":{"value":"s1_isolated","provenance":"llm_inferred"},"entry_actions":[],"invariants":[],"transitions":[]}
  ],
  "open_questions":[]
}|}
  in
  match Reason.ingest (Yojson.Safe.from_string json) with
  | Error errs -> List.iter (Printf.eprintf "  %s\n") errs; failwith "test_reason_partition: ingest failed"
  | Ok ing ->
      let c, p = Reason.partition ing in
      assert (List.length c.Ast.assumes = 2);
      assert (List.length c.Ast.guarantees = 2);
      assert (c.Ast.constants = []);
      assert (c.Ast.modes = []);
      assert (c.Ast.initial_mode = "");
      assert (c.Ast.system_name = "");
      assert (List.length p.Ast.constants = 1);
      assert (List.length p.Ast.modes = 2);
      assert (p.Ast.initial_mode = "all_healthy");
      assert (p.Ast.system_name = "FdiMini");
      print_endline "✓ test_reason_partition passed"

let test_reason_repairs () =
  (* Step 7: structural repairs (add_otherwise, add_transition, add_action,
     suggest_target/add_mode) and ask_user repairs, with for_diagnostic strings
     matching Prolog's term printing. *)
  let json =
    {|{
  "schema_version":"0.1","provenance_attested":true,
  "system_name":{"value":"Rep","provenance":"user_stated"},
  "assumes":[{"name":{"value":"x","provenance":"user_stated"},"atype":{"value":"boolean","provenance":"user_stated"}}],
  "definitions":[],
  "constants":[{"name":{"value":"n_fault","provenance":"llm_inferred"},"ctype":{"value":"integer","provenance":"llm_inferred"},"cvalue":{"value":5,"provenance":"user_stated"}}],
  "guarantees":[{"name":{"value":"g","provenance":"user_stated"},"gtype":{"value":"boolean","provenance":"user_stated"},"default":null}],
  "variables":[],"always_invariants":[],
  "initial_mode":{"value":"M1","provenance":"user_stated"},
  "modes":[
    {"name":{"value":"M1","provenance":"user_stated"},"entry_actions":[],"invariants":[],
     "transitions":[{"guard":{"value":{"when":{"kind":"is_true","expr":{"kind":"var","name":"x"}}},"provenance":"user_stated"},
       "actions":[{"kind":"set","name":"g","value":{"kind":"bool","value":true},"provenance":"user_stated"}],
       "target":{"value":{"transition_to":"M2x"},"provenance":"user_stated"}}]},
    {"name":{"value":"M2","provenance":"user_stated"},"entry_actions":[],"invariants":[],
     "transitions":[
       {"guard":{"value":{"when":{"kind":"is_true","expr":{"kind":"var","name":"x"}}},"provenance":"user_stated"},
        "actions":[],"target":{"value":{"remain":true},"provenance":"user_stated"}},
       {"guard":{"value":{"otherwise":true},"provenance":"user_stated"},
        "actions":[{"kind":"set","name":"g","value":{"kind":"bool","value":false},"provenance":"user_stated"}],
        "target":{"value":{"remain":true},"provenance":"user_stated"}}
     ]},
    {"name":{"value":"M3","provenance":"user_stated"},"entry_actions":[],"invariants":[],"transitions":[]}
  ],
  "open_questions":[]
}|}
  in
  match Reason.ingest (Yojson.Safe.from_string json) with
  | Error errs -> List.iter (Printf.eprintf "  %s\n") errs; failwith "test_reason_repairs: ingest failed"
  | Ok ing ->
      let rs = Reason.repairs ing (Reason.reasoning_diagnostics ing) in
      let fds = List.map (fun (r : Reason.repair) -> r.Reason.for_diagnostic) rs in
      assert (List.mem "guard_incomplete(M1)" fds);          (* M1 has no Otherwise *)
      assert (List.mem "empty_mode(M3)" fds);
      assert (List.mem "invalid_target(M1,1,M2x)" fds);
      assert (List.mem "missing_assignment(M2,1,g)" fds);    (* M2's When sets nothing *)
      assert (List.mem "unconfirmed(n_fault,constant)" fds); (* session.py contract *)
      (* suggest_target offers the near-miss mode M2 *)
      let action_field (r : Reason.repair) key =
        match r.Reason.action with `Assoc kvs -> List.assoc_opt key kvs | _ -> None
      in
      let suggest = List.find_opt (fun r -> action_field r "action" = Some (`String "suggest_target")) rs in
      (match suggest with
       | Some r -> (match action_field r "candidates" with
           | Some (`List cands) -> assert (List.mem (`String "M2") cands)
           | _ -> failwith "test_reason_repairs: suggest_target missing candidates")
       | None -> failwith "test_reason_repairs: no suggest_target repair");
      (* ask_user repair shape + provenance in the serialized form *)
      let unconf = List.find (fun (r : Reason.repair) -> r.Reason.for_diagnostic = "unconfirmed(n_fault,constant)") rs in
      assert (action_field unconf "action" = Some (`String "ask_user"));
      assert (action_field unconf "name" = Some (`String "n_fault"));
      (match Reason.repair_to_json unconf with
       | `Assoc kvs -> assert (List.assoc_opt "provenance" kvs = Some (`String "rule_derived"))
       | _ -> failwith "bad repair json");
      print_endline "✓ test_reason_repairs passed"

let test_reason_questions () =
  (* Step 8: pass-through open question + derived confirmation questions, with
     the exact text session.py greps. *)
  let json =
    {|{
  "schema_version":"0.1","provenance_attested":true,
  "system_name":{"value":"Q","provenance":"user_stated"},
  "assumes":[],"definitions":[],
  "constants":[{"name":{"value":"n_fault","provenance":"llm_inferred"},"ctype":{"value":"integer","provenance":"llm_inferred"},"cvalue":{"value":5,"provenance":"user_stated"}}],
  "guarantees":[{"name":{"value":"fused_value","provenance":"user_stated"},"gtype":{"value":"real","provenance":"user_stated"},"default":{"value":{"kind":"hold"},"provenance":"llm_inferred"}}],
  "variables":[],"always_invariants":[],
  "initial_mode":{"value":"M","provenance":"user_stated"},
  "modes":[{"name":{"value":"M","provenance":"user_stated"},"entry_actions":[],"invariants":[],
    "transitions":[{"guard":{"value":{"otherwise":true},"provenance":"user_stated"},
      "actions":[{"kind":"set","name":"fused_value","value":{"kind":"int","value":0},"provenance":"user_stated"}],
      "target":{"value":{"remain":true},"provenance":"user_stated"}}]}],
  "open_questions":[{"question_id":"q1","text":"Original?","relates_to":"M","category":"missing_transition","suggested_options":["a","b"]}]
}|}
  in
  match Reason.ingest (Yojson.Safe.from_string json) with
  | Error errs -> List.iter (Printf.eprintf "  %s\n") errs; failwith "test_reason_questions: ingest failed"
  | Ok ing ->
      let qs = Reason.questions_json ing (Reason.reasoning_diagnostics ing) in
      let field key j = match j with `Assoc kvs -> (match List.assoc_opt key kvs with Some (`String s) -> Some s | _ -> None) | _ -> None in
      let texts = List.filter_map (field "text") qs in
      let ids = List.filter_map (field "question_id") qs in
      assert (List.mem "q1" ids);                                  (* pass-through *)
      assert (List.mem "Original?" texts);
      assert (List.mem "repair_confirm_n_fault" ids);
      assert (List.mem "The LLM inferred constant 'n_fault'. Is this correct?" texts);
      assert (List.mem "repair_confirm_default_fused_value" ids);
      assert (List.mem "The LLM inferred a default for guarantee 'fused_value'. Is this correct?" texts);
      (* the unconfirmed question carries the confirm_inference category + Yes/No *)
      let qn = List.find (fun j -> field "question_id" j = Some "repair_confirm_n_fault") qs in
      assert (field "category" qn = Some "confirm_inference");
      (match qn with
       | `Assoc kvs -> assert (List.assoc_opt "suggested_options" kvs = Some (`List [`String "Yes"; `String "No"]))
       | _ -> failwith "bad question json");
      print_endline "✓ test_reason_questions passed"

let test_reason_verdict () =
  (* Step 9: status determination + verdict assembly. *)
  let status_of json =
    match Reason.ingest (Yojson.Safe.from_string json) with
    | Error errs -> List.iter (Printf.eprintf "  %s\n") errs; failwith "test_reason_verdict: ingest failed"
    | Ok ing ->
        let v, code = Reason.verdict ing in
        (match v with
         | `Assoc kvs ->
             (* required top-level keys present *)
             List.iter (fun k -> assert (List.mem_assoc k kvs))
               ["schema_version"; "status"; "diagnostics"; "repairs"; "questions";
                "committed_facts"; "pending_facts"];
             let s = match List.assoc "status" kvs with `String s -> s | _ -> "?" in
             (s, code)
         | _ -> failwith "verdict not an object")
  in
  (* pass: fully committed, well-posed, no llm_inferred. *)
  let s, code = status_of
    {|{"schema_version":"0.1","provenance_attested":true,
      "system_name":{"value":"OK","provenance":"user_stated"},
      "assumes":[],"definitions":[],"constants":[],
      "guarantees":[{"name":{"value":"g","provenance":"user_stated"},"gtype":{"value":"boolean","provenance":"user_stated"},"default":null}],
      "variables":[],"always_invariants":[],
      "initial_mode":{"value":"M","provenance":"user_stated"},
      "modes":[{"name":{"value":"M","provenance":"user_stated"},"entry_actions":[],"invariants":[],
        "transitions":[{"guard":{"value":{"otherwise":true},"provenance":"user_stated"},
          "actions":[{"kind":"set","name":"g","value":{"kind":"bool","value":true},"provenance":"user_stated"}],
          "target":{"value":{"remain":true},"provenance":"user_stated"}}]}],
      "open_questions":[]}|}
  in
  assert (s = "pass"); assert (code = 0);
  (* incomplete: an llm_inferred fact, no structural errors. *)
  let s, code = status_of
    {|{"schema_version":"0.1","provenance_attested":true,
      "system_name":{"value":"Inc","provenance":"user_stated"},
      "assumes":[],"definitions":[],
      "constants":[{"name":{"value":"n_fault","provenance":"llm_inferred"},"ctype":{"value":"integer","provenance":"llm_inferred"},"cvalue":{"value":5,"provenance":"user_stated"}}],
      "guarantees":[{"name":{"value":"g","provenance":"user_stated"},"gtype":{"value":"boolean","provenance":"user_stated"},"default":null}],
      "variables":[],"always_invariants":[],
      "initial_mode":{"value":"M","provenance":"user_stated"},
      "modes":[{"name":{"value":"M","provenance":"user_stated"},"entry_actions":[],"invariants":[],
        "transitions":[{"guard":{"value":{"otherwise":true},"provenance":"user_stated"},
          "actions":[{"kind":"set","name":"g","value":{"kind":"bool","value":true},"provenance":"user_stated"}],
          "target":{"value":{"remain":true},"provenance":"user_stated"}}]}],
      "open_questions":[]}|}
  in
  assert (s = "incomplete"); assert (code = 1);
  (* fail: an empty mode is a structural error. *)
  let s, code = status_of
    {|{"schema_version":"0.1","provenance_attested":true,
      "system_name":{"value":"Bad","provenance":"user_stated"},
      "assumes":[],"definitions":[],"constants":[],
      "guarantees":[{"name":{"value":"g","provenance":"user_stated"},"gtype":{"value":"boolean","provenance":"user_stated"},"default":null}],
      "variables":[],"always_invariants":[],
      "initial_mode":{"value":"M","provenance":"user_stated"},
      "modes":[{"name":{"value":"M","provenance":"user_stated"},"entry_actions":[],"invariants":[],"transitions":[]}],
      "open_questions":[]}|}
  in
  assert (s = "fail"); assert (code = 1);
  print_endline "✓ test_reason_verdict passed"

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
  test_reason_ingest ();
  test_reason_rules ();
  test_reason_provenance ();
  test_facts_roundtrip ();
  test_reason_partition ();
  test_reason_repairs ();
  test_reason_questions ();
  test_reason_verdict ();
  print_endline "All tests passed!"
