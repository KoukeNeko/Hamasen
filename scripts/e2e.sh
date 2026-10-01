#!/bin/sh
# Runs the end-to-end tests in E2E/ against the servers E2E/docker-compose.yml
# describes.
#
#   e2e.sh up      build and start the servers, and wait until they are healthy
#   e2e.sh test    protocol conformance, then network faults, then credential
#                  changes; extra arguments go to swift test
#   e2e.sh soak    five simulated years of use (HAMASEN_E2E_SOAK_YEARS, _DAYS,
#                  _OPERATIONS, _LANES and _SEED change its shape)
#   e2e.sh down    stop the servers and delete their data
#
# With HAMASEN_E2E_SSH=<ssh host> the servers run on that machine instead,
# copied to ~/hamasen-e2e there (HAMASEN_E2E_REMOTE_DIR), and the tests reach
# them across the network at HAMASEN_E2E_HOST, by default the address the
# remote machine reports as its own.
set -eu

repo=$(cd "$(dirname "$0")/.." && pwd)
e2e="$repo/E2E"
ssh_host=${HAMASEN_E2E_SSH:-}
remote_dir=${HAMASEN_E2E_REMOTE_DIR:-hamasen-e2e}

remote() {
    ssh -o BatchMode=yes "$ssh_host" "$@"
}

if [ -n "$ssh_host" ]; then
    if [ -z "${HAMASEN_E2E_HOST:-}" ]; then
        HAMASEN_E2E_HOST=$(remote "hostname -I | cut -d' ' -f1")
    fi
    export HAMASEN_E2E_HOST HAMASEN_E2E_SSH HAMASEN_E2E_REMOTE_DIR="$remote_dir"
    # The CA and SFTP key the remote stack made, copied here; kept apart from
    # a local stack's, which a different CA signed.
    export HAMASEN_E2E_RUN_DIR="$e2e/.run/$ssh_host"
fi

# TOKEN_LIFETIME and ROTATION_GRACE reach the cloud mock only when set; an
# empty value would replace its defaults with nothing.
compose() {
    if [ -n "$ssh_host" ]; then
        settings=""
        if [ -n "${TOKEN_LIFETIME:-}" ]; then settings="$settings TOKEN_LIFETIME=$TOKEN_LIFETIME"; fi
        if [ -n "${ROTATION_GRACE:-}" ]; then settings="$settings ROTATION_GRACE=$ROTATION_GRACE"; fi
        remote "cd '$remote_dir' && env$settings docker compose -p hamasen-e2e -f docker-compose.yml $*"
    else
        docker compose -p hamasen-e2e -f "$e2e/docker-compose.yml" "$@"
    fi
}

# The test package's own build products and the generated material stay
# here; the services are all the remote host needs.
push() {
    remote "mkdir -p '$remote_dir' && rm -rf '$remote_dir/services'"
    # Without these, macOS tar adds a ._ file for every file carrying an
    # extended attribute, which lands in the build contexts, and headers
    # GNU tar warns about once per file.
    COPYFILE_DISABLE=1 tar --no-xattrs -C "$e2e" -cf - docker-compose.yml services scripts CONTRACT.md \
        | remote "tar -C '$remote_dir' -xf -"
    # Read by every compose command there, the harness's restarts included,
    # so a recreated service keeps listening on the network.
    printf 'E2E_BIND=0.0.0.0\nE2E_HOST=%s\n' "$HAMASEN_E2E_HOST" | remote "cat > '$remote_dir/.env'"
}

pull_run_directory() {
    mkdir -p "$HAMASEN_E2E_RUN_DIR"
    remote "tar -C '$remote_dir/.run' -cf - certs/ca.pem keys" | tar -C "$HAMASEN_E2E_RUN_DIR" -xf -
}

run_tests() {
    export HAMASEN_E2E=1
    cd "$e2e"
    swift test "$@"
}

case "${1:-}" in
up)
    if [ -n "$ssh_host" ]; then
        push
        remote "mkdir -p '$remote_dir/.run'"
        compose up -d --build --wait
        pull_run_directory
        echo "Services running on $ssh_host, reached at $HAMASEN_E2E_HOST"
    else
        mkdir -p "$e2e/.run"
        compose up -d --build --wait
    fi
    ;;
test)
    shift
    # One suite at a time: the fault and credential suites change what
    # every client of a server sees. A failing suite does not keep the
    # later ones from reporting.
    status=0
    (run_tests --filter ConformanceTests "$@") || status=$?
    (run_tests --filter FaultTests "$@") || status=$?
    (run_tests --filter IdentityTests "$@") || status=$?
    exit "$status"
    ;;
soak)
    shift
    # Short-lived tokens, so the cloud sessions renew throughout the run
    # rather than once. Longer than the two minutes before expiry at which
    # the clients renew, or every request would renew first.
    (export TOKEN_LIFETIME=180 ROTATION_GRACE=15; compose up -d --wait cloud)
    status=0
    (HAMASEN_E2E_SOAK=1 run_tests --filter LongTermSimulation "$@") || status=$?
    (unset TOKEN_LIFETIME ROTATION_GRACE; compose up -d --wait cloud)
    echo "Reports: ${HAMASEN_E2E_RUN_DIR:-$e2e/.run}/soak-*.md"
    exit "$status"
    ;;
down)
    compose down -v
    ;;
*)
    sed -n '5,13s/^# *//p' "$0" >&2
    exit 2
    ;;
esac
