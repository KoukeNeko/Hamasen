#!/bin/sh
# Starts, stops and inspects the Docker services the end-to-end tests run
# against (E2E/CONTRACT.md).
#
#   e2e-services.sh up              build, start, and wait until all are healthy
#   e2e-services.sh down            stop all and delete their volumes
#   e2e-services.sh status          list the services and their health
#   e2e-services.sh logs [service]  print logs (extra arguments go to compose)
set -eu

e2e_dir=$(cd "$(dirname "$0")/.." && pwd)

compose() {
    docker compose -f "$e2e_dir/docker-compose.yml" "$@"
}

case "${1:-}" in
up)
    # The certs service fills .run once; later runs keep what is there, and
    # down leaves it alone, so clients that trust the CA keep trusting it.
    mkdir -p "$e2e_dir/.run"
    compose up -d --build --wait
    ;;
down)
    compose down -v
    ;;
status)
    compose ps -a
    ;;
logs)
    shift
    compose logs "$@"
    ;;
*)
    sed -n '5,8s/^# *//p' "$0" >&2
    exit 2
    ;;
esac
