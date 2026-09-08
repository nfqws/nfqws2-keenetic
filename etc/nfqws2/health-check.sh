#!/bin/sh
# health-check.sh - health check that runs ON THE ROUTER, not on a PC.
#
# Why it belongs here: a PC is not on 24/7, so scheduled checks there have
# blind gaps of many hours. The router is always up, and nfqws2 hooks live
# in mangle PREROUTING/POSTROUTING, so traffic originated by the router
# itself passes through the same NFQUEUE as client traffic - a probe from
# here exercises the real bypass path.
#
# Method: per target URL, download the body with wget (curl as fallback),
# count real bytes received, repeat --runs times and keep the best result -
# a single bad run is noise, a real outage fails every run. Compare against
# a saved baseline; less than half of it counts as degraded.
#
# KNOWN LIMITATION - read before trusting a green run: this script only
# ever opens ONE short-lived connection per request (wget/curl close it
# after the response). It cannot detect the class of breakage where short
# requests succeed in full but a long-lived keep-alive/HTTP2 connection
# stalls after the first response - that needs a harness that holds a raw
# TLS socket open and keeps writing to it, which is not something POSIX sh
# with wget/curl can do. A green result here does not rule out that failure
# mode; it only means short single-shot requests get through.
#
# Also out of reach here, for the same reason - no raw sockets: per-IP TLS
# handshake accounting, the number of resolved addresses, and the HTTP status
# code. If you need those, use a browser-based harness instead.
#
# Usage:
#   health-check.sh                  # 3 runs, compare against baseline
#   health-check.sh --runs 5
#   health-check.sh --save-baseline  # store current numbers as the reference
#   health-check.sh --quiet          # log only, no stdout table
#   health-check.sh -h               # this text

