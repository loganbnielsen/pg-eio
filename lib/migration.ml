let ( let* ) = Result.bind

type status = {
  version    : int;
  name       : string;
  applied_at : string option;
}

(* ── File parsing ────────────────────────────────────────────────────────── *)

let parse_filename f =
  if not (Filename.check_suffix f ".sql") then None
  else if Filename.check_suffix f ".down.sql" then None
  else
    let base = Filename.chop_suffix f ".sql" in
    match String.split_on_char '_' base with
    | [] | [_] -> None
    | version_str :: rest ->
      (match int_of_string_opt version_str with
       | None   -> None
       | Some v -> Some (v, String.concat "_" rest))

let read_migrations dir =
  match Sys.readdir dir with
  | exception Sys_error msg ->
    Error (Storage_error.Migration_error ("cannot read migrations dir: " ^ msg))
  | files ->
    let parsed = Array.to_list files |> List.filter_map (fun f ->
      match parse_filename f with
      | None           -> None
      | Some (v, name) -> Some (v, name, Filename.concat dir f))
    in
    let sorted = List.sort (fun (a, _, _) (b, _, _) -> compare a b) parsed in
    Ok sorted

(* A grammar, not an index-jumping scanner: a SQL file is a sequence of
   tokens, each either one character of real code, a statement-separating
   ';', or an entire "--"/"/* */" comment, '...'-quoted string (''
   escapes), or $tag$...$tag$ dollar-quoted block (tag discovered at parse
   time, so the closing delimiter isn't known until the opening one is
   read) — none of the latter is real SQL syntax, so neither
   statement-splitting nor keyword search (RETURNING, below) should look
   inside it. Declaring what each of these IS, via Angstrom, replaces the
   index-arithmetic that used to encode the same grammar as a hand-rolled
   state machine (skip_span) — the same shape of bug (a keyword search
   matching inside a string literal) that produced a real regression here
   once already. *)
module Token_grammar = struct
  open Angstrom

  type token =
    | Code of char
    | Skippable of string
    | Semi

  let line_comment = consumed (string "--" *> skip_while (fun c -> c <> '\n'))

  let block_comment =
    consumed (string "/*" *> (many_till any_char (string "*/") >>| ignore))

  (* '' inside a string is an escaped quote, not the closing quote — must be
     tried before the "is this the closing quote?" check, or the first '
     of a '' pair would end the string one character early. *)
  let string_literal =
    consumed (char '\'' *> fix (fun rest ->
      (string "''" *> rest)
      <|> (char '\'' *> return ())
      <|> (any_char *> rest)))

  (* A tag run of 0+ chars that aren't '$'/'\n'/' ', then a closing '$' —
     fails (backtracks) if no such '$' follows before one of those, so a
     lone '$' that isn't a real dollar-quote open falls through to being
     read as one ordinary code character instead. *)
  let dollar_tag = consumed (char '$' *> skip_while (function '$' | '\n' | ' ' -> false | _ -> true) *> char '$')

  let dollar_quoted =
    consumed (dollar_tag >>= fun tag -> fix (fun rest -> (string tag *> return ()) <|> (any_char *> rest)))

  let token =
    choice
      [ (line_comment >>| fun s -> Skippable s);
        (block_comment >>| fun s -> Skippable s);
        (string_literal >>| fun s -> Skippable s);
        (dollar_quoted >>| fun s -> Skippable s);
        (char ';' >>| fun _ -> Semi);
        (any_char >>| fun c -> Code c);
      ]

  let tokens_of_string s =
    match parse_string ~consume:Consume.All (many token) s with
    | Ok tokens -> tokens
    | Error msg ->
      (* token's any_char case matches any remaining input unconditionally,
         so `many token` cannot fail to consume the whole string — this is
         unreachable, not a real error path. *)
      failwith ("Migration.Token_grammar: unreachable parse failure: " ^ msg)
end

(* Splits a flat token stream into one token list per statement, dropping
   the ';' separators themselves — pure list recursion, no index into the
   original string. *)
let group_by_semicolons tokens =
  let rec go acc cur = function
    | [] -> List.rev (if cur = [] then acc else List.rev cur :: acc)
    | Token_grammar.Semi :: rest -> go (if cur = [] then acc else List.rev cur :: acc) [] rest
    | tok :: rest -> go acc (tok :: cur) rest
  in
  go [] [] tokens

