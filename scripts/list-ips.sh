#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [--profile NAME] [--region REGION] [--just-ips]

Lists all assigned IP addresses (private, public, IPv6) for resources in the Terraform-managed VPC.

Options:
  --profile NAME   AWS CLI profile to use.
  --region REGION  AWS region to use (defaults to AWS env/config).
  --just-ips       Print only a unique list of IP addresses.

Requires: terraform, aws, jq
EOF
}

PROFILE=""
REGION=""
JUST_IPS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      PROFILE="$2"; shift 2;;
    --region)
      REGION="$2"; shift 2;;
    --just-ips)
      JUST_IPS=true; shift;;
    -h|--help)
      usage; exit 0;;
    *)
      echo "Unknown argument: $1" >&2
      usage; exit 1;;
  esac
done

for cmd in terraform aws jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing dependency: $cmd" >&2; exit 2; }
done

if ! VPC_ID=$(terraform output -raw vpc_id 2>/dev/null); then
  echo "Failed to get VPC ID from 'terraform output -raw vpc_id'. Ensure you've applied the stack." >&2
  exit 3
fi

AWS_ARGS=()
[[ -n "$PROFILE" ]] && AWS_ARGS+=(--profile "$PROFILE")
[[ -n "$REGION" ]] && AWS_ARGS+=(--region "$REGION")

JSON=$(aws ec2 describe-network-interfaces \
  --filters Name=vpc-id,Values="$VPC_ID" \
  "${AWS_ARGS[@]}" 2>/dev/null || true)

if [[ -z "$JSON" || "$JSON" == "null" ]]; then
  echo "No network interfaces found or AWS CLI returned no data." >&2
  exit 4
fi

if $JUST_IPS; then
  echo "$JSON" | jq -r '
    [
      (.NetworkInterfaces[]?.PrivateIpAddresses[]?.PrivateIpAddress),
      (.NetworkInterfaces[]?.PrivateIpAddresses[]?.Association?.PublicIp),
      (.NetworkInterfaces[]?.Ipv6Addresses[]?.Ipv6Address)
    ]
    | flatten
    | map(select(. != null))
    | unique
    | .[]
  '
  exit 0
fi

# Detailed table
echo "ENI_ID\tINTERFACE_TYPE\tDESCRIPTION\tATTACHMENT\tSUBNET_ID\tPRIVATE_IP\tPUBLIC_IP\tIPV6"
echo "$JSON" | jq -r '
  .NetworkInterfaces[]? as $eni
  | (
      if ($eni.PrivateIpAddresses|length) > 0 then
        $eni.PrivateIpAddresses[] | {
          eni_id: $eni.NetworkInterfaceId,
          interface_type: $eni.InterfaceType,
          description: ($eni.Description // ""),
          attachment: ($eni.Attachment.InstanceId // $eni.InterfaceType // ""),
          subnet_id: $eni.SubnetId,
          private_ip: .PrivateIpAddress,
          public_ip: (.Association.PublicIp // null),
          ipv6: ([$eni.Ipv6Addresses[]?.Ipv6Address] | join(",") )
        }
      else
        [{
          eni_id: $eni.NetworkInterfaceId,
          interface_type: $eni.InterfaceType,
          description: ($eni.Description // ""),
          attachment: ($eni.Attachment.InstanceId // $eni.InterfaceType // ""),
          subnet_id: $eni.SubnetId,
          private_ip: null,
          public_ip: null,
          ipv6: ([$eni.Ipv6Addresses[]?.Ipv6Address] | join(",") )
        }][]
      end
    )
  | [
      .eni_id,
      .interface_type,
      .description,
      .attachment,
      .subnet_id,
      (.private_ip // ""),
      (.public_ip // ""),
      (.ipv6 // "")
    ]
  | @tsv'