#!/usr/bin/env bash
set -euo pipefail

# Small helper to parse values from backend.hcl (format: key = "value")
read_hcl_value() {
  local key="$1"
  local file="${2:-backend.hcl}"
  # Robust parser (BSD/mac-compatible):
  # - matches lines like: key = "value" or key="value" or key = value
  # - strips inline comments (# .. or // ..)
  # - trims whitespace and surrounding quotes
  awk -v k="$key" '
    $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
      line = $0
      sub(/^[^=]*=[[:space:]]*/, "", line)      # drop up to and including =
      sub(/(#|\/\/).*/, "", line)               # strip inline comments
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (line ~ /^".*"$/) { sub(/^"/, "", line); sub(/"$/, "", line) }
      print line
      exit
    }
  ' "$file" | head -n1
}

ensure_aws_cli() {
  if ! command -v aws >/dev/null 2>&1; then
    echo "Error: AWS CLI is not installed. Please install it and try again." >&2
    echo "See: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html" >&2
    exit 1
  fi
}

# Ensure bucket is not publicly accessible (S3 Public Access Block + private ACL)
ensure_bucket_not_public() {
  local bucket="$1" region="$2" profile_opt="$3"
  echo "Enforcing S3 Public Access Block on bucket: $bucket"
  aws $profile_opt s3api put-public-access-block --bucket "$bucket" --region "$region" \
    --public-access-block-configuration '{
      "BlockPublicAcls": true,
      "IgnorePublicAcls": true,
      "BlockPublicPolicy": true,
      "RestrictPublicBuckets": true
    }'

  # Prefer disabling ACLs entirely using Object Ownership = BucketOwnerEnforced
  echo "Enforcing S3 Object Ownership (BucketOwnerEnforced) on bucket: $bucket"
  aws $profile_opt s3api put-bucket-ownership-controls --bucket "$bucket" --region "$region" \
    --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]' >/dev/null 2>&1 || true

  # If ACLs are still enabled on an older bucket, set ACL to private as a best-effort
  if aws $profile_opt s3api get-bucket-ownership-controls --bucket "$bucket" --region "$region" \
       --query 'OwnershipControls.Rules[0].ObjectOwnership' --output text 2>/dev/null | grep -q "BucketOwnerEnforced"; then
    echo "ACLs are disabled (BucketOwnerEnforced); skipping ACL change."
  else
    echo "Setting bucket ACL to private (legacy bucket): $bucket"
    aws $profile_opt s3api put-bucket-acl --bucket "$bucket" --acl private --region "$region" >/dev/null 2>&1 || true
  fi

  echo "Current Public Access Block configuration:"
  aws $profile_opt s3api get-public-access-block --bucket "$bucket" --region "$region" || true
}

create_s3_bucket_if_needed() {
  local bucket="$1" region="$2" profile_opt="$3"

  echo "Checking S3 bucket: $bucket (region: $region)"
  BUCKET_WAS_CREATED=false
  if aws $profile_opt s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
    echo "S3 bucket already exists: $bucket"
  else
    echo "Creating S3 bucket: $bucket (with Object Lock enabled)"
    BUCKET_WAS_CREATED=true
    if [[ "$region" == "us-east-1" ]]; then
      aws $profile_opt s3api create-bucket --bucket "$bucket" --region "$region" \
        --object-lock-enabled-for-bucket
    else
      aws $profile_opt s3api create-bucket --bucket "$bucket" --region "$region" \
        --create-bucket-configuration "LocationConstraint=$region" \
        --object-lock-enabled-for-bucket
    fi
  fi

  echo "Enabling versioning on S3 bucket: $bucket"
  aws $profile_opt s3api put-bucket-versioning --bucket "$bucket" \
    --versioning-configuration Status=Enabled --region "$region"
}

# Apply deletion protection: try Object Lock default retention; otherwise add MFA delete bucket policy for the state key
ensure_bucket_delete_protection() {
  local bucket="$1" region="$2" key="$3" profile_opt="$4" lock_mode="$5" lock_days="$6"

  # Default values if not provided
  lock_mode=${lock_mode:-GOVERNANCE}
  lock_days=${lock_days:-30}

  if [[ "$BUCKET_WAS_CREATED" == true ]]; then
    echo "Setting default Object Lock retention: mode=$lock_mode, days=$lock_days"
    if ! aws $profile_opt s3api put-object-lock-configuration --bucket "$bucket" --region "$region" \
      --object-lock-configuration "ObjectLockEnabled=Enabled,Rule={DefaultRetention={Mode=$lock_mode,Days=$lock_days}}" >/dev/null 2>&1; then
      echo "Warning: failed to set Object Lock configuration (will fall back to bucket policy protection)."
    fi
  else
    # Attempt to enable default retention if bucket already had Object Lock enabled
    echo "Attempting to set Object Lock default retention (if bucket supports it)"
    aws $profile_opt s3api put-object-lock-configuration --bucket "$bucket" --region "$region" \
      --object-lock-configuration "ObjectLockEnabled=Enabled,Rule={DefaultRetention={Mode=$lock_mode,Days=$lock_days}}" >/dev/null 2>&1 || true
  fi

  # Apply a bucket policy that requires MFA for delete operations on the state object(s), only if no policy exists
  if aws $profile_opt s3api get-bucket-policy --bucket "$bucket" --region "$region" >/dev/null 2>&1; then
    echo "Bucket already has a policy; skipping automatic policy update. Consider adding an MFA delete rule for $key."
  else
    echo "Applying MFA delete protection bucket policy for key prefix: $key"
    local key_arn_single="arn:aws:s3:::${bucket}/${key}"
    local key_arn_prefix="arn:aws:s3:::${bucket}/${key%/}*"
    # Build policy JSON and apply
    POLICY_JSON=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyDeleteWithoutMFAForTFState",
      "Effect": "Deny",
      "Principal": "*",
      "Action": [
        "s3:DeleteObject",
        "s3:DeleteObjectVersion"
      ],
      "Resource": [
        "${key_arn_single}",
        "${key_arn_prefix}"
      ],
      "Condition": {
        "Bool": { "aws:MultiFactorAuthPresent": "false" }
      }
    }
  ]
}
EOF
)
    aws $profile_opt s3api put-bucket-policy --bucket "$bucket" --region "$region" --policy "${POLICY_JSON}"
  fi
}

