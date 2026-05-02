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
FULL_LOGS=false
FAIL_FAST=false

for arg in "$@"; do
  case "$arg" in
    --dry-run)       DRY_RUN=true ;;
    --max-combo=*)   MAX_COMBO="${arg#*=}" ;;
    --full-logs)     FULL_LOGS=true ;;
    --fail-fast)     FAIL_FAST=true ;;
    -h|--help)
      cat <<'USAGE'
Usage: ./failure-sim.sh [options]

Options:
  --dry-run         Discover scenarios only; do not terminate instances.
  --max-combo=N     Run combinations 1..N (N must be 1..15).
  --full-logs       Include full Lambda/CloudTrail excerpts in the report.
  --fail-fast       Stop at the first failed combo.
  -h, --help        Show this help text.
USAGE
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

CYAN='\033[0;36m' GREEN='\033[0;32m' YELLOW='\033[1;33m' NC='\033[0m'
log()  { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()   { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✓${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] !${NC} $*"; }
err()  { echo "ERROR: $*" >&2; }

require_cmd() {
  local cmd=$1
  command -v "$cmd" >/dev/null 2>&1 || { err "Missing required command: $cmd"; exit 1; }
}

is_int() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

join_csv() {
  local IFS=,
  echo "$*"
}

if ! is_int "$MAX_COMBO" || (( MAX_COMBO < 1 || MAX_COMBO > 15 )); then
  err "--max-combo must be an integer between 1 and 15 (got: $MAX_COMBO)"
  exit 2
fi

require_cmd aws
require_cmd jq

declare -a NAT_ASGS=()
declare -a PRIVATE_ASGS=()
declare -A NAT_ASG_SET=()
declare -A PRIVATE_ASG_SET=()
TOPOLOGY_MODE="fallback-tags"

declare -a MAP_IDS=()
declare -a MAP_NAMES=()
declare -a MAP_AZS=()
MAP_COMPLETE=false
LAST_NAT_COUNT=0
LAST_PRIVATE_COUNT=0

# Populates NAT_ASGS / PRIVATE_ASGS from Terraform outputs if available.
resolve_topology() {
  local tf_json
  if ! command -v terraform >/dev/null 2>&1; then
    warn "Terraform CLI not found; using fallback discovery by Name tags."
    TOPOLOGY_MODE="fallback-tags"
    return 0
  fi

  if ! tf_json=$(terraform output -json 2>/dev/null); then
    warn "Terraform outputs unavailable; using fallback discovery by Name tags."
    TOPOLOGY_MODE="fallback-tags"
    return 0
  fi

  mapfile -t NAT_ASGS < <(jq -r '.nat_asg_names.value[]? // empty' <<<"$tf_json" | sort)
  mapfile -t PRIVATE_ASGS < <(jq -r '.private_asg_names.value[]? // empty' <<<"$tf_json" | sort)

  if (( ${#NAT_ASGS[@]} != 2 || ${#PRIVATE_ASGS[@]} != 2 )); then
    warn "Terraform output did not provide 2 NAT + 2 private ASGs; using fallback Name-tag discovery."
    TOPOLOGY_MODE="fallback-tags"
    return 0
  fi

  local asg
  NAT_ASG_SET=()
  PRIVATE_ASG_SET=()
  for asg in "${NAT_ASGS[@]}"; do NAT_ASG_SET["$asg"]=1; done
  for asg in "${PRIVATE_ASGS[@]}"; do PRIVATE_ASG_SET["$asg"]=1; done

  TOPOLOGY_MODE="terraform-asg"
  log "Topology source: Terraform outputs (ASG scoped)."
}

# Emits scoped inventory in TSV:
#   id name az asg launchTime
fetch_inventory_tsv() {
  local -a filters=("Name=instance-state-name,Values=running")
  if [[ "$TOPOLOGY_MODE" == "terraform-asg" ]]; then
    local asg_csv
    asg_csv=$(join_csv "${NAT_ASGS[@]}" "${PRIVATE_ASGS[@]}")
    filters+=("Name=tag:aws:autoscaling:groupName,Values=$asg_csv")
  fi

  aws ec2 describe-instances \
    --profile "$PROFILE" --region "$REGION" \
    --filters "${filters[@]}" \
    --query "Reservations[].Instances[].{id:InstanceId,name:Tags[?Key=='Name']|[0].Value,az:Placement.AvailabilityZone,asg:Tags[?Key=='aws:autoscaling:groupName']|[0].Value,launch:LaunchTime}" \
    --output json 2>/dev/null \
    | jq -r '.[] | [.id, (.name // ""), (.az // ""), (.asg // ""), (.launch // "")] | @tsv'
}

classify_instance() {
  local name=$1 asg=$2

  if [[ "$TOPOLOGY_MODE" == "terraform-asg" ]]; then
    if [[ -n "${NAT_ASG_SET[$asg]:-}" ]]; then
      echo "nat"
    elif [[ -n "${PRIVATE_ASG_SET[$asg]:-}" ]]; then
      echo "private"
    else
      echo "ignore"
    fi
    return
  fi

  if [[ "$name" == NAT-* ]]; then
    echo "nat"
  elif [[ "$name" == Private-* ]]; then
    echo "private"
  else
    echo "ignore"
  fi
}

# Builds role map from current inventory, excluding any provided instance IDs.
# On success, sets MAP_COMPLETE=true and MAP_* arrays in this order:
#   0=nat-az-a  1=nat-az-b  2=priv-az-a  3=priv-az-b
collect_role_map() {
  local -a excluded_ids=("$@")
  local tsv

  if ! tsv=$(fetch_inventory_tsv); then
    return 1
  fi

  local -A excluded=()
  local id
  for id in "${excluded_ids[@]}"; do
    excluded["$id"]=1
  done

  local -A nat_id=() nat_name=() nat_ts=()
  local -A private_id=() private_name=() private_ts=()

  local name az asg launch class
  while IFS=$'\t' read -r id name az asg launch; do
    [[ -z "$id" || -z "$az" ]] && continue
    [[ -n "${excluded[$id]:-}" ]] && continue

    class=$(classify_instance "$name" "$asg")
    [[ "$class" == "ignore" ]] && continue

    [[ -z "$name" ]] && name="$id"
    [[ -z "$launch" ]] && launch="0000-00-00T00:00:00+00:00"

    if [[ "$class" == "nat" ]]; then
      if [[ -z "${nat_ts[$az]:-}" || "$launch" > "${nat_ts[$az]}" ]]; then
        nat_id["$az"]="$id"
        nat_name["$az"]="$name"
        nat_ts["$az"]="$launch"
      fi
    else
      if [[ -z "${private_ts[$az]:-}" || "$launch" > "${private_ts[$az]}" ]]; then
        private_id["$az"]="$id"
        private_name["$az"]="$name"
        private_ts["$az"]="$launch"
      fi
    fi
  done <<<"$tsv"

  LAST_NAT_COUNT=${#nat_id[@]}
  LAST_PRIVATE_COUNT=${#private_id[@]}

  mapfile -t MAP_AZS < <(printf '%s\n' "${!nat_id[@]}" | sort)

  MAP_IDS=()
  MAP_NAMES=()
  MAP_COMPLETE=false

  if (( ${#nat_id[@]} != 2 || ${#private_id[@]} != 2 || ${#MAP_AZS[@]} != 2 )); then
    return 0
  fi

  local az_a az_b
  az_a="${MAP_AZS[0]}"
  az_b="${MAP_AZS[1]}"

  if [[ -z "${private_id[$az_a]:-}" || -z "${private_id[$az_b]:-}" ]]; then
    return 0
  fi

  MAP_IDS=(
    "${nat_id[$az_a]}" "${nat_id[$az_b]}"
    "${private_id[$az_a]}" "${private_id[$az_b]}"
  )
  MAP_NAMES=(
    "${nat_name[$az_a]}" "${nat_name[$az_b]}"
    "${private_name[$az_a]}" "${private_name[$az_b]}"
  )
  MAP_COMPLETE=true

  return 0
}

# Polls SSM until the scoped 4-instance role map is present and all are Online.
wait_for_recovery() {
  local -a terminated=("$@")
  local elapsed=0

  log "Polling SSM for full recovery (timeout: ${RECOVERY_TIMEOUT}s)..."

  while true; do
    if ! collect_role_map "${terminated[@]}"; then
      warn "Instance discovery failed during recovery poll."
      return 1
    fi

    local online_count=0
    if $MAP_COMPLETE; then
      local ids_csv
      ids_csv=$(join_csv "${MAP_IDS[@]}")
      online_count=$(aws ssm describe-instance-information \
        --profile "$PROFILE" --region "$REGION" \
        --filters "Key=InstanceIds,Values=$ids_csv" "Key=PingStatus,Values=Online" \
        --query "length(InstanceInformationList)" \
        --output text 2>/dev/null || echo 0)
      [[ "$online_count" == "None" || -z "$online_count" ]] && online_count=0
    fi

    log "  Scoped roles: NAT ${LAST_NAT_COUNT}/2, Private ${LAST_PRIVATE_COUNT}/2, SSM Online ${online_count}/4"

    if $MAP_COMPLETE && [[ "$online_count" -eq 4 ]]; then
      return 0
    fi

    if [[ "$elapsed" -ge "$RECOVERY_TIMEOUT" ]]; then
      warn "Recovery timeout after ${RECOVERY_TIMEOUT}s"
      return 1
    fi

    sleep "$POLL_INTERVAL"
    elapsed=$(( elapsed + POLL_INTERVAL ))
  done
}

fetch_lambda_logs_full() {
  local start_ms=$1 end_ms=$2
  aws logs filter-log-events \
    --profile "$PROFILE" --region "$REGION" \
    --log-group-name "$LAMBDA_LOG_GROUP" \
    --start-time "$start_ms" --end-time "$end_ms" \
    --query "events[].message" \
    --output text 2>/dev/null || echo "(no Lambda log events in window)"
}

fetch_cloudtrail_logs_full() {
  local start_ms=$1 end_ms=$2
  local raw_json
  raw_json=$(aws logs filter-log-events \
    --profile "$PROFILE" --region "$REGION" \
    --log-group-name "$CLOUDTRAIL_LOG_GROUP" \
    --start-time "$start_ms" --end-time "$end_ms" \
    --filter-pattern '{ ($.eventName = "TerminateInstances") || ($.eventName = "RunInstances") || ($.eventName = "ReplaceRoute") }' \
    --query "events[].message" \
    --output json 2>/dev/null || echo "[]")

  if [[ "$(jq 'length' <<<"$raw_json" 2>/dev/null || echo 0)" -eq 0 ]]; then
    echo "(no TerminateInstances/RunInstances/ReplaceRoute events in window)"
    return
  fi

  jq -r '
    .[]
    | (try fromjson catch .)
    | if type == "object" then
        "  \(.eventTime // "unknown-time") \(.eventName // "unknown-event")"
      else
        "  \(.)"
      end
  ' <<<"$raw_json" 2>/dev/null || echo "(unable to parse CloudTrail messages)"
}

fetch_lambda_logs_summary() {
  local start_ms=$1 end_ms=$2
  local raw_json count

  raw_json=$(aws logs filter-log-events \
    --profile "$PROFILE" --region "$REGION" \
    --log-group-name "$LAMBDA_LOG_GROUP" \
    --start-time "$start_ms" --end-time "$end_ms" \
    --query "events[].{ts:timestamp,msg:message}" \
    --output json 2>/dev/null || echo "[]")

  count=$(jq 'length' <<<"$raw_json" 2>/dev/null || echo 0)
  if [[ "$count" -eq 0 ]]; then
    echo "(no Lambda log events in window)"
    return
  fi

  echo "count: $count"
  echo "sample:"
  jq -r '
    .[:5][]
    | "  " + ((.msg // "") | gsub("[\r\n\t]+"; " ") | .[0:220])
  ' <<<"$raw_json" 2>/dev/null || true
}

fetch_cloudtrail_logs_summary() {
  local start_ms=$1 end_ms=$2
  local raw_json normalized count

  raw_json=$(aws logs filter-log-events \
    --profile "$PROFILE" --region "$REGION" \
    --log-group-name "$CLOUDTRAIL_LOG_GROUP" \
    --start-time "$start_ms" --end-time "$end_ms" \
    --filter-pattern '{ ($.eventName = "TerminateInstances") || ($.eventName = "RunInstances") || ($.eventName = "ReplaceRoute") }' \
    --query "events[].message" \
    --output json 2>/dev/null || echo "[]")

  normalized=$(jq '[ .[] | (try fromjson catch empty) ]' <<<"$raw_json" 2>/dev/null || echo "[]")
  count=$(jq 'length' <<<"$normalized" 2>/dev/null || echo 0)
  if [[ "$count" -eq 0 ]]; then
    echo "(no TerminateInstances/RunInstances/ReplaceRoute events in window)"
    return
  fi

  echo "count: $count"
  echo "by event:"
  jq -r '
    sort_by(.eventName)
    | group_by(.eventName)
    | .[]
    | "  \(.[0].eventName): \(length)"
  ' <<<"$normalized" 2>/dev/null || true

  echo "timeline sample:"
  jq -r '
    sort_by(.eventTime)
    | .[:8][]
    | "  \(.eventTime // "unknown-time") \(.eventName // "unknown-event")"
  ' <<<"$normalized" 2>/dev/null || true
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

resolve_topology

echo ""
echo "=== Failure Simulation: All 15 Combinations ==="
echo "    Date   : $RUN_DATE"
echo "    Dry run: $DRY_RUN"
echo "    Combos : 1–$MAX_COMBO"
echo "    Logs   : $([[ "$FULL_LOGS" == true ]] && echo full || echo summary)"
echo "    Fail   : $([[ "$FAIL_FAST" == true ]] && echo fail-fast || echo continue-on-error)"
echo ""

declare -A RESULTS   # combo → "Xs" or "TIMEOUT (Xs)"
declare -A LABELS    # combo → human label
ANY_FAILURE=false

EXCERPTS_FILE=$(mktemp)
trap 'rm -f "$EXCERPTS_FILE"' EXIT

for ((combo=1; combo<=MAX_COMBO; combo++)); do
  log "━━━ Combo $combo/$MAX_COMBO ━━━"

  if ! collect_role_map; then
    err "Failed to discover scoped instances."
    RESULTS[$combo]="ERROR (discovery)"
    ANY_FAILURE=true
    $FAIL_FAST && break
    continue
  fi

  if ! $MAP_COMPLETE; then
    err "Expected 2 NAT + 2 private running instances in scoped topology. Found NAT=${LAST_NAT_COUNT}, Private=${LAST_PRIVATE_COUNT}."
    RESULTS[$combo]="ERROR (incomplete topology)"
    ANY_FAILURE=true
    $FAIL_FAST && break
    continue
  fi

  ALL_IDS=("${MAP_IDS[@]}")
  ALL_NAMES=("${MAP_NAMES[@]}")
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

  if ! aws ec2 terminate-instances \
    --profile "$PROFILE" --region "$REGION" \
    --instance-ids "${TERMINATE_IDS[@]}" \
    --query "TerminatingInstances[].{ID:InstanceId,State:CurrentState.Name}" \
    --output table; then
    warn "Termination request failed."
    RESULTS[$combo]="ERROR (terminate)"
    ANY_FAILURE=true
    $FAIL_FAST && break
    echo ""
    continue
  fi

  if wait_for_recovery "${TERMINATE_IDS[@]}"; then
    T_RECOVERY=$(date +%s)
    ELAPSED=$(( T_RECOVERY - T_START ))
    ok "Recovered in ${ELAPSED}s"
    RESULTS[$combo]="${ELAPSED}s"
  else
    T_RECOVERY=$(date +%s)
    ELAPSED=$(( T_RECOVERY - T_START ))
    RESULTS[$combo]="TIMEOUT (${ELAPSED}s)"
    ANY_FAILURE=true
    if $FAIL_FAST; then
      warn "Fail-fast active; stopping after combo $combo."
    fi
  fi

  T_END_MS=$(( T_RECOVERY * 1000 + 30000 ))

  log "Fetching log excerpts..."
  {
    echo ""
    echo "### Log Excerpts — $LABEL"
    echo ""
    echo "**Lambda (route healer):**"
    echo '```'
    if $FULL_LOGS; then
      fetch_lambda_logs_full "$T_START_MS" "$T_END_MS"
    else
      fetch_lambda_logs_summary "$T_START_MS" "$T_END_MS"
    fi
    echo '```'
    echo ""
    echo "**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**"
    echo '```'
    if $FULL_LOGS; then
      fetch_cloudtrail_logs_full "$T_START_MS" "$T_END_MS"
    else
      fetch_cloudtrail_logs_summary "$T_START_MS" "$T_END_MS"
    fi
    echo '```'
  } >> "$EXCERPTS_FILE"

  echo ""
  if $FAIL_FAST && [[ "${RESULTS[$combo]}" == TIMEOUT* ]]; then
    break
  fi
done

if $DRY_RUN; then
  warn "Dry run complete — nothing written to $REPORT."
  $ANY_FAILURE && exit 1 || exit 0
fi

log "Appending results to $REPORT..."
mkdir -p "$(dirname "$REPORT")"

{
  echo ""
  echo "## Automated Run: $RUN_DATE"
  echo ""
  echo "Run timestamp: $RUN_TS  "
  echo "Script: \`failure-sim.sh\`  "
  echo "Topology source: \`$TOPOLOGY_MODE\`  "
  echo "Log mode: \`$([[ "$FULL_LOGS" == true ]] && echo full || echo summary)\`  "
  echo "Failure policy: \`$([[ "$FAIL_FAST" == true ]] && echo fail-fast || echo continue-on-error)\`  "
  echo ""
  echo "| Combo | Scenario | Recovery Time |"
  echo "|---|---|---|"
  for ((combo=1; combo<=MAX_COMBO; combo++)); do
    echo "| $combo | ${LABELS[$combo]:-—} | ${RESULTS[$combo]:-skipped} |"
  done
  echo ""
  cat "$EXCERPTS_FILE"
} >> "$REPORT"

ok "Done. Results appended to $REPORT."
$ANY_FAILURE && exit 1 || exit 0
