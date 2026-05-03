#!/usr/bin/env bash
set -euo pipefail

PROFILE=mrpocket2726
REGION=us-west-2
CLOUDTRAIL_LOG_GROUP=/aws/cloudtrail/main
REPORT=docs/resilience-testing.md
DB_INSTANCE_ID=main-postgres
PROBE_INTERVAL=0.5
PROBE_LEAD_SECONDS=5
RECOVERY_TIMEOUT=300
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    -h|--help)
      cat <<'USAGE'
Usage: ./rds-sim.sh [options]

Triggers an RDS Multi-AZ forced failover, measures the writer-unavailability
window from a private EC2 instance, and appends a report to docs/resilience-testing.md.

Options:
  --dry-run    Resolve config + target instance only; do not failover.
  -h, --help   Show this help.
USAGE
      exit 0
      ;;
    *) echo "ERROR: Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

CYAN='\033[0;36m' GREEN='\033[0;32m' YELLOW='\033[1;33m' NC='\033[0m'
TFMT='+%-I:%M:%S %p'
log()  { echo -e "${CYAN}[$(date "$TFMT")]${NC} $*"; }
ok()   { echo -e "${GREEN}[$(date "$TFMT")] ✓${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date "$TFMT")] !${NC} $*"; }
err()  { echo "ERROR: $*" >&2; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "Missing required command: $1"; exit 1; }
}

require_cmd aws
require_cmd jq
require_cmd terraform

# ── Resolve DB connection info ────────────────────────────────────────────────

log "Resolving DB connection info from terraform outputs..."
TF_JSON=$(terraform output -json)
DB_HOST=$(jq -r '.db_host.value' <<<"$TF_JSON")
DB_PORT=$(jq -r '.db_port.value' <<<"$TF_JSON")
DB_NAME=$(jq -r '.db_name.value' <<<"$TF_JSON")
DB_USERNAME="appuser"

if [[ -z "$DB_HOST" || "$DB_HOST" == "null" ]]; then
  err "Could not resolve db_host from terraform outputs."
  exit 1
fi

if [[ ! -f terraform.tfvars ]]; then
  err "terraform.tfvars not found — needed for db_password."
  exit 1
fi
DB_PASSWORD_LINE=$(grep -Em1 '^[[:space:]]*db_password[[:space:]]*=' terraform.tfvars || true)
if [[ -z "$DB_PASSWORD_LINE" ]]; then
  err "db_password was not found in terraform.tfvars."
  exit 1
