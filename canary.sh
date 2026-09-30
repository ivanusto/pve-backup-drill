#!/bin/sh
# canary: proves which point in time a restored VM came back from.
#
# Runs inside the guest. Every minute it appends one heartbeat line
# (epoch seconds, ISO time, hostname) to a log, fsyncs it, and keeps a
# fixed payload file whose sha256 was recorded at install. After a
# restore you run "verify": the most recent gap between two heartbeats
# is the restore boundary, the beat before the gap is the restore point,
# and the payload check tells you the data came back intact.
#
#   canary.sh install            # cron.d entry + 64 MiB payload + sha256
#   canary.sh beat               # one heartbeat (cron calls this)
#   canary.sh verify [FAILED_AT] # after restore; FAILED_AT is ISO UTC,
#                                # e.g. 2026-10-02T03:10:00Z, to get RPO
#
# POSIX sh, works on Debian/Ubuntu guests with cron and coreutils.
set -eu

DIR=${CANARY_DIR:-/var/lib/canary}
PAYLOAD_MIB=${CANARY_PAYLOAD_MIB:-64}
GAP_MIN=${CANARY_GAP_MIN:-180}   # seconds; a gap larger than this is a restore boundary

die() { printf 'canary: %s\n' "$*" >&2; exit 1; }

cmd_install() {
  [ "$(id -u)" -eq 0 ] || die "install needs root"
  mkdir -p "$DIR"
  cp "$0" /usr/local/bin/canary.sh
  chmod 0755 /usr/local/bin/canary.sh
  if [ ! -f "$DIR/payload.bin" ]; then
    dd if=/dev/urandom of="$DIR/payload.bin" bs=1M count="$PAYLOAD_MIB" status=none
    sha256sum "$DIR/payload.bin" | cut -d' ' -f1 > "$DIR/payload.sha256"
    sync "$DIR"
  fi
  printf '* * * * * root /usr/local/bin/canary.sh beat\n' > /etc/cron.d/canary
  chmod 0644 /etc/cron.d/canary
  /usr/local/bin/canary.sh beat
  printf 'canary installed: %s (payload %s MiB, sha256 %s)\n' \
    "$DIR" "$PAYLOAD_MIB" "$(cut -c1-12 "$DIR/payload.sha256")"
}

cmd_beat() {
  [ -d "$DIR" ] || die "$DIR missing, run install first"
  now=$(date -u +%s)
  iso=$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)
  printf '%s %s %s\n' "$now" "$iso" "$(hostname)" >> "$DIR/beats.log"
  # fsync the log so the beat is on disk before the next backup snapshot
  sync "$DIR/beats.log"
}

cmd_verify() {
  failed_at=${1:-}
  [ -s "$DIR/beats.log" ] || die "no beats in $DIR/beats.log"

  # Beat now, so the boundary shows up without waiting up to a minute
  # for cron (that minute would otherwise be counted into the RTO).
  ( cmd_beat ) 2>/dev/null || true

  # The restore boundary is the most recent gap larger than GAP_MIN.
  # Older gaps are earlier shutdowns or earlier restores. A backward
  # step (guest clock corrected after boot) is never a gap.
  # shellcheck disable=SC2046
  set -- $(awk -v min="$GAP_MIN" '
    NR > 1 && ($1 - prev) > min { before = prev; before_iso = prev_iso; after_iso = $2; gap = $1 - prev }
    { prev = $1; prev_iso = $2 }
    END {
      if (gap > 0) printf "%d %s %s %d\n", before, before_iso, after_iso, gap
      else print "0 - - 0"
    }' "$DIR/beats.log")
  before=$1; before_iso=$2; after_iso=$3; gap=$4

  synced=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown)

  printf 'beats logged      : %s\n' "$(wc -l < "$DIR/beats.log")"
  printf 'guest clock       : %s (NTP synchronized: %s)\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$synced"
  if [ "$gap" -gt 0 ]; then
    printf 'restore boundary  : gap of %d s between %s and %s\n' "$gap" "$before_iso" "$after_iso"
    printf 'restore point     : %s\n' "$before_iso"
    if [ -n "$failed_at" ]; then
      failed_epoch=$(date -u -d "$failed_at" +%s) || die "bad FAILED_AT: $failed_at"
      printf 'RPO (data lost)   : %d s (failure %s minus restore point)\n' "$((failed_epoch - before))" "$failed_at"
    fi
  else
    printf 'restore boundary  : none found (no gap > %d s), either not restored yet or cron resumed within the window\n' "$GAP_MIN"
  fi

  want=$(cat "$DIR/payload.sha256")
  got=$(sha256sum "$DIR/payload.bin" | cut -d' ' -f1)
  if [ "$want" = "$got" ]; then
    printf 'payload           : OK (%s)\n' "$(printf '%s' "$got" | cut -c1-12)"
  else
    printf 'payload           : MISMATCH want %s got %s\n' "$want" "$got"
    exit 2
  fi
  [ "$gap" -gt 0 ] || exit 1
}

case "${1:-}" in
  install) cmd_install ;;
  beat)    cmd_beat ;;
  verify)  shift; cmd_verify "$@" ;;
  *) sed -n '2,15p' "$0"; exit 64 ;;
esac
