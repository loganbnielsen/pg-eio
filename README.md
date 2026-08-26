# pg-eio

A thin, opinionated PostgreSQL layer for OCaml 5 / Eio, built directly on
[`caqti`](https://github.com/paurkedal/ocaml-caqti) /
[`caqti-eio`](https://github.com/paurkedal/ocaml-caqti) /
`caqti-driver-postgresql`: a connection pool, typed `exec`/`find`/`collect`/
`transaction` helpers, a SQL migration runner, and a `Table.Make(SCHEMA)` functor for
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
# any local Postgres instance works, e.g.:
docker run -d --rm -e POSTGRES_PASSWORD=dev -p 5432:5432 postgres:16-alpine

POSTGRES_URL=postgresql://postgres:dev@localhost:5432/postgres dune runtest
```

Unit tests that don't need a database (identifier/limit/offset validation, migration
filename parsing, the SQL statement splitter) run unconditionally. Every test that
touches a real database is gated on the `POSTGRES_URL` environment variable and skips
cleanly (`[skip] POSTGRES_URL not set`) when it isn't set.

## Public API

### `Storage_error`

```ocaml
type t =
  | Connection_failed of string
  | Query_error       of string
  | Not_found
  | Constraint_violation of string
  | Migration_error   of string

val to_string : t -> string
```

### `Db`

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
  -> (pool, Storage_error.t) result

val exec        : pool -> ('p, unit, [< `Zero]) Caqti_request.t -> 'p -> (unit, Storage_error.t) result
val find        : pool -> ('p, 'r, [< `Zero | `One]) Caqti_request.t -> 'p -> ('r option, Storage_error.t) result
val collect     : pool -> ('p, 'r, [< `Zero | `One | `Many]) Caqti_request.t -> 'p -> ('r list, Storage_error.t) result
val transaction : pool -> (pool -> ('a, Storage_error.t) result) -> ('a, Storage_error.t) result
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
  let pool = Db.create_pool ~url:"postgresql://..." ~sw
               ~stdenv:(env :> Caqti_eio.stdenv) ()
             |> Result.get_ok in
  let _ = Db.exec pool insert_q (1, "Alice") in
  let name = Db.find pool find_q 1 in
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
  -> Db.pool
  -> dir:string
  -> (unit, Storage_error.t) result

val status
  :  ?table:string
  -> Db.pool
  -> dir:string
  -> (status list, Storage_error.t) result

val rollback
  :  ?table:string
  -> Db.pool
  -> dir:string
  -> (unit, Storage_error.t) result
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

### `Table.Make(SCHEMA)`

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
  val find   : Db.pool -> S.id -> (S.t option, Storage_error.t) result
  val insert : Db.pool -> S.t  -> (unit, Storage_error.t) result
  val delete : Db.pool -> S.id -> (unit, Storage_error.t) result
  val list   : Db.pool -> ?limit:int -> ?offset:int -> unit -> (S.t list, Storage_error.t) result
end
```

`table`, `id_column`, and each entry in `columns` are validated once when `Table.Make`
is applied. They must be unquoted SQL identifiers matching `[A-Za-z_][A-Za-z0-9_]*`;
quoted and schema-qualified identifiers are rejected — `Table.Make` interpolates them
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

module Users = Table.Make(UserSchema)

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
  field (`{ use_conn : 'b. (Caqti_eio.connection -> ('b, Storage_error.t) result) -> ... }`),
  so callers never see a `caqti` type parameter.
- `Db`, `Migration`, and `Table` are flat, unwrapped top-level modules (matching the
  same shape as this author's sibling packages `kafka-eio-core` and `obs-eio`). `Db`
  and `Table` are common enough names that a consuming project should watch for
  collisions if it also depends on another library exposing the same bare module name.

## Out of Scope

- Update/upsert helpers (use `Db.exec` with a hand-written query)
- Query builder / DSL
- Multiple database backends (PostgreSQL is the only supported backend)
