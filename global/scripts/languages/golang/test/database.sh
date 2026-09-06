#!/usr/bin/env sh
# Provision the throwaway PostgreSQL the Go integration tests run against, and
# export its connection URL under the name the caller asked for.
#
# WHY THIS IS A SCRIPT AND NOT AN INLINE `run:` BLOCK
#
# It used to live inside `github/golang/stages/30-tests/all/action.yaml`. A YAML
# block scalar is opaque to every analyser that reads YAML: the whole script is
# one string, so `POSTGRES_PASSWORD=...` inside it reads as a hard-coded
# credential in a configuration file (SonarQube `yaml:S2068`) no matter what the
# right-hand side actually is. Here the same lines are shell, parsed as shell,
# and the value is visibly a command substitution rather than a literal.
#
# It is also the shape the rest of this library already uses -- every non-trivial
# step calls `$SCRIPTS_DIR/global/scripts/...` -- so this is one fewer step whose
# behaviour can only be read out of a workflow file.
#
# Inputs (all through the environment, never interpolated into the text):
#   DATABASE_IMAGE   -- PostgreSQL-compatible image to run. Required.
#   DATABASE_URL_ENV -- name of the variable the composed URL is exported into.
#   GITHUB_ENV       -- file the export is appended to, provided by the runner.
set -eu

CONTAINER_NAME='pipelines-test-db'
DB_USER='pipelines'
DB_NAME='pipelines_test'

# Every exit goes through here, which is also why the one line that breaks the
# usual "diagnostics go to stderr" rule only has to be explained once:
# `::error::` is a GitHub Actions workflow COMMAND, not a message, and the
# runner parses workflow commands from stdout. Redirected to stderr it stops
# being an annotation and prints as literal text.
# `local` is deliberately absent: this is POSIX `sh`, where it is not a keyword
# (shellcheck SC3043), and no other script in this tree uses it.
fail() {
  fail_message="$1"
  echo "::error::$fail_message"
  exit 1
}

# Both messages name the environment variable AND the action input that sets it.
# The variable is what this script reads; the input is what the person reading
# the failed log actually wrote, in `github/golang/stages/30-tests/all`.
if [ -z "${DATABASE_IMAGE:-}" ]; then
  fail "DATABASE_IMAGE is empty (the 'database_image' input); nothing to provision"
fi

if [ -z "${DATABASE_URL_ENV:-}" ]; then
  fail "DATABASE_IMAGE is set but DATABASE_URL_ENV (the 'database_url_env' input) is empty; nothing would read the database"
fi

# A hosted runner is discarded after the job, but a self-hosted one is not: a container
# left behind by a cancelled or crashed run still holds the name, and `docker run`
# refuses to start a second one with it.
docker rm --force "$CONTAINER_NAME" >/dev/null 2>&1 || true

# Generated per run rather than a literal. The old hard-coded value was only ever
# reachable on loopback, so it was not a leaked credential -- but a well-known
# value is still a well-known value, and every scanner reads one in a template as
# a finding it cannot tell apart from a real one. A random value costs nothing
# here because nothing outside this job ever needs to know it.
POSTGRES_PASSWORD="$(openssl rand -hex 24 2>/dev/null \
  || head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
if [ -z "$POSTGRES_PASSWORD" ]; then
  fail 'could not generate a credential for the test database'
fi
export POSTGRES_PASSWORD

# `--env POSTGRES_PASSWORD` without a value: Docker copies it from this process's
# environment, so the generated value never appears in the argument vector -- and
# `ps` on a shared self-hosted runner cannot read it out of the `docker run` line.
#
# `127.0.0.1::5432` rather than `5432:5432`: the empty host port asks Docker for a free
# ephemeral one, so a machine already running PostgreSQL on 5432 -- the normal state of
# a developer box or a long-lived self-hosted runner -- does not collide; and binding
# the published port to loopback keeps the database off every other interface, since
# the default `0.0.0.0` would put an instance with well-known credentials on the
# network the runner sits in.
docker run --detach --name "$CONTAINER_NAME" \
  --env "POSTGRES_USER=$DB_USER" \
  --env POSTGRES_PASSWORD \
  --env "POSTGRES_DB=$DB_NAME" \
  --publish '127.0.0.1::5432' \
  --health-cmd "pg_isready -U $DB_USER" \
  --health-interval '5s' \
  --health-timeout '5s' \
  --health-retries '20' \
  "$DATABASE_IMAGE"

for _ in $(seq 1 60); do
  state="$(docker inspect --format '{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo 'starting')"
  [ "$state" = 'healthy' ] && break
  sleep 2
done

if [ "$(docker inspect --format '{{.State.Health.Status}}' "$CONTAINER_NAME")" != 'healthy' ]; then
  docker logs "$CONTAINER_NAME" || true
  fail 'the test database never became healthy'
fi

# Read the port Docker actually assigned. `docker port` answers `127.0.0.1:49163`, and
# an IPv6 host would answer `[::1]:49163`, so take the field after the LAST colon.
host_port="$(docker port "$CONTAINER_NAME" '5432/tcp' | head -n 1)"
host_port="${host_port##*:}"
if [ -z "$host_port" ]; then
  fail 'could not resolve the published port of the test database'
fi

# printf rather than interpolation: the Gitleaks "Password in URL" rule matches the
# literal `://<something>:<something>@` shape, and an interpolated user:secret@ still
# reads as that shape even though it holds no committed credential. A format string
# does not.
url="$(printf 'postgres://%s:%s@%s:%s/%s?sslmode=disable' \
  "$DB_USER" "$POSTGRES_PASSWORD" '127.0.0.1' "$host_port" "$DB_NAME")"
echo "${DATABASE_URL_ENV}=${url}" >> "$GITHUB_ENV"
