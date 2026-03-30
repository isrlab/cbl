(** CBL Compiler main entry point *)

open Cbl_lib

(** Parse a CBL file *)
let parse_file (filename : string) : (Ast.spec, string) result =
  try
    let ic = open_in filename in
    Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
      let lexbuf = Lexing.from_channel ic in
      lexbuf.Lexing.lex_curr_p <- { lexbuf.Lexing.lex_curr_p with Lexing.pos_fname = filename };
      try
        let spec = Parser.specification Lexer.token lexbuf in
        Ok spec
      with
      | Parser.Error ->
          let pos = lexbuf.Lexing.lex_curr_p in
          Error (Printf.sprintf "Parse error at line %d, column %d"
                   pos.Lexing.pos_lnum
                   (pos.Lexing.pos_cnum - pos.Lexing.pos_bol))
      | Lexer.LexError msg ->
          Error (Printf.sprintf "Lexical error: %s" msg)
    )
  with
  | Sys_error msg -> Error msg

(** Print usage information *)
let usage () =
  print_endline "CBL Compiler (OCaml implementation)";
  print_endline "";
  print_endline "Usage:";
  print_endline "  cblc check <file.cbl>           Check well-posedness";
  print_endline "  cblc compile <file.cbl> -o <out.json>  Compile to JSON IR";
  print_endline "  cblc parse <file.cbl>           Parse and print AST";
  print_endline "  cblc ingest <verdict.json> -o <spec.cbl>  Ingest verdict facts to CBL";
  print_endline "  cblc ingest <verdict.json> --check-only   Validate only (exit 0/1)";
  print_endline "  cblc help                       Show this help";
  print_endline "";
  exit 1

(** Command dispatch *)
let () =
  let args = Array.to_list Sys.argv |> List.tl in
  match args with
  | [] | "help" :: _ -> usage ()
  
  | "check" :: filename :: _ -> (
      match parse_file filename with
      | Error msg ->
          Printf.eprintf "Error: %s\n" msg;
          exit 1
      | Ok spec ->
          let result = Checker.check spec in
          Checker.print_result result;
          if result.Checker.errors <> [] then exit 1
    )
  
  | "compile" :: filename :: "-o" :: output :: _ -> (
      match parse_file filename with
      | Error msg ->
          Printf.eprintf "Error: %s\n" msg;
          exit 1
      | Ok spec ->
          let result = Checker.check spec in
          if result.Checker.errors <> [] then begin
            Checker.print_result result;
            exit 1
          end else begin
            Json_emit.emit_to_file_pretty spec output;
            Printf.printf "✓ Compiled %s → %s\n" filename output
          end
    )
  
  | "parse" :: filename :: _ -> (
      match parse_file filename with
      | Error msg ->
          Printf.eprintf "Error: %s\n" msg;
          exit 1
      | Ok spec ->
          print_endline (Ast.show_spec spec)
    )
  
  | "ingest" :: filename :: rest -> (
      let json =
        try Ok (Yojson.Safe.from_file filename)
        with exn -> Error (Printexc.to_string exn)
      in
      match json with
      | Error msg ->
          Printf.eprintf "Error reading %s: %s\n" filename msg;
          exit 2
      | Ok json -> (
          match Nlp_bridge.ingest_facts json with
          | Error msgs ->
              Printf.eprintf "Ingestion errors:\n";
              List.iter (fun m -> Printf.eprintf "  %s\n" m) msgs;
              exit 1
          | Ok spec -> (
              let result = Nlp_bridge.validate spec in
              if result.Checker.errors <> [] then begin
                let diags = Nlp_bridge.diagnostics_to_json result in
                print_string (Yojson.Safe.pretty_to_string diags);
                print_newline ();
                exit 1
              end else begin
                match rest with
                | "--check-only" :: _ ->
                    print_endline "✓ Verdict facts pass validation";
                    exit 0
                | "-o" :: output :: _ ->
                    let cbl = Nlp_bridge.emit_cbl spec in
                    let oc = open_out output in
                    Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
                      output_string oc cbl
                    );
                    Printf.printf "✓ Ingested %s → %s\n" filename output
                | _ ->
                    (* No output flag: print CBL to stdout *)
                    print_string (Nlp_bridge.emit_cbl spec)
              end
            )
        )
    )

  | _ -> usage ()
