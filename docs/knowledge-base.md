# Knowledge base

Networking and AWS concepts that came up while building Phases 1–2, in question-and-answer form. Floci-specific behavior is covered in [edge-cases.md](edge-cases.md).

## Contents

- [Project and app](#project-and-app)
- [Cost and accounts](#cost-and-accounts)
- [VPC](#vpc)
- [Subnets and CIDR](#subnets-and-cidr)
- [Internet gateway and route tables](#internet-gateway-and-route-tables)
- [Security groups and network ACLs](#security-groups-and-network-acls)
- [RDS](#rds)
- [EC2 and SSH](#ec2-and-ssh)
- [Application Load Balancer](#application-load-balancer)
- [AWS CLI](#aws-cli)
- [Docker and local setup](#docker-and-local-setup)
- [CI and GitHub Actions](#ci-and-github-actions)
- [Terraform](#terraform)

---

## Project and app

**Why does a URL shortener need a database?**
To persist the `short_code → original_url` mapping across restarts, and to count clicks. Every redirect runs the equivalent of `UPDATE links SET clicks = clicks + 1`. That counter is the agency's campaign data, in its own database.

**Why build everything by hand before writing Terraform?**
So each line of IaC maps to a resource that has already been created, broken and understood. IaC written without that context is configuration nobody can defend.

**Why does `curl -L` on a short link print a whole web page?**
`-L` follows the redirect, so curl downloads the destination page. `curl -v` without `-L` shows what the app actually returns: `302 Found` plus a `location:` header.

**Why does `docker compose up` keep printing `GET /health`?**
That's the Dockerfile `HEALTHCHECK` running every 30 s. Use `up -d` to run detached, and `docker compose logs -f` to watch the logs.

---

## Cost and accounts

**Is any of this free on AWS?**
VPCs, subnets, internet gateways, route tables and security groups have no charge. EC2, RDS, load balancers and Route 53 hosted zones cost money, or consume free-tier credits. Newer accounts get a credit-based free plan rather than the older "12 months of 750 hours". Check current pricing directly.

**How do I avoid surprise bills?**
Billing → Budgets → *Zero spend budget*. It emails you when any charge appears.

**Does AWS provide free domains?**
No. Route 53 is a paid registrar. Without a domain, test with the load balancer's DNS name.

---

## VPC

**What is a VPC?**
A Virtual Private Cloud: an isolated private network within an AWS account and region, where subnets and resources live.

**Without my own VPC, are my instances shared with other customers?**
No. Every account has a *default VPC* per region, and resources are isolated per account. Every EC2 instance lives in some VPC.

**Why not use the default VPC?**
It contains only public subnets (a route to the internet gateway, plus automatic public IPs). It's built for "launch and connect immediately", not for separating tiers. There's no private tier for a database.

**Is RDS in the default VPC public?**
Not automatically, because `PubliclyAccessible` is a separate setting. But it sits in a public subnet, one setting and one loose security group rule away from exposure.

**Why a `/16` VPC when a `/24` would fit today?**
The primary CIDR can't be changed after creation. Secondary blocks can be added (5 per VPC by default), but that's messier than sizing correctly upfront. Address space costs nothing.

---

## Subnets and CIDR

**How does CIDR notation work?**
The number after `/` is how many of the 32 bits are fixed, the network part. The rest are host addresses: `/16` is 2¹⁶ = 65,536 addresses, `/24` is 256, `/32` is exactly one, and `/0` is everything.

**How can a `/16` contain `/24` subnets?**
The `/16` is the building (`10.0.0.0`–`10.0.255.255`), and each `/24` is a floor (`10.0.1.x`, `10.0.2.x`, …). A subnet is valid as long as it fits inside the VPC range.

**Why `10.0.1.0/24` and not `10.0.1.1/24`?**
A CIDR block must start on its boundary, with all host bits zero. For `/24` that means the last octet is `.0`; for `/16`, the last two octets are `.0.0`.

**How many `/24` subnets fit in a `/16`?**
256. AWS reserves 5 addresses **per subnet** (the first 4 and the last one), leaving 251 usable per `/24`. The default quota is 200 subnets per VPC, and it's adjustable.

**What is `255.255.255.0`?**
A subnet mask, the older notation for `/24`. `255` means 8 fixed bits; `0` means 8 free bits.

**Why four subnets?**
Two tiers (public for the load balancer and app, private for the database) times two availability zones. If one AZ, a physically separate data center, fails, the other keeps serving.

**Can a subnet's AZ be changed?**
No. Delete it and recreate it with `--availability-zone` set explicitly.

**What makes a subnet "public"?**
A route table entry `0.0.0.0/0 → internet gateway`. There's no public/private flag. `MapPublicIpOnLaunch` only controls whether new instances get a public IP automatically.

**Why can't an instance span two subnets?**
It's one machine in one place. Spreading across AZs means multiple instances behind a load balancer.

---

## Internet gateway and route tables

**What connects a VPC to the internet?**
An internet gateway. You create it, then attach it to the VPC. It isn't a Transit Gateway, which connects VPCs and networks to each other, and it isn't a VPS, which is what an EC2 instance is.

**If the gateway attaches to the VPC, what decides which subnets can use it?**
Route tables. The gateway is the door; a route to it is what lets a subnet use the door.

**How many route tables does this design need?**
One new table for the public subnets, with `0.0.0.0/0 → IGW`. Private subnets use the main table, which has only `10.0.0.0/16 → local`. Traffic between subnets is covered by that local route in every table. An explicit private table is safer, because adding an internet route to the main table would silently make every implicitly associated subnet public.

**Why is `0.0.0.0/0` the *destination*?**
In a route table, the destination is where the packet is going. `0.0.0.0/0 → IGW` means "anything outside the VPC goes out the front door".

**Why route a narrower range than `/0`?**
When the destination is known, for example a partner's IP range, and only that should match. Public-facing traffic uses `/0` because anyone can click a campaign link.

---

## Security groups and network ACLs

**What's the difference?**

| | Security group | Network ACL |
|---|---|---|
| Applies to | A resource (network interface) | A subnet |
| State | Stateful: return traffic is automatic | Stateless: both directions explicit |
| Rules | Allow only | Allow and deny, evaluated by number, first match wins |
| Sources | CIDRs or other security groups | CIDRs only |

A useful mental model: the NACL is the building's perimeter fence, and a security group is the lock on each office door.

**When should each be used?**
Security groups for everything, by default. NACLs as an optional second layer for blunt, subnet-wide rules, such as denying a known-bad range, because security groups can't deny.

**Does every subnet have a NACL even if none was configured?**
Yes. Every VPC gets a default allow-all NACL, and every subnet is always associated with exactly one NACL. Changing it means replacing the association.

**Isn't IAM what controls this?**
No. IAM controls who can call AWS APIs. Security groups and NACLs control network traffic.

**Security groups are stateful, so why do both the ALB outbound 8000 and the EC2 inbound 8000 rules exist?**
Statefulness covers the *return* traffic of a connection on the *same* group. ALB → EC2 is a new connection, checked by two separate firewalls: the ALB group ("may I send?") and the EC2 group ("may I receive?").

**Then why is there no EC2 → RDS outbound rule?**
Every security group starts with a default egress rule allowing all traffic (`IpProtocol: -1` to `0.0.0.0/0`). That same default makes the explicit ALB egress rule redundant too. It only matters once the default egress rule is revoked, which is the stricter, least-privilege posture.

**Where does a rule for EC2 → RDS go?**
On the receiver: the RDS group allows inbound 5432 from the EC2 group.

**In what order are the groups created?**
Create all the shells first (RDS, EC2, ALB), then add rules, because rules reference groups by ID.

**Why not attach the VPC's default security group too?**
It allows inbound traffic from anything else in the default group, plus all outbound: access nobody designed. It doesn't expose anything to the internet, but it's unintended access.

**Why does the load balancer need a security group?**
It's a network resource. Its group defines who can reach it (80/443 from anywhere) and where it can send (the app on 8000).

**Why "tcp" and not "http" as the protocol?**
Security groups work at the transport layer: `tcp`, `udp`, `icmp`, or `-1` for all. SSH, HTTP, HTTPS and PostgreSQL all run over TCP because they need reliable, ordered delivery. The console's "HTTP" and "SSH" types are just presets for TCP 80 and 22.

**Why does an IP go inside `--cidr` as `x.x.x.x/32`?**
A CIDR is an address plus a prefix length in one value; `/32` means exactly that address.

**`--ip-permissions` or `--protocol/--port/--cidr`?**
Either one. The JSON form handles multiple ports or sources in one call. The CLI parses these flags on the client, so the same syntax works against Floci and against AWS.

**Why the console warning on `0.0.0.0/0`?**
It's usually a mistake. For the load balancer's 80/443 it's intentional.

**Why restrict SSH to one IP?**
Port 22 open to the world gets brute-forced constantly. Home IPs change, so update the rule when yours does. The better pattern is no SSH at all: use SSM Session Manager.

---

## RDS

**Why can't subnets be picked directly when creating RDS?**
RDS needs a *DB subnet group* listing its allowed subnets (at least two AZs). Use the private ones.

**`--db-security-groups` or `--vpc-security-group-ids`?**
`--db-security-groups` belongs to the retired EC2-Classic platform. In a VPC, use `--vpc-security-group-ids` with group IDs.

**What does the app connect to?**
The instance *endpoint*: a DNS name on AWS, returned by `describe-db-instances` together with the port. Never hardcode an IP or a port.

**What should change for production?**
Encryption at rest, deletion protection, Multi-AZ, credentials in Secrets Manager, and optionally IAM database authentication.

**Where does the database password come from?**
RDS generates it and keeps it in Secrets Manager (`manage_master_user_password`). Terraform never sees it, so it's not in code, `terraform.tfvars`, plans or state. The alternatives were a write-only `password_wo` fed by a generated password (still needs somewhere to store it) or a password from an environment variable (it lives in your shell).

**How do I log in manually?**
Read the secret's ARN from `describe-db-instances` (`MasterUserSecret.SecretArn`), read the password with `secretsmanager get-secret-value`, and pass it as `PGPASSWORD=… psql …` for that one command. Never save it: it can be rotated, and reading the secret is the access check.

**What is an ARN?**
An Amazon Resource Name, the unique ID of any AWS resource: `arn:partition:service:region:account:resource`. IAM policies use ARNs to say which resources an identity may use, e.g. "may read this secret". Floci's account ID is `000000000000`.

**How is the database protected from being destroyed?**
Two layers. `prevent_destroy` makes Terraform refuse to plan its destruction; it lives in the code, so deleting the resource block removes it. `deletion_protection` makes the AWS API refuse the delete, whatever tool calls it. If both fail, `skip_final_snapshot = false` takes a last snapshot and `delete_automated_backups = false` keeps the automated backups until they expire. On Floci only the first layer exists (edge case #43).

**How do RDS backups work?**
RDS makes them, not Terraform. Automated backups (`backup_retention_period = 7`) are a daily snapshot plus transaction logs, allowing a restore to any second of the last 7 days. Snapshots are manual and kept until deleted; the final snapshot is one. A restore always creates a new instance with a new endpoint. Whether Floci takes any backups is untested.

---

## EC2 and SSH

**What has to exist before launching an instance?**
The network, security groups and a key pair. The database should exist before the app starts, because the app connects at startup.

**Why ed25519, `.pem`, `~/.ssh` and `chmod 600`?**
ed25519 is a modern, compact key type. `.pem` is the format OpenSSH uses. `600` means owner read/write only, and SSH refuses private keys that others can read, because the key is effectively the server's password.

**Where is the "pair" if only one file is downloaded?**
The public key stays with AWS and is placed on the instance. Only the private half is downloaded.

**Why is the app instance in a public subnet?**
For direct SSH in this phase. The recommended pattern is private subnets behind the load balancer, which can reach private targets, with SSM or a bastion for access and a NAT gateway for outbound traffic.

**Is a second instance in the other AZ needed?**
For production redundancy, yes. For Phase 2, one instance is enough. The load balancer spans both AZs, so it stays available, and instances can be added later.

**Why is there no public IP on a new instance?**
`MapPublicIpOnLaunch` wasn't enabled on the subnet when the instance launched, and it isn't applied retroactively.

**"REMOTE HOST IDENTIFICATION HAS CHANGED". Is it an attack?**
Here, no: a recreated instance has a new host key. Run `ssh-keygen -R '[host]:port'` for that entry only, rather than wiping `known_hosts`.

**How does code get onto an instance?**
Manually with `scp` in Phase 2. In production, a pipeline builds an image, pushes it to a registry (ECR), and the host pulls it. S3 is object storage, not a container registry.

**Why does a hand-started app die when the SSH session ends?**
A foreground or `&` process is tied to the session. `nohup … &` detaches it, but nothing restarts it after a reboot. That needs a systemd unit.

**How can an app port be reached before a load balancer exists?**
With an SSH tunnel: `ssh -L 8080:localhost:8000 …`, then `curl localhost:8080`.

**Why `--break-system-packages` with pip?**
Ubuntu 24.04 blocks system-wide pip installs (PEP 668). It's acceptable on a throwaway host; a virtualenv is cleaner.

---

## Application Load Balancer

**What is it for?**
It's the single internet-facing entry point. It spreads traffic across instances, health-checks them, and stops sending traffic to unhealthy ones.

**Where does it live?**
In the public subnets, across both AZs.

**What are the pieces, and in what order are they created?**
Target group (destinations and health check) → register targets → load balancer (subnets and security group) → listener (a port, with a default action forwarding to the target group).

**One target group for HTTP and another for HTTPS?**
No, one. HTTP vs HTTPS is a listener concern. TLS terminates at the load balancer, and both listeners forward to the same group on 8000.

**Where does the HTTP → HTTPS redirect happen?**
On the port-80 listener, whose action is `redirect` instead of `forward`. The app never sees the plain-HTTP request.

**Why listener port 80 but target port 8000?**
The listener is what clients hit, and the target group is where the app listens. The load balancer translates between the two.

**Why does a new target stay `unhealthy` for a while after a fix?**
A healthy threshold of 5 checks at 30-second intervals means about 2.5 minutes of consecutive passes before it's marked healthy.

**Why does `aws elbv2 wait target-in-service` look stuck?**
Waiters print nothing while polling (by default every 15 s, for up to about 10 minutes). Silence means "not healthy yet".

**Can the API be used from a browser?**
`/health` and redirects work in a browser. `/shorten` is a POST, so use curl, DevTools `fetch`, or a REST client.

---

## AWS CLI

**How do I tell which parameters are required?**
Run `aws <service> <command> help` and look at the SYNOPSIS: anything in `[brackets]` is optional. `--generate-cli-skeleton` shows the full shape of the input, but not which parts are required.

**How do I get readable output without a pager?**
Use `--output table` or `--output text`, plus `--no-cli-pager` or `export AWS_PAGER=""`.

**Why did exported credentials disappear?**
`export` lasts for one shell session. `aws configure` writes `~/.aws/`, and a line in `~/.bashrc` restores the environment in every new shell.

**How do I wait for infrastructure?**
With waiters, for example `aws ec2 wait instance-running`, never with fixed sleeps. A fixed `sleep` caused a real race condition during testing.

---

## Docker and local setup

**How can a non-root process bind port 80 inside a container?**
Docker sets `net.ipv4.ip_unprivileged_port_start=0` inside containers. On a normal host, only root (or a process with `CAP_NET_BIND_SERVICE`) can bind below 1024.

**What does exit code 137 mean?**
128 + 9: the process was killed with SIGKILL. A container whose PID 1 ignores SIGTERM (like `tail -f /dev/null`) is always killed after `docker stop`'s timeout.

**`curl` exit codes worth knowing?**
`6` means the host name couldn't be resolved, `7` means the connection was refused or there's no route to the host, and `28` means timeout.

---

## CI and GitHub Actions

**Where do GitHub Actions jobs run?**
GitHub reads the workflow and schedules jobs; each job runs on a *runner*. GitHub-hosted runners are fresh VMs in GitHub's cloud; a self-hosted runner is an agent on your own machine that polls GitHub for jobs (outbound only). One workflow can mix both.

**Why not run CI on the laptop too?**
CI proves the code works on a clean machine, not just yours. A fresh VM has none of your caches, packages or environment variables.

**Why lint before tests?**
Fail fast, fail cheap: lint takes seconds and needs no database.

**Why real PostgreSQL in tests instead of SQLite?**
Dev/prod parity. Different SQL dialects, types and constraint behaviour mean tests could pass on SQLite and fail in production. CI uses a `postgres:16` service container, the same major version as RDS.

**Why pin actions to a commit SHA?**
A tag can be moved to different code; a SHA can't.

**Why is a public repo with a self-hosted runner risky, and how is it contained?**
A fork's pull request runs its own copy of the workflow, so it could target the self-hosted runner. Containment: approval required for all external contributors' workflows, never use `pull_request_target`, deploy only on `push` to `main`, and CI jobs only on GitHub-hosted runners.

**Should the version be recorded at build time or deploy time?**
Build time: the artifact is labelled when it's made, from the same commit, and can't drift from its contents. A deploy-time value travels separately and can be wrong.

**Mutable or immutable deploys?**
Mutable updates instances in place (fast, but drift and port conflicts). Immutable replaces instances every release (no drift, easy rollback, zero downtime via blue/green). Containers (ECS/Kubernetes) are immutable by nature.

**Why did `Lint` and `Test` still run when `Terraform` failed?**
Jobs in a workflow run in parallel unless one declares `needs:`. Only `Test` needs `Lint` (it starts a database, so a lint failure skips it). `Terraform` checks unrelated code, so it runs independently and one push shows every problem at once.

**Why does the Terraform check run on every PR, not only when `.tf` files change?**
A required check whose workflow is skipped by a `paths:` filter stays pending forever, and a job skipped by `if:` reports success. Path-awareness would save about 15 seconds and add a way for a required check to pass without running (edge case #40).

**Why does CI take about a minute when the tests take 0.4 s?**
Setup dominates: a fresh VM, the `postgres:16` service and its health check, Python and dependencies, plus `Test` waiting for `Lint`. Measured and accepted for now; running `Test` in parallel with `Lint` is the first lever if it ever matters.

---

## Terraform

**How does Terraform know what already exists?**
The state file maps each address in the code (e.g. `aws_vpc.main`) to a real resource ID. Every plan reads the state, refreshes each resource from the API, and diffs the code against what's really there.

**Why doesn't running the same code twice create two VPCs?**
Idempotence: Terraform only acts on differences between code, state and reality.

**How do I get two identical VPCs?**
Give them two addresses: two blocks, `for_each`/`count`, or a module called twice. Identity is the address, not the configuration.

**Why did fixing a drifted tag change only the tag?**
The diff is per attribute. The provider also knows which attributes update in place and which force replacement; look for `# forces replacement` in every plan.

**Why doesn't Terraform detect a security group rule nobody declared?**
Refresh only reads what's in the state. With standalone rule resources, no resource owns the complete set of rules.

**How does Terraform decide the order?**
From references. `vpc_id = aws_vpc.main.id` means the subnet needs the VPC's ID as input, so the VPC comes first. Terraform builds a graph (`terraform graph`), creates independent resources in parallel, and destroys in reverse. Dependencies are per resource block, so something depending on `aws_subnet.this` waits for all its instances.

**What are `for_each`, `each.key` and `each.value`?**
`for_each` creates one instance per map entry; `each.key` is the entry's name, `each.value` its settings. A map with names keeps identities stable; a list would renumber everything when an item is removed.

**What are `locals`?**
Named values computed inside the code, defined in a `locals` block and referenced as `local.<name>`.

**What is a for expression like `[for k, s in aws_subnet.this : s.id if var.subnets[k].public]`?**
A filter: loop over the subnets, keep the ID when the entry is public. Like `SELECT id FROM subnets WHERE public`.

**Why `plan -out tfplan` then `apply tfplan`?**
A bare `apply` computes a new plan; something may have changed since you reviewed the last one. Applying the saved file applies exactly what was reviewed.

**What does `-replace=<address>` do?**
Plans a destroy-and-recreate of that resource even though its code didn't change.

**Where do secrets and personal values go?**
In `terraform.tfvars` (git-ignored), not in code. They still appear in plans, state and debug logs, so none of those are committed.

**What is a postcondition?**
A check in a resource's `lifecycle` block, evaluated after the resource is created or read. `shortify-db` uses one to fail the apply if the API doesn't report deletion protection on: it verifies the effect, not the request.

**Does a failed plan leave a plan file?**
Yes. With `-out`, Terraform saves the partial plan, marked as errored, so it can be inspected with `terraform show -json`; it can't be applied. Judge a plan by its exit code, not by the file (edge case #44).
