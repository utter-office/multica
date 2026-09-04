#!/bin/bash
# =============================================================================
# SIT unified deploy: backend + frontend + executor on ONE tag (三端一键部署)
#
#   bash deploy-sit.sh                # deploy all three services at the tag in
#                                     # the server's .env (MULTICA_IMAGE_TAG)
#   bash deploy-sit.sh --check        # read-only: running state vs desired tag
#                                     # vs latest fork release tag; no changes
#   bash deploy-sit.sh --tag <tag>    # write tag into the server .env
#                                     # (MULTICA_IMAGE_TAG), then deploy
#
# Tag forms: semver without leading v (0.4.41, canonical — every service image
# is published under it), or a branch/commit tag the images were pushed with
# (utter-main, sha-<short>). "latest" is rejected: the workflow never pushes it
# and rolling tags defeat rollback.
#
# The three services always move together: the executor's multica CLI is the
# same binary the backend image carries (COPY --from), so a mixed-tag pair can
# trip the server's quick-create version gate (422 daemon_version_unsupported).
#
# Requirements: SIT_HOST env var (root@<server>), ssh key auth.
# =============================================================================
set -euo pipefail

SIT_HOST="${SIT_HOST:?请先设置 SIT_HOST 环境变量，如: export SIT_HOST=root@your-server}"
# NOTE: /www/server/panel/data/compose/utter-office belongs to utter-office;
# multica runs in its own compose dir with a non-default file name.
COMPOSE_DIR="/www/server/panel/data/compose/multica"
COMPOSE_FILE="docker-compose.selfhost.yml"
# Service names must match docker-compose.selfhost.yml (postgres stays pinned
# to its own image and is never part of a release).
SERVICES="backend frontend executor"
ENV_FILE=".env"
MODE="deploy"
TAG_ARG=""

usage() {
    sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --check) MODE="check" ;;
        --tag)
            [ $# -ge 2 ] || { echo "error: --tag needs a value" >&2; exit 1; }
            TAG_ARG="$2"
            shift
            ;;
        -h|--help) usage ;;
        *) echo "error: unknown argument: $1" >&2; exit 1 ;;
    esac
    shift
done

# Canonical registry tag form is without a leading v (docker meta type=semver
# strips it; v-prefixed twins exist only for backend and executor-base, which
# the executor FROM chain references by git ref name).
normalize_tag() {
    case "$1" in
        v[0-9]*.[0-9]*.[0-9]*) echo "${1#v}" ;;
        *) echo "$1" ;;
    esac
}
[ -n "$TAG_ARG" ] && TAG_ARG="$(normalize_tag "$TAG_ARG")"
case "$TAG_ARG" in
    latest) echo "error: refusing tag 'latest' — the workflow never pushes it" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# remote() runs a bash script on the SIT host. Selected local vars are in
