(lang dune 3.0)
(name pg-eio)
(version 0.1.0)
(generate_opam_files true)

(package
 (name pg-eio)
 (synopsis "Eio-native PostgreSQL pool, typed queries, migrations, and a table functor")
 (description "\
A thin, opinionated PostgreSQL layer for Eio 5 built directly on caqti / caqti-eio /
caqti-driver-postgresql: a connection pool, typed exec/find/collect/transaction
helpers, a SQL migration runner (apply/status/rollback with a per-workspace tracking
table), and a Table.Make(SCHEMA) functor for basic CRUD on a single table. Not a
query builder, not an ORM, not a multi-backend abstraction — PostgreSQL is the only
supported backend by design.")
 (maintainers "lbendtlynielsen@gmail.com")
 (authors "lbendtly")
 (license "MIT")
 (homepage "https://github.com/loganbnielsen/pg-eio")
 (bug_reports "https://github.com/loganbnielsen/pg-eio/issues")
 (source (github loganbnielsen/pg-eio))
 (depends
  (ocaml (>= 5.4.0))
  (uri (>= 4.4.0))
  (caqti (>= 2.3.0))
  (caqti-eio (>= 2.2.0))
  (caqti-driver-postgresql (>= 2.3.0))
  (eio_main (and (>= 1.3) :with-test))
  (alcotest :with-test)
  (odoc :with-doc)))
