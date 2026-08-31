module type SCHEMA = sig
  val table     : string
  (** Postgres table name. Validated by [Make] as an unquoted SQL identifier. *)

  val id_column : string
  (** Name of the primary-key column. Validated by [Make] as an unquoted SQL
      identifier. *)

  val columns   : string list
  (** All column names in declaration order; must match the fields encoded by
      [row_type]. Validated by [Make] as unquoted SQL identifiers. *)

  type t
  (** OCaml row type. *)

  type id
  (** OCaml primary-key type. *)

  val row_type : t Caqti_type.t
  (** Caqti type for encoding/decoding a full row. Field order must match
      [columns]. Use [Caqti_type.custom] to map between tuples and [t]. *)

  val id_type  : id Caqti_type.t
  val get_id   : t -> id
end

(** Validated unquoted SQL identifier.

    Identifiers must match [[A-Za-z_][A-Za-z0-9_]*]. Quoted identifiers and
    schema-qualified names are intentionally rejected because [Table.Make]
    interpolates identifiers into generated SQL without quoting. *)
module Identifier : sig
  type t = private string

  val of_string : ?kind:string -> string -> (t, Storage_error.t) result
  val to_string : t -> string
end

(** Validated LIMIT value for table listing. *)
module Limit : sig
  type t = private int

  val max_value : int
  val of_int : int -> (t, Storage_error.t) result
  val to_int : t -> int
end

(** Validated OFFSET value for table listing. *)
module Offset : sig
  type t = private int

  val of_int : int -> (t, Storage_error.t) result
  val to_int : t -> int
end

(** Generate standard CRUD operations for a table from its schema. *)
module Make (S : SCHEMA) : sig
  val find   : Db.pool -> S.id  -> (S.t option, Storage_error.t) result
  val insert : Db.pool -> S.t   -> (unit, Storage_error.t) result
  val delete : Db.pool -> S.id  -> (unit, Storage_error.t) result
  val list
    :  Db.pool
    -> ?limit:Limit.t
    -> ?offset:Offset.t
    -> unit
    -> (S.t list, Storage_error.t) result
  (** Defaults to a limit of 100 rows starting at offset 0. Takes the
      validated [Limit.t]/[Offset.t] types directly (rather than raw [int])
      so a caller who already validated a value once — e.g. parsing a
      [?limit=] query param at an HTTP route boundary — can pass it straight
      through instead of paying the runtime check again, and so an invalid
      value is rejected at [Limit.of_int]/[Offset.of_int], not folded into
      the same [Storage_error.t] a genuine connection failure would produce. *)
end
