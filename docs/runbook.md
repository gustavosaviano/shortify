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
- **Only one Floci:** there must be exactly one Floci stack. An old standalone `~/workspace/floci` stack was still being started by `.bashrc`, and it had to be deleted (along with its `floci_floci-data` volume).

Put only the AWS CLI configuration in `~/.bashrc`, plus a named start command. Don't auto-start the stack on every shell: a hidden start that silences its errors failed invisibly and started the wrong stack.

```bash
cat >> ~/.bashrc << 'RC'
eval "$(floci env)"
shortify_up() { (cd ~/workspace/floci-ui && docker compose start) && source ~/workspace/shortify-phase1/shortify/scripts/shortify-env.sh && bash ~/workspace/shortify-phase1/shortify/scripts/floci-network-check.sh && bash ~/workspace/shortify-phase1/shortify/scripts/floci-instance-check.sh; }
shortify_replace() { bash ~/workspace/shortify-phase1/shortify/scripts/floci-replace-instance.sh && source ~/workspace/shortify-phase1/shortify/scripts/shortify-env.sh; }
RC
source ~/.bashrc
type shortify_up                            # prints the function
aws s3 ls                                   # empty output, no error
curl http://localhost:4566/_floci/health    # every service "running"
```

**GitHub CLI:** install `gh` from GitHub's apt repository, never Ubuntu's package (broken upstream, edge case #45). Verify the key before trusting it; the checksum and fingerprints are published at the top of `docs/install_linux.md` in `cli/cli`.

```bash
out=$(mktemp)
wget -nv -O "$out" https://cli.github.com/packages/githubcli-archive-keyring.gpg
echo "6084d5d7bd8e288441e0e94fc6275570895da18e6751f70f057485dc2d1a811b  $out" | sha256sum -c -   # must print OK
gpg --show-keys "$out"      # fingerprints 2C6106201985B60E6C7AC87323F3D4EA75716059 and 7F38BBB59D064DBCB3D84D725612B36462313325
sudo install -D -m 644 "$out" /etc/apt/keyrings/githubcli-archive-keyring.gpg && rm -f "$out"
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt update && sudo apt install gh -y
apt-cache policy gh | head -6    # installed version must come from cli.github.com
gh auth status
```

---

## 2. Session helpers

Shell variables die with the terminal. `scripts/shortify-env.sh` (in the repo) exports the IDs from `terraform output`, so they always match what Terraform built. It's all-or-nothing: if the state or any output is missing, it prints an error and exports nothing, so an empty or `None` ID can't reach a command (edge case #22). `shortify_up` sources it.

```bash
source ~/workspace/shortify-phase1/shortify/scripts/shortify-env.sh
env | grep -E '^(VPC_ID|PUB[12]|ALB_SG|EC2_SG|RDS_SG|TG_ARN|ALB_DNS|DB_PORT|DB_SECRET|INSTANCE_ID)=' | sort   # 11 lines
```

When `outputs.tf` gains or renames an output the runbook uses, update the script in the same PR. `INSTANCE_ID` comes from the `instance_id` output. The instance's SSH host port doesn't come from Terraform: `docker port floci-ec2-$INSTANCE_ID 22/tcp`.

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

## 3. Start of session (also after a PC restart)

```bash
cd ~/workspace/shortify-phase1/shortify                                        # repo root: the terraform -chdir commands are relative to it
shortify_up                                                                    # starts the stack, loads the IDs, checks the instance
docker exec floci-ui-floci-1 id                                               # must list the docker.sock gid
docker logs floci-ui-floci-1 --since 5m 2>&1 | grep -i "no docker daemon"     # must print nothing
```

`shortify_up` first runs `scripts/floci-network-check.sh`: if a Floci recreate dropped the container's attachment to the VPC network, it reconnects it, then verifies the attachment and fails if it's still missing (edge case #11). Unlike the instance check it repairs, because the fix is idempotent and destroys nothing, so there is no plan to read. It then ends with `scripts/floci-instance-check.sh`, a read-only Floci check of the instance container and its sshd listener; its exit code says whether the session is ready. **Expect it to report the instance as not usable after any Floci stop or PC restart** (edge case #26). Nothing else will tell you: after a PC restart the API still said `running` and `terraform plan` was clean (#48). The platform (VPC, ALB, RDS with its data) comes back by itself; an instance never does (#9). The check detects and tells, it never replaces: replacing is a plan to read first.

**If the check says not usable, replace the instance** (replace, don't repair): run `shortify_replace` (`scripts/floci-replace-instance.sh`). It refuses any plan that does more than replace the instance, asks before applying, clears the host key, waits for sshd and checks the key, then the function re-sources the IDs (a script can't change its caller's variables). Then deploy (section 11). The commands it runs:

```bash
terraform -chdir=infra/terraform plan -replace=aws_instance.app -out tfplan     # read it: 1 to add, 1 to destroy
terraform -chdir=infra/terraform apply tfplan && rm -f infra/terraform/tfplan
source scripts/shortify-env.sh                                                  # the new INSTANCE_ID
SSH_PORT=$(docker port floci-ec2-$INSTANCE_ID 22/tcp | head -1 | sed 's/.*://'); ssh-keygen -R "[127.0.0.1]:$SSH_PORT"   # new host key, often the same port
bash scripts/floci-instance-check.sh                                            # "usable" once sshd is up: ~25-35 s after launch (#25); re-run until then
```

Then check the key (section 9). The app itself is deployed separately (Phase 4: Ansible); until then the instance has no app and isn't registered in the target group.

**Baseline, once the app is deployed and registered.** This must pass before any work or test:

```bash
curl -s http://localhost/health
aws elbv2 describe-target-health --target-group-arn $TG_ARN --query 'TargetHealthDescriptions[].[Target.Id,Target.Port,TargetHealth.State]' --output text
```

The database needs the password from Secrets Manager for `psql` (section 6).

## End of session

```bash
cd ~/workspace/floci-ui && docker compose stop
```

**Simulating a machine reboot:** quit Docker Desktop first, then `wsl --shutdown` from PowerShell, then start Docker Desktop and wait for "Engine running". Running `wsl --shutdown` while Docker Desktop is running leaves it hung at "Turning off the Docker Engine" until its processes are killed.

---

## 4. After the Floci container is recreated

Any compose configuration change or a `down`/`up` recreates Floci. Two things follow:

- The old Floci stops the instances on its way out, so plan an instance replacement.
- The new Floci must be reconnected to every VPC network. Otherwise the ALB can't reach any instance (health checks fail with `Target.Timeout`).

```bash
bash scripts/floci-network-check.sh        # reconnects Floci to the VPC network if needed, then verifies it (shortify_up runs it too)
docker inspect floci-ui-floci-1 --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{$v.IPAddress}}{{"\n"}}{{end}}'
```

---

## 5. Replace the instance

> **Phase 4:** the instance is now managed by Terraform. Replace it with `terraform plan -replace=aws_instance.app -out tfplan` (section 9). The CLI steps below are the manual Phase 2 path, kept until Ansible takes over the deploy.

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
DB_SECRET=$(aws rds describe-db-instances --db-instance-identifier shortify-db --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text)
PGPASSWORD=$(aws secretsmanager get-secret-value --secret-id "$DB_SECRET" --query SecretString --output text | python3 -c "import json,sys; print(json.load(sys.stdin)['password'])") \
  psql -h localhost -p 7001 -U shortify -d shortify -P pager=off -c "select short_code, clicks from links;"   # read the password fresh, never save it (edge case #41)

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

---

## 8. Running the tests locally

The project targets Python 3.12; the laptop may have another version. Run exactly what CI runs, in a container:

```bash
cd ~/workspace/shortify-phase1/shortify
docker compose up -d db
docker run --rm --network shortify_default \
  -e DATABASE_URL=postgresql://shortify:shortify@db:5432/shortify \
  -v "$PWD":/src -w /src python:3.12-slim \
  sh -c "pip install -q -r requirements-dev.txt && ruff check app tests && pytest -q -p no:cacheprovider"
docker compose down
```

Every change to `main` goes branch → pull request → green `Lint`, `Test` and `Terraform` → merge (enforced by the `protect-main` ruleset).

## 9. Terraform workflow

```bash
cd ~/workspace/shortify-phase1/shortify/infra/terraform
cat terraform.tfvars          # git-ignored; must contain:
#   admin_cidr                     = "<your public IP>/32"
#   emulator_revoke_default_egress = true      # Floci only (edge case #34)
#   emulator_rds_unsupported_settings = true   # Floci only (edge case #43)
#   emulator_key_pair_create_tags     = true   # Floci only (edge case #47)
#   ssh_public_key                    = "ssh-ed25519 ..."   # contents of ~/.ssh/shortify-real.pub, never a path
#   app_ami_id                        = "ami-ubuntu2404-amd64"   # Floci's AMI; on AWS the pipeline passes the image it built

terraform fmt -check && terraform validate
terraform plan -out tfplan    # read it; look for "forces replacement"
terraform apply tfplan        # applies exactly the reviewed plan
terraform output
```

- CI runs `terraform fmt -check -recursive -diff`, `terraform init -backend=false -lockfile=readonly` and `terraform validate` on every PR (required check `Terraform`). Run the same locally before pushing; locally, `fmt -check` also covers `terraform.tfvars`, which CI never sees.
- The provider reads `AWS_ENDPOINT_URL` and the test credentials from the shell: the code has no Floci settings.
- The database password lives only in Secrets Manager: every `psql` against the Terraform-built database needs the `PGPASSWORD=…` prefix from section 6.
- A failed plan still writes its `-out` file, marked errored. Judge a plan by its exit code, never by the file, and delete leftovers (edge case #44).
- Never commit `terraform.tfstate`, `tfplan`, `terraform.tfvars` or `tf-debug.log`. Commit `.terraform.lock.hcl`.
- Recreate one resource on purpose: `terraform plan -replace=<address> -out tfplan`.
- Set `ssh_public_key` without typing it: `printf 'ssh_public_key = "%s"\n' "$(cat ~/.ssh/shortify-real.pub)" >> terraform.tfvars`, then `terraform fmt terraform.tfvars` (an unformatted file makes `fmt -check` print it, admin IP included: edge case #37).
- Rotate the admin key: generate a new key, update `ssh_public_key`, plan. The key pair is replaced (AWS can't update key material) and the instance with it (`replace_triggered_by`: keys are only installed at launch); on Floci the tag workaround re-runs (#47).
- Replace the app instance (replace, don't repair): `terraform plan -replace=aws_instance.app -out tfplan`, read it, `terraform apply tfplan`.
- Check that a new instance trusts the Terraform key: `ssh -i ~/.ssh/shortify-real -p "$(docker port floci-ec2-$INSTANCE_ID 22/tcp | head -1 | sed 's/.*://')" -o BatchMode=yes root@127.0.0.1 'ssh-keygen -lf /root/.ssh/authorized_keys'` must print exactly one line, with the same fingerprint as `ssh-keygen -lf ~/.ssh/shortify-real.pub`.
- Check that IMDSv2 is required: `aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[].Instances[].MetadataOptions.[State,HttpTokens]' --output text` must print `applied required`. On Floci a tokenless request still succeeds (edge case #49); that part is only checked on AWS.
- Stop a running Terraform with **one** Ctrl+C; two can corrupt the state.
- Debug the API calls: `TF_LOG=DEBUG TF_LOG_PATH=tf-debug.log terraform apply tfplan` (delete the log afterwards).
- Check that no default allow-all egress rule survived:
  ```bash
  for sg in alb app db; do SG=$(terraform output -json security_group_ids | python3 -c "import json,sys; print(json.load(sys.stdin)['$sg'])")
    echo "== $sg"; aws ec2 describe-security-groups --group-ids $SG --query 'SecurityGroups[0].IpPermissionsEgress[].[IpProtocol,FromPort,ToPort]' --output text; done
  ```

## 10. Resetting Floci to an empty account

Used once before Phase 4 so Terraform builds everything from nothing:

```bash
cd ~/workspace/floci-ui && docker compose stop
docker ps -aq --filter name=floci-ec2 --filter name=floci-rds | xargs -r docker rm -f
docker network ls --format '{{.Name}}' | grep '^floci-vpc-' | xargs -r docker network rm
sudo find data -mindepth 1 -delete          # empty the state, keep the folder and its permissions
docker compose up -d
aws ec2 describe-vpcs --query 'Vpcs[].[VpcId,IsDefault]' --output text   # only the default VPC
```

## 11. Deploying the app with Ansible

```bash
python3 -m venv ~/.venvs/shortify-ansible && ~/.venvs/shortify-ansible/bin/pip install -r infra/ansible/requirements.txt   # once per machine
A=~/.venvs/shortify-ansible/bin
echo "$ANSIBLE_CONFIG"                        # must point at infra/ansible/ansible.cfg (shortify-env.sh sets it, edge case #50)
$A/ansible app -m ansible.builtin.ping        # SSH and Python on the instance
$A/ansible-playbook infra/ansible/app.yml     # deploys the committed code; a second run for the same commit reports changed=0 (the first run after HEAD moves deploys a new release, even for a docs-only commit)
bash scripts/release-register.sh               # cutover: register the instance, wait until in service, deregister every other target, verify through the ALB
```

- Commit first: the playbook deploys `HEAD` and refuses uncommitted changes in `app/` or `requirements.txt`.
- The playbook fails if `/health` doesn't answer within 60 s. The app's log is `/var/log/shortify/app.log` on Floci (`journalctl -u shortify` on AWS).
- A replaced instance has no app: run the playbook after `shortify_replace`.
- On Floci, `/usr/local/sbin/shortify-floci status|stop|start` controls the app by hand (edge case #53).
