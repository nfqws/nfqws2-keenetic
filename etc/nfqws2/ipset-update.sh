#!/bin/sh
# ipset-update.sh - refresh ipset.list from a public per-service address feed.
#
# Some services rotate their addresses often enough that a hand-written
# ipset.list goes stale within days. This script rebuilds the file from
# https://iplist.opencck.org for the services listed in ipset-sites.list.
#
# Only data=ip4 is used. data=cidr4 dumps whole whois zones, up to /8, which is
# far too wide: desyncing an entire /8 breaks unrelated traffic.
#
# nfqws2 re-reads the list on mtime change, so nothing is restarted here.
#
# Safety. The live file is replaced only if the result looks sane: at least
# half of the per-service downloads succeeded, and the merged list did not
# shrink below half of what was there before. One rotation backup is kept and
# the replacement is atomic (mv within the same filesystem).
#
# Suggested cron entry (every 6 hours):
#   17 */6 * * * /opt/etc/nfqws2/ipset-update.sh >/dev/null 2>&1

NFQWS2_DIR=$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")
LIST_DIR="$NFQWS2_DIR/lists"
LIST_FILE="$LIST_DIR/ipset.list"
BACKUP_FILE="$LIST_DIR/ipset.list.prev"
SITES_FILE="$NFQWS2_DIR/ipset-sites.list"

