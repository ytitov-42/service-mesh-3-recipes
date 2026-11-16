#!/usr/bin/env bash
# Shared helpers. Sourced by every script; not executable on its own.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
STATE_DIR="${STATE_DIR:-$SCRIPT_DIR/state}"
HANDOFF_FILE="$STATE_DIR/handoff.env"     # cluster admin -> AWS owner
HANDBACK_FILE="$STATE_DIR/handback.env"   # AWS owner -> cluster admin

mkdir -p "$STATE_DIR"

# How long the scripts wait for slow things (CSV install, BGP convergence, endpoints).
# Defaults are generous because a real cluster is slow; override to fail fast when testing:
#   WAIT_ATTEMPTS=3 WAIT_INTERVAL=1 ./03-cluster-deploy.sh
WAIT_ATTEMPTS="${WAIT_ATTEMPTS:-60}"
WAIT_INTERVAL="${WAIT_INTERVAL:-15}"

# ---- output ------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RST=$'\033[0m'; C_RED=$'\033[31m'; C_GRN=$'\033[32m'
  C_YEL=$'\033[33m'; C_BLU=$'\033[34m'; C_BLD=$'\033[1m'
else
  C_RST=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BLD=""
fi

step()  { printf '\n%s==>%s %s%s%s\n' "$C_BLU" "$C_RST" "$C_BLD" "$*" "$C_RST"; }
info()  { printf '    %s\n' "$*"; }
ok()    { printf '    %s[ ok ]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn()  { printf '    %s[warn]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
fail()  { printf '\n%s[FAIL]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }

# fail with a pointer back to the runbook
fail_ref() { printf '\n%s[FAIL]%s %s\n    See runbook: %s\n' "$C_RED" "$C_RST" "$1" "$2" >&2; exit 1; }

confirm() {
  [ "${ASSUME_YES:-false}" = "true" ] && return 0
  local reply
  printf '\n%s%s%s [y/N] ' "$C_BLD" "$1" "$C_RST"
  read -r reply
  case "$reply" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

run() {
  if [ "${DRY_RUN:-false}" = "true" ]; then
    printf '    %s[dry]%s %s\n' "$C_YEL" "$C_RST" "$*"
    return 0
  fi
  "$@"
}

require_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || fail "required command not found: $c"
  done
}

# ---- config / state ----------------------------------------------------------
load_config() {
  local f="$SCRIPT_DIR/config.env"
  [ -f "$f" ] || fail "config.env not found next to the scripts ($f)"
  # shellcheck disable=SC1090
  . "$f"
  : "${CLUSTER_NAME:?set in config.env}"
  : "${REGION:?set in config.env}"
  : "${CUDN_CIDR:?set in config.env}"
  [ "$AMAZON_ASN" != "$CLUSTER_ASN" ] || \
    fail "AMAZON_ASN and CLUSTER_ASN must differ, otherwise the session is not eBGP"
}

load_state() {   # load_state <file> <human description>
  [ -f "$1" ] || fail "missing $2: $1
    The other role has not run their script yet, or did not send you the file."
  # shellcheck disable=SC1090
  . "$1"
}

save_var() {     # save_var <file> <NAME> <value>
  local f="$1" k="$2" v="$3"
  touch "$f"
  grep -v "^${k}=" "$f" > "$f.tmp" 2>/dev/null || true
  mv "$f.tmp" "$f"
  printf '%s=%q\n' "$k" "$v" >> "$f"
}

# ---- networking helpers ------------------------------------------------------
# returns 0 (true) when the two CIDRs overlap
cidr_overlap() {
  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 not available — skipping overlap check for $1 vs $2. Verify by hand."
    return 1
  fi
  python3 - "$1" "$2" <<'PY'
import ipaddress, sys
try:
    a = ipaddress.ip_network(sys.argv[1], strict=False)
    b = ipaddress.ip_network(sys.argv[2], strict=False)
except ValueError as e:
    print(f"could not parse CIDR: {e}", file=sys.stderr)
    sys.exit(2)
sys.exit(0 if a.overlaps(b) else 1)
PY
}

# returns 0 when <ip> falls inside <cidr>
ip_in_cidr() {
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$1" "$2" <<'PY'
import ipaddress, sys
try:
    ip = ipaddress.ip_address(sys.argv[1])
    net = ipaddress.ip_network(sys.argv[2], strict=False)
except ValueError:
    sys.exit(2)
sys.exit(0 if ip in net else 1)
PY
}

# ---- auth preflight ----------------------------------------------------------
require_oc_login() {
  require_cmd oc
  oc whoami >/dev/null 2>&1 || fail "not logged in to a cluster — run 'oc login' first"
  oc auth can-i '*' '*' --all-namespaces >/dev/null 2>&1 \
    || warn "you do not appear to be cluster-admin; several steps will fail"
}

require_aws() {
  require_cmd aws
  aws sts get-caller-identity --region "$REGION" >/dev/null 2>&1 \
    || fail "AWS credentials not usable for region $REGION"
}

# Tolerate 'already exists / already associated' style errors without masking real ones.
# usage: tolerate "<regex of acceptable error text>" <command...>
tolerate() {
  local pattern="$1"; shift
  local out rc
  if [ "${DRY_RUN:-false}" = "true" ]; then
    printf '    %s[dry]%s %s\n' "$C_YEL" "$C_RST" "$*"
    return 0
  fi
  set +e
  out="$("$@" 2>&1)"; rc=$?
  set -e
  if [ $rc -ne 0 ]; then
    if printf '%s' "$out" | grep -Eqi "$pattern"; then
      info "already present, continuing"
      return 0
    fi
    printf '%s\n' "$out" >&2
    return $rc
  fi
  printf '%s' "$out"
}
