{
open Parser

exception LexError of string

let keywords = [
  ("System", SYSTEM);
  ("Assumes", ASSUMES);
  ("Definitions", DEFINITIONS);
  ("Constants", CONSTANTS);
  ("Guarantees", GUARANTEES);
  ("Variables", VARIABLES);
  ("Always", ALWAYS);
  ("Initial", INITIAL);
  ("mode", MODE);
  ("Mode", MODE);
  ("When", WHEN);
  ("Otherwise", OTHERWISE);
  ("shall", SHALL);
  ("set", SET);
  ("to", TO);
  ("hold", HOLD);
  ("increment", INCREMENT);
  ("reset", RESET);
  ("transition", TRANSITION);
  ("remain", REMAIN);
  ("in", IN);
  ("on", ON);
  ("entry", ENTRY);
  ("invariant", INVARIANT);
  ("is", IS);
  ("true", TRUE);
  ("false", FALSE);
  ("boolean", TYPE_BOOLEAN);
  ("integer", TYPE_INTEGER);
  ("real", TYPE_REAL);
  ("signal", SIGNAL);
  ("and", AND);
  ("or", OR);
  ("not", NOT);
  ("for", FOR);
  ("consecutive", CONSECUTIVE);
  ("cycles", CYCLES);
  ("fewer", FEWER);
  ("than", THAN);
  ("deviates", DEVIATES);
  ("from", FROM);
  ("beyond", BEYOND);
  ("agrees", AGREES);
  ("with", WITH);
  ("within", WITHIN);
  ("of", OF);
  ("one", ONE);
  ("exceeds", EXCEEDS);
  ("below", BELOW);
  ("equals", EQUALS);
  ("average", AVERAGE);
  ("median", MEDIAN);
  ("means", MEANS);
  ("default", DEFAULT);
]

let keyword_table = Hashtbl.create 53
let () = List.iter (fun (k, v) -> Hashtbl.add keyword_table k v) keywords
}

let whitespace = [' ' '\t']+
let newline = '\r' | '\n' | "\r\n"
let digit = ['0'-'9']
let letter = ['a'-'z' 'A'-'Z']
let ident_char = letter | digit | '_'
let ident = letter ident_char*

let integer = digit+
let real = digit+ '.' digit* | digit* '.' digit+

rule token = parse
  | whitespace    { token lexbuf }
  | newline       { Lexing.new_line lexbuf; token lexbuf }
  | "#" [^ '\n']* { token lexbuf }  (* line comment *)
  | "/*"          { comment lexbuf; token lexbuf }  (* block comment *)
  
  (* Literals *)
  | integer as i  { INT (int_of_string i) }
  | real as r     { REAL (float_of_string r) }
  
  (* Punctuation *)
  | ':'   { COLON }
  | ','   { COMMA }
  | '.'   { DOT }
  | '{'   { LBRACE }
  | '}'   { RBRACE }
  | '['   { LBRACKET }
  | ']'   { RBRACKET }
  | '('   { LPAREN }
  | ')'   { RPAREN }
  | '='   { EQ }
  | '+'   { PLUS }
  | '-'   { MINUS }
  | '*'   { STAR }
  | '/'   { SLASH }
  | '<'   { LT }
  | '>'   { GT }
  | "<="  { LE }
  | ">="  { GE }
  | "=="  { EQEQ }
  | "!="  { NE }
  | ".."  { DOTDOT }
  | "∞"   { INFINITY }
  | "inf" { INFINITY }
  
  (* Identifiers and keywords *)
  | ident as id {
      try Hashtbl.find keyword_table id
      with Not_found -> IDENT id
    }
  
  | eof { EOF }
  | _ as c { raise (LexError (Printf.sprintf "Unexpected character: %c" c)) }

and comment = parse
  | "*/" { () }
  | newline { Lexing.new_line lexbuf; comment lexbuf }
  | eof { raise (LexError "Unterminated comment") }
  | _ { comment lexbuf }