# Paths are derived from where this script lives, not hardcoded to /opt,
# so the same file works unmodified on Entware (/opt/...) and OpenWrt
# (root filesystem) - Entware keeps writable state under /opt/var, OpenWrt
# under /var.
NFQWS2_DIR=$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")
case "$NFQWS2_DIR" in
  /opt/*) VARDIR=/opt/var ;;
  *) VARDIR=/var ;;
esac

TARGETS_FILE="$NFQWS2_DIR/health-targets.list"
BASELINE="$NFQWS2_DIR/health-baseline.tsv"
LOG="$VARDIR/log/nfqws2-health.log"
LOG_MAX=1048576  # 1 MB, then rotate to .1

TIMEOUT=15       # seconds; covers both connect and read, wget/curl have no separate knobs here
DEGRADE_RATIO_DIV=2  # degraded if bytes < baseline / this

RUNS=3
SAVE=0
QUIET=0

usage() {
  echo "usage: health-check.sh [--runs N] [--save-baseline] [--quiet] [-h]"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --runs) shift; RUNS="$1" ;;
    --save-baseline) SAVE=1 ;;
    --quiet) QUIET=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

case "$RUNS" in
  ''|*[!0-9]*) echo "--runs wants a positive integer, got: $RUNS" >&2; exit 2 ;;
esac
[ "$RUNS" -ge 1 ] || { echo "--runs must be >= 1" >&2; exit 2; }

[ -f "$TARGETS_FILE" ] || { echo "no such targets file: $TARGETS_FILE" >&2; exit 2; }

if command -v wget >/dev/null 2>&1; then
  DOWNLOADER=wget
elif command -v curl >/dev/null 2>&1; then
  DOWNLOADER=curl
else
  echo "no downloader found (need wget or curl)" >&2
  exit 2
fi

# same rotate-on-size policy as the janitor review log; also echoes what it
# writes, so a caller can do `msg=$(log "...")` in one line
log() {
  stamp=$(date '+%Y-%m-%d %H:%M:%S')
  line="$stamp $1"
  mkdir -p "$(dirname "$LOG")" 2>/dev/null
  if [ -f "$LOG" ]; then
    sz=$(wc -c < "$LOG" 2>/dev/null)
    [ -n "$sz" ] && [ "$sz" -gt "$LOG_MAX" ] && mv -f "$LOG" "$LOG.1" 2>/dev/null
  fi
  echo "$line" >> "$LOG" 2>/dev/null
  echo "$line"
}

# host part of a target URL, for baseline keys and display - strip scheme,
# then everything from the first slash onward
host_of() {
  printf '%s' "$1" | sed -e 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##' -e 's#/.*##'
}

# download one URL, print the byte count received. Failure (bad host,
# refused connection, timeout) shows up as 0 bytes, same as a zero-length
# response - both mean "nothing usable came through", which is exactly
# what FAIL is supposed to catch.
fetch_bytes() {
  tmp=$(mktemp 2>/dev/null || echo "/tmp/nfqws2-health.$$")
  if [ "$DOWNLOADER" = wget ]; then
    wget -q -T "$TIMEOUT" -O "$tmp" "$1" 2>/dev/null
  else
    curl -s -m "$TIMEOUT" -o "$tmp" "$1" 2>/dev/null
  fi
  bytes=$(wc -c < "$tmp" 2>/dev/null)
  rm -f "$tmp" 2>/dev/null
  [ -n "$bytes" ] || bytes=0
  echo "$bytes"
}

# baseline stored bytes for a host, empty if none on record
baseline_for() {
  [ -f "$BASELINE" ] || return 1
  awk -F'\t' -v h="$1" '$1==h {print $2; found=1} END{exit !found}' "$BASELINE"
}

RESULTS=$(mktemp 2>/dev/null || echo "/tmp/nfqws2-health-results.$$")
BEST=$(mktemp 2>/dev/null || echo "/tmp/nfqws2-health-best.$$")
: > "$RESULTS"
trap 'rm -f "$RESULTS" "$BEST"' EXIT

run=1
while [ "$run" -le "$RUNS" ]; do
  while IFS= read -r url || [ -n "$url" ]; do
    case "$url" in ''|'#'*) continue ;; esac
    host=$(host_of "$url")
    bytes=$(fetch_bytes "$url")
    printf '%s\t%s\n' "$host" "$bytes" >> "$RESULTS"
  done < "$TARGETS_FILE"
  run=$((run + 1))
done

# keep the best run per host: a single bad run is noise, a real outage
# fails all of them
awk -F'\t' '{ if (!($1 in max) || $2 > max[$1]) max[$1] = $2 }
            END { for (h in max) print h "\t" max[h] }' "$RESULTS" > "$BEST"

if [ "$SAVE" -eq 1 ]; then
  {
    echo "# host<TAB>bytes - generated by health-check.sh --save-baseline"
    cat "$BEST"
  } > "$BASELINE"
  n=$(wc -l < "$BEST" 2>/dev/null)
  log "baseline saved: $BASELINE ($n targets, runs=$RUNS)"
  exit 0
fi

bad_count=0
total=0
lines=""
while IFS= read -r url || [ -n "$url" ]; do
  case "$url" in ''|'#'*) continue ;; esac
  host=$(host_of "$url")
  total=$((total + 1))
  bytes=$(awk -F'\t' -v h="$host" '$1==h {print $2; found=1} END{exit !found}' "$BEST")
  [ -n "$bytes" ] || bytes=0
  ref=$(baseline_for "$host")

  mark=OK
  if [ "$bytes" -le 0 ]; then
    mark=FAIL
    bad_count=$((bad_count + 1))
  elif [ -n "$ref" ] && [ "$ref" -gt 0 ] && [ "$bytes" -lt $((ref / DEGRADE_RATIO_DIV)) ]; then
    mark=DEGRADED
    bad_count=$((bad_count + 1))
  fi

  lines="$lines
  $(printf '%-38s %8s  ref=%-8s %s' "$host" "$bytes" "${ref:--}" "$mark")"
done < "$TARGETS_FILE"

if [ "$QUIET" -eq 0 ]; then
  echo "health-check: $total targets, runs=$RUNS"
  echo "$lines"
fi

if [ "$bad_count" -gt 0 ]; then
  log "ALERT: $bad_count of $total targets bad"
  exit 1
fi
log "OK: all $total targets healthy (runs=$RUNS)"
exit 0
