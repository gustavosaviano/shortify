#!/usr/bin/env bash
# Floci only: is the app instance actually usable? After a Floci stop the API can still
# report "running" and terraform plan shows no changes (edge cases #26, #48), so check the
# container and sshd directly (a container started behind Floci has no sshd, #9).
# Read-only: it never starts, stops or replaces anything. On AWS, use EC2 status checks
# and ALB target health instead.
# Usage, after sourcing scripts/shortify-env.sh:  bash scripts/floci-instance-check.sh
set -u
: "${INSTANCE_ID:?source scripts/shortify-env.sh first}"
name="floci-ec2-$INSTANCE_ID"
api=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null) || api="unknown"
container=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null) || container="missing"
sshd=no
# Plain `docker top`: `-o comm` is rejected (Docker needs the PID column). Match the sshd
# *listener* (OpenSSH's process title), not per-connection sessions; if a future OpenSSH
# changes the title, this fails closed ("not usable"), never falsely "usable".
if [ "$container" = running ] && docker top "$name" 2>/dev/null | grep -q 'sshd: .*\[listener\]'; then sshd=yes; fi
if [ "$container" = running ] && [ "$sshd" = yes ]; then
  echo "instance $INSTANCE_ID: usable (container running, sshd up; API: $api)"
  exit 0
fi
echo "instance $INSTANCE_ID is NOT usable: container $container, sshd $sshd, API says $api (edge cases #9, #26)" >&2
echo "replace it: terraform -chdir=infra/terraform plan -replace=aws_instance.app -out tfplan (runbook section 9)" >&2
exit 1
