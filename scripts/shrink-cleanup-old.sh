#!/usr/bin/env bash
# Terminate retired primary instance and 600 GB root volume after bake period.
# Usage: shrink-cleanup-old.sh [--yes] [--dry-run]
set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-wbat}"
OLD_INSTANCE_ID="${OLD_INSTANCE_ID:-i-0572702f0a58f6dcd}"
OLD_VOLUME_ID="${OLD_VOLUME_ID:-vol-0d5064ffa1256b9fa}"
CUTOVER_DATE="${CUTOVER_DATE:-2026-06-30}"
BAKE_DAYS="${BAKE_DAYS:-7}"
DRY_RUN=false
YES=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --yes) YES=true ;;
    -h|--help)
      echo "Usage: $0 [--dry-run] [--yes]"
      echo "  Retires OLD primary after ${BAKE_DAYS}-day bake from CUTOVER_DATE=${CUTOVER_DATE}"
      exit 0
      ;;
  esac
done

aws_cmd() {
  aws --profile "$AWS_PROFILE" "$@"
}

cutover_epoch=$(date -j -f "%Y-%m-%d" "$CUTOVER_DATE" "+%s" 2>/dev/null || date -d "$CUTOVER_DATE" "+%s")
now_epoch=$(date "+%s")
bake_seconds=$((BAKE_DAYS * 86400))
elapsed=$((now_epoch - cutover_epoch))

if [[ "$elapsed" -lt "$bake_seconds" ]]; then
  remaining=$(( (bake_seconds - elapsed) / 86400 + 1 ))
  echo "ERROR: Bake period not complete. ~${remaining} day(s) remaining (cutover ${CUTOVER_DATE}, bake ${BAKE_DAYS}d)."
  echo "Override only if you accept rollback risk: CUTOVER_DATE=... BAKE_DAYS=0 $0 --yes"
  exit 1
fi

echo "=== OLD instance state ==="
aws_cmd ec2 describe-instances --instance-ids "$OLD_INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{State:State.Name,Name:Tags[?Key==`Name`].Value|[0]}' --output table

echo "=== OLD root volume ==="
aws_cmd ec2 describe-volumes --volume-ids "$OLD_VOLUME_ID" \
  --query 'Volumes[0].{State:State,Size:Size,Attachments:Attachments}' --output json

if [[ "$DRY_RUN" == true ]]; then
  echo "DRY RUN: would snapshot ${OLD_VOLUME_ID}, terminate ${OLD_INSTANCE_ID}, delete volume after snap"
  exit 0
fi

if [[ "$YES" != true ]]; then
  read -r -p "Terminate ${OLD_INSTANCE_ID} and delete ${OLD_VOLUME_ID}? [y/N] " ans
  [[ "$ans" =~ ^[yY] ]] || { echo "Aborted."; exit 1; }
fi

SNAP_NAME="primary-old-retired-${CUTOVER_DATE}"
echo "Creating final snapshot of ${OLD_VOLUME_ID}..."
SNAP_ID=$(aws_cmd ec2 create-snapshot \
  --volume-id "$OLD_VOLUME_ID" \
  --description "OLD primary retired after shrink cutover ${CUTOVER_DATE}" \
  --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=${SNAP_NAME}}]" \
  --query SnapshotId --output text)
echo "Snapshot: ${SNAP_ID} (waiting...)"
aws_cmd ec2 wait snapshot-completed --snapshot-ids "$SNAP_ID"

STATE=$(aws_cmd ec2 describe-instances --instance-ids "$OLD_INSTANCE_ID" --query 'Reservations[0].Instances[0].State.Name' --output text)
if [[ "$STATE" != "terminated" ]]; then
  echo "Disabling API termination on ${OLD_INSTANCE_ID} if set..."
  aws_cmd ec2 modify-instance-attribute --instance-id "$OLD_INSTANCE_ID" --no-disable-api-termination 2>/dev/null || true
  echo "Terminating ${OLD_INSTANCE_ID}..."
  aws_cmd ec2 terminate-instances --instance-ids "$OLD_INSTANCE_ID"
  aws_cmd ec2 wait instance-terminated --instance-ids "$OLD_INSTANCE_ID"
fi

VOL_STATE=$(aws_cmd ec2 describe-volumes --volume-ids "$OLD_VOLUME_ID" --query 'Volumes[0].State' --output text 2>/dev/null || echo "deleted")
if [[ "$VOL_STATE" == "available" ]]; then
  echo "Deleting detached volume ${OLD_VOLUME_ID}..."
  aws_cmd ec2 delete-volume --volume-id "$OLD_VOLUME_ID"
elif [[ "$VOL_STATE" == "in-use" ]]; then
  echo "Waiting for volume detach after terminate..."
  sleep 30
  aws_cmd ec2 delete-volume --volume-id "$OLD_VOLUME_ID" 2>/dev/null || echo "Delete volume manually if still attached"
fi

echo "Cleanup complete. Retained snapshot: ${SNAP_ID}"
