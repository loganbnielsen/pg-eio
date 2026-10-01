# Changes

## Unreleased

- **Breaking:** `Db.` handles are now capability-typed. `type 'a handle` carries a
  phantom: `Db.pool = [`Pool] handle` is the pool, and `Db.transaction`'s callback
  receives a `Db.tx = [`Tx] handle`. `exec`/`find`/`collect` are polymorphic in the
  capability, so they take either without duplication, and a function that requires a
  `tx` — a job enqueue, an outbox publish — is now uncallable outside a transaction.
  The representation is unchanged, so the distinction costs nothing at runtime.

  This also makes nesting unrepresentable: `Db.transaction tx f` used to type-check
  because a `tx` *was* a `pool`, and the inner `COMMIT` then ended the caller's
  transaction early — a later `Error` in the outer callback rolled back nothing.
  Verified against a live database before the change (outer `Error` after a nested
  transaction left both rows committed).

  Callers that only pass the pool around need no change; a callback parameter named
  `pool` still compiles, and any code that fed a transaction callback's handle to
  `enqueue`-style functions now needs those functions to take `Db.tx`.
- `Migration.apply`/`status` now refuse a migrations directory in which two files
  share a version, naming both files, before connecting. The tracking table keys on
  version, so the second file used to be skipped forever once the first was applied.
  New `Migration.migrations ~fs ~dir` lists `(version, name)` in order without a
  database (Sol BUG-041 / FND-0032).
- `Db.create_pool` now rejects non-positive `pool_size` values with
  `Connection_error` before constructing the Caqti pool.
- `Db.transaction` now converts non-fatal callback exceptions into returned
  `Query_error`s after rollback instead of leaking an exception path.
- `Table.Identifier.of_string_exn` is no longer part of the installed
  interface; callers should use the `result`-returning `of_string`.
- `Migration.apply`/`status`/`rollback` classify constraint violations and
  detect `RETURNING` clauses to route statements through `Db.exec` vs.
  `Db.collect` correctly (#12); `RETURNING` detection no longer matches
  inside string literals, comments, or dollar-quoted blocks (#13); statement
  splitting and `RETURNING` detection now run on an Angstrom grammar instead
  of a hand-rolled scanner, adding `angstrom` as a new direct dependency
  (#14).
- `Migration.apply`/`status`/`rollback` now take a required `~fs` capability
  and read migration files via `Eio.Path` instead of blocking
  `Sys`/`In_channel` calls (#15).
- `Storage_error.Not_found` removed — it had zero producers; `Db.find` and
  `Table.Make.find` already signal an absent row via `'r option`.

## 0.1.0

- Initial standalone OPAM package: `Db` connection pool (`exec`/`find`/`collect`/
  `transaction`), `Migration` SQL migration runner (`apply`/`status`/`rollback`,
  PostgreSQL-aware statement splitting), and `Table.Make(SCHEMA)` CRUD functor.
- `Migration`'s `?table` parameter is now validated as an unquoted SQL identifier
  (reusing `Table`'s existing validator) before use, closing an injection surface
  that existed while this code lived in-tree.
- `Db.transaction` no longer silently discards a rollback failure; if rollback
  itself fails after the original error, both are reported together.
- `Db.transaction` now rolls back when the callback raises, so the pooled
  connection is not returned with an open transaction.
- Public-API cleanup: `Migration.split_sql_statements` is private to the
  migration runner instead of an installed helper.
