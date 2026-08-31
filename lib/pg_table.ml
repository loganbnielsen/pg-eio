module type SCHEMA = sig
  val table     : string
  val id_column : string
  val columns   : string list
  (** All column names in order, matching the fields of [row_type]. *)

  type t
  type id

  val row_type : t Caqti_type.t
  (** Encodes/decodes the full row. Field order must match [columns]. *)

  val id_type  : id Caqti_type.t
  val get_id   : t -> id
end

module Identifier : sig
  type t = private string

  val of_string : ?kind:string -> string -> (t, Pg_error.t) result
  val of_string_exn : ?kind:string -> string -> t
  val to_string : t -> string
end = struct
  type t = string

  let is_initial_char = function
    | 'A' .. 'Z' | 'a' .. 'z' | '_' -> true
    | _ -> false

  let is_identifier_char = function
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' -> true
    | _ -> false

  let error kind msg =
    Pg_error.Query_error (Printf.sprintf "%s identifier %s" kind msg)

  let of_string ?(kind = "SQL") name =
    if String.length name = 0 then
      Error (error kind "must not be empty")
    else if not (is_initial_char name.[0]) then
      Error
        (error kind
           (Printf.sprintf "%S is unsafe; expected [A-Za-z_][A-Za-z0-9_]*" name))
    else
      let rec loop i =
        if i = String.length name then
          Ok name
        else if is_identifier_char name.[i] then
          loop (i + 1)
        else
          Error
            (error kind
               (Printf.sprintf "%S is unsafe; expected [A-Za-z_][A-Za-z0-9_]*" name))
      in
      loop 1

  let of_string_exn ?kind name =
    match of_string ?kind name with
    | Ok identifier -> identifier
    | Error (Pg_error.Query_error msg) -> invalid_arg msg
    | Error err -> invalid_arg (Pg_error.to_string err)

  let to_string identifier = identifier
end

module Limit : sig
  type t = private int

  val max_value : int
  val of_int : int -> (t, Pg_error.t) result
  val to_int : t -> int
end = struct
  type t = int

  let max_value = 10_000

  let of_int n =
    if n <= 0 then
      Error (Pg_error.Query_error "table list limit must be positive")
    else if n > max_value then
      Error
        (Pg_error.Query_error
           (Printf.sprintf "table list limit must be <= %d" max_value))
    else
      Ok n

  let to_int n = n
end

module Offset : sig
  type t = private int

  val of_int : int -> (t, Pg_error.t) result
  val to_int : t -> int
end = struct
  type t = int

  let of_int n =
    if n < 0 then
      Error (Pg_error.Query_error "table list offset must be non-negative")
    else
      Ok n

  let to_int n = n
end

module Make (S : SCHEMA) = struct

  let placeholders n =
    List.init n (fun _ -> "?") |> String.concat ", "

  let table =
    S.table
    |> Identifier.of_string_exn ~kind:"table"
    |> Identifier.to_string

  let id_column =
    S.id_column
    |> Identifier.of_string_exn ~kind:"column"
    |> Identifier.to_string

  let columns =
    S.columns
    |> List.map (fun column ->
      column
      |> Identifier.of_string_exn ~kind:"column"
      |> Identifier.to_string)

  let column_list = String.concat ", " columns

  let find_q =
    Caqti_request.Infix.(S.id_type ->? S.row_type)
      (Printf.sprintf "SELECT %s FROM %s WHERE %s = ?" column_list table id_column)

  let insert_q =
    Caqti_request.Infix.(S.row_type ->. Caqti_type.unit)
      (Printf.sprintf "INSERT INTO %s (%s) VALUES (%s)"
         table column_list (placeholders (List.length columns)))

  let delete_q =
    Caqti_request.Infix.(S.id_type ->. Caqti_type.unit)
      (Printf.sprintf "DELETE FROM %s WHERE %s = ?" table id_column)

  let list_q =
    Caqti_request.Infix.(Caqti_type.(t2 int int) ->* S.row_type)
      (Printf.sprintf "SELECT %s FROM %s LIMIT ? OFFSET ?" column_list table)

  let find   pool id  = Pg_db.find    pool find_q   id
  let insert pool row = Pg_db.exec    pool insert_q  row
  let delete pool id  = Pg_db.exec    pool delete_q  id

  let default_limit = Result.get_ok (Limit.of_int 100)
  let default_offset = Result.get_ok (Offset.of_int 0)

  let list pool ?(limit = default_limit) ?(offset = default_offset) () =
    Pg_db.collect pool list_q (Limit.to_int limit, Offset.to_int offset)
end