# Entware keeps everything under /opt, OpenWrt uses the system root
case "$NFQWS2_DIR" in
  /opt/*) VARDIR=/opt/var ;;
  *) VARDIR=/var ;;
esac
LOG_FILE="$VARDIR/log/ipset-update.log"
WORK_DIR="${TMPDIR:-/tmp}/ipset-update"
LOCK_DIR="$WORK_DIR/lock"

LOG_MAX_LINES=2000
LOG_KEEP_LINES=1000

# An empty or near-empty result must never reach the live file
MIN_LINES=100
# ...and neither must a result that lost most of the previous content
MIN_FRACTION_NUM=1
MIN_FRACTION_DEN=2

CONNECT_TIMEOUT=10
MAX_TIME=30
# One flaky source is enough to lose thousands of addresses for the next six
# hours, so every download is retried before it is written off.
RETRIES=3
RETRY_DELAY=4

BASE_URL="https://iplist.opencck.org/?format=text&data=ip4&site="
CF_URL="https://www.cloudflare.com/ips-v4"

# Strict IPv4, one address per line, and plain CIDR
IPV4_REGEX='^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$'
CIDR_REGEX='^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'

trim_log() {
  [ -f "$LOG_FILE" ] || return 0
  line_count=$(wc -l < "$LOG_FILE" 2>/dev/null)
  [ -n "$line_count" ] || return 0
  if [ "$line_count" -gt "$LOG_MAX_LINES" ]; then
    skip=$((line_count - LOG_KEEP_LINES))
    awk -v skip="$skip" 'NR>skip' "$LOG_FILE" > "$LOG_FILE.trim" 2>/dev/null \
      && mv -f "$LOG_FILE.trim" "$LOG_FILE"
  fi
}

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [$$] $1" >> "$LOG_FILE"
}

cleanup() {
  rm -f "$TMP_MERGE" "$TMP_SITE" "$TMP_VALID" "$TMP_CF" 2>/dev/null
  rmdir "$LOCK_DIR" 2>/dev/null
}

fail() {
  log "ERROR: $1 - keeping the previous list unchanged"
  cleanup
  exit 1
}

# download <url> <outfile>. wget-ssl is a documented dependency of this
# package; curl is used only if it happens to be installed and wget is not.
download() {
  if [ -n "$WGET_BIN" ]; then
    "$WGET_BIN" -q -T "$MAX_TIME" -O "$2" "$1" 2>>"$LOG_FILE"
  else
    curl -fsS --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
      -o "$2" "$1" 2>>"$LOG_FILE"
  fi
}

# fetch_retry <url> <outfile> <label>. An empty body counts as a failure and is
# retried: the feed has answered 200 with a zero-length body under load, which
# a single attempt cannot tell from a genuine "no addresses" answer.
fetch_retry() {
  fr_try=1
  while [ "$fr_try" -le "$RETRIES" ]; do
    rm -f "$2"
    if download "$1" "$2" && [ -s "$2" ]; then
      [ "$fr_try" -gt 1 ] && log "INFO: $3 recovered on attempt $fr_try"
      return 0
    fi
    log "WARN: $3 failed (attempt $fr_try/$RETRIES)"
    fr_try=$((fr_try + 1))
    [ "$fr_try" -le "$RETRIES" ] && sleep "$RETRY_DELAY"
  done
  return 1
}

WGET_BIN=
for candidate in /opt/bin/wget /usr/bin/wget wget; do
  if command -v "$candidate" >/dev/null 2>&1; then
    WGET_BIN="$candidate"
    break
  fi
done
if [ -z "$WGET_BIN" ] && ! command -v curl >/dev/null 2>&1; then
  echo "neither wget nor curl found, install wget-ssl" >&2
  exit 1
fi

mkdir -p "$WORK_DIR" "$VARDIR/log" 2>/dev/null
trim_log
touch "$LOG_FILE" 2>/dev/null

# mkdir is atomic even on busybox: guards against overlapping cron runs
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  log "ERROR: another instance is running (lock: $LOCK_DIR)"
  exit 1
fi
trap cleanup INT TERM EXIT

[ -d "$LIST_DIR" ] || fail "target directory $LIST_DIR does not exist"
[ -f "$SITES_FILE" ] || fail "no service list: $SITES_FILE"

TMP_MERGE="$WORK_DIR/merge.$$"
TMP_SITE="$WORK_DIR/site.$$"
TMP_VALID="$WORK_DIR/valid.$$"
TMP_CF="$WORK_DIR/cloudflare.$$"

: > "$TMP_MERGE" || fail "cannot create temp file $TMP_MERGE"

total_sites=0
failed_sites=0

while read -r site; do
  site=$(printf '%s' "$site" | tr -d '\r')
  case "$site" in ''|'#'*) continue ;; esac
  total_sites=$((total_sites + 1))
  if fetch_retry "${BASE_URL}${site}" "$TMP_SITE" "site=$site"; then
    cat "$TMP_SITE" >> "$TMP_MERGE"
    # Some responses are not newline-terminated. Without this the next block
    # glues onto the last address of this one and the validator silently drops
    # the malformed line.
    printf '\n' >> "$TMP_MERGE"
  else
    failed_sites=$((failed_sites + 1))
    log "WARN: giving up on site=$site after $RETRIES attempts"
  fi
done < "$SITES_FILE"
rm -f "$TMP_SITE"

[ "$total_sites" -gt 0 ] || fail "no services listed in $SITES_FILE"

# Services behind Cloudflare rotate their point addresses, so the published
# ranges are needed as well. Anything that must not be desynced belongs in
# ipset_exclude.list, which takes priority over this file.
if fetch_retry "$CF_URL" "$TMP_CF" "cloudflare ranges"; then
  cf_count=$(grep -cE "$CIDR_REGEX" "$TMP_CF")
  if [ "$cf_count" -ge 10 ]; then
    grep -E "$CIDR_REGEX" "$TMP_CF" >> "$TMP_MERGE"
    log "INFO: added $cf_count Cloudflare ranges"
  else
    log "WARN: Cloudflare answer had only $cf_count ranges, skipped"
  fi
else
  log "WARN: could not fetch Cloudflare ranges, continuing without them"
fi
rm -f "$TMP_CF"

grep -E "$IPV4_REGEX|$CIDR_REGEX" "$TMP_MERGE" | sort -u > "$TMP_VALID"
line_count=$(wc -l < "$TMP_VALID" 2>/dev/null)
[ -n "$line_count" ] || line_count=0

if [ $((failed_sites * 2)) -ge "$total_sites" ]; then
  fail "too many failed downloads: $failed_sites of $total_sites services"
fi

if [ "$line_count" -lt "$MIN_LINES" ]; then
  fail "result too small: $line_count lines, $failed_sites of $total_sites services failed"
fi

# Guard against a partial feed quietly halving the list
if [ -f "$LIST_FILE" ]; then
  prev_count=$(grep -cE '.' "$LIST_FILE" 2>/dev/null)
  [ -n "$prev_count" ] || prev_count=0
  if [ "$prev_count" -gt "$MIN_LINES" ] \
     && [ $((line_count * MIN_FRACTION_DEN)) -lt $((prev_count * MIN_FRACTION_NUM)) ]; then
    fail "result shrank from $prev_count to $line_count lines"
  fi
  cp -f "$LIST_FILE" "$BACKUP_FILE" 2>>"$LOG_FILE" \
    || log "WARN: could not back up the previous list to $BACKUP_FILE"
fi

mv -f "$TMP_VALID" "$LIST_FILE" || fail "atomic replace of $LIST_FILE failed"
chmod 644 "$LIST_FILE" 2>/dev/null

log "OK: $LIST_FILE updated - $line_count lines, $((total_sites - failed_sites))/$total_sites services"

cleanup
trap - INT TERM EXIT
exit 0