# scope via the exports above the heredoc; the heredoc body runs under
# `bash -s` on the server, so nothing needs shell-escaping.
# ---------------------------------------------------------------------------
remote() {
    ssh -o BatchMode=yes "$SIT_HOST" \
        "export COMPOSE_DIR='$COMPOSE_DIR' COMPOSE_FILE='$COMPOSE_FILE' SERVICES='$SERVICES' ENV_FILE='$ENV_FILE' TAG_ARG='$TAG_ARG' MODE='$MODE'; bash -s" <<'REMOTE'
    set -euo pipefail
    cd "$COMPOSE_DIR"

    # --tag <x> persists the desired tag first so every later read (compose
    # config, preflight) already sees the target state.
    if [ -n "$TAG_ARG" ]; then
        cp "$ENV_FILE" "$ENV_FILE.bak.$(date +%Y%m%d%H%M%S)"
        sed -i "s/^MULTICA_IMAGE_TAG=.*/MULTICA_IMAGE_TAG=$TAG_ARG/" "$ENV_FILE"
        echo "== .env updated: MULTICA_IMAGE_TAG=$TAG_ARG (backup kept) =="
    fi

    desired="$(grep '^MULTICA_IMAGE_TAG=' "$ENV_FILE" | head -1 | cut -d= -f2- || true)"
    if [ -z "$desired" ]; then
        echo "error: MULTICA_IMAGE_TAG not found in $ENV_FILE" >&2
        exit 1
    fi
    case "$desired" in
        latest) echo "error: .env MULTICA_IMAGE_TAG=latest — the workflow never pushes it; pick a real tag" >&2; exit 1 ;;
    esac

    # service -> image map, restricted to $SERVICES (excludes the pinned
    # postgres image). --services and --images do NOT share an output order,
    # so each image is extracted by name from the compose model instead.
    service_image() { # $1 = service name
        docker compose -f "$COMPOSE_FILE" config | awk -v svc="$1:" '
            $0 ~ "^  " svc { in_svc = 1; next }
            in_svc && /^  [a-zA-Z]/ { in_svc = 0 }
            in_svc && /^    image:/ { sub(/^    image: /, ""); print; exit }
        '
    }
    declare -a svc_names=() svc_images=()
    for s in $SERVICES; do
        img="$(service_image "$s")"
        [ -n "$img" ] || { echo "error: no image resolved for service $s in the compose model" >&2; exit 1; }
        svc_names+=("$s")
        svc_images+=("$img")
    done

    echo "== desired tag (${ENV_FILE}): $desired =="
    for i in "${!svc_names[@]}"; do
        echo "   ${svc_names[$i]} -> ${svc_images[$i]}"
    done

    if [ "$MODE" = "check" ]; then
        echo ""
        echo "== running containers =="
        docker ps --filter "name=multica-" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' || true
        exit 0
    fi

    # Preflight: every service image must exist at the desired tag before we
    # touch a running container. manifest inspect needs no pull.
    echo "== preflight: images exist at tag '$desired' =="
    for img in "${svc_images[@]}"; do
        case "$img" in
            *":$desired") ;;
            *) echo "error: compose resolves $img, expected :$desired — .env drift?" >&2; exit 1 ;;
        esac
        docker manifest inspect "$img" >/dev/null 2>&1 \
            || { echo "error: image not found on registry: $img" >&2; exit 1; }
        echo "   ok: $img"
    done

    echo "== pulling =="
    docker compose -f "$COMPOSE_FILE" pull $SERVICES

    echo "== recreating $SERVICES =="
    docker compose -f "$COMPOSE_FILE" up -d --force-recreate $SERVICES

    # Wait for backend readiness (backend runs ./migrate up on boot).
    echo "== waiting for backend /readyz =="
    ready=""
    for i in $(seq 1 90); do
        port="$(docker compose -f "$COMPOSE_FILE" port backend 8080 2>/dev/null | sed 's/.*://' | tr -d ' ')"
        code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/readyz" 2>/dev/null || true)"
        if [ "$code" = "200" ]; then echo "   ok: backend /readyz -> 200"; ready=1; break; fi
        sleep 2
    done
    [ -n "$ready" ] || { echo "error: backend /readyz never returned 200" >&2; exit 1; }

    # Frontend serves its app shell. It binds a moment after start, so probe
    # with retries — a single cold read races startup and reports a false 000.
    echo "   frontend http -> checking with retries"
    fcode="000"
    for i in $(seq 1 10); do
        fport="$(docker compose -f "$COMPOSE_FILE" port frontend 3000 2>/dev/null | sed 's/.*://' | tr -d ' ' || true)"
        if [ -n "$fport" ]; then
            fcode="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${fport}/" 2>/dev/null || true)"
            [ "$fcode" = "200" ] && break
        fi
        sleep 2
    done
    echo "   frontend http -> $fcode"

    # Executor: daemon up + CLI stamp sane. The stamp is what the server's
    # quick-create gate parses (cli_version at registration): it must be a
    # semver (v0.4.41) or the dev git-describe shape (v0.4.41-1-g<sha>) — a
    # bare sha or branch name would be rejected with 422. The container only
    # accepts exec once its entrypoint is up, so probe with retries instead of
    # letting a transient exec failure kill the script under set -e.
    exec_up=""
    for i in $(seq 1 30); do
        if docker compose -f "$COMPOSE_FILE" ps --status running executor 2>/dev/null | grep -q "executor"; then exec_up=1; break; fi
        sleep 2
    done
    [ -n "$exec_up" ] || { echo "error: executor container not running" >&2; exit 1; }

    stamp=""
    for i in $(seq 1 15); do
        stamp="$(docker compose -f "$COMPOSE_FILE" exec -T executor multica --version 2>/dev/null | head -1 || true)"
        [ -n "$stamp" ] && break
        sleep 2
    done
    echo "   executor CLI: $stamp"
    case "$stamp" in
        *"v"[0-9]*.[0-9]*.[0-9]*) echo "   executor stamp: ok (parsable by the version gate)" ;;
        *) echo "   executor stamp: WARNING — not a semver/git-describe string; quick-create will be rejected (422)" ;;
    esac

    echo ""
    echo "== daemon status =="
    for i in $(seq 1 10); do
        dstatus="$(docker compose -f "$COMPOSE_FILE" exec -T executor multica daemon status 2>/dev/null | head -6 || true)"
        [ -n "$dstatus" ] && { echo "$dstatus"; break; }
        sleep 2
    done

    echo ""
    echo "== summary =="
    docker ps --filter "name=multica-" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
REMOTE
}

remote

if [ "$MODE" = "check" ]; then
    # Local hint: newest fork release tag vs desired tag (network may be down;
    # then this is skipped rather than failing the check).
    latest="$(git ls-remote --tags origin 'v[0-9]*' 2>/dev/null | grep -v '\^{}' | sed 's|.*refs/tags/||' | sort -V | tail -1 || true)"
    if [ -n "$latest" ]; then
        echo ""
        echo "== hint =="
        echo "   latest fork release tag on origin: $latest"
    fi
fi
