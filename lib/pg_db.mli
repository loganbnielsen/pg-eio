module Type    = Caqti_type
module Request = Caqti_request

(** A database capability: the handle statements are issued through.

    The parameter is a phantom recording what the handle is. It is erased at runtime:
    a {!tx} is the same value as the {!pool} it came from, and the only difference is
    what the type checker lets you do with it. *)
type 'a handle

(** The pool. Create with {!create_pool}; this is what lives outside a transaction. *)
type pool = [`Pool] handle

(** A transaction-scoped handle. The only way to obtain one is {!transaction}'s
    callback, and functions that need to run inside the caller's transaction take this
    rather than {!pool}, so calling them outside one is a type error. *)
type tx = [`Tx] handle

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
  :  'a handle
  -> ('p, unit, [< `Zero]) Request.t
  -> 'p
  -> (unit, Pg_error.t) result

(** Return zero or one row. *)
val find
  :  'a handle
  -> ('p, 'r, [< `Zero | `One]) Request.t
  -> 'p
  -> ('r option, Pg_error.t) result

(** Return all matching rows as a list. *)
val collect
  :  'a handle
  -> ('p, 'r, [< `Zero | `One | `Many]) Request.t
  -> 'p
  -> ('r list, Pg_error.t) result

(** Run [f] inside a database transaction.

    Commits on [Ok], rolls back on [Error]. Non-fatal exceptions raised by [f]
    are converted to [Error] after rollback; cancellation and runtime-fatal
    exceptions still propagate.

    [f] receives a {!tx}, not the pool: a statement issued through it runs on the
    transaction's own connection, and a function that requires a {!tx} cannot be called
    outside a transaction. Nesting is a type error, which matters because a nested
    [BEGIN]/[COMMIT] on the same connection commits the outer transaction early. *)
val transaction
  :  pool
  -> (tx -> ('a, Pg_error.t) result)
  -> ('a, Pg_error.t) result
