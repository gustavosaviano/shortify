# Runbook — operating the Floci environment

How to set up, start, stop, recover and rebuild the Phase 2 environment. For the reasoning behind each step, see [edge-cases.md](edge-cases.md).

> **Golden rule: operate through the control plane, never behind it.** Start, stop, reboot and terminate instances only with the AWS CLI. Starting Floci's backing containers from Docker Desktop is like power-cycling a server behind AWS's back. The box comes up, but Floci isn't told, and nothing it does at launch (key injection, sshd, UserData) runs.

---

## 1. One-time setup

Floci runs from the [floci-ui](https://github.com/floci-io/floci-ui) compose stack, which also provides a web console on `http://localhost:4500`.

```bash
git clone https://github.com/floci-io/floci-ui ~/workspace/floci-ui
```

Required settings for the `floci` service in `~/workspace/floci-ui/docker-compose.yml`:

```yaml
  floci:
    image: floci/floci:latest-compat      # compat = Floci + AWS CLI; the floci-ui init hook needs it
    group_add:
      - "1001"                            # gid of /var/run/docker.sock on this machine: stat -c %g /var/run/docker.sock
    ports:
      - "4566:4566"                       # AWS API endpoint
      - "80:80"                           # ALB listener (HTTP)
      - "8080:8080"                       # second ALB listener, kept as a control
      - "7001-7099:7001-7099"             # RDS proxy ports
      - "6379-6399:6379-6399"             # ElastiCache proxy ports
    environment:
      FLOCI_STORAGE_MODE: persistent
      FLOCI_STORAGE_PERSISTENT_PATH: /app/data
```

A few notes on these settings:

- **Why `group_add` and not `chmod 666`:** a `chmod` on the socket is undone every time Docker restarts, and Floci then silently loses Docker access. See edge case #18 in [edge-cases.md](edge-cases.md).
- **`FLOCI_NETWORK_SECURITY_GROUP_ENFORCEMENT_ENABLED`:** it's still set to `"true"` from the enforcement test, but it has no observable effect on this machine. Remove it at the next Floci recreate (edge case #13).
- **Only one Floci:** an old standalone `~/workspace/floci/docker-compose.yml` is obsolete. Two emulators running at once split resources between them.

Point the AWS CLI at Floci permanently:

```bash
echo '(cd ~/workspace/floci-ui && docker compose start > /dev/null 2>&1); eval $(floci env)' >> ~/.bashrc
source ~/.bashrc
aws s3 ls                                   # empty output, no error
curl http://localhost:4566/_floci/health    # every service "running"
```

The subshell keeps new terminals from changing directory. `start` resumes existing containers instead of recreating them.

---

## 2. Session helpers

Shell variables die with the terminal, so IDs are rediscovered by name.

```bash
cat > ~/workspace/shortify-ids.sh << 'IDS'
export VPC_ID=$(aws ec2 describe-vpcs --filters Name=tag:Name,Values=shortify-vpc --query 'Vpcs[0].VpcId' --output text)
export PUB1=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=shortify-public-01 --query 'Subnets[0].SubnetId' --output text)
export PUB2=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=shortify-public-02 --query 'Subnets[0].SubnetId' --output text)
export RDS_SG=$(aws ec2 describe-security-groups --filters Name=group-name,Values=shortify-rds-sg --query 'SecurityGroups[0].GroupId' --output text)
export EC2_SG=$(aws ec2 describe-security-groups --filters Name=group-name,Values=shortify-ec2-sg --query 'SecurityGroups[0].GroupId' --output text)
export ALB_SG=$(aws ec2 describe-security-groups --filters Name=group-name,Values=shortify-alb-sg --query 'SecurityGroups[0].GroupId' --output text)
export INSTANCE_ID=$(aws ec2 describe-instances --filters Name=instance-state-name,Values=running --query 'Reservations[-1].Instances[0].InstanceId' --output text)
export TG_ARN=$(aws elbv2 describe-target-groups --names shortify-alb-target --query 'TargetGroups[0].TargetGroupArn' --output text)
export ALB_ARN=$(aws elbv2 describe-load-balancers --names shortify-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text)
export ALB_DNS=$(aws elbv2 describe-load-balancers --names shortify-alb --query 'LoadBalancers[0].DNSName' --output text)
IDS
source ~/workspace/shortify-ids.sh
env | grep -E 'VPC_ID|PUB|_SG|INSTANCE|ARN|DNS'   # nothing may be None; INSTANCE_ID must match docker ps
```

Watch target health for 90 seconds:

```bash
watch_tg() { for i in 1 2 3 4 5 6; do aws elbv2 describe-target-health --target-group-arn $TG_ARN --query 'TargetHealthDescriptions[].[Target.Id,Target.Port,TargetHealth.State,TargetHealth.Reason]' --output text; echo ---; sleep 15; done; }
```

Optional SSH alias in `~/.ssh/config` (update `Port` when a new instance gets a different one):

```
Host shortify-ec2
    HostName 127.0.0.1
    Port 2200
    User root
    IdentityFile ~/.ssh/shortify-real
```

---

## 3. Start of session

```bash
cd ~/workspace/floci-ui && docker compose start
docker exec floci-ui-floci-1 id                                               # must list the docker.sock gid
docker logs floci-ui-floci-1 --since 5m 2>&1 | grep -i "no docker daemon"     # must print nothing
source ~/workspace/shortify-ids.sh
```

**Baseline.** This must pass before any work or test:

```bash
curl -s http://localhost/health
psql -h localhost -p 7001 -U shortify -d shortify -c "select count(*) from links;"
aws elbv2 describe-target-health --target-group-arn $TG_ARN --query 'TargetHealthDescriptions[].[Target.Id,Target.Port,TargetHealth.State]' --output text
```

If Floci was stopped, restarted or recreated since the last session, expect the app to be gone. A Floci shutdown stops its instance containers (edge case #26). The signature is `docker ps -a --filter name=floci-ec2` showing `Exited (137)` while the API still says `running`. Go to section 5.

## End of session

```bash
cd ~/workspace/floci-ui && docker compose stop
```

---

## 4. After the Floci container is recreated

Any compose configuration change or a `down`/`up` recreates Floci. Two things follow:

- The old Floci stops the instances on its way out, so plan an instance replacement.
- The new Floci must be reconnected to every VPC network. Otherwise the ALB can't reach any instance (health checks fail with `Target.Timeout`).

```bash
for n in $(docker network ls --format '{{.Name}}' | grep '^floci-vpc-'); do docker network connect "$n" floci-ui-floci-1 2>/dev/null; done
docker inspect floci-ui-floci-1 --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{$v.IPAddress}}{{"\n"}}{{end}}'
```

---

## 5. Replace the instance

This is the recovery procedure: replace, don't repair.

```bash
# 1. Out of the load balancer first. Deregister in the same form it was registered (with or without Port).
aws elbv2 deregister-targets --target-group-arn $TG_ARN --targets Id=$INSTANCE_ID,Port=8000
aws elbv2 deregister-targets --target-group-arn $TG_ARN --targets Id=$INSTANCE_ID
aws ec2 terminate-instances --instance-ids $INSTANCE_ID
aws ec2 wait instance-terminated --instance-ids $INSTANCE_ID

# 2. Fresh launch: the only lifecycle event where Floci injects the key and starts sshd
INSTANCE_ID=$(aws ec2 run-instances --image-id ami-ubuntu2404-amd64 --count 1 --instance-type t2.micro \
  --key-name shortify-real --security-group-ids $EC2_SG --subnet-id $PUB1 \
  --query 'Instances[0].InstanceId' --output text)
aws ec2 wait instance-running --instance-ids $INSTANCE_ID
docker ps --filter name=floci-ec2 --format '{{.Names}}  {{.Ports}}'      # note the SSH host port

# `running` is not "ready": sshd appears about 15-35 s later. Retry instead of failing.
ssh-keygen -R '[127.0.0.1]:2200'
for i in $(seq 1 12); do ssh -i ~/.ssh/shortify-real -p 2200 -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new root@127.0.0.1 true 2>/dev/null && echo "sshd ready" && break; sleep 5; done

# 3. Manual deploy
scp -i ~/.ssh/shortify-real -P 2200 -r ~/workspace/shortify-phase1/shortify root@127.0.0.1:/root/
RDS_HOST=$(aws rds describe-db-instances --db-instance-identifier shortify-db --query 'DBInstances[0].Endpoint.Address' --output text)
RDS_PORT=$(aws rds describe-db-instances --db-instance-identifier shortify-db --query 'DBInstances[0].Endpoint.Port' --output text)
ssh -i ~/.ssh/shortify-real -p 2200 root@127.0.0.1 << EOF
apt-get update -q && apt-get install -y -q python3 python3-pip postgresql-client
pip3 install -q -r /root/shortify/requirements.txt --break-system-packages
cd /root/shortify
DATABASE_URL="postgresql://shortify:shortify@${RDS_HOST}:${RDS_PORT}/shortify" nohup uvicorn app.main:app --host 0.0.0.0 --port 8000 > app.log 2>&1 &
sleep 3; tail -5 app.log
EOF

# 4. Back into the load balancer: wait for state, don't sleep
aws elbv2 register-targets --target-group-arn $TG_ARN --targets Id=$INSTANCE_ID,Port=8000
aws elbv2 wait target-in-service --target-group-arn $TG_ARN --targets Id=$INSTANCE_ID,Port=8000
curl -s http://localhost/health
```

**If the waiter never returns,** debug hop by hop from the ALB inwards:

1. `describe-target-health`: what does the ALB report?
2. `ssh … "pgrep -af uvicorn; tail -5 /root/shortify/app.log"`: is the app alive?
3. `docker exec floci-ui-floci-1 curl -sS -m 5 http://<private-ip>:8000/health; echo exit=$?`: can Floci reach the app?
   - `28` (timeout) means no route; reconnect the networks (section 4).
   - `7` means nothing is listening.

**Wait for state, never `sleep`.** Use `aws ec2 wait instance-running|instance-stopped|instance-terminated` and `aws elbv2 wait target-in-service`. Waiters print nothing while polling.

---

## 6. Access and smoke tests

```bash
# SSH (host port from: docker ps --filter name=floci-ec2)
ssh -i ~/.ssh/shortify-real -p 2200 root@127.0.0.1

# RDS: Floci's proxy, published to the host
psql -h localhost -p 7001 -U shortify -d shortify -c "select short_code, clicks from links;"

# Full path through the ALB (listeners on 80 and 8080)
curl -s http://localhost/health
curl -s -X POST http://localhost/shorten -H "Content-Type: application/json" -d '{"url":"https://github.com"}'
curl -v http://localhost/<code>
curl -s http://$ALB_DNS/health          # the ALB DNS name resolves to ::1 (IPv6 loopback)
```

---

## 7. Full rebuild (empty environment)

These are reference commands for recreating everything from nothing, in dependency order. Paste them section by section and check the output of each before moving on.

```bash
# ── VPC ──────────────────────────────────────────────────────────────────────
VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --query 'Vpc.VpcId' --output text)
aws ec2 create-tags --resources $VPC_ID --tags Key=Name,Value=shortify-vpc

# ── Subnets: always pass --availability-zone, otherwise they may all land in one AZ ──
PUB1=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.1.0/24 --availability-zone us-east-1a --query 'Subnet.SubnetId' --output text)
PUB2=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.2.0/24 --availability-zone us-east-1b --query 'Subnet.SubnetId' --output text)
PRIV1=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.3.0/24 --availability-zone us-east-1a --query 'Subnet.SubnetId' --output text)
PRIV2=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.4.0/24 --availability-zone us-east-1b --query 'Subnet.SubnetId' --output text)
aws ec2 create-tags --resources $PUB1  --tags Key=Name,Value=shortify-public-01
aws ec2 create-tags --resources $PUB2  --tags Key=Name,Value=shortify-public-02
aws ec2 create-tags --resources $PRIV1 --tags Key=Name,Value=shortify-private-01
aws ec2 create-tags --resources $PRIV2 --tags Key=Name,Value=shortify-private-02
# Public IPs for new instances. This only applies to instances launched afterwards.
aws ec2 modify-subnet-attribute --subnet-id $PUB1 --map-public-ip-on-launch
aws ec2 modify-subnet-attribute --subnet-id $PUB2 --map-public-ip-on-launch

# ── Internet gateway: the VPC's door to the internet ─────────────────────────
IGW_ID=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 create-tags --resources $IGW_ID --tags Key=Name,Value=shortify-igw
aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID

# ── Public route table: a route to the IGW is what makes a subnet public ─────
RTB_ID=$(aws ec2 create-route-table --vpc-id $VPC_ID --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-tags --resources $RTB_ID --tags Key=Name,Value=shortify-public-route
aws ec2 create-route --route-table-id $RTB_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
aws ec2 associate-route-table --route-table-id $RTB_ID --subnet-id $PUB1
aws ec2 associate-route-table --route-table-id $RTB_ID --subnet-id $PUB2

# ── Security groups: create all shells first, then rules (they reference each other) ──
RDS_SG=$(aws ec2 create-security-group --group-name shortify-rds-sg --description "shortify-rds-sg" --vpc-id $VPC_ID --query 'GroupId' --output text)
EC2_SG=$(aws ec2 create-security-group --group-name shortify-ec2-sg --description "shortify-ec2-sg" --vpc-id $VPC_ID --query 'GroupId' --output text)
ALB_SG=$(aws ec2 create-security-group --group-name shortify-alb-sg --description "shortify-alb-sg" --vpc-id $VPC_ID --query 'GroupId' --output text)
MY_IP=$(curl -s https://checkip.amazonaws.com)
aws ec2 authorize-security-group-ingress --group-id $RDS_SG --protocol tcp --port 5432 --source-group $EC2_SG   # DB only from app
aws ec2 authorize-security-group-ingress --group-id $EC2_SG --protocol tcp --port 8000 --source-group $ALB_SG   # app only from ALB
aws ec2 authorize-security-group-ingress --group-id $EC2_SG --protocol tcp --port 22   --cidr $MY_IP/32         # SSH only from admin IP
aws ec2 authorize-security-group-ingress --group-id $ALB_SG --protocol tcp --port 80   --cidr 0.0.0.0/0          # campaign links are public
aws ec2 authorize-security-group-ingress --group-id $ALB_SG --protocol tcp --port 443  --cidr 0.0.0.0/0
aws ec2 authorize-security-group-egress  --group-id $ALB_SG --protocol tcp --port 8000 --source-group $EC2_SG   # redundant while default allow-all egress exists; meaningful once egress is locked down

# ── RDS: a DB subnet group (private subnets only) is required first ──────────
aws rds create-db-subnet-group --db-subnet-group-name shortify-rds --db-subnet-group-description "shortify-rds" --subnet-ids "$PRIV1" "$PRIV2"
aws rds create-db-instance --db-instance-identifier shortify-db --db-instance-class db.t3.micro --engine postgres \
  --db-name shortify --master-username shortify --master-user-password shortify \
  --vpc-security-group-ids $RDS_SG --db-subnet-group-name shortify-rds

# ── Key pair ──────────────────────────────────────────────────────────────────
# Either option works. What matters is saving the private key correctly.
#   a) aws ec2 create-key-pair --key-name shortify-app --query 'KeyMaterial' --output text > ~/.ssh/shortify-app.pem
#   b) a local key plus import (used here):
[ -f ~/.ssh/shortify-real ] || ssh-keygen -t ed25519 -f ~/.ssh/shortify-real -N ""
chmod 600 ~/.ssh/shortify-real
aws ec2 import-key-pair --key-name shortify-real --public-key-material fileb://~/.ssh/shortify-real.pub

# ── EC2, then deploy: follow section 5, steps 2-3 ─────────────────────────────

# ── ALB: target group → load balancer (both AZs) → listeners ──────────────────
TG_ARN=$(aws elbv2 create-target-group --name shortify-alb-target --vpc-id $VPC_ID --protocol HTTP --port 8000 \
  --target-type instance --health-check-protocol HTTP --health-check-port 8000 --health-check-path /health \
  --health-check-interval-seconds 30 --query 'TargetGroups[0].TargetGroupArn' --output text)
ALB_ARN=$(aws elbv2 create-load-balancer --name shortify-alb --subnets $PUB1 $PUB2 --security-groups $ALB_SG \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)
aws elbv2 create-listener --load-balancer-arn $ALB_ARN --protocol HTTP --port 80   --default-actions Type=forward,TargetGroupArn=$TG_ARN
aws elbv2 create-listener --load-balancer-arn $ALB_ARN --protocol HTTP --port 8080 --default-actions Type=forward,TargetGroupArn=$TG_ARN   # Floci-only control; the ALB SG doesn't allow 8080 on real AWS

# Port is optional (it falls back to the target group port), but explicit is unambiguous
aws elbv2 register-targets --target-group-arn $TG_ARN --targets Id=$INSTANCE_ID,Port=8000
aws elbv2 wait target-in-service --target-group-arn $TG_ARN --targets Id=$INSTANCE_ID,Port=8000
curl -s http://localhost/health
```

Rules of thumb that apply to every step:

- **Check for unset variables.** An unset `$INSTANCE_ID` silently turns into `--targets Id=`, and the API accepts it.
- **Never use `--dry-run` on Floci.** It creates the resource anyway.
