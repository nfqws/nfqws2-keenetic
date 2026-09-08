#!/bin/sh
# auto-janitor.sh - prunes auto.list from entries that do not belong there.
#
# In auto mode nfqws2 appends a host to auto.list after three failures in
# 60 seconds, and never removes it. Over time the list fills up with entries
# that either cannot help or are actively harmful:
#   1. ephemeral session hostnames - a name generated per session is gone by the
#      time it is written, so the entry is dead on arrival
#   2. hosts already covered by user.list or exclude.list - redundant at best,
#      contradictory at worst
#   3. second-level domains whose subdomains are already curated in user.list -
#      keeping the apex widens desync to everything under it
#   4. anything matched by janitor-drop.list, a user-maintained suffix denylist
# Everything else is kept and tallied in janitor-seen.tsv.
#
# Counter semantics. Since nfqws2 never drops a host by itself, a single counter
# would only tell how long an entry has been sitting in the file. Two columns:
#   episodes - how many times the host appeared in auto.list after being absent,
#              i.e. how many times nfqws2 detected it anew. This is the signal
#              worth acting on: episodes >= 3 means the block keeps coming back
#              and the host is a candidate for user.list.
#   runs     - how many janitor runs saw it. Age only, not a signal.
#
# Usage:
#   auto-janitor.sh              apply changes and SIGHUP the daemon
#   auto-janitor.sh -n           dry run: print verdicts, change nothing
#   auto-janitor.sh -n -f FILE   dry run against another list, for testing
#
# Suggested cron entry (hourly):
#   27 * * * * /opt/etc/nfqws2/auto-janitor.sh >/dev/null 2>&1

NFQWS2_DIR=$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")
LISTS="$NFQWS2_DIR/lists"
AUTO="$LISTS/auto.list"
USERLIST="$LISTS/user.list"
EXCLUDELIST="$LISTS/exclude.list"
DROPRULES="$NFQWS2_DIR/janitor-drop.list"

