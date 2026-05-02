#!/usr/bin/env bash
set -euo pipefail

PROFILE=mrpocket2726
REGION=us-west-2
LAMBDA_LOG_GROUP=/aws/lambda/main-nat-route-healer
CLOUDTRAIL_LOG_GROUP=/aws/cloudtrail/main
REPORT=docs/resilience-testing.md
POLL_INTERVAL=5
RECOVERY_TIMEOUT=360
DRY_RUN=false
MAX_COMBO=15

for arg in "$@"; do
  case "$arg" in
    --dry-run)       DRY_RUN=true ;;
    --max-combo=*)   MAX_COMBO="${arg#*=}" ;;
  esac
done

CYAN='\033[0;36m' GREEN='\033[0;32m' YELLOW='\033[1;33m' NC='\033[0m'
log()  { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()   { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✓${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] !${NC} $*"; }

# Populates ALL_IDS[0..3] and ALL_NAMES[0..3]:
#   0=nat-az-a  1=nat-az-b  2=priv-az-a  3=priv-az-b
discover_instances() {
  local nat_data priv_data

  nat_data=$(aws ec2 describe-instances \
    --profile "$PROFILE" --region "$REGION" \
    --filters "Name=instance-state-name,Values=running" \
    --query "Reservations[].Instances[?PublicIpAddress].[InstanceId,Tags[?Key=='Name']|[0].Value,Placement.AvailabilityZone]" \
    --output text | sort -k3)

  priv_data=$(aws ec2 describe-instances \
    --profile "$PROFILE" --region "$REGION" \
    --filters "Name=instance-state-name,Values=running" \
    --query "Reservations[].Instances[?!PublicIpAddress].[InstanceId,Tags[?Key=='Name']|[0].Value,Placement.AvailabilityZone]" \
    --output text | sort -k3)

  local nat_count priv_count
  nat_count=$(echo "$nat_data" | grep -c . || true)
  priv_count=$(echo "$priv_data" | grep -c . || true)

  if [[ "$nat_count" -ne 2 || "$priv_count" -ne 2 ]]; then
    echo "ERROR: Expected 2 NAT and 2 private running instances, got $nat_count NAT and $priv_count private." >&2
    exit 1
  fi

  ALL_IDS=()
  ALL_NAMES=()
  while IFS=$'\t' read -r id name _az; do
    ALL_IDS+=("$id")
    ALL_NAMES+=("$name")
  done < <(printf '%s\n%s\n' "$nat_data" "$priv_data")
}

# Polls SSM until 4 Online instances are found, none matching the terminated set.
wait_for_recovery() {
  local -a terminated=("$@")
  local elapsed=0

  log "Polling SSM for full recovery (timeout: ${RECOVERY_TIMEOUT}s)..."

  while true; do
    local online_raw
    online_raw=$(aws ssm describe-instance-information \
      --profile "$PROFILE" --region "$REGION" \
      --filters "Key=PingStatus,Values=Online" \
      --query "InstanceInformationList[].InstanceId" \
      --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' || true)

    local online_count=0
    while IFS= read -r id; do
      [[ -z "$id" ]] && continue
      local skip=false
      for tid in "${terminated[@]}"; do
        [[ "$id" == "$tid" ]] && skip=true && break
      done
      "$skip" || online_count=$(( online_count + 1 ))
    done <<< "$online_raw"

    log "  Online (excl. terminated): $online_count/4"

    if [[ "$online_count" -eq 4 ]]; then
      return 0
    fi

    if [[ "$elapsed" -ge "$RECOVERY_TIMEOUT" ]]; then
      warn "Recovery timeout after ${RECOVERY_TIMEOUT}s ($online_count/4 Online)"
      return 1
    fi

    sleep "$POLL_INTERVAL"
    elapsed=$(( elapsed + POLL_INTERVAL ))
  done
}

fetch_lambda_logs() {
  local start_ms=$1 end_ms=$2
  aws logs filter-log-events \
    --profile "$PROFILE" --region "$REGION" \
    --log-group-name "$LAMBDA_LOG_GROUP" \
    --start-time "$start_ms" --end-time "$end_ms" \
    --query "events[].message" \
    --output text 2>/dev/null || echo "(no Lambda log events in window)"
}

fetch_cloudtrail_logs() {
  local start_ms=$1 end_ms=$2
  local raw
  raw=$(aws logs filter-log-events \
    --profile "$PROFILE" --region "$REGION" \
    --log-group-name "$CLOUDTRAIL_LOG_GROUP" \
    --start-time "$start_ms" --end-time "$end_ms" \
    --filter-pattern '{ ($.eventName = "TerminateInstances") || ($.eventName = "RunInstances") || ($.eventName = "ReplaceRoute") }' \
    --query "events[].message" \
    --output text 2>/dev/null || true)

  if [[ -z "$raw" ]]; then
    echo "(no TerminateInstances/RunInstances/ReplaceRoute events in window)"
    return
  fi

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    echo "$line" | jq -r '"  \(.eventTime) \(.eventName)"' 2>/dev/null || echo "  $line"
  done <<< "$raw"
}

# Returns "Name-a + Name-b" label for the given combo bitmask.
scenario_label() {
  local combo=$1
  local parts=()
  for bit in 0 1 2 3; do
    if (( (combo >> bit) & 1 )); then
      parts+=("${ALL_NAMES[$bit]}")
    fi
  done
  local IFS=' + '; echo "${parts[*]}"
}

# ── Main ──────────────────────────────────────────────────────────────────────

RUN_DATE=$(date -u '+%Y-%m-%d')
RUN_TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

echo ""
echo "=== Failure Simulation: All 15 Combinations ==="
echo "    Date   : $RUN_DATE"
echo "    Dry run: $DRY_RUN"
echo "    Combos : 1–$MAX_COMBO"
echo ""

declare -A RESULTS   # combo → "Xs" or "TIMEOUT (Xs)"
declare -A LABELS    # combo → human label

EXCERPTS_FILE=$(mktemp)
trap 'rm -f "$EXCERPTS_FILE"' EXIT

for combo in $(seq 1 "$MAX_COMBO"); do
  log "━━━ Combo $combo/$MAX_COMBO ━━━"

  discover_instances
  log "Current: ${ALL_NAMES[*]}"

  TERMINATE_IDS=()
  TERMINATE_NAMES=()
  for bit in 0 1 2 3; do
    if (( (combo >> bit) & 1 )); then
      TERMINATE_IDS+=("${ALL_IDS[$bit]}")
      TERMINATE_NAMES+=("${ALL_NAMES[$bit]}")
    fi
  done

  LABEL=$(scenario_label "$combo")
  LABELS[$combo]="$LABEL"
  log "Scenario : $LABEL"
  log "Terminate: ${TERMINATE_IDS[*]}"

  T_START=$(date +%s)
  T_START_MS=$(( T_START * 1000 ))

  if $DRY_RUN; then
    warn "DRY RUN — skipping termination"
    RESULTS[$combo]="dry-run"
    echo ""
    continue
  fi

  aws ec2 terminate-instances \
    --profile "$PROFILE" --region "$REGION" \
    --instance-ids "${TERMINATE_IDS[@]}" \
    --query "TerminatingInstances[].{ID:InstanceId,State:CurrentState.Name}" \
    --output table

  if wait_for_recovery "${TERMINATE_IDS[@]}"; then
    T_RECOVERY=$(date +%s)
    ELAPSED=$(( T_RECOVERY - T_START ))
    ok "Recovered in ${ELAPSED}s"
    RESULTS[$combo]="${ELAPSED}s"
  else
    T_RECOVERY=$(date +%s)
    ELAPSED=$(( T_RECOVERY - T_START ))
    RESULTS[$combo]="TIMEOUT (${ELAPSED}s)"
  fi

  T_END_MS=$(( T_RECOVERY * 1000 + 30000 ))

  log "Fetching log excerpts..."
  {
    echo ""
    echo "### Log Excerpts — $LABEL"
    echo ""
    echo "**Lambda (route healer):**"
    echo '```'
    fetch_lambda_logs "$T_START_MS" "$T_END_MS"
    echo '```'
    echo ""
    echo "**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**"
    echo '```'
    fetch_cloudtrail_logs "$T_START_MS" "$T_END_MS"
    echo '```'
  } >> "$EXCERPTS_FILE"

  echo ""
done

if $DRY_RUN; then
  warn "Dry run complete — nothing written to $REPORT."
  exit 0
fi

log "Appending results to $REPORT..."

{
  echo ""
  echo "## Automated Run: $RUN_DATE"
  echo ""
  echo "Run timestamp: $RUN_TS  "
  echo "Script: \`failure-sim.sh\`  "
  echo ""
  echo "| Combo | Scenario | Recovery Time |"
  echo "|---|---|---|"
  for combo in $(seq 1 "$MAX_COMBO"); do
    echo "| $combo | ${LABELS[$combo]:-—} | ${RESULTS[$combo]:-skipped} |"
  done
  echo ""
  cat "$EXCERPTS_FILE"
} >> "$REPORT"

ok "Done. Results appended to $REPORT."
