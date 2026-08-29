# Changes

## Unreleased

- `Db.create_pool` now rejects non-positive `pool_size` values with
  `Connection_error` before constructing the Caqti pool.

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
