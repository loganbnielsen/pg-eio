type status = {
  version    : int;
  name       : string;
  applied_at : string option; (** None if not yet applied *)
}

(** [apply ~fs pool ~dir] applies all pending SQL migrations from [dir].
    Migrations are files named [NNNN_description.sql] (e.g. [0001_init.sql]).
    Each file is executed in a transaction; the applied version is recorded in
    the migrations tracking table (default: [sun_schema_migrations]).

    Pass [~table] to use a per-workspace table, avoiding version-number
    collisions when multiple workspaces share the same database in development. *)
val apply
  :  ?table:string
  -> fs:_ Eio.Path.t
  -> Pg_db.pool
  -> dir:string
  -> (unit, Pg_error.t) result

(** [status ~fs pool ~dir] returns one entry per migration file, showing whether
    each version has been applied and when. Pass [~table] to match the table
    used in [apply]. *)
val status
  :  ?table:string
  -> fs:_ Eio.Path.t
  -> Pg_db.pool
  -> dir:string
  -> (status list, Pg_error.t) result

(** [migrations ~fs ~dir] is the [(version, name)] of every migration file in [dir],
    ordered by version, without touching a database. It is an error for two files
    to share a version: the tracking table records versions, so one of them would be
    applied and the other silently skipped forever. [apply] and [status] run this
    check before they connect. *)
val migrations
  :  fs:_ Eio.Path.t
  -> dir:string
  -> ((int * string) list, Pg_error.t) result

(** [rollback ~fs pool ~dir] rolls back the last applied migration by running the
    companion [NNNN_name.down.sql] file and removing the version record from the
    tracking table.  Fails with an error if no migrations are applied or if the
    down-migration file does not exist.  Pass [~table] to match the table used
    in [apply]. *)
val rollback
  :  ?table:string
  -> fs:_ Eio.Path.t
  -> Pg_db.pool
  -> dir:string
  -> (unit, Pg_error.t) result
