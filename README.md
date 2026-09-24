# Shortify — URL Shortener SaaS

A self-hosted URL shortener built for a marketing agency use case — replacing third-party SaaS dependency (Bitly/TinyURL) with an owned, observable, cost-controlled redirect layer on AWS.

## Business Context

Marketing agencies run campaigns across email, Instagram, WhatsApp. Every campaign has long URLs with UTM parameters like:

`https://store.mybrand.com/products/summer?utm_source=email&utm_campaign=july4&utm_medium=cta`

**Three real business problems this solves:**

1. **No control over uptime** — if Bitly goes down, every campaign link across every channel goes dead. Direct revenue loss.
2. **No data ownership** — click data lives in a third party's database. Campaign performance is opaque.
3. **Cost at scale** — per-link pricing on SaaS tools doesn't scale with campaign volume.

**Shortify gives the agency:**
- Owned infrastructure — no vendor dependency
- Click tracking — every redirect increments a counter in their own database
- Full observability — latency, uptime, error rates on their own terms
- Custom domains — `go.brand.com` instead of `bit.ly/xxx`

**Every architectural decision in this project has a business justification.** That's what separates a portfolio piece from a tutorial clone.

---

## Stack

| Layer | Technology | Why |
|-------|-----------|-----|
| App | FastAPI + PostgreSQL | Simple, real API with persistent storage |
| Local emulation | Floci (floci.io) | Free, open-source AWS emulator — no cloud costs |
| Cloud target | AWS | Industry standard, free tier available |
| IaC | Terraform + Ansible | Phase 4 — codify everything built manually |
| CI/CD | GitHub Actions | Phase 3 — automate the deploy pipeline |

---

## Roadmap

| Phase | Description | Status |
|-------|-------------|--------|
| 1 | Local bootstrap — Docker Compose | ✅ Done |
| 2 | Manual deploy via CLI — VPC, EC2, RDS, ALB | ✅ Done |
| 3 | CI/CD — GitHub Actions + ECR + SSH deploy | ⏳ Pending |
| 4 | IaC — Terraform + Ansible | ⏳ Pending |
| 5 | Containers — ECS Fargate or EKS | ⏳ Pending |
| 6 | Observability — CloudWatch, X-Ray, WAF | ⏳ Pending |

---

## Phase 1 — Local Bootstrap ✅

### Why this phase exists
Before touching any infrastructure, you need to understand what you're deploying. The app has two flows:

**Flow 1 — Shorten:** `POST /shorten` → generates 6-char code → saves to DB → returns short URL

**Flow 2 — Redirect:** `GET /{code}` → looks up code in DB → increments `clicks` counter → returns `302` redirect

The `clicks` counter is the business value — every campaign redirect is tracked automatically.

### Prerequisites
- Docker + Docker Compose installed

### Run locally

```bash
docker compose up --build
```

### Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Health check — used by ALB to verify instance is alive |
| GET | `/metrics` | Total link count — basic observability |
| POST | `/shorten` | Create a short URL |
| GET | `/{code}` | Redirect to original URL (302) |

### Test

```bash
# Health
curl http://localhost:8000/health

# Shorten
curl -X POST http://localhost:8000/shorten \
  -H "Content-Type: application/json" \
  -d '{"url": "https://www.github.com"}'

# Redirect (replace code with value returned above)
curl -v http://localhost:8000/{code}

# Metrics
curl http://localhost:8000/metrics
```

### Why the /health endpoint matters
The ALB pings `/health` every 30 seconds. If it gets no `200 OK`, it marks the instance unhealthy and stops routing traffic. For the marketing agency, this means a crashed app never silently serves errors — the ALB detects it automatically.

### Tear down

```bash
docker compose down -v
```

---

## Phase 2 — Manual Deploy via CLI ✅

### Why manual first?
Before writing a single line of Terraform, every resource was built manually via AWS CLI against Floci. The goal: **feel every dependency, every gotcha, every decision** — so that when Phase 4 codifies it in Terraform, every line makes sense.

The manual phase teaches you:
- Why resources have a creation order
- Why subnets need AZs specified explicitly
- Why security groups reference each other by ID
- Why a DB subnet group exists as a separate resource
- Why target registration and health checks are separate concerns

### Why Floci instead of real AWS?
Original AWS account free tier had expired (account from 2021). A new account creation was blocked by AWS due to existing identity association (same credit card, phone, address).

**Floci** (floci.io) was chosen:
- Free, open-source, MIT licensed
- Runs via Docker Compose on localhost:4566
- Emulates 100+ AWS services including EC2, RDS, VPC, ALB, EKS
- EC2 instances are real Ubuntu Docker containers — SSH works
- RDS instances are real PostgreSQL containers — psql works
- ALB listener forwards real HTTP traffic to EC2 containers

### Floci setup

```bash
# Clone the floci-ui repo (includes Floci + web console)
git clone https://github.com/floci-io/floci-ui ~/workspace/floci-ui
cd ~/workspace/floci-ui

# Edit docker-compose.yml — floci service must have:
# image: floci/floci:latest-compat      # compat = Floci + AWS CLI/boto3; the floci-ui init hooks need it
# group_add:
#   - "1001"                            # gid of /var/run/docker.sock on THIS machine: stat -c %g /var/run/docker.sock
# ports:
#   - "4566:4566"
#   - "7001-7099:7001-7099"   # RDS proxy ports
#   - "6379-6399:6379-6399"   # ElastiCache proxy ports
#   - "80:80"                 # ALB listener on the real HTTP port (works, see edge case #10)
#   - "8080:8080"             # second ALB listener, kept as a control / for existing scripts
# NOTE: FLOCI_NETWORK_SECURITY_GROUP_ENFORCEMENT_ENABLED was set to "true" for Test A stage 2.
#       It has no observable effect on this setup (edge case #13) — remove it at the next recreate.
# environment:
#   FLOCI_STORAGE_MODE: persistent
#   FLOCI_STORAGE_PERSISTENT_PATH: /app/data

# Start
docker compose up -d

# Configure AWS CLI to point at Floci
eval $(floci env)

# Make permanent
# Subshell so every new terminal does NOT cd into floci-ui; `start` so existing containers are resumed
echo '(cd ~/workspace/floci-ui && docker compose start > /dev/null 2>&1); eval $(floci env)' >> ~/.bashrc
source ~/.bashrc

# Verify
aws s3 ls   # should return empty, no error
curl http://localhost:4566/_floci/health   # all services should show "running"
```

**Docker socket access (why `group_add`):** Floci runs as `uid=1001(floci)` and needs `/var/run/docker.sock` to create EC2/RDS backing containers. The socket is `root:docker 660`. Our first fix, `sudo chmod 666`, was silently undone the next time Docker restarted (the socket is recreated with default permissions), and Floci started without Docker access. Symptoms: log line `No Docker daemon is reachable from Floci`, RDS proxy on 7001 accepts connections then drops them (`server closed the connection unexpectedly`), instances not restored. The durable fix is `group_add` with the socket's gid, verified with `docker exec floci-ui-floci-1 id` (must list the gid). It survives restarts and doesn't open the socket to every local user. If Docker is reinstalled, re-check the gid.

See the **Operating runbook** below before starting or stopping anything.

**Only one Floci:** the old standalone `~/workspace/floci/docker-compose.yml` is obsolete — the floci-ui compose file runs Floci. Two Floci instances running at once caused resources to be created on one while the ALB listener was checked on the other. Delete or never start the old one.

### Operating runbook (Floci)

**Golden rule: operate through the control plane, never behind it.** Start, stop, reboot and terminate instances only with the AWS CLI. Starting Floci's backing containers from Docker Desktop is the equivalent of power-cycling a server behind AWS's back: the box comes up, but Floci doesn't know, and nothing it runs at launch (key injection, sshd, UserData) happens.

**Session helpers** (shell variables die with the terminal, so rediscover IDs by name):

```bash
cat > ~/workspace/shortify-ids.sh << 'EOF'
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
EOF
source ~/workspace/shortify-ids.sh
env | grep -E 'VPC_ID|PUB|_SG|INSTANCE|ARN|DNS'   # nothing should be None; INSTANCE_ID must match docker ps

watch_tg() { for i in 1 2 3 4 5 6; do aws elbv2 describe-target-health --target-group-arn $TG_ARN --query 'TargetHealthDescriptions[].[Target.Id,Target.Port,TargetHealth.State,TargetHealth.Reason]' --output text; echo ---; sleep 15; done; }
```

Optional SSH alias (`~/.ssh/config`), update `Port` whenever a new instance gets a different one:

```
Host shortify-ec2
    HostName 127.0.0.1
    Port 2200
    User root
    IdentityFile ~/.ssh/shortify-real
```

**Start of session**

```bash
cd ~/workspace/floci-ui && docker compose start
docker exec floci-ui-floci-1 id                       # must list the docker.sock gid
docker logs floci-ui-floci-1 --since 5m 2>&1 | grep -i "no docker daemon"   # must print nothing
source ~/workspace/shortify-ids.sh
```

Then the **baseline** (must pass before any work or test):

```bash
curl -s http://localhost:8080/health
psql -h localhost -p 7001 -U shortify -d shortify -c "select count(*) from links;"
aws elbv2 describe-target-health --target-group-arn $TG_ARN --query 'TargetHealthDescriptions[].[Target.Id,Target.Port,TargetHealth.State]' --output text
```

