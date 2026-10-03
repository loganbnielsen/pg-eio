type status = {
  version          : int;
  name             : string;
  applied_at       : string option; (** None if not yet applied *)
  checksum         : string option;
  (** The content checksum recorded when this version was applied, or [None]
      if the version is not applied or was applied before checksums were
      recorded. *)
  content_checksum : string;
  (** The checksum of the file as it reads now. A [checksum] that is [Some]
      and differs from this is an edited already-applied migration. *)
}

val parse_filename : string -> (int * string) option

(** [apply ~fs pool ~dir] applies all pending SQL migrations from [dir].
    Migrations are files named [NNNN_description.sql] (e.g. [0001_init.sql]).
    Each file is executed in a transaction; the applied version and the
    checksum of the file content are recorded in the migrations tracking table
    (default: [sun_schema_migrations]).

    An applied migration whose recorded checksum no longer matches its file is
    refused before anything runs: the applied set and the files must agree.
    A version applied before checksums were recorded has no baseline and is
    not compared.

    Pass [~table] to use a per-workspace table, avoiding version-number
    collisions when multiple workspaces share the same database in development. *)
val apply
  :  ?table:string
  -> fs:_ Eio.Path.t
  -> Pg_db.pool
  -> dir:string
  -> (unit, Pg_error.t) result

(** [status ~fs pool ~dir] returns one entry per migration file, showing whether
    each version has been applied, when, the checksum it was applied with, and
    the checksum the file reads as now. Pass [~table] to match the table
    used in [apply]. *)
val status
  :  ?table:string
  -> fs:_ Eio.Path.t
  -> Pg_db.pool
  -> dir:string
  -> (status list, Pg_error.t) result

(** [migrations ~fs ~dir] returns [(version, name, original_path)] for every
    migration, ordered by version, without touching a database. Invalid SQL
    filenames and duplicate versions are errors. [apply] and [status] use
    the same directory check. *)
val migrations
  :  fs:_ Eio.Path.t
  -> dir:string
  -> ((int * string * string) list, Pg_error.t) result

val pending
  :  ?table:string
  -> fs:_ Eio.Path.t
  -> Pg_db.pool
  -> dir:string
  -> ((int * string * string) list, Pg_error.t) result

(** [rollback ~fs pool ~dir] rolls back the last applied migration by running the
    companion [name.down.sql] file beside the original up file and removing the version record from the
    tracking table.  Fails with an error if no migrations are applied or if the
    down-migration file does not exist.  Pass [~table] to match the table used
    in [apply]. *)
val rollback
  :  ?table:string
  -> fs:_ Eio.Path.t
  -> Pg_db.pool
  -> dir:string
  -> (unit, Pg_error.t) result