let text_of_tokens tokens =
  let buf = Buffer.create 256 in
  List.iter (function
    | Token_grammar.Code c -> Buffer.add_char buf c
    | Token_grammar.Skippable s -> Buffer.add_string buf s
    | Token_grammar.Semi -> Buffer.add_char buf ';')
    tokens;
  String.trim (Buffer.contents buf)

(* PostgreSQL-aware: semicolons inside strings, comments, and dollar-quoted bodies don't split. *)
let split_sql_statements sql =
  Token_grammar.tokens_of_string sql
  |> group_by_semicolons
  |> List.map text_of_tokens
  |> List.filter (fun s -> String.length s > 0)

let is_word_char = function
  | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' -> true
  | _ -> false

(* Every Skippable span becomes a single space — safe to search this view
   with a plain substring scan for a keyword string literals/comments can
   no longer hide inside, since any span that could contain "RETURNING" as
   ordinary text is now exactly one space character. The single space also
   still yields a correct word boundary either side of where the span was,
   since every span this grammar recognizes opens on a non-word character
   ('-', '/', '\'', '$'). *)
let code_view_of_tokens tokens =
  let buf = Buffer.create 256 in
  List.iter (function
    | Token_grammar.Code c -> Buffer.add_char buf c
    | Token_grammar.Skippable _ -> Buffer.add_char buf ' '
    | Token_grammar.Semi -> Buffer.add_char buf ';')
    tokens;
  Buffer.contents buf

let contains_bare_keyword s keyword =
  let s = String.uppercase_ascii s in
  let n = String.length s and kn = String.length keyword in
  let rec scan i =
    i + kn <= n
    && ((String.sub s i kn = keyword
         && (i = 0 || not (is_word_char s.[i - 1]))
         && (i + kn = n || not (is_word_char s.[i + kn])))
        || scan (i + 1))
  in
  n >= kn && scan 0

let leading_word s =
  let n = String.length s in
  let rec scan i = if i < n && Char.code s.[i] > 32 && s.[i] <> '(' then scan (i + 1) else i in
  String.uppercase_ascii (String.sub s 0 (scan 0))

(* Caqti requires multiplicity to match: SELECT/WITH/TABLE/VALUES return
   Tuples_ok, DDL returns Command_ok — as does INSERT/UPDATE/DELETE unless it
   carries a RETURNING clause, which also produces rows. *)
let returns_rows stmt =
  let s = String.trim (code_view_of_tokens (Token_grammar.tokens_of_string stmt)) in
  let kw = leading_word s in
  kw = "SELECT" || kw = "WITH" || kw = "TABLE" || kw = "VALUES"
  || contains_bare_keyword s "RETURNING"

let exec_statements pool stmts =
  List.fold_left (fun acc stmt ->
    match acc with
    | Error _ as e -> e
    | Ok () ->
      if returns_rows stmt then
        let q = Caqti_request.Infix.(Caqti_type.unit ->* Caqti_type.unit) ~oneshot:true stmt in
        (match Db.collect pool q () with
         | Ok _   -> Ok ()
         | Error e -> Error e)
      else
        let q = Caqti_request.Infix.(Caqti_type.unit ->. Caqti_type.unit) ~oneshot:true stmt in
        Db.exec pool q ()
  ) (Ok ()) stmts

(* ── Per-table helpers (table name injected at call time) ───────────────── *)

let ensure_table table pool =
  let q = Caqti_request.Infix.(Caqti_type.unit ->. Caqti_type.unit) ~oneshot:true
    (Printf.sprintf
       {|CREATE TABLE IF NOT EXISTS %s (
           version    INTEGER PRIMARY KEY,
           name       TEXT    NOT NULL,
           applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
         )|} table)
  in
  Db.exec pool q ()

let applied_versions table pool =
  let q = Caqti_request.Infix.(Caqti_type.unit ->* Caqti_type.int) ~oneshot:true
    (Printf.sprintf "SELECT version FROM %s ORDER BY version" table)
  in
  Db.collect pool q ()

let record_migration table pool version name =
  let q = Caqti_request.Infix.(Caqti_type.(t2 int string) ->. Caqti_type.unit) ~oneshot:true
    (Printf.sprintf "INSERT INTO %s (version, name) VALUES (?, ?)" table)
  in
  Db.exec pool q (version, name)

let applied_at_q table =
  Caqti_request.Infix.(Caqti_type.int ->? Caqti_type.string) ~oneshot:true
    (Printf.sprintf "SELECT applied_at::text FROM %s WHERE version = ?" table)

let last_applied_q table =
  Caqti_request.Infix.(Caqti_type.unit ->? Caqti_type.(t2 int string)) ~oneshot:true
    (Printf.sprintf "SELECT version, name FROM %s ORDER BY version DESC LIMIT 1" table)

let delete_version_q table =
  Caqti_request.Infix.(Caqti_type.int ->. Caqti_type.unit) ~oneshot:true
    (Printf.sprintf "DELETE FROM %s WHERE version = ?" table)

(* ── Public API ──────────────────────────────────────────────────────────── *)

let default_table = "sun_schema_migrations"

(* ~table is interpolated unquoted into SQL; reuse Table's identifier validator to prevent injection. *)
let validate_table table =
  match Table.Identifier.of_string ~kind:"migrations table" table with
  | Ok id   -> Ok (Table.Identifier.to_string id)
  | Error _ -> Error (Storage_error.Migration_error
      (Printf.sprintf "invalid migrations table name %S; expected [A-Za-z_][A-Za-z0-9_]*" table))

let apply ?(table = default_table) pool ~dir =
  let wrap msg = Result.map_error (fun e ->
    Storage_error.Migration_error (msg ^ Storage_error.to_string e))
  in
  let* table = validate_table table in
  let* () = ensure_table table pool |> wrap "create migrations table: " in
  let* migrations = read_migrations dir in
  let* applied = applied_versions table pool |> wrap "query applied migrations: " in
  let pending = List.filter (fun (v, _, _) -> not (List.mem v applied)) migrations in
  List.fold_left (fun acc (version, name, path) ->
    let* () = acc in
    let* sql =
      match In_channel.with_open_text path In_channel.input_all with
      | s -> Ok s
      | exception Sys_error msg ->
        Error (Storage_error.Migration_error ("cannot read " ^ path ^ ": " ^ msg))
    in
    Db.transaction pool (fun pool ->
      let* () = exec_statements pool (split_sql_statements sql) in
      record_migration table pool version name
    )
    |> Result.map_error (fun e ->
      Storage_error.Migration_error (
        Printf.sprintf "migration %04d (%s) failed: %s"
          version name (Storage_error.to_string e)))
  ) (Ok ()) pending

let status ?(table = default_table) pool ~dir =
  let wrap msg = Result.map_error (fun e ->
    Storage_error.Migration_error (msg ^ Storage_error.to_string e))
  in
  let* table = validate_table table in
  let* () = ensure_table table pool |> wrap "create migrations table: " in
  let* migrations = read_migrations dir in
  let row_q = applied_at_q table in
  List.fold_right (fun (version, name, _) acc ->
    let* rows = acc in
    let* applied_at = Db.find pool row_q version in
    Ok ({ version; name; applied_at } :: rows)
  ) migrations (Ok [])

(** Roll back the last applied migration using a companion .down.sql file.
    Expects e.g. db/migrations/0001_notifications.down.sql alongside the up file. *)
let rollback ?(table = default_table) pool ~dir =
  let wrap msg = Result.map_error (fun e ->
    Storage_error.Migration_error (msg ^ Storage_error.to_string e))
  in
  let* table = validate_table table in
  let* () = ensure_table table pool |> wrap "create migrations table: " in
  let* last = Db.find pool (last_applied_q table) () in
  match last with
  | None ->
    Error (Storage_error.Migration_error
      "no migrations have been applied; nothing to roll back")
  | Some (version, name) ->
    let down_file = Printf.sprintf "%04d_%s.down.sql" version name in
    let down_path = Filename.concat dir down_file in
    if not (Sys.file_exists down_path) then
      Error (Storage_error.Migration_error (Printf.sprintf
        "no down-migration file found for version %04d (%s).\n\
         Create %s with the reverse SQL and retry."
        version name down_path))
    else
      let* sql =
        match In_channel.with_open_text down_path In_channel.input_all with
        | s -> Ok s
        | exception Sys_error msg ->
          Error (Storage_error.Migration_error ("cannot read " ^ down_path ^ ": " ^ msg))
      in
      Db.transaction pool (fun pool ->
        let* () = exec_statements pool (split_sql_statements sql) in
        Db.exec pool (delete_version_q table) version
        |> Result.map_error (fun e ->
          Storage_error.Migration_error (
            "update tracking table: " ^ Storage_error.to_string e))
      )
      |> Result.map_error (fun e ->
        Storage_error.Migration_error (
          Printf.sprintf "rollback %04d (%s) failed: %s"
            version name (Storage_error.to_string e)))
