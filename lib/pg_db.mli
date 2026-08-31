module Type    = Caqti_type
module Request = Caqti_request

(** Opaque connection pool. Create with [create_pool]; pass to query functions. *)
type pool

(** [create_pool ~url ~sw ~stdenv ()] opens a connection pool to the Postgres
    instance at [url] (e.g. ["postgresql://user:pass@localhost/mydb"]).
    The pool lives for the lifetime of [sw]. [?pool_size], when supplied,
    must be positive. *)
val create_pool
  :  url:string
  -> ?pool_size:int
  -> sw:Eio.Switch.t
  -> stdenv:Caqti_eio.stdenv
  -> unit
  -> (pool, Pg_error.t) result

(** [of_env ~sw ~stdenv ()] reads [POSTGRES_URL] and calls {!create_pool}.
    [Error (Connection_error _)] if the variable is unset or empty. *)
val of_env
  :  sw:Eio.Switch.t
  -> stdenv:Caqti_eio.stdenv
  -> ?pool_size:int
  -> unit
  -> (pool, Pg_error.t) result

(** Execute a statement that returns no rows. *)
val exec
  :  pool
  -> ('p, unit, [< `Zero]) Request.t
  -> 'p
  -> (unit, Pg_error.t) result

(** Return zero or one row. *)
val find
  :  pool
  -> ('p, 'r, [< `Zero | `One]) Request.t
  -> 'p
  -> ('r option, Pg_error.t) result

(** Return all matching rows as a list. *)
val collect
  :  pool
  -> ('p, 'r, [< `Zero | `One | `Many]) Request.t
  -> 'p
  -> ('r list, Pg_error.t) result

(** Run [f] inside a database transaction.

    Commits on [Ok], rolls back on [Error]. Non-fatal exceptions raised by [f]
    are converted to [Error] after rollback; cancellation and runtime-fatal
    exceptions still propagate. *)
val transaction
  :  pool
  -> (pool -> ('a, Pg_error.t) result)
  -> ('a, Pg_error.t) result