# Entware keeps everything under /opt, OpenWrt uses the system root. Derive it
# from where this script lives rather than probing for /opt, which may exist on
# an OpenWrt box that also has Entware installed.
case "$NFQWS2_DIR" in
  /opt/*) VARDIR=/opt/var ;;
  *) VARDIR=/var ;;
esac
REVIEW="$VARDIR/log/nfqws2-janitor.log"
PIDFILE="$VARDIR/run/nfqws2.pid"
TMPDIR=${TMPDIR:-/tmp}

REVIEW_MAX_LINES=2000
REVIEW_KEEP_LINES=1000
SEEN="$NFQWS2_DIR/janitor-seen.tsv"
PREVSET="$NFQWS2_DIR/janitor-prev-hosts.txt"
TMP="$TMPDIR/janitor.$$"

DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    -n|--dry-run) DRY=1 ;;
    -f|--file) shift; AUTO="$1" ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

[ -f "$AUTO" ] || { echo "no such list: $AUTO" >&2; exit 1; }
[ -s "$AUTO" ] || { [ $DRY -eq 1 ] && echo "list is empty, nothing to do"; exit 0; }

STAMP=$(date '+%Y-%m-%d %H:%M:%S')

# keep the review log from growing without bound
trim_review() {
  [ -f "$REVIEW" ] || return 0
  rc=$(wc -l < "$REVIEW" 2>/dev/null)
  [ -n "$rc" ] || return 0
  if [ "$rc" -gt "$REVIEW_MAX_LINES" ]; then
    skip=$((rc - REVIEW_KEEP_LINES))
    awk -v skip="$skip" 'NR>skip' "$REVIEW" > "$REVIEW.trim" 2>/dev/null \
      && mv -f "$REVIEW.trim" "$REVIEW"
  fi
}

[ $DRY -eq 0 ] && { mkdir -p "$VARDIR/log" 2>/dev/null; trim_review; }

# host is covered if it or any of its parent domains is an exact line in the list
in_list() {
  h="$1"
  while :; do
    grep -qxF "$h" "$2" 2>/dev/null && return 0
    case "$h" in
      *.*) h="${h#*.}" ;;
      *) return 1 ;;
    esac
  done
}

# second-level apex whose subdomains are already curated in user.list.
# Keeping the apex would widen desync to everything under it.
apex_of_curated() {
  case "$1" in
    *.*.*) return 1 ;;
    *.*) : ;;
    *) return 1 ;;
  esac
  awk -v h=".$1" '
    index($0, h) && substr($0, length($0) - length(h) + 1) == h { found = 1; exit }
    END { exit !found }
  ' "$USERLIST"
}

# first label looks like a generated session name: >=6 chars, >=2 digits, no hyphen
ephemeral() {
  first="${1%%.*}"
  [ ${#first} -ge 6 ] || return 1
  echo "$first" | grep -qE '^[a-z]*[0-9]{2,}[a-z0-9]*$'
}

# host matches a suffix rule from janitor-drop.list
denied() {
  [ -f "$DROPRULES" ] || return 1
  while read -r rule; do
    rule=$(printf '%s' "$rule" | tr -d '\r')
    case "$rule" in ''|'#'*) continue ;; esac
    [ "$1" = "$rule" ] && return 0
    case "$1" in *".$rule") return 0 ;; esac
  done < "$DROPRULES"
  return 1
}

: > "$TMP"
kept=0; dropped=0

while read -r host; do
  host=$(printf '%s' "$host" | tr -d '\r')
  case "$host" in ''|'#'*) continue ;; esac
  if grep -qxF "$host" "$TMP" 2>/dev/null; then
    reason=duplicate
  elif ephemeral "$host"; then
    reason=ephemeral
  elif in_list "$host" "$USERLIST"; then
    reason=covered-by-user-list
  elif in_list "$host" "$EXCLUDELIST"; then
    reason=already-excluded
  elif apex_of_curated "$host"; then
    reason=apex-of-curated-subdomains
  elif denied "$host"; then
    reason=denylist
  else
    reason=""
  fi

  if [ -n "$reason" ]; then
    dropped=$((dropped+1))
    [ $DRY -eq 1 ] && echo "DROP  $host  ($reason)"
    [ $DRY -eq 0 ] && echo "$STAMP  DROP  $host  ($reason)" >> "$REVIEW"
  else
    kept=$((kept+1))
    echo "$host" >> "$TMP"
    [ $DRY -eq 1 ] && echo "KEEP  $host"
    if [ $DRY -eq 0 ]; then
      echo "$STAMP  KEEP  $host" >> "$REVIEW"
      episodes=1; runs=1; first="$STAMP"
      if [ -f "$SEEN" ]; then
        old=$(awk -F'\t' -v h="$host" '$3==h {print $1 "\t" $2 "\t" $4; exit}' "$SEEN")
        if [ -n "$old" ]; then
          episodes=$(printf '%s' "$old" | cut -f1)
          runs=$(printf '%s' "$old" | cut -f2)
          first=$(printf '%s' "$old" | cut -f3)
          runs=$((runs+1))
          # a fresh episode only if the host was absent from auto.list last run.
          # With no snapshot yet assume it was there, so the first run after an
          # upgrade does not inflate every counter by one.
          if [ -f "$PREVSET" ] && ! grep -qxF "$host" "$PREVSET"; then
            episodes=$((episodes+1))
          fi
        fi
        awk -F'\t' -v h="$host" '$3!=h' "$SEEN" > "$SEEN.tmp" && mv "$SEEN.tmp" "$SEEN"
      fi
      [ -f "$SEEN" ] || printf '# episodes\truns\thost\tfirst_seen\tlast_seen\n' > "$SEEN"
      printf '%s\t%s\t%s\t%s\t%s\n' "$episodes" "$runs" "$host" "$first" "$STAMP" >> "$SEEN"
    fi
  fi
done < "$AUTO"

echo "janitor: kept=$kept dropped=$dropped list=$AUTO"

if [ $DRY -eq 1 ]; then
  rm -f "$TMP"
  exit 0
fi

# snapshot of what stays in auto.list after this run - the next run compares
# against it to tell "still sitting there" from "detected again"
cp -f "$TMP" "$PREVSET" 2>/dev/null

if [ $dropped -eq 0 ]; then
  rm -f "$TMP"
  exit 0
fi

cp -a "$AUTO" "$AUTO.janitor-prev"
mv "$TMP" "$AUTO"
chmod 644 "$AUTO"

if [ -f "$PIDFILE" ]; then
  pid=$(cat "$PIDFILE")
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill -HUP "$pid"
    echo "janitor: SIGHUP sent to $pid"
  fi
fi