create_dynamodb_table_if_needed() {
  local table="$1" region="$2" profile_opt="$3"
  if [[ -z "$table" ]]; then
    echo "DynamoDB lock table not configured (skipping)."
    return 0
  fi

  echo "Checking DynamoDB table: $table (region: $region)"
  if aws $profile_opt dynamodb describe-table --table-name "$table" --region "$region" >/dev/null 2>&1; then
    echo "DynamoDB table already exists: $table"
  else
    echo "Creating DynamoDB table: $table"
    aws $profile_opt dynamodb create-table \
      --table-name "$table" \
      --attribute-definitions AttributeName=LockID,AttributeType=S \
      --key-schema AttributeName=LockID,KeyType=HASH \
      --billing-mode PAY_PER_REQUEST \
      --region "$region"
    echo "Waiting for table to become ACTIVE: $table"
    aws $profile_opt dynamodb wait table-exists --table-name "$table" --region "$region"
  fi
}

if [[ -f backend.hcl ]]; then
  echo "Loading backend configuration from backend.hcl"

  ensure_aws_cli

  bucket=$(read_hcl_value bucket backend.hcl || true)
  key=$(read_hcl_value key backend.hcl || true)
  region=$(read_hcl_value region backend.hcl || true)
  dynamodb_table=$(read_hcl_value dynamodb_table backend.hcl || true)
  profile=$(read_hcl_value profile backend.hcl || true)
  object_lock_mode=$(read_hcl_value object_lock_mode backend.hcl || true)
  object_lock_retention_days=$(read_hcl_value object_lock_retention_days backend.hcl || true)

  tfvars_project=$(read_hcl_value project terraform.tfvars || true)
  tfvars_environment=$(read_hcl_value environment terraform.tfvars || true)
  tfvars_region=$(read_hcl_value aws_region terraform.tfvars || true)

  if [[ -z "${key}" && -n "${tfvars_project}" && -n "${tfvars_environment}" ]]; then
    key="${tfvars_project}/${tfvars_environment}/terraform.tfstate"
  fi

  if [[ -z "${region}" && -n "${tfvars_region}" ]]; then
    region="${tfvars_region}"
  fi

  if [[ -z "${bucket}" ]]; then
    echo "Error: 'bucket' must be set in backend.hcl." >&2
    exit 1
  fi

  if [[ -z "${key}" ]]; then
    echo "Error: Backend key not provided. Set it in backend.hcl or ensure project and environment are defined in terraform.tfvars." >&2
    exit 1
  fi

  if [[ -z "${region}" ]]; then
    echo "Error: AWS region not provided. Set it in backend.hcl or terraform.tfvars (aws_region)." >&2
    exit 1
  fi

  # AWS CLI options (optional profile)
  profile_opt=""
  if [[ -n "${profile}" ]]; then
    profile_opt="--profile ${profile}"
  fi

  # Ensure S3 bucket exists and has versioning enabled
  create_s3_bucket_if_needed "$bucket" "$region" "$profile_opt"

  # Ensure DynamoDB lock table exists (if configured)
  create_dynamodb_table_if_needed "${dynamodb_table:-}" "$region" "$profile_opt"

  # Ensure deletion protection for Terraform state in S3
  ensure_bucket_delete_protection "$bucket" "$region" "$key" "$profile_opt" "${object_lock_mode:-}" "${object_lock_retention_days:-}"

  # Ensure the bucket is not publicly accessible
  ensure_bucket_not_public "$bucket" "$region" "$profile_opt"

  echo "Initializing Terraform with remote backend (S3)"

  # Choose between -migrate-state and -reconfigure (mutually exclusive):
  # - If local state exists and remote object is missing -> migrate (-migrate-state)
  # - Else if .terraform exists (previously initialized) -> reconfigure (-reconfigure)
  # - Else no special flag

  migrate_flag=""
  reconfigure_flag=""
  force_copy_flag=""

  has_local_state=false
  if [[ -s terraform.tfstate ]]; then
    has_local_state=true
  fi

  remote_state_exists=false
  if aws $profile_opt s3api head-object --bucket "$bucket" --key "$key" --region "$region" >/dev/null 2>&1; then
    remote_state_exists=true
  fi

  if [[ "$has_local_state" == true && "$remote_state_exists" == false ]]; then
    migrate_flag="-migrate-state"
    force_copy_flag="-force-copy"   # avoids interactive approval with -input=false
    echo "Detected local state and missing remote state -> using -migrate-state -force-copy"
  elif [[ -d .terraform ]]; then
    reconfigure_flag="-reconfigure"
    echo "Detected previous initialization (.terraform) -> using -reconfigure"
  fi

  terraform init -input=false $reconfigure_flag $migrate_flag $force_copy_flag -backend-config=backend.hcl
else
  echo "backend.hcl not found; initializing local backend (no remote state)."
  terraform init -input=false -backend=false
fi

terraform validate
