#!/usr/bin/env bash
# Release cutover: put the new instance behind the ALB, then take every other target out.
# The order is the zero-downtime promise: register, wait until in service, then deregister
# the rest, so there is always a healthy target. If the new instance never becomes
# healthy, it is deregistered again and the previous targets keep serving (exit 1).
# Every other target is removed whatever its state: after a Floci restart a dead one can
# sit in "initial" forever (edge case #8). Each is deregistered in the form it was
# registered, with or without a port (edge case #7). AWS CLI only: same on Floci and AWS.
# Idempotent. Usage, after sourcing scripts/shortify-env.sh: bash scripts/release-register.sh
set -u
: "${TG_ARN:?source scripts/shortify-env.sh first}" "${INSTANCE_ID:?source scripts/shortify-env.sh first}" "${ALB_DNS:?source scripts/shortify-env.sh first}"

port=$(aws elbv2 describe-target-groups --target-group-arns "$TG_ARN" --query 'TargetGroups[0].Port' --output text) || exit 1
case "$port" in
  ''|*[!0-9]*) echo "register: can't read the target group's port (got '$port')" >&2; exit 1 ;;
esac
new="Id=$INSTANCE_ID,Port=$port"

before=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].[Target.Id,Target.Port]' --output text) || exit 1
already=no
grep -qxF "$(printf '%s\t%s' "$INSTANCE_ID" "$port")" <<< "$before" && already=yes

echo "register: $INSTANCE_ID on port $port (already registered: $already); waiting until in service (a new target takes about 2.5 min)"
aws elbv2 register-targets --target-group-arn "$TG_ARN" --targets "$new" || exit 1
if ! aws elbv2 wait target-in-service --target-group-arn "$TG_ARN" --targets "$new"; then
  state=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" --targets "$new" \
    --query 'TargetHealthDescriptions[0].[TargetHealth.State,TargetHealth.Reason]' --output text)
  if [ "$already" = no ]; then
    echo "register: $INSTANCE_ID never became healthy ($state); deregistering it, the previous targets keep serving" >&2
    aws elbv2 deregister-targets --target-group-arn "$TG_ARN" --targets "$new"
  else
    echo "register: $INSTANCE_ID was already registered and isn't healthy ($state); left as it was" >&2
  fi
  exit 1
fi
echo "register: $INSTANCE_ID in service"

all=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].[Target.Id,Target.Port]' --output text) || exit 1
others=()
while read -r id p; do
  [ -z "$id" ] && continue
  [ "$id" = "$INSTANCE_ID" ] && [ "$p" = "$port" ] && continue
  if [ "$p" = None ]; then others+=("Id=$id"); else others+=("Id=$id,Port=$p"); fi
done <<< "$all"

if [ "${#others[@]}" -gt 0 ]; then
  echo "register: deregistering ${others[*]}"
  aws elbv2 deregister-targets --target-group-arn "$TG_ARN" --targets "${others[@]}" || exit 1
  aws elbv2 wait target-deregistered --target-group-arn "$TG_ARN" --targets "${others[@]}" || exit 1
fi

# Verify the effect: exactly the new instance, healthy, and the ALB answering through it.
final=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].[Target.Id,Target.Port,TargetHealth.State]' --output text) || exit 1
if [ "$final" != "$(printf '%s\t%s\t%s' "$INSTANCE_ID" "$port" healthy)" ]; then
  echo "register: expected only $INSTANCE_ID healthy in the target group, found:" >&2
  echo "$final" >&2
  exit 1
fi
code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' "http://$ALB_DNS/health")
if [ "$code" != 200 ]; then
  echo "register: the ALB answered /health with $code" >&2
  exit 1
fi
echo "register: only $INSTANCE_ID behind the ALB; /health through the ALB: 200"