fi
if [[ "$DB_PASSWORD_LINE" =~ ^[[:space:]]*db_password[[:space:]]*=[[:space:]]*\"([^\"]*)\"[[:space:]]*(#.*)?$ ]]; then
  DB_PASSWORD="${BASH_REMATCH[1]}"
else
  err "Could not parse db_password from terraform.tfvars (expected quoted string on one line)."
  exit 1
fi
DB_PASSWORD_SHELL=$(printf '%q' "$DB_PASSWORD")

log "DB endpoint: $DB_HOST:$DB_PORT/$DB_NAME"

# ── Pre-failover state ────────────────────────────────────────────────────────

PRE_AZ=$(aws rds describe-db-instances \
  --profile "$PROFILE" --region "$REGION" \
  --db-instance-identifier "$DB_INSTANCE_ID" \
  --query "DBInstances[0].AvailabilityZone" --output text)
PRE_STATUS=$(aws rds describe-db-instances \
  --profile "$PROFILE" --region "$REGION" \
  --db-instance-identifier "$DB_INSTANCE_ID" \
  --query "DBInstances[0].DBInstanceStatus" --output text)
log "Pre-failover: AZ=$PRE_AZ, status=$PRE_STATUS"

if [[ "$PRE_STATUS" != "available" ]]; then
  err "RDS not in 'available' state (got '$PRE_STATUS'). Aborting."
  exit 1
fi

# ── Target private instance ───────────────────────────────────────────────────

log "Selecting an Online private instance..."
PRIVATE_ID=$(aws ec2 describe-instances \
  --profile "$PROFILE" --region "$REGION" \
  --filters "Name=instance-state-name,Values=running" "Name=tag:Name,Values=Private-*" \
  --query "Reservations[].Instances[?!PublicIpAddress] | [0][0].InstanceId" \
  --output text)

if [[ -z "$PRIVATE_ID" || "$PRIVATE_ID" == "None" ]]; then
  err "No running private instance found."
  exit 1
fi

PING=$(aws ssm describe-instance-information \
  --profile "$PROFILE" --region "$REGION" \
  --filters "Key=InstanceIds,Values=$PRIVATE_ID" \
  --query "InstanceInformationList[0].PingStatus" --output text)
if [[ "$PING" != "Online" ]]; then
  err "Private instance $PRIVATE_ID not Online in SSM (status=$PING)."
  exit 1
fi
log "Probe host: $PRIVATE_ID (Online)"

if $DRY_RUN; then
  warn "DRY RUN — would trigger failover. Stopping here."
  exit 0
fi

# ── Helpers ───────────────────────────────────────────────────────────────────

PROBE_LOG=/tmp/rds-probe.log
PROBE_PID_FILE=/tmp/rds-probe.pid
PROBE_SCRIPT=/tmp/rds-probe.sh

ssm_run() {
  local cmd_text=$1
  local params
  params=$(jq -n --arg c "$cmd_text" '{commands: [$c]}')
  local cmd_id
  cmd_id=$(aws ssm send-command \
    --profile "$PROFILE" --region "$REGION" \
    --instance-ids "$PRIVATE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "$params" \
    --query "Command.CommandId" --output text)
  echo "$cmd_id"
}

ssm_wait() {
  local cmd_id=$1
  local elapsed=0
  while true; do
    local status
    status=$(aws ssm get-command-invocation \
      --profile "$PROFILE" --region "$REGION" \
      --command-id "$cmd_id" --instance-id "$PRIVATE_ID" \
      --query "Status" --output text 2>/dev/null || echo "Pending")
    case "$status" in
      Success|Failed|Cancelled|TimedOut) echo "$status"; return 0 ;;
    esac
    if (( elapsed > 180 )); then echo "Timeout"; return 1; fi
    sleep 2
    elapsed=$(( elapsed + 2 ))
  done
}

ssm_output() {
  local cmd_id=$1
  aws ssm get-command-invocation \
    --profile "$PROFILE" --region "$REGION" \
    --command-id "$cmd_id" --instance-id "$PRIVATE_ID" \
    --query "StandardOutputContent" --output text
}

# ── Install psql + start probe ────────────────────────────────────────────────

log "Installing psql + writing probe..."
SETUP=$(cat <<OUTER_EOF
set -e
if ! command -v psql >/dev/null 2>&1; then
  sudo apt-get update >/dev/null
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql-client >/dev/null
fi
cat >${PROBE_SCRIPT} <<'INNER_EOF'
#!/bin/bash
DB_HOST="${DB_HOST}"
DB_PORT="${DB_PORT}"
DB_USER="${DB_USERNAME}"
DB_NAME="${DB_NAME}"
DB_PASS=${DB_PASSWORD_SHELL}
LOG="${PROBE_LOG}"
export PGCONNECT_TIMEOUT=2
while true; do
  ts=\$(date -u +%s.%N)
  if PGPASSWORD="\$DB_PASS" psql -h "\$DB_HOST" -p "\$DB_PORT" -U "\$DB_USER" -d "\$DB_NAME" \\
       -c "SELECT 1" -tA >/dev/null 2>&1; then
    echo "\$ts OK" >> "\$LOG"
  else
    echo "\$ts FAIL" >> "\$LOG"
  fi
  sleep ${PROBE_INTERVAL}
done
INNER_EOF
chmod +x ${PROBE_SCRIPT}
: > ${PROBE_LOG}
nohup ${PROBE_SCRIPT} >/dev/null 2>&1 &
echo \$! > ${PROBE_PID_FILE}
echo "probe started, pid=\$(cat ${PROBE_PID_FILE})"
OUTER_EOF
)

CMD_ID=$(ssm_run "$SETUP")
STATUS=$(ssm_wait "$CMD_ID")
if [[ "$STATUS" != "Success" ]]; then
  err "Probe setup failed (status=$STATUS)."
  ssm_output "$CMD_ID" >&2 || true
  exit 1
fi
log "$(ssm_output "$CMD_ID")"

log "Letting probe baseline for ${PROBE_LEAD_SECONDS}s..."
sleep "$PROBE_LEAD_SECONDS"

# ── Trigger failover ──────────────────────────────────────────────────────────

T_START=$(date +%s)
T_START_ISO=$(date -u -d "@$T_START" '+%Y-%m-%dT%H:%M:%SZ')
T_START_MS=$(( T_START * 1000 ))
log "Triggering forced failover..."
aws rds reboot-db-instance \
  --profile "$PROFILE" --region "$REGION" \
  --db-instance-identifier "$DB_INSTANCE_ID" \
  --force-failover >/dev/null

# ── Poll for recovery ─────────────────────────────────────────────────────────

log "Polling for status=available (timeout ${RECOVERY_TIMEOUT}s)..."
elapsed=0
POST_STATUS=""
RECOVERY_TIMED_OUT=false
while true; do
  POST_STATUS=$(aws rds describe-db-instances \
    --profile "$PROFILE" --region "$REGION" \
    --db-instance-identifier "$DB_INSTANCE_ID" \
    --query "DBInstances[0].DBInstanceStatus" --output text 2>/dev/null || echo "unknown")
  log "  status=$POST_STATUS (${elapsed}s elapsed)"
  if [[ "$POST_STATUS" == "available" ]]; then
    break
  fi
  if (( elapsed >= RECOVERY_TIMEOUT )); then
    warn "Recovery timeout reached."
    RECOVERY_TIMED_OUT=true
    break
  fi
  sleep 5
  elapsed=$(( elapsed + 5 ))
done
T_END=$(date +%s)
WALL=$(( T_END - T_START ))
if $RECOVERY_TIMED_OUT; then
  WALL_DISPLAY="timeout (${WALL}s)"
  warn "Did not observe status=available before timeout; collecting evidence anyway."
else
  WALL_DISPLAY="${WALL}s"
fi

log "Letting probe run +30s to capture writer-back signal..."
sleep 30
T_EVENTS_END=$(date +%s)
T_EVENTS_END_ISO=$(date -u -d "@$T_EVENTS_END" '+%Y-%m-%dT%H:%M:%SZ')
T_END_MS=$(( T_EVENTS_END * 1000 ))

# describe-db-instances.AvailabilityZone lags by minutes after failover; use
# describe-events as the authoritative record of failover start/restart/complete.
EVENTS_JSON=$(aws rds describe-events \
  --profile "$PROFILE" --region "$REGION" \
  --source-identifier "$DB_INSTANCE_ID" --source-type db-instance \
  --start-time "$T_START_ISO" \
  --end-time "$T_EVENTS_END_ISO" \
  --query "Events[].{t:Date,m:Message}" --output json 2>/dev/null || echo "[]")
EVENTS_TIMELINE=$(jq -r 'sort_by(.t) | .[] | "  \(.t) \(.m)"' <<<"$EVENTS_JSON" 2>/dev/null || echo "")
FAILOVER_COMPLETED=$(jq -r '[.[] | select((.m | ascii_downcase) | contains("failover completed"))] | length' <<<"$EVENTS_JSON" 2>/dev/null || echo 0)
log "Failover completed events in this run window: $FAILOVER_COMPLETED"

# ── Stop probe and pull log ───────────────────────────────────────────────────

log "Stopping probe and fetching log..."
STOP=$(cat <<OUTER_EOF
if [ -f ${PROBE_PID_FILE} ]; then
  kill \$(cat ${PROBE_PID_FILE}) 2>/dev/null || true
  rm -f ${PROBE_PID_FILE}
fi
sleep 1
cat ${PROBE_LOG}
OUTER_EOF
)
CMD_ID=$(ssm_run "$STOP")
STATUS=$(ssm_wait "$CMD_ID")
if [[ "$STATUS" != "Success" ]]; then
  err "Probe stop/fetch failed (status=$STATUS)."
  ssm_output "$CMD_ID" >&2 || true
  exit 1
fi
PROBE_OUT=$(ssm_output "$CMD_ID")
if ! grep -Eq '^[0-9]+\.[0-9]+ (OK|FAIL)$' <<<"$PROBE_OUT"; then
  err "Probe output was empty or malformed; cannot compute writer-unavailability."
  exit 1
fi

# ── Compute longest FAIL streak ───────────────────────────────────────────────

DISCONNECT=$(awk -v interval="${PROBE_INTERVAL}" '
  $2 == "FAIL" {
    if (start == "") start = $1
    last = $1
    next
  }
  $2 == "OK" {
    if (start != "") {
      diff = (last - start) + interval
      if (diff > max) max = diff
      start = ""
    }
  }
  END {
    if (start != "") {
      diff = (last - start) + interval
      if (diff > max) max = diff
    }
    if (max == "") max = 0
    printf "%.1f", max
  }
' <<<"$PROBE_OUT")

TOTAL_PROBE_LINES=$(printf '%s\n' "$PROBE_OUT" | grep -c "^[0-9]" || true)
FAIL_LINES=$(printf '%s\n' "$PROBE_OUT" | grep -c " FAIL$" || true)

# ── CloudTrail evidence ───────────────────────────────────────────────────────

log "Fetching CloudTrail RebootDBInstance events..."
CT_RAW=$(aws logs filter-log-events \
  --profile "$PROFILE" --region "$REGION" \
  --log-group-name "$CLOUDTRAIL_LOG_GROUP" \
  --start-time "$T_START_MS" --end-time "$T_END_MS" \
  --filter-pattern '{ $.eventName = "RebootDBInstance" }' \
  --query "events[].message" --output json 2>/dev/null || echo "[]")
CT_NORMALIZED=$(jq '[ .[] | (try fromjson catch empty) ]' <<<"$CT_RAW" 2>/dev/null || echo "[]")
CT_COUNT=$(jq 'length' <<<"$CT_NORMALIZED" 2>/dev/null || echo 0)
CT_TIMELINE=$(jq -r '
  sort_by(.eventTime)
  | .[]
  | "  \(.eventTime) \(.eventName) (forceFailover=\(.requestParameters.forceFailover // false))"
' <<<"$CT_NORMALIZED" 2>/dev/null || true)

# ── Append report ─────────────────────────────────────────────────────────────

RUN_DATE=$(date -u '+%Y-%m-%d')
RUN_TS=$(date -u '+%Y-%m-%d %-I:%M:%S %p UTC')

log "Appending report to $REPORT..."
mkdir -p "$(dirname "$REPORT")"
{
  echo ""
  echo "## RDS Failover Test: $RUN_DATE"
  echo ""
  echo "Run timestamp: $RUN_TS  "
  echo "Script: \`rds-sim.sh\`  "
  echo "DB instance: \`$DB_INSTANCE_ID\`  "
  echo "Probe host: \`$PRIVATE_ID\`  "
  echo ""
  echo "| Metric | Value |"
  echo "|---|---|"
  echo "| psql writer-unavailability window | ${DISCONNECT}s |"
  echo "| Status return-to-available | ${WALL_DISPLAY} |"
  echo "| Pre-failover primary AZ | $PRE_AZ |"
  echo "| Multi-AZ failover completed events | $FAILOVER_COMPLETED |"
  echo "| Probe samples (total / failed) | $TOTAL_PROBE_LINES / $FAIL_LINES |"
  echo "| CloudTrail RebootDBInstance events | $CT_COUNT |"
  echo ""
  echo "**RDS event timeline:**"
  echo '```'
  echo "${EVENTS_TIMELINE:-(no events)}"
  echo '```'
  echo ""
  if [[ -n "$CT_TIMELINE" ]]; then
    echo "**CloudTrail timeline:**"
    echo '```'
    echo "$CT_TIMELINE"
    echo '```'
    echo ""
  fi
  echo "> Note: \`DBInstances[0].AvailabilityZone\` lags by 3–6 minutes after a"
  echo "> Multi-AZ failover, so \"before/after\" AZ readings from describe-db-instances"
  echo "> are unreliable in real time. The RDS event log above is authoritative."
  echo ""
} >> "$REPORT"

ok "Done."
echo ""
echo "Writer-unavailability window: ${DISCONNECT}s"
echo "Status return-to-available:   ${WALL_DISPLAY}"
echo "Pre-failover AZ:              $PRE_AZ"
echo "Failover completed events:    $FAILOVER_COMPLETED"
echo "Report appended to $REPORT"
