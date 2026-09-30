#!/bin/sh
# restore-drill: time a VM restore from "go" to "the guest proves its data".
#
# Run on a Proxmox VE node the moment you click restore in HDP (or start
# any other restore). It polls until the VM exists, is running, answers
# ping, opens SSH, and finally until canary.sh verify inside the guest
# says the payload is intact. Stop the original VM first: the restored
# guest comes back on the same IP, and ping and SSH must not reach the
# original. Each step is stamped; the last line is a
# drill-log row you paste into drill-log.md, and a JSON line goes to
# drills.jsonl.
#
#   restore-drill.sh VMID GUEST_IP [--failed-at ISO] [--ssh user@host]
#                                  [--timeout SEC] [--label TEXT] [--no-pve]
#
#   VMID      the VMID the restore wizard assigned
#   GUEST_IP  address the restored guest should answer on
#   --failed-at  simulated failure time, passed to canary.sh verify for RPO
#   --ssh     login for the guest, default root@GUEST_IP (key auth, BatchMode)
#   --name    find the VMID by VM name in "qm list" (use VMID "auto" when
#             the restore tool assigns the VMID itself)
#   --no-pve  the restore lands outside Proxmox VE (HDP instant restore
#             boots the VM on the NAS's Virtualization Station), so skip
#             the qm steps; runs on any host with ping, nc and ssh
#
# Environment overrides for testing without a cluster: QM, PING, NC, SSH.
set -eu

QM=${QM:-qm}; PING=${PING:-ping}; NC=${NC:-nc}; SSH=${SSH:-ssh}
OUT=${OUT:-drills.jsonl}

VMID=${1:-}; IP=${2:-}
if [ -z "$VMID" ] || [ -z "$IP" ]; then sed -n '2,27p' "$0"; exit 64; fi
shift 2
FAILED_AT=""; SSHTARGET="root@$IP"; TIMEOUT=1800; LABEL=""; PVE=1; NAME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --failed-at) FAILED_AT=$2; shift 2 ;;
    --ssh)       SSHTARGET=$2; shift 2 ;;
    --timeout)   TIMEOUT=$2; shift 2 ;;
    --label)     LABEL=$2; shift 2 ;;
    --no-pve)    PVE=0; shift ;;
    --name)      NAME=$2; shift 2 ;;
    *) printf 'unknown option %s\n' "$1" >&2; exit 64 ;;
  esac
done

t0=$(date -u +%s)
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
since() { printf '%d' "$(( $(date -u +%s) - t0 ))"; }
stamp() { printf '%s  +%4ss  %s\n' "$(iso "$(date -u +%s)")" "$(since)" "$1"; }
deadline() { [ "$(since)" -lt "$TIMEOUT" ] || { stamp "TIMEOUT after ${TIMEOUT}s at step: $1"; exit 3; }; }

stamp "T0 start  vmid=$VMID ip=$IP ${LABEL:+label=$LABEL}"

if [ "$PVE" -eq 1 ]; then
  # T1: VM exists in the cluster config (qm is node-local: run this on
  # the node the restore targets)
  while :; do
    if [ -n "$NAME" ]; then
      VMID=$($QM list 2>/dev/null | awk -v n="$NAME" '$2 == n {print $1; exit}')
    fi
    if [ -n "$VMID" ] && [ "$VMID" != auto ] && $QM config "$VMID" >/dev/null 2>&1; then break; fi
    deadline "vm exists"; sleep 2
  done
  t1=$(date -u +%s); stamp "T1 vm exists vmid=$VMID"

  # T2: VM running
  while ! $QM status "$VMID" 2>/dev/null | grep -q 'running'; do deadline "vm running"; sleep 2; done
  t2=$(date -u +%s); stamp "T2 vm running"
  s1=$((t1 - t0))s; s2=$((t2 - t0))s; j1=$((t1 - t0)); j2=$((t2 - t0))
else
  stamp "T1/T2 skipped (--no-pve)"
  s1=-; s2=-; j1=null; j2=null
fi

# T3: guest answers ping
while ! $PING -c1 -W1 "$IP" >/dev/null 2>&1; do deadline "ping"; sleep 2; done
t3=$(date -u +%s); stamp "T3 ping ok"

# T4: SSH port open
while ! $NC -z -w1 "$IP" 22 >/dev/null 2>&1; do deadline "ssh port"; sleep 2; done
t4=$(date -u +%s); stamp "T4 ssh port open"

# T5: canary verify inside the guest
verify_out=""
rc=1
while :; do
  # shellcheck disable=SC2086
  if verify_out=$($SSH -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$SSHTARGET" \
        "/usr/local/bin/canary.sh verify $FAILED_AT" 2>&1); then rc=0; break; fi
  case "$verify_out" in *MISMATCH*) rc=2; break ;; esac
  deadline "canary verify"; sleep 5
done
t5=$(date -u +%s)
printf '%s\n' "$verify_out" | sed 's/^/        /'
if [ "$rc" -eq 0 ]; then stamp "T5 canary OK"; else stamp "T5 canary FAILED rc=$rc"; fi

restore_point=$(printf '%s\n' "$verify_out" | awk '/^restore point/ {print $4}')
rpo=$(printf '%s\n' "$verify_out" | awk '/^RPO/ {print $5}')
rto=$((t5 - t0))
if [ -n "${rpo:-}" ]; then rpo_cell="${rpo}s"; else rpo_cell="?"; fi

printf '\ndrill-log row:\n'
printf '| %s | %s | %s | %s | %s | %s | %ss | %ss | %ss | %s | %s | %s |\n' \
  "$(iso "$t0")" "${LABEL:-}" "$VMID" "${restore_point:-?}" \
  "$s1" "$s2" "$((t3 - t0))" "$((t4 - t0))" "$rto" "$rpo_cell" \
  "$([ "$rc" -eq 0 ] && echo OK || echo FAIL)" ""

printf '{"t0":"%s","label":"%s","vmid":"%s","ip":"%s","restore_point":"%s","t_exists":%s,"t_running":%s,"t_ping":%d,"t_ssh":%d,"rto_s":%d,"rpo_s":"%s","result":"%s","host":"%s"}\n' \
  "$(iso "$t0")" "$LABEL" "$VMID" "$IP" "${restore_point:-}" \
  "$j1" "$j2" "$((t3 - t0))" "$((t4 - t0))" "$rto" "${rpo:-}" \
  "$([ "$rc" -eq 0 ] && echo OK || echo FAIL)" "$(hostname)" >> "$OUT"
exit "$rc"
