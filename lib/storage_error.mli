type t =
  | Connection_error of string
  | Query_error       of string
  | Not_found
  | Constraint_error of string
  | Migration_error   of string

val to_string : t -> string
