#!/usr/bin/env bash
set -euo pipefail

# Terraform lock cleanup helper
# - Removes local lock file (.terraform/terraform.tfstate.lock.info)
# - If backend.hcl configures DynamoDB locking, deletes the lock item from the table
#   using the configured key (tries both <key> and <bucket>/<key> as LockID).
#
# Usage:
#   scripts/unlock-tf.sh [-y]
#
# Options:
#   -y    Non-interactive (assume yes)

YES="false"
while getopts ":yh" opt; do
  case $opt in
    y) YES="true" ;;
    h)
      echo "Usage: $0 [-y]";
      exit 0
      ;;
    *) echo "Unknown option: -$OPTARG" >&2; exit 1 ;;
  esac
done

confirm() {
  if [[ "$YES" == "true" ]]; then
    return 0
  fi
  read -r -p "Proceed with unlocking? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

read_hcl_value() {
  local key="$1" file="${2:-backend.hcl}"
  awk -v k="$key" '
    $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
      line = $0
      sub(/^[^=]*=[[:space:]]*/, "", line)
      sub(/(#|\/\/).*/, "", line)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (line ~ /^".*"$/) { sub(/^"/, "", line); sub(/"$/, "", line) }
      print line
      exit
    }
  ' "$file" | head -n1
}

ensure_aws_cli() {
  if ! command -v aws >/dev/null 2>&1; then
    echo "Error: AWS CLI not found. Install it and retry." >&2
    exit 1
  fi
}

echo "==> Terraform unlock helper"

# Always try to remove local lock file if present
if [[ -f .terraform/terraform.tfstate.lock.info ]]; then
  echo "Found local lock file: .terraform/terraform.tfstate.lock.info"
  if confirm; then
    rm -f .terraform/terraform.tfstate.lock.info
    echo "Removed local lock file."
  else
    echo "Skipped removing local lock file."
  fi
else
  echo "No local lock file present."
fi

# Handle DynamoDB lock when backend.hcl exists and defines a table
if [[ -f backend.hcl ]]; then
  echo "backend.hcl detected; checking DynamoDB lock configuration..."
  bucket=$(read_hcl_value bucket backend.hcl || true)
  key=$(read_hcl_value key backend.hcl || true)
  region=$(read_hcl_value region backend.hcl || true)
  table=$(read_hcl_value dynamodb_table backend.hcl || true)
  profile=$(read_hcl_value profile backend.hcl || true)

  if [[ -n "$table" && -n "$key" ]]; then
    ensure_aws_cli
    profile_opt=""; [[ -n "$profile" ]] && profile_opt="--profile $profile"

    echo "Looking for lock items in DynamoDB table: $table (region: ${region:-auto})"
    # Try two common LockID formats
    candidates=("$key" "${bucket}/${key}")

    for lock_id in "${candidates[@]}"; do
      echo "Checking LockID: $lock_id"
      if aws $profile_opt dynamodb get-item \
           --table-name "$table" \
           --key "{\"LockID\":{\"S\":\"$lock_id\"}}" \
           ${region:+--region "$region"} \
           --output text >/dev/null 2>&1; then
        echo "Found lock item with LockID=$lock_id"
        if confirm; then
          aws $profile_opt dynamodb delete-item \
            --table-name "$table" \
            --key "{\"LockID\":{\"S\":\"$lock_id\"}}" \
            ${region:+--region "$region"}
          echo "Deleted DynamoDB lock item: $lock_id"
        else
          echo "Skipped deleting DynamoDB lock: $lock_id"
        fi
      else
        echo "No item with LockID=$lock_id"
      fi
    done
  else
    echo "DynamoDB locking not configured (table or key missing in backend.hcl)."
  fi
else
  echo "backend.hcl not found; assuming local backend."
fi

echo "Done."

