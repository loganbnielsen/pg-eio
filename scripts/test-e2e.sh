#!/usr/bin/env bash
# Runs the pg-eio test suite against a real PostgreSQL instance.
# If POSTGRES_URL is already set, that database is used and left alone.
# Otherwise, a disposable postgres:16-alpine container is started and removed.
set -euo pipefail
cd "$(dirname "$0")/.."

CONTAINER="${PG_EIO_TEST_CONTAINER:-pg-eio-test}"
PORT="${PG_EIO_TEST_PORT:-55432}"
PASSWORD="${PG_EIO_TEST_PASSWORD:-dev}"
DATABASE="${PG_EIO_TEST_DATABASE:-pg_eio_test}"
started_container=0

cleanup() {
  if [ "$started_container" = 1 ]; then
    echo "==> Tearing down PostgreSQL container ${CONTAINER}..."
    docker rm -f "$CONTAINER" > /dev/null || true
  fi
}
trap cleanup EXIT

if [ -z "${POSTGRES_URL:-}" ]; then
  echo "==> Starting PostgreSQL container ${CONTAINER}..."
  docker run -d --rm \
    --name "$CONTAINER" \
    -e POSTGRES_PASSWORD="$PASSWORD" \
    -e POSTGRES_DB="$DATABASE" \
    -p "${PORT}:5432" \
    postgres:16-alpine > /dev/null
  started_container=1

  echo "==> Waiting for PostgreSQL..."
  for _ in $(seq 1 60); do
    if docker exec "$CONTAINER" pg_isready -q; then break; fi
    sleep 0.5
  done

  POSTGRES_URL="postgresql://postgres:${PASSWORD}@localhost:${PORT}/${DATABASE}"
  export POSTGRES_URL
fi

echo "==> Running pg-eio tests against ${POSTGRES_URL}..."
dune runtest --force
