type t =
  | Connection_error of string
  | Query_error       of string
  | Not_found
  | Constraint_error of string
  | Migration_error   of string

let to_string = function
  | Connection_error msg    -> "connection failed: " ^ msg
  | Query_error msg          -> "query error: " ^ msg
  | Not_found                -> "not found"
  | Constraint_error msg -> "constraint violation: " ^ msg
  | Migration_error msg      -> "migration error: " ^ msg