If the machine was rebooted **or Floci was restarted/recreated**, the baseline will fail on the app: a Floci shutdown stops its instance containers (edge case #26), and processes (sshd, uvicorn) don't survive a restart anyway. Check `docker ps -a --filter name=floci-ec2` — `Exited (137)` while the API still says `running` is the signature. That's expected — use **Replace the instance** below.

**End of session:** `cd ~/workspace/floci-ui && docker compose stop`

**After the Floci container is recreated** (any compose config change, or `down`/`up`): the old Floci stops the instances on its way out (so plan to replace the instance), and the new one must be reconnected to every VPC network, otherwise the ALB can't reach any instance (health check `Target.Timeout`):

```bash
for n in $(docker network ls --format '{{.Name}}' | grep '^floci-vpc-'); do docker network connect "$n" floci-ui-floci-1 2>/dev/null; done
docker inspect floci-ui-floci-1 --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{$v.IPAddress}}{{"\n"}}{{end}}'
```

**Replace the instance** (the recovery procedure — replace, don't repair):

```bash
# 1. Out of the load balancer first. Deregister must match how it was registered (with or without Port).
aws elbv2 deregister-targets --target-group-arn $TG_ARN --targets Id=$INSTANCE_ID,Port=8000
aws elbv2 deregister-targets --target-group-arn $TG_ARN --targets Id=$INSTANCE_ID
aws ec2 terminate-instances --instance-ids $INSTANCE_ID
aws ec2 wait instance-terminated --instance-ids $INSTANCE_ID

# 2. Fresh launch — the only lifecycle event where Floci injects the key and starts sshd
INSTANCE_ID=$(aws ec2 run-instances --image-id ami-ubuntu2404-amd64 --count 1 --instance-type t2.micro \
  --key-name shortify-real --security-group-ids $EC2_SG --subnet-id $PUB1 \
  --query 'Instances[0].InstanceId' --output text)
aws ec2 wait instance-running --instance-ids $INSTANCE_ID
docker ps --filter name=floci-ec2 --format '{{.Names}}  {{.Ports}}'      # note the SSH host port
# `running` is not "ready": key injection and sshd follow ~15–35 s later (edge case #25). Retry, don't give up:
ssh-keygen -R '[127.0.0.1]:2200'
for i in $(seq 1 12); do ssh -i ~/.ssh/shortify-real -p 2200 -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new root@127.0.0.1 true 2>/dev/null && echo "sshd ready" && break; sleep 5; done

# 3. Manual deploy
scp -i ~/.ssh/shortify-real -P 2200 -o StrictHostKeyChecking=accept-new -r ~/workspace/shortify-phase1/shortify root@127.0.0.1:/root/
RDS_HOST=$(aws rds describe-db-instances --db-instance-identifier shortify-db --query 'DBInstances[0].Endpoint.Address' --output text)
RDS_PORT=$(aws rds describe-db-instances --db-instance-identifier shortify-db --query 'DBInstances[0].Endpoint.Port' --output text)
ssh -i ~/.ssh/shortify-real -p 2200 root@127.0.0.1 << EOF
apt-get update -q && apt-get install -y -q python3 python3-pip postgresql-client
pip3 install -q -r /root/shortify/requirements.txt --break-system-packages
cd /root/shortify
DATABASE_URL="postgresql://shortify:shortify@\${RDS_HOST}:\${RDS_PORT}/shortify" nohup uvicorn app.main:app --host 0.0.0.0 --port 8000 > app.log 2>&1 &
sleep 3; tail -5 app.log
EOF

# 4. Back into the load balancer — wait for state, don't sleep
aws elbv2 register-targets --target-group-arn $TG_ARN --targets Id=$INSTANCE_ID,Port=8000
aws elbv2 wait target-in-service --target-group-arn $TG_ARN --targets Id=$INSTANCE_ID,Port=8000
```

If the waiter never returns, debug hop by hop from the ALB inwards: target health → `pgrep -af uvicorn` on the instance → `docker exec floci-ui-floci-1 curl -sS -m 5 http://<private-ip>:8000/health; echo exit=$?` (`28` = no route → reconnect networks; `7` = nothing listening).

**Wait for state, never `sleep`.** Fixed sleeps caused a real race: stop takes 30 s in Floci, we called `start` after 15 s, the start was lost and the instance ended `stopped`. Use `aws ec2 wait instance-running|instance-stopped|instance-terminated` and `aws elbv2 wait target-in-service`. Waiters print nothing while polling; silence means "not there yet", not "frozen".

### Architecture overview

```
Internet
    ↓
Internet Gateway (shortify-igw)
    ↓
VPC 10.0.0.0/16
    ├── Public subnet 10.0.1.0/24 (us-east-1a)  ─┐
    └── Public subnet 10.0.2.0/24 (us-east-1b)  ─┴─→ ALB → EC2
    ├── Private subnet 10.0.3.0/24 (us-east-1a) ─┐
    └── Private subnet 10.0.4.0/24 (us-east-1b) ─┴─→ RDS
```

**Business reason for this layout:**
- ALB in 2 AZs → if one AWS data center fails, campaign links stay alive
- EC2 in public subnet → reachable from the internet via ALB
- RDS in private subnet → campaign link data never directly exposed to the internet
- Security groups chain: internet → ALB → EC2 → RDS, each layer only accepts traffic from the previous one

**Simplification to be aware of:** EC2 sits in a **public** subnet so we can SSH to it directly. The more secure production pattern is EC2 in **private** subnets behind the ALB (the ALB can reach private targets), with SSM Session Manager or a bastion for admin access and a NAT gateway for outbound package installs. NAT gateways are not free, which is why we didn't do it here. Candidate for Phase 4.

**Route table note:** private subnets currently use the VPC's *main* route table implicitly. If someone ever adds an IGW route to the main table, every implicitly-associated subnet becomes public. Safer: an explicit `shortify-private-route` table associated to the private subnets. Candidate for Phase 4.

### Full rebuild script

Use this script to rebuild all infrastructure from scratch (e.g. after `docker compose down`):

```bash
# ── VPC ──────────────────────────────────────────────────────────────────────
VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --query 'Vpc.VpcId' --output text)
aws ec2 create-tags --resources $VPC_ID --tags Key=Name,Value=shortify-vpc
echo "VPC: $VPC_ID"

# ── SUBNETS ──────────────────────────────────────────────────────────────────
# IMPORTANT: always specify --availability-zone explicitly
# Without it, AWS/Floci puts all subnets in the same AZ — defeats redundancy
PUB1=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.1.0/24 --availability-zone us-east-1a --query 'Subnet.SubnetId' --output text)
PUB2=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.2.0/24 --availability-zone us-east-1b --query 'Subnet.SubnetId' --output text)
PRIV1=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.3.0/24 --availability-zone us-east-1a --query 'Subnet.SubnetId' --output text)
PRIV2=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.4.0/24 --availability-zone us-east-1b --query 'Subnet.SubnetId' --output text)

aws ec2 create-tags --resources $PUB1  --tags Key=Name,Value=shortify-public-01
aws ec2 create-tags --resources $PUB2  --tags Key=Name,Value=shortify-public-02
aws ec2 create-tags --resources $PRIV1 --tags Key=Name,Value=shortify-private-01
aws ec2 create-tags --resources $PRIV2 --tags Key=Name,Value=shortify-private-02

# Enable public IP assignment on public subnets
# IMPORTANT: must be done BEFORE launching EC2
# The setting only applies to new instances — existing ones are NOT retroactively assigned a public IP
aws ec2 modify-subnet-attribute --subnet-id $PUB1 --map-public-ip-on-launch
aws ec2 modify-subnet-attribute --subnet-id $PUB2 --map-public-ip-on-launch
echo "Subnets: $PUB1 $PUB2 $PRIV1 $PRIV2"

# ── INTERNET GATEWAY ─────────────────────────────────────────────────────────
# VPC is sealed by default — IGW is the door to the internet
# Without it, no traffic reaches the ALB and every campaign link is dead
IGW_ID=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 create-tags --resources $IGW_ID --tags Key=Name,Value=shortify-igw
aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
echo "IGW: $IGW_ID"

# ── ROUTE TABLE ───────────────────────────────────────────────────────────────
# Public subnets need a route to the IGW (0.0.0.0/0 = all internet traffic)
# Private subnets use the default route table (local only — no internet)
# This is what makes a subnet "public" or "private" — not a flag, but a route
RTB_ID=$(aws ec2 create-route-table --vpc-id $VPC_ID --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-tags --resources $RTB_ID --tags Key=Name,Value=shortify-public-route
aws ec2 create-route --route-table-id $RTB_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
aws ec2 associate-route-table --route-table-id $RTB_ID --subnet-id $PUB1
aws ec2 associate-route-table --route-table-id $RTB_ID --subnet-id $PUB2
echo "Route table: $RTB_ID"

# ── SECURITY GROUPS ───────────────────────────────────────────────────────────
# Create in dependency order: RDS first, EC2 second, ALB last
# Each SG references the previous one — you can't reference something that doesn't exist yet
RDS_SG=$(aws ec2 create-security-group --group-name shortify-rds-sg --description "shortify-rds-sg" --vpc-id $VPC_ID --query 'GroupId' --output text)
EC2_SG=$(aws ec2 create-security-group --group-name shortify-ec2-sg --description "shortify-ec2-sg" --vpc-id $VPC_ID --query 'GroupId' --output text)
ALB_SG=$(aws ec2 create-security-group --group-name shortify-alb-sg --description "shortify-alb-sg" --vpc-id $VPC_ID --query 'GroupId' --output text)
echo "SGs: RDS=$RDS_SG EC2=$EC2_SG ALB=$ALB_SG"

MY_IP=$(curl -s https://checkip.amazonaws.com)

# RDS: only accept PostgreSQL from EC2
aws ec2 authorize-security-group-ingress --group-id $RDS_SG --protocol tcp --port 5432 --source-group $EC2_SG

# EC2: only accept app traffic from ALB, SSH from admin IP only
# Business reason: EC2 is never exposed directly to the internet — only ALB can reach it
# SSH locked to admin IP — prevents brute force attacks on port 22
aws ec2 authorize-security-group-ingress --group-id $EC2_SG --protocol tcp --port 8000 --source-group $ALB_SG
aws ec2 authorize-security-group-ingress --group-id $EC2_SG --protocol tcp --port 22 --cidr $MY_IP/32

# ALB: accept HTTP + HTTPS from internet, forward to EC2 on port 8000
# Business reason: campaigns use HTTP links — both ports needed, 80 redirects to 443
# Outbound to EC2 is a NEW connection from ALB (not return traffic) — needs explicit egress rule
# Security groups are stateful but statefulness only applies to return traffic on the SAME SG
aws ec2 authorize-security-group-ingress --group-id $ALB_SG --protocol tcp --port 80  --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $ALB_SG --protocol tcp --port 443 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-egress  --group-id $ALB_SG --protocol tcp --port 8000 --source-group $EC2_SG
echo "Security group rules applied"

# ── RDS ──────────────────────────────────────────────────────────────────────
# DB subnet group required before RDS creation — tells RDS which subnets it can use
# Always use private subnets — RDS should never be publicly accessible
aws rds create-db-subnet-group \
  --db-subnet-group-name shortify-rds \
  --db-subnet-group-description "shortify-rds" \
  --subnet-ids "$PRIV1" "$PRIV2"

aws rds create-db-instance \
  --db-instance-identifier shortify-db \
  --db-instance-class db.t3.micro \
  --engine postgres \
  --db-name shortify \
  --master-username shortify \
  --master-user-password shortify \
  --vpc-security-group-ids $RDS_SG \
  --db-subnet-group-name shortify-rds
echo "RDS created"

# ── KEY PAIR ─────────────────────────────────────────────────────────────────
# CRITICAL: use import-key-pair with a REAL locally generated key
# Floci's create-key-pair generates dummy/invalid key material
# SSH will fail with "error in libcrypto" if you use the Floci-generated key
if [ ! -f ~/.ssh/shortify-real ]; then
  ssh-keygen -t ed25519 -f ~/.ssh/shortify-real -N ""
  chmod 600 ~/.ssh/shortify-real
fi
aws ec2 import-key-pair --key-name shortify-real \
  --public-key-material fileb://~/.ssh/shortify-real.pub

# ── EC2 ──────────────────────────────────────────────────────────────────────
# IMPORTANT: enable MapPublicIpOnLaunch on subnets BEFORE launching EC2
# This was done above — but if you skip it, the EC2 won't get a public IP
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id ami-ubuntu2404-amd64 \
  --count 1 \
  --instance-type t2.micro \
  --key-name shortify-real \
  --security-group-ids $EC2_SG \
  --subnet-id $PUB1 \
  --query 'Instances[0].InstanceId' \
  --output text)
echo "EC2: $INSTANCE_ID"

# Wait for the state, not a fixed time
aws ec2 wait instance-running --instance-ids $INSTANCE_ID
docker ps --filter name=floci-ec2 --format '{{.Names}}  {{.Ports}}'   # note the SSH host port

# ── APP DEPLOYMENT ────────────────────────────────────────────────────────────
# Remove only the stale host key — EC2 host key changes on every recreation
# (echo > ~/.ssh/known_hosts also works but wipes EVERY host you've trusted)
ssh-keygen -R '[127.0.0.1]:2200'

# SCP code to EC2
# Business reason: in Phase 3 CI/CD replaces this manual step
scp -i ~/.ssh/shortify-real -P 2200 -r ~/workspace/shortify-phase1/shortify root@127.0.0.1:/root/

# Install dependencies and start app
# nohup keeps the app running after SSH session closes (unlike bare &)
RDS_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier shortify-db --query 'DBInstances[0].Endpoint.Address' --output text)
RDS_PORT=$(aws rds describe-db-instances --db-instance-identifier shortify-db --query 'DBInstances[0].Endpoint.Port' --output text)

ssh -i ~/.ssh/shortify-real -p 2200 root@127.0.0.1 << EOF
apt-get update -q
apt-get install -y python3 python3-pip postgresql-client
pip3 install -r /root/shortify/requirements.txt --break-system-packages
export DATABASE_URL="postgresql://shortify:shortify@${RDS_ENDPOINT}:${RDS_PORT}/shortify"
cd /root/shortify
nohup uvicorn app.main:app --host 0.0.0.0 --port 8000 > /root/shortify/app.log 2>&1 &
echo "App started"
EOF

# ── ALB ──────────────────────────────────────────────────────────────────────
# Target group first — defines where traffic goes and how to health check
# Business reason: ALB health checks /health every 30s
# If the app crashes, ALB stops routing campaign traffic to it automatically
TG_ARN=$(aws elbv2 create-target-group \
  --name shortify-alb-target \
  --vpc-id $VPC_ID \
  --protocol HTTP \
  --port 8000 \
  --target-type instance \
  --health-check-protocol HTTP \
  --health-check-port 8000 \
  --health-check-path /health \
  --health-check-interval-seconds 30 \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text)
echo "Target group: $TG_ARN"

# IMPORTANT: always specify Port explicitly when registering targets
# Without Port, Floci health checks may fail even when the app is running
# The empty target ID gotcha: registering without Id= creates an invalid target
# that poisons health checks for all other targets — always verify with describe-target-health
aws elbv2 register-targets \
  --target-group-arn $TG_ARN \
  --targets Id=$INSTANCE_ID,Port=8000

# ALB spans both public subnets (both AZs) for high availability
# Business reason: ALB itself stays up even if one AZ fails
ALB_ARN=$(aws elbv2 create-load-balancer \
  --name shortify-alb \
  --subnets $PUB1 $PUB2 \
  --security-groups $ALB_SG \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text)
echo "ALB: $ALB_ARN"

# Listener on port 8080 in Floci. Port 80 was tried first and failed, but the target was
# UNHEALTHY at the time, so port 80 itself was never proven to be the problem (see Open Items).
# On real AWS use port 80 (redirect to 443) — the ALB SG only allows 80/443, so an 8080
# listener would be blocked there. Floci does not enforce security groups, which is why 8080 works here.
aws elbv2 create-listener \
  --load-balancer-arn $ALB_ARN \
  --protocol HTTP \
  --port 8080 \
  --default-actions Type=forward,TargetGroupArn=$TG_ARN

# Wait for health check to pass (30s interval)
echo "Waiting for health check (up to ~10 min, prints nothing while polling)..."
aws elbv2 wait target-in-service --target-group-arn $TG_ARN --targets Id=$INSTANCE_ID,Port=8000
aws elbv2 describe-target-health --target-group-arn $TG_ARN

# ── SUMMARY ──────────────────────────────────────────────────────────────────
echo ""
echo "=== SHORTIFY INFRASTRUCTURE ==="
echo "VPC:         $VPC_ID"
echo "Public:      $PUB1 $PUB2"
echo "Private:     $PRIV1 $PRIV2"
echo "IGW:         $IGW_ID"
echo "RTB:         $RTB_ID"
echo "RDS SG:      $RDS_SG"
echo "EC2 SG:      $EC2_SG"
echo "ALB SG:      $ALB_SG"
echo "EC2:         $INSTANCE_ID"
echo "Target Group: $TG_ARN"
echo "ALB:         $ALB_ARN"
echo "RDS:         $RDS_ENDPOINT:$RDS_PORT"
echo ""
echo "Test via ALB:"
echo "  curl http://localhost:8080/health"
echo "  curl -X POST http://localhost:8080/shorten -H 'Content-Type: application/json' -d '{\"url\": \"https://github.com\"}'"
```

### SSH into EC2

```bash
# Floci maps EC2 SSH to port 2200 (not 22)
# Find the exact port:
docker ps | grep floci-ec2

# SSH
ssh -i ~/.ssh/shortify-real -p 2200 root@127.0.0.1

# If "REMOTE HOST IDENTIFICATION HAS CHANGED":
ssh-keygen -R '[127.0.0.1]:2200'
# Then retry — this happens every time EC2 is recreated (host key changes)
```

### Connect to RDS

```bash
# From WSL directly (port 7001 exposed in docker-compose.yml)
psql -h localhost -p 7001 -U shortify -d shortify

# From inside EC2
psql -h <RDS_ENDPOINT> -p 7001 -U shortify -d shortify

# Verify data
SELECT * FROM links;
```

### Test the full stack via ALB

```bash
# Health
curl http://localhost:8080/health

# Shorten
curl -X POST http://localhost:8080/shorten \
  -H "Content-Type: application/json" \
  -d '{"url": "https://www.github.com"}'

# Redirect (replace code)
curl -v http://localhost:8080/{code}

# Metrics
curl http://localhost:8080/metrics

# Verify in DB
psql -h localhost -p 7001 -U shortify -d shortify -c "SELECT * FROM links;"
```

### Edge cases and gotchas

**1. `--dry-run` actually creates resources in Floci**
Floci doesn't fully implement `--dry-run`. Running `aws ec2 create-subnet --dry-run` will actually create the subnet, causing a CIDR conflict on the second attempt. Never use `--dry-run` with Floci.

**2. AZ assignment is not automatic**
If you don't specify `--availability-zone` when creating subnets, AWS/Floci puts all subnets in the same AZ. This defeats the entire redundancy purpose. Always specify AZs explicitly and verify with `describe-subnets`.

**3. Key pairs — save the private key correctly**
Our first SSH attempt failed with `error in libcrypto`, and I blamed Floci for "dummy keys". The current Floci EC2 docs say `CreateKeyPair` returns real RSA key material and that created or imported keys both work. The likely real cause: the key was copied by hand out of the JSON `KeyMaterial` field, leaving literal `\n` sequences in the file. Correct ways:
```bash
aws ec2 create-key-pair --key-name shortify-app --query 'KeyMaterial' --output text > ~/.ssh/shortify-app.pem && chmod 600 ~/.ssh/shortify-app.pem
# or, as we did:
ssh-keygen -t ed25519 -f ~/.ssh/shortify-real -N "" && aws ec2 import-key-pair --key-name shortify-real --public-key-material fileb://~/.ssh/shortify-real.pub
```
Note: we asked for `--key-type ed25519` but Floci returned an RSA key.

**4. `MapPublicIpOnLaunch` must be set before EC2 launch**
This setting only applies to new instances. If you forgot it, terminate and relaunch — existing instances are not retroactively assigned a public IP.

**5. Security group creation order matters**
SGs reference each other by ID. Create innermost-first: RDS → EC2 → ALB. You can't reference an SG that doesn't exist yet. Create the shells first, then add rules once all three exist.

**6. DB subnet group is required before RDS**
RDS can't be placed directly in a subnet — it needs a DB subnet group first. This is an RDS-specific resource that tells it which subnets it's allowed to use. Always use private subnets.

**7. Stale targets — clean them up, but they're not what broke health checks**
Yesterday I claimed an empty-ID target "poisoned" health checks. Today a terminated, portless target sat at `initial / Elb.RegistrationInProgress` the whole time and the new target still went `healthy`, so a stale target does not block others. Test D2 then reproduced the empty-ID case: `--targets Id=` is accepted silently, the empty target goes `unhealthy / FailedHealthChecks` (identical to day 1), and the real target stays `healthy` with traffic flowing. **Neither a stale nor an empty target poisons the group** — health is per target. Day 1's empty target almost certainly came from `Id=$INSTANCE_ID` in a terminal where the variable was unset (see #21). Two rules that do hold:
- **Deregister must match the registration.** A target registered without `Port` is not removed by `--targets Id=X,Port=8000`; the call succeeds and silently removes nothing. Deregister with the same form it was registered with.
- Always check `describe-target-health` after registering or deregistering.

**8. ALB target registration — specify Port explicitly**
```bash
aws elbv2 register-targets --target-group-arn $TG_ARN --targets Id=$INSTANCE_ID,Port=8000
```
Test D1: a portless registration also goes `healthy` (falls back to the target group port, as on AWS; `Target.Port` shows `None`, meaning "not set", not "no port"). So `Port` is not required — it's hygiene: it makes the registration unambiguous and deregistration predictable (#7).
Reason codes worth knowing: `Elb.InitialHealthChecking` = new target, checks in progress (wait ~5 × interval); `Elb.RegistrationInProgress` stuck forever = the instance behind it is gone.

**9. Instance lifecycle — only a fresh launch gives you a working instance**
Floci's EC2 image (`ami-ubuntu2404-amd64` → plain `ubuntu:24.04`) runs `tail -f /dev/null` as PID 1 — no systemd. Tested:

| Action | What Floci does | Result |
|---|---|---|
| `run-instances` | Creates container, injects key, starts sshd, runs UserData | ✅ usable |
| `reboot-instances` | `docker restart` | Filesystem kept; no sshd, no app |
| `stop-instances` / `start-instances` | `docker stop` (30 s, then SIGKILL → exit 137) / `docker start`, same container ID | Filesystem kept; no sshd, no app |
| Start from Docker Desktop | Same as above, Floci not told | Same, plus Floci's state out of sync |

So recovery = **replace, don't repair** (runbook above). On real AWS a reboot keeps sshd (systemd starts it), but our hand-started uvicorn would die there too. Not to confuse with Floci's own image tag (`latest` vs `latest-compat`), which has nothing to do with instance boot. An experimental `ami-ubuntu2404-cloud` with systemd + cloud-init exists, but is listed arm64-only (this machine is x86_64) — Open Items.
Observed oddity: right after an API reboot, `stop-instances` reported `PreviousState: stopped` while the instance was running.

**10. ALB listener on port 80 works — the day-1 failure was the backend**
Test C: with a healthy target, a second listener on 80 answered exactly like 8080 when curled from inside the Floci container. Floci runs as non-root (`uid=1001`) yet binds 80 because Docker sets `net.ipv4.ip_unprivileged_port_start=0` inside containers (verified: `0`). "WSL2 blocks privileged ports" was a myth. Reaching 80 **from the host** needs `"80:80"` in compose — added during Test A stage 2, and `curl http://localhost/health` now works. The ALB has listeners on 80 and 8080. On real AWS use 80/443; the ALB SG does not allow 8080.

**11. ALB → EC2: Floci must be attached to the VPC network (root cause of the ALB saga)**
Each VPC is a real Docker network (`floci-vpc-{account}-{region}-{vpc-id}`) and the instance holds its real private IP. The ALB runs inside the Floci container and forwards to that IP, so **Floci itself must be on the VPC network**.
Confirmed today: Floci attaches itself when it *creates* the VPC network (first launch in that VPC). After the Floci container was recreated (compose config change), it came back only on `floci_default`; launching a new instance into the already-existing VPC network did not reattach it. Symptom: target `unhealthy / Target.Timeout` while the app is fine; `curl` from inside Floci to the private IP exits `28` (timeout).
Fix: `docker network connect floci-vpc-... floci-ui-floci-1` (loop in the runbook). After it, the target went healthy in ~2 min — consistent with `HealthyThresholdCount 5 × 30 s`. This also best explains yesterday: the target fixes coincided with Floci being on the network. The attachment is runtime-only: it survives `stop`/`start` but not a container recreate. No durable fix known yet.

**12. `docker compose down` vs `docker compose stop`**
- `stop` → containers stop, data preserved, can restart with `start`
- `down` → containers AND networks removed, EC2/ALB containers lost
- `down -v` → also removes named/anonymous volumes. The floci-ui compose uses a **bind mount** (`./data:/app/data`), which `-v` does not delete — Floci state and RDS data under `./data` survive.

**Always use `stop`.**

**13. Security groups are not enforced by default; NACLs never**
By default every container on a Docker network reaches every other on every port — e.g. `psql -h localhost -p 7001` from WSL works although `shortify-rds-sg` only allows the EC2 SG. Floci has an **opt-in** firewall: `FLOCI_NETWORK_SECURITY_GROUP_ENFORCEMENT_ENABLED=true` puts each instance behind default-deny nftables and checks sender egress + receiver ingress. It does not emulate NACLs, and it applies to Docker-backed *instances*.
**Test A stage 2 (flag on, fresh instance launched after enabling it):** SSH worked with **zero** port-22 rules; a brand-new connection from Floci to the instance on 8000 worked with **zero** port-8000 rules; ALB traffic kept flowing; the instance was a plain `bridge` container; nothing about enforcement in the logs. Conclusion: on WSL2 + Docker Desktop the flag is accepted but has **no observable effect**. Not fully excluded: Floci exempting its own container's traffic and published SSH while still filtering instance-to-instance traffic (Open Items). NACL behaviour can only be validated on real AWS.
Tested on this setup — Test A stage 1: with **zero** inbound rules on `shortify-rds-sg`, both `psql` from WSL and the app's writes through the ALB kept working. Test B: a deny-all NACL on PUB1 changed nothing (health `ok`, target `healthy`). On real AWS the first would make the app hang on DB calls; the second would cut the instance off entirely (stateless, both directions).
Related: with enforcement off, Floci publishes CIDR-sourced TCP ingress ports of an instance on host ports 30000–30999 via `alpine/socat` sidecars. Our EC2 SG has none that qualify (22 is never re-forwarded; 8000 is SG-sourced), so no sidecars appear.

**14. Earlier "RDS unreachable = private subnet working" was a wrong conclusion**
The first `psql` from WSL to `172.17.0.2:7001` timed out. That was NOT subnet isolation (Floci doesn't enforce it) — the RDS proxy ports weren't published to the host, and on Docker Desktop/WSL2 container IPs don't answer from the host. Publishing `7001-7099` fixed it.

**15. `short_url` in the API response is wrong behind the ALB**
`main.py` hardcodes `http://localhost:8000/{code}`. Through the ALB the real URL is `http://localhost:8080/{code}` (or the domain in production). Fix later with a `BASE_URL` env var.

**16. AWS CLI pager (`:...skipping...`)**
Long output opens in `less`. Use `--no-cli-pager` or `export AWS_PAGER=""`.

**17. Tags at creation time**
`create-vpc` has no `--tags`, but it does have `--tag-specifications` (it showed up as `TagSpecifications` in the skeleton), e.g.
`aws ec2 create-vpc --cidr-block 10.0.0.0/16 --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=shortify-vpc}]'`. We used the separate `create-tags` call instead — both work. Not yet tested against Floci.

**18. Manual deployment is not reboot-safe (accepted Phase 2 limitation)**
The app is started by hand with `nohup`. Any restart kills it and nothing brings it back — on real AWS too. The real fix is a systemd unit / UserData managed by automation (Phase 3–4). Don't patch it in Phase 2; document it.

**19. `/health` is a shallow health check**
It doesn't touch the database, so the ALB would keep a target `healthy` with RDS down while `/shorten` fails. (It also means the app *crashes at startup* when RDS is unreachable, because `create_all()` runs on import.) Revisit in Phase 6: separate liveness vs readiness.

**20. Non-standard ports are by design**
SSH is on 2200–2299 because every Floci instance shares `127.0.0.1` as public IP; RDS is behind Floci's proxy on 7001–7099 (Postgres itself is on 5432 inside its container, and host 5432 is used by Phase 1's compose). Never hardcode host/port: read them from the API (`describe-db-instances`, `docker ps`). Whether the ranges can be narrowed to 22/5432 is untested.

**21. Unset shell variables expand to nothing — silently**
`--targets Id=$INSTANCE_ID` with `INSTANCE_ID` unset becomes `--targets Id=`, which the API accepts. Guard scripts with `set -u` (unset variable = error) and re-source `shortify-ids.sh` in every new terminal.

**22. Every NACL (and route table) association replace mints a new association ID**
Test B: `aclassoc-32f5…` → `aclassoc-6cdd…` → `aclassoc-4330…`. A subnet always has exactly one NACL; you never add/remove, you *replace the association* — and must capture the `NewAssociationId` to undo it.

**23. The ALB DNS name resolves to IPv6 loopback (`::1`)**
Test E: `getent hosts $ALB_DNS` → `::1` (listed under `localhost.floci.io`). It works only because Docker published 8080 on IPv6 too (`[::]:8080`). On real AWS an ALB name resolves to several public IPs that change — point a Route 53 alias at the name, never hardcode IPs.

**24. `latest-compat` is required for the floci-ui stack**
Test F: `init/ready.d/01-setup.sh` calls the AWS CLI, which only the compat image contains (`aws-cli/2.36.24` inside). That's the best explanation for "Runtime unavailable" on `latest`. The Floci image also has no `ss`/`netstat` (only `curl`) — which is why `ss -tlnp` "showed nothing" on day 1.

**25. `running` is not "ready"**
Launch timeline (from Floci logs): container `running` → +16 s SSH key injected → +34 s sshd started (plus the IMDS `socat` proxy). SSH right after the waiter returns fails with `Connection reset by peer`. Same on real AWS: `running` = hypervisor started the VM; boot, cloud-init and sshd come later — use `aws ec2 wait instance-status-ok` and retry SSH in scripts.

**26. A Floci shutdown stops its instances**
During the stage-2 recreate the instance container was SIGKILLed (`Exited (137)`) at 22:40:25 — 9 s **before** the new Floci started (22:40:34), so it was the *old* Floci stopping it on shutdown, not the new flag. It survived the morning's recreate only because that Floci had no Docker access. Afterwards the API still reported `running` (state out of sync). Implication, **not yet confirmed**: `docker compose stop` at end of session probably stops instances too, so every session may start with "replace the instance".

**27. Don't keep misleading config**
The enforcement flag is still set but does nothing here. Config that claims a control that isn't there creates false confidence. Remove it at the next Floci recreate (not worth a recreate on its own, since a recreate costs an instance replacement).

### Verification test results (day 2)

| Test | Question | Prediction | Result | What it proves |
|---|---|---|---|---|
| Baseline | Does the stack survive a reboot? | — | ❌ Floci lost Docker access; app/sshd gone | `group_add`, runbook, replace-don't-repair |
| G | What do reboot / stop / start / Docker-Desktop-start do to an instance? | No sshd after any of them | Confirmed | Only `run-instances` yields a usable instance |
| ALB saga | Why `Target.Timeout` with a healthy app? | Floci not on VPC network | Confirmed (`curl` exit 28 → reconnect → healthy) | Edge case #11 |
| A (stage 1) | Are SGs enforced by default? | No | No — zero RDS rules, everything worked | SG design untestable in default Floci |
| B | Are NACLs enforced? | No | No — deny-all NACL, everything worked | NACLs only testable on real AWS |
| C | Does a port-80 listener work? | Yes | Yes (from inside Floci) | Day-1 port-80 failure was the backend |
| D1 | Is `Port` required at registration? | No | No — portless target healthy | `Port` is hygiene, not a requirement |
| D2 | Does an empty-ID target break others? | No | No — empty target unhealthy, real one healthy | Day-1 "poisoning" theory refuted |
| E | Does the ALB DNS name work? | Yes, via 127.0.0.1 | Yes, via `::1` | IPv6 publish matters |
| F | Do the init hooks need compat? | Yes | Yes — `01-setup.sh` uses the AWS CLI | Use `latest-compat` |
| A (stage 2) | Does the opt-in SG firewall enforce our design? | SSH denied (P1); ALB path unknown (P2); RDS open (P3) | P1 ✗ SSH worked even with no rule; P2: fresh connection to 8000 worked with no rule; P3 ✓ | Flag has no observable effect on WSL2/Docker Desktop (edge case #13) |
| Launch timing | Why did SSH fail on a fresh launch? | Timing (H1) | ✓ sshd started 34 s after `running` | `running` ≠ ready (#25) |
| Recreate impact | Why did the control instance die? | The new flag | ✗ The old Floci killed it on shutdown, 9 s before the new one started | Floci shutdown stops instances (#26) |
| Port 80 from host | Does `http://localhost/` reach the ALB? | Yes | ✓ | Listener on 80 kept |

### Floci vs real AWS — key differences

| Behavior | Floci | Real AWS |
|----------|-------|----------|
| EC2 SSH port | 2200 (mapped) | 22 |
| EC2 public IP | 127.0.0.1 | Real public IP |
| RDS endpoint | 172.x.x.x:7001 | DNS name:5432 |
| RDS host access | localhost:7001 (with ports exposed) | Private DNS only |
| `--dry-run` | Actually creates resource | Simulates only |
| `create-key-pair` | Real RSA key (save with `--query KeyMaterial --output text`) | Real key |
| EC2 Docker daemon | Not available inside container | Available |
| ALB listener port | 80 and 8080, both published and working from the host | 80/443 |
| Security groups | Not enforced; the opt-in `FLOCI_NETWORK_SECURITY_GROUP_ENFORCEMENT_ENABLED` flag had no observable effect on WSL2/Docker Desktop | Enforced |
| NACLs | Never enforced | Enforced |
| Container IPs from host | Not reachable on Docker Desktop/WSL2 — use published ports | N/A |
| Provisioning time | Instant | 3-10 minutes |
| EC2 after restart/reboot | Filesystem kept, but no sshd/app (no systemd) — replace the instance | sshd back via systemd; hand-started app still lost |
| ALB → instance path | Floci container must be on the VPC Docker network (lost on Floci recreate) | Native VPC routing |

### Production notes (interview talking points)

- **Encryption at rest** should be enabled on RDS (`--storage-encrypted`)
- **Deletion protection** should be enabled on RDS (`--deletion-protection`)
- **Multi-AZ** for RDS in production (`--multi-az`) — not used here due to cost
- **HTTPS** via ACM certificate + Route 53 — skipped in Floci (no real domain), done in Phase 4
- **Port 80 → 443 redirect** at ALB listener level — not the app's responsibility
- **IAM roles** instead of SSH keys for EC2 access — Phase 4 with Ansible
- **Secrets Manager** for DATABASE_URL — Phase 5

---

## Project structure

```
shortify/
├── app/
│   ├── __init__.py
│   ├── main.py        # FastAPI routes — 4 endpoints
│   ├── models.py      # SQLAlchemy model (links table: short_code, original_url, clicks, created_at)
│   └── database.py    # DB connection + session factory
├── Dockerfile         # Multi-stage build, non-root user (important for ECS Fargate later)
├── docker-compose.yml # App + Postgres for local dev only
├── requirements.txt
└── README.md
```

---

## Q&A Knowledge Base

Every question asked during Phases 1–2, deduplicated and grouped by topic. Where an answer I gave during the session was wrong, the corrected version is here and the mistake is listed in the Corrections Log below.

### Project & business

**Q: What real business problem does Shortify solve?**
A marketing agency whose campaign links depend on a third-party shortener has no control over uptime (vendor outage = every campaign link dead), no ownership of click data, and per-link cost at scale. Shortify is their own redirect layer: owned infra, click tracking in their own DB, their own domain.

**Q: Why does the app need a database, and what are "clicks"?**
The DB stores the mapping `short_code → original_url` so it survives restarts. `clicks` starts at 0 and every `GET /{code}` runs the equivalent of `UPDATE links SET clicks = clicks + 1` before returning the 302. That counter is the agency's campaign performance data, owned by them.

**Q: Why build everything manually before Terraform?**
So every Terraform line maps to a resource you've already created by hand and a gotcha you've already hit. Terraform without that context is copying config you can't defend in an interview.

### Phase 1 (local)

**Q: What was the empty `{app,infra}` folder in the tarball?**
A mistake on my side. `mkdir -p shortify/{app,infra}` relies on brace expansion, which the shell in my sandbox (`/bin/sh`) doesn't do, so it created a folder literally named `{app,infra}`. Delete it. `infra/` arrives in Phase 4.

**Q: `docker compose up` looks stuck printing `GET /health` forever — shouldn't it be detached?**
It's working. Those lines are the Dockerfile `HEALTHCHECK` hitting `/health` every 30s. It's attached because you ran `up` without `-d`. Use `docker compose up -d` and `docker compose logs -f` when you want logs.

**Q: `docker-compose.yml` ends abruptly with `volumes: pgdata:` — is something missing?**
No. That's the declaration of the named volume Postgres uses for its data.

**Q: `curl -L` on the short URL dumped a whole HTML page — shouldn't it return the original URL?**
`-L` follows the redirect, so curl downloaded GitHub's homepage. Use `curl -v` without `-L` to see the `302 Found` and `location:` header, which is what the app actually returns.

**Q: Where do I download files you create?**
From the file card in the chat. On mobile it may appear at the bottom.

### Accounts, cost, domains

**Q: Does AWS give free domains for temporary projects?**
No. Route 53 is a paid registrar like any other. Without a domain you can test with the ALB's own DNS name.

**Q: Is everything we're doing free? How do I confirm?**
VPC, subnets, IGW, route tables and security groups have no charge. EC2, RDS, ALB and Route 53 hosted zones do (or consume free-tier/credits). Check **Billing → Free Tier** and create a **Budget → Zero spend budget** so any charge emails you.
Note: my earlier "750 hrs/month for 12 months" figures describe the older free tier. The sign-up screen you saw offers the newer **Free plan: 6 months, up to $200 credits**. Check current AWS pricing pages rather than my numbers.

**Q: Why did the new AWS account fail?**
AWS linked it to your existing identity (card/phone/address) and refused the free plan. That's why we moved to Floci.

### VPC & default VPC

**Q: What is a VPC?**
Virtual Private Cloud — your isolated private network inside AWS where subnets and resources live.

**Q: Doesn't AWS already put me in a VPC? Without one, is my EC2 shared with everyone?**
Every account gets a **default VPC** per region, and resources are isolated per account — nothing is shared with other customers. Every EC2 lives in some VPC (the old non-VPC "EC2-Classic" is retired).

**Q: Why not use the default VPC?**
It only has public subnets (IGW route + auto public IPs) — it's built for "launch and reach it immediately", not for tiering. There's no private tier to put a database in. We built our own so public vs private is a deliberate design, not a default.

**Q: If I create RDS in the default VPC, is it public?**
Not automatically — `PubliclyAccessible` is a separate setting. But it would sit in a public subnet, so it's one toggle plus one loose security group rule away from being exposed. That's the risk. (Earlier I overstated this as "public by default".)

**Q: Why /16 for the VPC when /24 would fit the app?**
Room to grow (more instances, cache, internal tools) and because the primary CIDR block can't be changed after creation. You can add *secondary* CIDR blocks later, but that's messier than sizing right up front. /16 = 65,536 addresses, costs nothing extra.

### Subnets & CIDR

**Q: How does CIDR notation work?**
The number after `/` is how many of the 32 bits are fixed (network part). Remaining bits are host addresses: `/16` → 2¹⁶ = 65,536; `/24` → 2⁸ = 256; `/32` → exactly 1 IP; `/0` → everything.

**Q: How can a /16 VPC contain /24 subnets?**
The /16 is the building (`10.0.0.0–10.0.255.255`); each /24 is a floor carved from it (`10.0.1.x`, `10.0.2.x`…). A subnet is valid as long as it fits inside the VPC range.

**Q: Why `10.0.1.0/24` and not `10.0.1.1/24`? Why `10.0.0.0/16` and not `10.0.1.0/16`?**
A CIDR block must start on its network boundary: all host bits zero. `/24` → last octet `.0`; `/16` → last two octets `.0.0`.

**Q: How many /24 subnets fit in a /16, and how many IPs total?**
256 subnets × 256 = 65,536 addresses. AWS reserves 5 IPs **per subnet** (first 4 + last), so each /24 has 251 usable. AWS also has a default quota of subnets per VPC (I believe 200, adjustable — verify in Service Quotas). (Earlier I wrongly said "a few subnets are reserved, ~251 usable subnets" — the reservation is IPs per subnet, not subnets.)

**Q: What happens if I try to create more subnets than fit?**
AWS rejects the creation (CIDR outside the VPC range, or conflict with an existing subnet).

**Q: What is `255.255.255.0`?**
A subnet mask — the older notation for `/24`. `255` = 8 fixed bits, `0` = 8 free bits. `255.255.0.0` = `/16`.

**Q: Why 4 subnets and not 2?**
Two tiers (public for ALB/EC2, private for RDS) × two Availability Zones. If one AZ (physically separate data center) fails, the other keeps campaign links alive.

**Q: All 4 subnets landed in the same AZ — can I edit them?**
No. A subnet's AZ can't be changed; delete and recreate, specifying the AZ explicitly. Leaving it on "auto" is how they all ended up in `sa-east-1a`.

**Q: `create-subnet` has no "public/private" option — how do I make one public?**
There's no flag. A subnet is public because its route table has `0.0.0.0/0 → IGW`. `MapPublicIpOnLaunch` only controls whether new instances get a public IP automatically.

**Q: Why can't an EC2 be in more than one subnet?**
An instance is one machine in one place. Spreading across subnets/AZs means multiple instances, which is what the ALB distributes across.

### Internet Gateway & route tables

**Q: What connects the VPC to the internet? (VPS? Transit Gateway?)**
An **Internet Gateway**. A VPS is basically what EC2 is (a virtual server). A **Transit Gateway** connects multiple VPCs/networks together — different job.

**Q: What are the IGW steps?**
Create it, attach it to the VPC. It takes no CIDR or VPC at creation time.

**Q: The IGW attaches to the VPC — why do docs talk about subnets?**
The IGW is the building's door. Resources live in subnets, and the **route table** decides which subnets can use the door. Flow: Internet → IGW → VPC → subnet (via route) → resource.

**Q: How many route tables do we need?**
One new one for the public subnets (`0.0.0.0/0 → IGW`). Private subnets stay on the main route table, which only has `10.0.0.0/16 → local`. Internal subnet-to-subnet traffic is already covered by that local route in every table. (Consider an explicit private table — see architecture note.)

**Q: What are the steps for a route table?**
Create it (with the VPC id), add the route (`create-route`), associate it to the public subnets (`associate-route-table`).

**Q: Why is `0.0.0.0/0` the *destination*? Isn't that where traffic comes from?**
In a route table, destination = where the packet is trying to go. `0.0.0.0/0 → IGW` means "anything not inside the VPC, send out the front door".

**Q: What are the other CIDR options in the dropdown (`/8`, `/16`, `::/0`, `pl-...`)?**
Smaller IPv4 ranges; `::` entries are IPv6; `pl-` are AWS managed prefix lists. They're suggestions — you can type any CIDR.

**Q: Why would anyone route something narrower than /0? Doesn't /16 just let random IPs through?**
Yes, a narrower route only matches that range. You use specific CIDRs when you know the destination, e.g. a partner's IP range, and want least privilege. Public-facing traffic uses `/0` because you don't know who'll click a campaign link.

### Security Groups vs Network ACLs

**Q: What's the difference?**
| | Security Group | Network ACL |
|---|---|---|
| Scope | Resource (ENI) | Subnet |
| State | Stateful — return traffic automatic | Stateless — inbound and outbound both explicit |
| Rules | Allow only | Allow and deny, evaluated by number, first match wins |
| Sources | Can reference other SGs | CIDR only |

Mental model: NACL = the building's perimeter fence; SG = the lock on each office door.

**Q: When do I choose one over the other?**
Security groups by default, for everything. NACLs as an optional second layer for blunt subnet-wide rules, e.g. denying a known-bad IP range before it reaches anything. SGs can't deny, NACLs can.

**Q: Why SGs for Shortify?**
We need different rules per resource and "RDS only from EC2" expressed as "from this SG" instead of IP ranges that change. Statefulness also halves the rule count.

**Q: Isn't IAM what controls this?**
No. IAM controls *who can call AWS APIs* (identity). SGs/NACLs control *network traffic*.

**Q: The default NACL allows all — should I change it?**
Left at default for this project. SGs do the real filtering.

**Q: If SGs are stateful, why do I need ALB *outbound* 8000 AND EC2 *inbound* 8000?**
Statefulness only means return traffic of a connection is allowed on the **same** SG. ALB → EC2 is a new connection the ALB initiates, checked by two separate firewalls: the ALB SG (may I send?) and the EC2 SG (may I receive?). Two bouncers, two doors.

**Q: Then why didn't we add an EC2 → RDS outbound rule?**
Every SG gets a default outbound rule `all traffic → 0.0.0.0/0` (you saw it as `IpProtocol: -1`). That already covers EC2 → RDS.
**Honest correction:** the same default rule exists on the ALB SG, so the explicit ALB egress 8000 rule is currently redundant. It only becomes meaningful if you revoke the default egress rule and go least-privilege on outbound — which is the stricter posture and a good Phase 4 improvement. Earlier I presented the ALB egress rule as required; it isn't while the default exists.

**Q: Where does the RDS rule live — EC2 or RDS?**
On the resource **receiving** the connection: RDS SG inbound 5432 from the EC2 SG.

**Q: Why create SGs in the order RDS → EC2 → ALB, and what source do I use if the other SG doesn't exist yet?**
Rules reference other SGs by id, so they must exist. Create all three empty shells first, then add the rules.

**Q: Why attach only `shortify-rds-sg` to RDS and not also `default`?**
Least privilege. The default SG allows inbound from anything else in the default SG and all outbound — you'd be granting access you never designed. (Correction: it does **not** expose the DB to the internet, as I agreed earlier. The problem is unintended access, not internet exposure.)

**Q: Why does the ALB need a security group?**
It's a network resource like EC2. Its SG defines who can reach it (internet on 80/443) and where it can send (EC2 on 8000).

**Q: SSH is TCP? And why not type HTTP/HTTPS as the protocol?**
SG rules work at the transport layer: `tcp`, `udp`, `icmp` (or `-1` all). SSH, HTTP, HTTPS, PostgreSQL all ride on TCP because they need reliable ordered delivery; UDP is for speed-over-reliability (DNS, streaming, games). The console's "HTTP"/"HTTPS"/"SSH" types are just presets for TCP 80/443/22.

**Q: Why does my IP go inside `--cidr` (`x.x.x.x/32`) instead of `0.0.0.0/32` plus an IP flag?**
A CIDR is address + prefix in one value. `/32` = exactly that one IP. `0.0.0.0/32` would literally mean the address 0.0.0.0.

**Q: Should I use `--ip-permissions` instead of `--protocol/--port/--cidr`?**
Either. `--ip-permissions` (JSON) is for complex rules — multiple ports/sources in one call. The shorthand is fine for single rules. (The shorthand on `authorize-security-group-egress` worked on Floci; if real AWS CLI rejects it for egress, use `--ip-permissions`.)

**Q: How do I create an outbound rule?**
`aws ec2 authorize-security-group-egress` — same shape as `-ingress`.

**Q: Why the console warning on `0.0.0.0/0`?**
AWS flags it because it's usually a mistake. For the ALB's 80/443 inbound it's intentional: anyone must be able to click a link.

**Q: Why restrict SSH to my IP?**
Port 22 open to `0.0.0.0/0` gets brute-forced constantly. `/32` of your IP = only you. (Your home IP can change; update the rule when it does.)

### RDS

**Q: Why can't I pick my subnets when creating RDS?**
RDS needs a **DB subnet group** first — an RDS-specific resource listing the subnets (at least 2 AZs) it may live in. Use the private subnets.

**Q: `--db-security-groups` vs `--vpc-security-group-ids`?**
`--db-security-groups` is from EC2-Classic (retired). In a VPC use `--vpc-security-group-ids` with SG **ids**.

**Q: What do I connect to — an IP?**
The **endpoint** (DNS name on real AWS, e.g. `shortify-db.xxxx.sa-east-1.rds.amazonaws.com:5432`). It replaces `db` in `DATABASE_URL`. Don't use IPs; they can change.

**Q: Why port 7001 instead of 5432 on Floci?**
Floci fronts each RDS instance with a TCP proxy on a host port from the 7001–7099 range. Postgres itself listens on 5432 inside its container.

**Q: Why did `psql` from WSL time out at first, and how did we fix it?**
The proxy ports weren't published to the host, and on Docker Desktop/WSL2 container IPs aren't reachable from the host. Publishing `7001-7099:7001-7099` in compose fixed it: `psql -h localhost -p 7001 -U shortify -d shortify`.

**Q: Why is the RDS container outside docker compose?**
Floci creates it on demand through the mounted Docker socket (`/var/run/docker.sock`), so it isn't a compose service. Same for EC2 containers.

**Q: What should be different in production?**
Encryption at rest, deletion protection, Multi-AZ, credentials in Secrets Manager instead of a CLI flag, IAM DB auth optional.

### EC2, keys, SSH

**Q: What must exist before launching EC2?**
A key pair (and the network + SGs). RDS should exist before the app starts because it connects on startup.

**Q: Why ed25519 and .pem? Where do I keep it? Why 600?**
ed25519 is a modern, small, fast key type; `.pem` is the format OpenSSH on WSL uses. Keep it in `~/.ssh/`. `chmod 600` = read/write for owner only; SSH refuses keys readable by others (`Permissions 0644 ... are too open`) because the private key is effectively the password to the server.

**Q: I only got a `.pem` — where's the pair?**
The public key stays with AWS and is placed on the instance; you only download the private half.

**Q: Which subnet for EC2, and why not private?**
Public here, so we can SSH to it directly. **Correction:** I said a private-subnet EC2 would make the ALB unable to reach it — that's wrong. The ALB can reach targets in private subnets; that's actually the recommended production pattern. What you lose is direct SSH from the internet (use SSM or a bastion) and outbound internet without a NAT gateway.

**Q: Do we need a second EC2 in the other AZ?**
For production redundancy, yes. For Phase 2, one is enough; the ALB spans both AZs so the load balancer itself is highly available and more instances can be added later.

**Q: Why is there no public IP on my EC2?**
`MapPublicIpOnLaunch` wasn't enabled on the subnet at launch and it isn't applied retroactively. Enable it (`modify-subnet-attribute --map-public-ip-on-launch`) and relaunch. In Floci the public IP shows as `127.0.0.1`.

**Q: How do I SSH on Floci?**
Floci maps container port 22 to a host port in 2200–2299 (`docker ps --filter name=floci-ec2`). Either key path works (edge case #3): `create-key-pair` saved with `--query KeyMaterial --output text`, or a local key + `import-key-pair`. Then `ssh -i ~/.ssh/shortify-real -p 2200 root@127.0.0.1`, or the `shortify-ec2` alias from the runbook.

**Q: SSH suddenly says "Connection closed" on 2200.**
Docker's port mapping accepted the connection but nothing inside answered: sshd isn't running. That happens after any restart of the instance (edge case #9). Check with `docker exec <container> ps aux`; recover by replacing the instance.

**Q: Can SSH be on 22 and RDS on 5432?**
Not worth it. All Floci instances share `127.0.0.1`, so each needs its own SSH port (range is configurable, but a range of one allows one instance). Postgres already is on 5432 inside its container; 7001 is Floci's proxy, and host 5432 belongs to Phase 1's compose. The real lesson: discover host/port from the API, never hardcode them.

**Q: "REMOTE HOST IDENTIFICATION HAS CHANGED" — am I being attacked?**
No, the recreated instance has a new host key. `ssh-keygen -R '[127.0.0.1]:2200'`.

**Q: How do I get the code onto the EC2? Docker image? S3? ECR?**
For the manual phase, `scp -r` the code. The production answer is a registry — **ECR** — which the Phase 3 pipeline pushes to. S3 is general object storage, not a container registry.

**Q: Why couldn't I `docker build` inside the EC2?**
Floci's EC2 is itself a container (`tail -f /dev/null`) with no Docker daemon running inside. We ran the app with Python directly. (Whether starting `dockerd` manually would work was never tested — Open Items.)

**Q: The app died when I closed SSH / the tunnel said connection refused.**
A foreground or `&` process dies with its SSH session. Use `nohup ... > app.log 2>&1 &`.

**Q: How do I reach port 8000 on the EC2 before the ALB existed?**
Floci only publishes SSH. SSH tunnel: `ssh -i ~/.ssh/shortify-real -p 2200 -L 8080:localhost:8000 root@127.0.0.1`, then `curl localhost:8080`.

**Q: Why use `--break-system-packages` with pip?**
Ubuntu 24.04 blocks system-wide pip installs (PEP 668). Fine for a throwaway box; a venv is the cleaner way. Phase 4/5 moves to containers anyway.

### ALB

**Q: What is an ALB and why do we need it?**
Application Load Balancer. It's the only thing facing the internet, spreads traffic across instances, health-checks them, and stops sending traffic to unhealthy ones. Without it one overloaded or crashed EC2 = dead campaign links.

**Q: The ALB has no subnet of its own?**
It lives in the public subnets (both AZs). EC2 is in one of those.

**Q: What are the pieces and their order?**
Target group (where traffic goes + health check) → register targets → load balancer (subnets + SG) → listener (port + default action forwarding to the target group). The listener needs both to exist.

**Q: Isn't the target group for the ALB rather than EC2?**
It's the ALB's list of destinations: ALB → listener → rule → target group → EC2.

**Q: One target group for HTTP and another for HTTPS?**
One. HTTP vs HTTPS is a listener concern. Both listeners forward to the same target group on 8000; TLS terminates at the ALB.

**Q: Where does the 80 → 443 redirect happen?**
On the port-80 listener: its action is `redirect` to HTTPS instead of `forward`. The EC2 never sees the plain HTTP request. Not built yet — needs a certificate (Open Items).

**Q: Why is the listener port 80 but the target group port 8000?**
Listener = what the internet hits. Target group = the app's port. The ALB translates.

**Q: The health check port — 80 or 8000?**
8000, where the app listens. Path `/health`.

**Q: Why did the target stay unhealthy, and what fixed it?**
Day 1: two changes were made at once (removed an empty-id target, re-registered with `Port=8000`) and it went healthy; I credited the empty target — a guess. Day 2 found the real mechanism: the Floci container (where the ALB runs) was not attached to the VPC Docker network, so health checks timed out (`curl` exit 28). `docker network connect` fixed it, and the target turned healthy ~2 min later with a stale target still registered. So: network + threshold timing, not the stale target (edge cases #7, #11).

**Q: The `target-in-service` waiter looks stuck.**
Waiters print nothing while polling (by default ~every 15 s for up to ~10 min). Silence = "not healthy yet". Ctrl+C and debug hop by hop from the ALB inwards (runbook).

**Q: Why did the health check stay `unhealthy` for a while after the fix?**
`HealthyThresholdCount 5` × `30 s` interval ≈ 2.5 min of consecutive passes, counted from the first success.

**Q: Can I use it from the browser?**
`http://localhost:8080/health` works. `/shorten` is a POST, which the address bar can't send — use curl, DevTools `fetch`, or a REST client.

### AWS CLI & Floci mechanics

**Q: `aws configure list` shows credentials as `env` — and they vanished later.**
`export` only lives for that shell session. `aws configure` writes `~/.aws/`. We use `eval $(floci env)` from `~/.bashrc`.

**Q: How do I make the endpoint permanent?**
`eval $(floci env)` in `~/.bashrc` (it sets the endpoint and fake creds).

**Q: How do I tell which parameters are required?**
`aws <service> <command> help` → SYNOPSIS: anything in `[brackets]` is optional. `--generate-cli-skeleton` shows the full shape but not what's required.

**Q: How do I list resources without the interactive pager?**
`--output table` (or `text`) for readability, and `--no-cli-pager` / `export AWS_PAGER=""` to stop `less` opening.

**Q: Why aren't my tags showing?**
In this case you'd tagged the VPC id instead of the route table id. (I first told you tags don't appear in table output — wrong, they do.)

**Q: `--dry-run` created the subnet?!**
Floci doesn't implement dry-run; it executes. Don't use it on Floci.

**Q: Why did everything disappear after restarting Floci the first time?**
`floci start` defaults to in-memory storage. We moved to compose with `FLOCI_STORAGE_MODE: persistent`.

**Q: Why did the floci-ui not see the new Floci instance?**
It was talking to its own Floci. We switched to running Floci *from* the floci-ui compose file and added the port ranges there.

**Q: `latest` vs `latest-compat` image?**
Per the Floci docs, compat = the standard image + Python 3, AWS CLI and boto3; startup and memory are identical. The floci-ui init hooks (`init/ready.d`) run AWS CLI commands at startup (`make_bucket`, `upload:` in the logs), which the standard image can't run — the leading hypothesis for "Runtime unavailable" on `latest`. The TLS permission warning is **not** it: it also appears on `latest-compat` and is non-fatal. Use `latest-compat` with floci-ui.

**Q: Is the instance-restart problem caused by `latest` vs `latest-compat`?**
No — different image. `latest`/`latest-compat` is Floci's own container. The instance's image comes from the AMI (`ami-ubuntu2404-amd64` → plain `ubuntu:24.04`, no systemd), and that's what decides boot behaviour.

**Q: Why does RDS come back after restart but EC2 doesn't?**
RDS: Postgres is started by its container's own entrypoint, and Floci's restore reattaches its proxy — **provided Floci can reach Docker** (day 2 it couldn't, see the socket note). Postgres even did WAL crash recovery after an unclean shutdown, with data intact. EC2: the container can come back (same filesystem), but sshd and the app were started by Floci's *launch* routine and by hand, and nothing restarts them (edge case #9). On real AWS both survive a reboot; only the hand-started app would be lost.

**Q: Why were we going in circles on day 2?**
Because day 1's "fix" was never root-caused. Two environment changes surfaced it: the Docker socket permission reset on reboot (Floci lost Docker), and recreating the Floci container dropped its VPC network attachment. Both are now in the runbook.

**Q: How does the ALB reach the EC2 in Floci?**
Each VPC gets a real Docker network (`floci-vpc-<acct>-<region>-<vpc-id>`) and the EC2 container holds its real private IP (`10.0.1.12`). Floci itself must be on that network too (`10.0.0.2`) to forward to the instance's private IP — and loses that attachment when its container is recreated (edge case #11). **Correction:** I said EC2 containers are only on the default bridge and ALB→EC2 was an unfixable Floci limitation. Wrong — `docker inspect` showed the EC2 on bridge, the VPC network and `floci_default`.

**Q: How can Floci bind port 80 if it doesn't run as root?**
Inside Docker containers `net.ipv4.ip_unprivileged_port_start` is `0`, so any process may bind low ports. On a normal Linux host only root (or `CAP_NET_BIND_SERVICE`) can bind below 1024.

**Q: Why did the NACL association ID keep changing?**
Every `replace-network-acl-association` creates a new association. Always capture `NewAssociationId` if you need to undo it.

**Q: What does `Target.Port: None` mean?**
The target was registered without an explicit port; the ALB uses the target group's port (8000).

**Q: `InitialHealthChecking` vs `RegistrationInProgress`?**
The first means a new target is being checked (wait ~5 × 30 s). The second, if it never changes, means the instance behind it is gone.

**Q: Why did SSH fail right after launching a new instance?**
The waiter returns at `running`, but Floci injects the key and starts sshd ~15–35 s later. Retry SSH in a loop (runbook). On AWS: `wait instance-status-ok`.

**Q: Why did the instance die when we recreated Floci?**
The old Floci stops its instances when it shuts down; the timestamps show the kill 9 s before the new Floci started. Plan an instance replacement after any Floci recreate.

**Q: Does Floci's security-group enforcement work here?**
Not observably. With the flag on and a freshly launched instance, SSH and port 8000 stayed reachable with no allowing rules. Treat SG rules as design until validated on real AWS.

**Q: Why test NACLs if we never configured one?**
Every VPC has a default allow-all NACL and every subnet is always associated with exactly one. The test swaps in a deny-all NACL to see whether Floci honours it (it doesn't).

---

## Corrections Log

Things I told you during the session that were wrong or overstated. Kept here so future-you doesn't repeat them in an interview.

| # | What I said | What's actually true |
|---|---|---|
| 1 | `{app,infra}` was just a shell expansion bug | Correct, but cause is specifically that `/bin/sh` has no brace expansion |
| 2 | Default VPC → RDS "publicly accessible by default" | Only public subnets exist there; `PubliclyAccessible` is a separate setting |
| 3 | "VPC CIDR cannot be changed" | Primary can't; secondary CIDR blocks can be added |
| 4 | "~251 usable /24 subnets in a /16" | 256 subnets fit; the 5-reserved rule is IPs per subnet |
| 5 | Build order "outside-in: IGW → VPC → subnets" | That's traffic flow. Build order is VPC → subnets → IGW → routes → SGs → resources |
| 6 | Agreed "default SG exposes to the internet" | It allows traffic from the same SG + all outbound; issue is unintended access |
| 7 | ALB egress 8000 is required | Redundant while the default allow-all egress exists |
| 8 | EC2 in private subnet → ALB can't reach it | ALB can reach private targets; that's the recommended pattern |
| 9 | psql timeout = "private subnet design working" | Floci doesn't enforce subnets/SGs; ports just weren't published |
| 10 | "Tags don't show in table output" | They do; the wrong resource had been tagged |
| 11 | Port 80 listener failed due to WSL2 privileged ports | Never confirmed; target was unhealthy at the time |
| 12 | `latest` image uses a different hostname | Never confirmed |
| 13 | EC2 containers only on bridge; ALB→EC2 impossible in Floci | EC2 was on the VPC network; it worked |
| 14 | Empty target "poisoned" health checks | Hypothesis; fix not isolated from the `Port=8000` change |
| 15 | `docker compose up` destroyed EC2/RDS in the last session | Unverified; screenshot shows both containers existing but stopped |
| 16 | `.gitignore` ignores `.terraform.lock.hcl` | The lock file should be **committed**; fix before Phase 4 |
| 17 | "Floci ALB is metadata only, no traffic" | It does forward real traffic once the target is healthy |
| 18 | Floci `CreateKeyPair` returns dummy keys | Docs: real RSA key; our failure was most likely saving `\n` literally |
| 19 | Floci can't enforce security groups | Opt-in enforcement exists (`FLOCI_NETWORK_SECURITY_GROUP_ENFORCEMENT_ENABLED`); NACLs are the ones never enforced |
| 20 | "You used `up` instead of `start`, so the containers are gone" (day 2 morning) | They existed, stopped after a reboot; Floci had lost Docker access |
| 21 | Fixed `sleep` in scripts is fine | Caused a stop/start race; use waiters |
| 22 | Row 14's stale-target theory | Refuted for a stale terminated target; real cause was the VPC network attachment. Empty-ID case untested |
| 23 | `chmod 666` fixes the Docker socket | Undone on every Docker restart; `group_add` is the durable fix |
| 24 | Port 80 failed because of WSL2 privileged ports | Test C: 80 works; Docker allows unprivileged low ports in containers |
| 25 | `ss` showing nothing was a mystery | `ss`/`netstat` aren't installed in the Floci image |
| 26 | ALB DNS resolves to `127.0.0.1` | Resolves to `::1` (IPv6 loopback) |
| 27 | Empty-ID target poisons health checks | Test D2: it doesn't; health is per target |
| 28 | With enforcement on, SSH from WSL would be denied (P1) | SSH worked even with no port-22 rule — the flag had no effect |
| 29 | The enforcement flag killed the control instance | The old Floci's shutdown did, 9 s before the new Floci started |
| 30 | SSH failing after launch meant the firewall blocked it | sshd simply wasn't up yet (+34 s) |

---

## Open Items (unknown / not yet verified)

**Resolved on day 2**
- ALB health mystery → Floci not attached to the VPC network + health threshold timing (edge case #11).
- Instance lifecycle → tested reboot, stop/start, Docker Desktop start (edge case #9).
- Docker socket → `group_add` (Floci setup).
- Subnets per VPC → 200 default, adjustable; 5 IPv4 CIDR blocks per VPC (primary + secondary).
- Egress shorthand flags → the CLI parses flags client-side, so it's the same CLI for Floci and AWS.

**Resolved by the day-2 verification tests** (see the results table): D1, D2, port 80, ALB DNS name, compat requirement, `ss` mystery.

**Still open**
1. **Enforcement flag — last alternative:** does Floci filter *instance-to-instance* traffic even though its own traffic and published SSH are unfiltered? Test: two instances, curl between them on 8000 with the rule revoked. Then remove the flag at the next recreate.
1b. **Does `docker compose stop` also stop instances?** (#26) — confirm deliberately at the end of the next session.
2. **Durable fix for the VPC network attachment** after a Floci recreate (today: runbook reconnect loop).
3. **NACL behaviour** — only testable on real AWS.
4. **Would real AWS reject `--targets Id=`?** Probably (validation error) — untested.
5. **`restart: unless-stopped`** for the Floci services — does Floci then come back on its own after a reboot and restore RDS cleanly?
6. **`down`/`up` behaviour** with the socket-fixed setup — deliberately not re-tested.
7. **systemd AMI** (`ami-ubuntu2404-cloud`, listed arm64-only) — does it run on x86_64 and survive reboots?
8. **SSH/RDS port ranges** — can they be narrowed; does `create-db-instance --port` affect Floci's proxy?
9. **`PreviousState: stopped`** reported right after an API reboot — Floci state inconsistency?
10. **Docker inside the Floci EC2** — could `dockerd` be started manually?
11. **HTTPS listener + 80→443 redirect** with a Floci ACM cert.
12. **Current AWS pricing/free-tier numbers** quoted from memory — unverified.
13. **`short_url` returns `localhost:8000`** behind the ALB — needs a `BASE_URL` env var.
14. **Push the repo to GitHub** — first step of Phase 3.
