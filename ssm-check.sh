#!/usr/bin/env bash
set -euo pipefail

PROFILE=mrpocket2726
REGION=us-west-2

echo "=== Running EC2 Instances ==="
aws ec2 describe-instances \
  --profile "$PROFILE" --region "$REGION" \
  --filters "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].{ID:InstanceId,Name:Tags[?Key=='Name']|[0].Value,AZ:Placement.AvailabilityZone,Profile:IamInstanceProfile.Arn}" \
  --output table

echo ""
echo "=== SSM Connectivity ==="
aws ssm describe-instance-information \
  --profile "$PROFILE" --region "$REGION" \
  --query "InstanceInformationList[].{ID:InstanceId,Ping:PingStatus,LastPing:LastPingDateTime,Platform:PlatformName}" \
  --output table

echo ""
echo "=== SSM Connection Commands (Private Instances) ==="
aws ec2 describe-instances \
  --profile "$PROFILE" --region "$REGION" \
  --filters "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[?!PublicIpAddress].[InstanceId,Tags[?Key=='Name']|[0].Value]" \
  --output text | while read id name; do
    echo "aws ssm start-session --target $id ($name)"
  done

echo ""
echo "=== Cross-Check ==="
RUNNING=$(aws ec2 describe-instances \
  --profile "$PROFILE" --region "$REGION" \
  --filters "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text | tr '\t' '\n' | sort)

SSM=$(aws ssm describe-instance-information \
  --profile "$PROFILE" --region "$REGION" \
  --query "InstanceInformationList[].InstanceId" \
  --output text | tr '\t' '\n' | sort)

MISSING=$(comm -23 <(echo "$RUNNING") <(echo "$SSM"))

if [ -z "$MISSING" ]; then
  echo "All $(echo "$RUNNING" | wc -l | tr -d ' ') running instances are Online in SSM."
else
  echo "WARNING: The following instances are running but NOT in SSM:"
  echo "$MISSING"
fi
