#!/usr/bin/env bash
# Floci only: keep the Floci container attached to the VPC's Docker network.
# The ALB runs inside Floci and forwards to the instances' private IPs on that network.
# A recreated Floci comes back without the attachment, and health checks then time out
# (edge case #11). Floci has no API for this, so the script goes behind it on purpose:
# if the attachment is missing it connects the container, then verifies the attachment
# and fails if it's still absent. Idempotent and non-destructive. Never needed on AWS.
# Usage, after sourcing scripts/shortify-env.sh:  bash scripts/floci-network-check.sh
set -u
: "${VPC_ID:?source scripts/shortify-env.sh first}"
floci="${FLOCI_CONTAINER:-floci-ui-floci-1}"

mapfile -t nets < <(docker network ls --format '{{.Name}}' | grep -E "^floci-vpc-.+-${VPC_ID}\$")
if [ "${#nets[@]}" -ne 1 ]; then
  echo "network: expected exactly one Docker network for $VPC_ID, found ${#nets[@]} (Floci creates it at the first launch in the VPC, edge case #11)" >&2
  exit 1
fi
net="${nets[0]}"

ip_on() { docker inspect -f "{{with index .NetworkSettings.Networks \"$net\"}}{{.IPAddress}}{{end}}" "$floci" 2>/dev/null; }

ip=$(ip_on)
if [ -n "$ip" ]; then
  echo "network: $floci attached to $net ($ip)"
  exit 0
fi

echo "network: $floci not attached to $net; connecting (edge case #11)"
if ! docker network connect "$net" "$floci"; then
  echo "network: docker network connect failed: the ALB can't reach any instance" >&2
  exit 1
fi
ip=$(ip_on)
if [ -n "$ip" ]; then
  echo "network: $floci attached to $net ($ip) after reconnect"
  exit 0
fi
echo "network: still not attached after connect: ALB health checks will time out (Target.Timeout)" >&2
exit 1
