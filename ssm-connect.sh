#!/usr/bin/env bash
set -euo pipefail

PROFILE="${AWS_PROFILE:-mrpocket2726}"
REGION="${AWS_REGION:-us-west-2}"

print_instances() {
  local label="$1"
  local tag_filter="$2"

  mapfile -t instances < <(
    aws ec2 describe-instances \
      --profile "$PROFILE" \
      --region "$REGION" \
      --filters \
        "Name=tag:Name,Values=${tag_filter}" \
        "Name=instance-state-name,Values=running" \
      --query "Reservations[].Instances[].[InstanceId, Tags[?Key=='Name'].Value|[0], Placement.AvailabilityZone]" \
      --output text
  )

  if [[ ${#instances[@]} -eq 0 ]]; then
    echo "  (none running)"
    return
  fi

  for row in "${instances[@]}"; do
    read -r instance_id name az <<< "$row"
    printf "  %-20s  %-10s  %s\n" "$instance_id" "$name" "$az"
    printf "  aws ssm start-session --target %s\n\n" "$instance_id"
  done
}

echo "=== NAT Instances ==="
echo ""
print_instances "NAT" "NAT-*"

echo "=== Private Instances ==="
echo ""
print_instances "Private" "Private-*"

# echo "=== App Instances (legacy tag) ==="
# echo ""
# print_instances "App" "App-*"
