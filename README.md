# pg-eio

A thin, opinionated PostgreSQL layer for OCaml 5 / Eio, built directly on
[`caqti`](https://github.com/paurkedal/ocaml-caqti) /
[`caqti-eio`](https://github.com/paurkedal/ocaml-caqti) /
`caqti-driver-postgresql`: a connection pool, typed `exec`/`find`/`collect`/
`transaction` helpers, a SQL migration runner, and a `Pg_table.Make(SCHEMA)` functor for
basic CRUD on a single table. Not a query builder, not an ORM, not a multi-backend
abstraction — PostgreSQL is the only supported backend, by design.

Extracted from the [Sun](https://github.com/loganbnielsen/sun) platform, where it
continues to be used as an external dependency.

## Build

```bash
eval $(opam env)
dune build
```

## Test

```bash
./scripts/test-e2e.sh
```

Unit tests that don't need a database (identifier/limit/offset validation, migration
filename parsing, the SQL statement splitter) run unconditionally. Every test that
touches a real database is gated on the `POSTGRES_URL` environment variable and skips
cleanly (`[skip] POSTGRES_URL not set`) when it isn't set.

## Public API

### `Pg_error`

```ocaml
type t =
  | Connection_error  of string
  | Query_error       of string
  | Constraint_error  of string
  | Migration_error   of string

val to_string : t -> string
```

### `Pg_db`

```ocaml
module Type    = Caqti_type
module Request = Caqti_request

type pool

val create_pool
  :  url:string
  -> ?pool_size:int
  -> sw:Eio.Switch.t
  -> stdenv:Caqti_eio.stdenv
  -> unit
  -> (pool, Pg_error.t) result

(* Reads POSTGRES_URL and calls create_pool. *)
val of_env
  :  sw:Eio.Switch.t
  -> stdenv:Caqti_eio.stdenv
  -> ?pool_size:int
  -> unit
  -> (pool, Pg_error.t) result

val exec        : pool -> ('p, unit, [< `Zero]) Caqti_request.t -> 'p -> (unit, Pg_error.t) result
val find        : pool -> ('p, 'r, [< `Zero | `One]) Caqti_request.t -> 'p -> ('r option, Pg_error.t) result
val collect     : pool -> ('p, 'r, [< `Zero | `One | `Many]) Caqti_request.t -> 'p -> ('r list, Pg_error.t) result
val transaction : pool -> (pool -> ('a, Pg_error.t) result) -> ('a, Pg_error.t) result
```

`caqti` uses `?` placeholders in SQL strings; the PostgreSQL driver translates them to
`$1`, `$2`, etc.

```ocaml
let insert_q =
  Caqti_request.Infix.(Caqti_type.(t2 int string) ->. Caqti_type.unit)
    "INSERT INTO users (id, name) VALUES (?, ?)"

let find_q =
  Caqti_request.Infix.(Caqti_type.int ->? Caqti_type.string)
    "SELECT name FROM users WHERE id = ?"

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let pool = Pg_db.create_pool ~url:"postgresql://..." ~sw
               ~stdenv:(env :> Caqti_eio.stdenv) ()
             |> Result.get_ok in
  let _ = Pg_db.exec pool insert_q (1, "Alice") in
  let name = Pg_db.find pool find_q 1 in
  ignore name
```

`transaction` commits on `Ok`, rolls back on `Error`. If the rollback itself fails,
that failure is folded into the returned error alongside the original one rather than
discarded.

### `Migration`

```ocaml
type status = {
  version    : int;
  name       : string;
  applied_at : string option;  (* None if not yet applied *)
}

val apply
  :  ?table:string
  -> Pg_db.pool
  -> dir:string
  -> (unit, Pg_error.t) result

val status
  :  ?table:string
  -> Pg_db.pool
  -> dir:string
  -> (status list, Pg_error.t) result

val rollback
  :  ?table:string
  -> Pg_db.pool
  -> dir:string
  -> (unit, Pg_error.t) result
```

Migration files follow the naming convention `NNNN_description.sql` (e.g.
`0001_init.sql`). Down-migration files follow `NNNN_description.down.sql` (required
for `rollback`). Applied versions are tracked in a table created automatically on
first `apply` (default name `sun_schema_migrations` — override with `~table` to keep
multiple logical databases/tenants sharing one Postgres instance from colliding on
version numbers). `~table` is validated as an unquoted SQL identifier
(`[A-Za-z_][A-Za-z0-9_]*`) before use.

The statement splitter used internally to break a migration file into individual
statements is PostgreSQL-aware: it correctly handles semicolons inside single-quoted
strings, `--` line comments, `/* */` block comments, and `$tag$...$tag$` dollar-quoted
bodies (PL/pgSQL functions, triggers, etc.) — not a naive `split_on_char ';'`.

### `Pg_table.Make(SCHEMA)`

```ocaml
module type SCHEMA = sig
  val table     : string
  val id_column : string
  val columns   : string list
  type t
  type id
  val row_type : t Caqti_type.t
  val id_type  : id Caqti_type.t
  val get_id   : t -> id
end

module Make (S : SCHEMA) : sig
  val find   : Pg_db.pool -> S.id -> (S.t option, Pg_error.t) result
  val insert : Pg_db.pool -> S.t  -> (unit, Pg_error.t) result
  val delete : Pg_db.pool -> S.id -> (unit, Pg_error.t) result
  val list   : Pg_db.pool -> ?limit:int -> ?offset:int -> unit -> (S.t list, Pg_error.t) result
end
```

`table`, `id_column`, and each entry in `columns` are validated once when `Pg_table.Make`
is applied. They must be unquoted SQL identifiers matching `[A-Za-z_][A-Za-z0-9_]*`;
quoted and schema-qualified identifiers are rejected — `Pg_table.Make` interpolates them
into generated SQL without quoting.

```ocaml
module UserSchema = struct
  let table     = "users"
  let id_column = "id"
  let columns   = ["id"; "name"; "email"]
  type t  = { id : int; name : string; email : string }
  type id = int
  let row_type =
    Caqti_type.(custom
      ~encode:(fun u -> Ok (u.id, u.name, u.email))
      ~decode:(fun (id, name, email) -> Ok { id; name; email })
      (t3 int string string))
  let id_type = Caqti_type.int
  let get_id u = u.id
end

module Users = Pg_table.Make(UserSchema)

let _ = Users.insert pool { id = 1; name = "Alice"; email = "alice@example.com" }
let _ = Users.find   pool 1
let _ = Users.list   pool ~limit:10 ()
let _ = Users.delete pool 1
```

## Configuration

| Parameter   | Type               | Default             | Description                       |
|-------------|--------------------|----------------------|-----------------------------------|
| `url`       | `string`           | —                    | PostgreSQL connection URL         |
| `pool_size` | `int`              | caqti default (10)  | Max connections in pool           |
| `sw`        | `Eio.Switch.t`     | —                    | Pool lifetime tied to switch      |
| `stdenv`    | `Caqti_eio.stdenv` | —                    | Coerce from full env with `:>`    |

`Caqti_eio.stdenv` requires `< net; clock; mono_clock >`. Coerce from the full Eio env
with `(env :> Caqti_eio.stdenv)`.

## Design Notes

- `pool` hides the underlying `caqti` pool's type variable behind a polymorphic record
  field (`{ use_conn : 'b. (Caqti_eio.connection -> ('b, Pg_error.t) result) -> ... }`),
  so callers never see a `caqti` type parameter.
- `Pg_error`, `Pg_db`, `Migration`, and `Pg_table` are flat, unwrapped top-level modules
  (matching the same shape as this author's sibling packages `kafka-eio-core` and
  `obs-eio`). They were originally named `Storage_error`/`Db`/`Table` — names that read
  as backend-agnostic while the implementation is 100% Postgres-specific (`Pg_db.create_pool`
  takes a `Caqti_eio.stdenv` directly; no second backend has ever been built or planned).
  Renamed to be honest about what this package is, matching every sibling package's own
  convention of naming things after the backend it actually is (`S3_client` in `s3-eio`,
  `Kafka_service` in `kafka-eio-service`). `Migration` keeps its generic name since
  nothing about migration-running itself implies backend-agnosticism the way `Db`/`Table`
  did.

## Out of Scope

- Update/upsert helpers (use `Pg_db.exec` with a hand-written query)
- Query builder / DSL
- Multiple database backends (PostgreSQL is the only supported backend)
