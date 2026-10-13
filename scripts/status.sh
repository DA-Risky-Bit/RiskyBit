#!/usr/bin/env bash

set -e
set -o pipefail
trap 'echo "Error: command failed (exit $?) at line $LINENO: $BASH_COMMAND" >&2' ERR

die() { echo "Error: $1" >&2; exit "${2:-1}"; }

dev=0
for a in "$@"; do
  case $a in
    --dev) dev=1 ;;
    *) die "unknown option: $a (supported: --dev)" 2 ;;
  esac
done

for cmd in docker awk sort cut column mktemp; do
  command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
done
docker compose version >/dev/null 2>&1 \
  || die "the 'docker compose' plugin is not available. Install Docker Compose v2."
docker info >/dev/null 2>&1 \
  || die "cannot connect to the Docker daemon. Is it running, and do you have permission to use it?"
docker compose config -q >/dev/null 2>&1 \
  || die "no valid compose project found in '$(pwd)'. Run this from the project directory (check the compose file and any required env vars)."

ids=$(docker compose ps -q)
[ -z "$ids" ] && { echo "No running containers"; exit 0; }

stats=$(mktemp); ps_out=$(mktemp)
trap 'rm -f "$stats" "$ps_out"' EXIT
trap 'echo "Error: command failed (exit $?) at line $LINENO: $BASH_COMMAND" >&2' ERR

docker stats --no-stream --format '{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}' $ids > "$stats"

docker compose ps -a --format '{{.Name}}\t{{.Service}}\t{{.State}}\t{{range .Publishers}}{{if .PublishedPort}}{{.PublishedPort}} {{end}}{{end}}' > "$ps_out"

{
  printf 'SERVICE\tSTATE\tPORTS\tCPU\tMEM\tMEM%%\n'
  awk '
    BEGIN { FS = OFS = "\t" }
    NR == FNR { cpu[$1]=$2; mem[$1]=$3; memp[$1]=$4; next }
    {
      n = split($4, p, " "); first = ""; ports = ""; delete seen
      for (i = 1; i <= n; i++)
        if (!(p[i] in seen)) {
          seen[p[i]] = 1
          ports = ports (ports ? "," : "") p[i]
          if (first == "") first = p[i]
        }
      print (first == "" ? 99999 : first), $2, $3, (ports == "" ? "-" : ports), \
            ($1 in cpu ? cpu[$1] : "-"), ($1 in mem ? mem[$1] : "-"), ($1 in memp ? memp[$1] : "-")
    }' "$stats" "$ps_out" | sort -n | cut -f2-
} | column -t -s $'\t'
exit 0
