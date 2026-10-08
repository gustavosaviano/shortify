# Shortify — self-hosted URL shortener on AWS

A URL shortener built as a realistic DevOps project: a small FastAPI + PostgreSQL app deployed on AWS-style infrastructure (VPC, ALB, EC2, RDS). It is built **manually first**, then automated with CI/CD, Terraform and Ansible, containerized, and finally made observable. Every infrastructure decision is tied to a business reason.

AWS is emulated locally with [Floci](https://floci.io) (free, open-source). Where the emulator differs from AWS, that is tested and documented rather than assumed.

---

## The business problem

A marketing agency shares campaign links across email, Instagram and WhatsApp, using long URLs with UTM parameters. Relying on a third-party shortener means:

1. **No control over uptime.** If the vendor goes down, every live campaign link breaks.
2. **No data ownership.** Click data lives in someone else's database.
3. **Cost at scale.** Per-link pricing grows with campaign volume.

Shortify is the agency's own redirect layer: owned infrastructure, click tracking in its own database, its own domain.

The app has two flows:

- **Shorten:** `POST /shorten` returns a 6-character code.
- **Redirect:** `GET /{code}` increments `clicks` and returns a `302` to the original URL.

---

## Architecture

```
Internet
   │
Internet Gateway
   │
VPC 10.0.0.0/16
   ├─ public  10.0.1.0/24 (AZ a) ─┐
   ├─ public  10.0.2.0/24 (AZ b) ─┴─ ALB (80/443) ──► EC2 :8000 (FastAPI)
   ├─ private 10.0.3.0/24 (AZ a) ─┐                          │
   └─ private 10.0.4.0/24 (AZ b) ─┴─ RDS PostgreSQL :5432 ◄───┘
```

Security groups chain the tiers: internet → ALB SG → EC2 SG → RDS SG. Each tier only accepts traffic from the one in front of it.

### Key decisions

| Decision | Business reason |
|---|---|
| Custom VPC instead of the default one | The default VPC has only public subnets, so there's no private tier for the database |
| `/16` VPC | The primary CIDR can't be changed later; address space is free, re-architecture isn't |
| Two AZs per tier | A single data-center failure must not take down live campaign links |
| RDS in private subnets | Link data reveals campaign strategy; it's never reachable from the internet |
| ALB in front of EC2 | One entry point, health checks, and the ability to scale out; a crashed instance stops receiving traffic |
| Security groups referencing security groups | Rules express intent ("only the ALB may call the app") instead of IP lists that go stale |
| Manual build before Terraform | Every line of IaC maps to a resource already built by hand and understood |
| Local emulation (Floci) | Zero cloud cost while learning; gaps versus AWS are measured, not guessed |
| Immutable deploys (replace instances every release) | No drift and no in-place port conflicts; the new version is healthy before the old one leaves, so campaign links never go down |
| Terraform before the deploy pipeline | The pipeline reads resource IDs from Terraform outputs instead of hardcoding hand-made IDs |
| Public repo, CI on GitHub runners, deploy only from protected `main` | Visible portfolio; the self-hosted deploy runner is registered only to a separate private repo, because GitHub advises self-hosted runners only for private repos, so no fork pull request can reach the machine that holds the keys to production |
| RDS password managed by RDS in Secrets Manager; two layers of deletion protection | Credentials never touch code, plans or state; the click history can't be deleted by one mistaken command |
| SSH public key passed as a value, never a file path | The same code runs on a laptop and in the pipeline; nothing depends on one machine's filesystem |
| Image passed at release time; a rotated key is followed by a release | The image is a release input, so shipping a version never means editing code; a release launches an instance with the new key and retires the old one, so the old key can't stay trusted on a running server |
| IMDSv2 required on the instances | The app takes arbitrary URLs from users: a future SSRF bug must not turn into stolen cloud credentials |
| Instances are registered by whoever launches them, never by Terraform | Only the release process knows when the new instance is healthy; two owners would let a routine infra change roll back a release |
| The app reads its database password at start through an IAM role limited to that one secret | The RDS-managed secret rotates, so a copy on the host would break the app within days; a role leaves nothing on disk to leak |
| Phase 5 on EKS rather than ECS | Floci emulates EKS, so Kubernetes can be built and tested at zero cost like everything else, and Kubernetes skills transfer across clouds. The cost on AWS: an hourly control-plane fee even when idle (pricing not verified here) |
| Private app tier designed in Phase 3b, not before | The launch template picks the subnet and the deploy mechanism decides the access path, so moving first would mean building it twice; a NAT gateway is a recurring charge, needed only if instances install packages at boot |
| Terraform state in S3 with a lockfile, its bucket created by a separate bootstrap root | The laptop and the deploy pipeline read one record of the infrastructure and can't write it at the same time; every change keeps a version, so a bad apply can be rolled back; on AWS the record no longer depends on one laptop's disk |
| Releases launched by the pipeline (option B), not by an Auto Scaling group | Zero downtime is the requirement, and B's cutover is the only one verified end to end on Floci; Floci's instance refresh terminates before it launches (edge case #58), so a zero-downtime ASG release can't be demonstrated here. ASG self-healing and scaling add little for one instance, and Phase 5 (EKS) replaces this layer |

**Known simplifications (planned for Phase 3b):** the app instance sits in a public subnet so Ansible can deploy over SSH. The production pattern is a private app tier with SSM Session Manager instead of SSH, and outbound traffic through a NAT gateway or VPC endpoints. It's designed together with the deploy: the launch template picks the subnet, and how a release reaches an instance (Ansible over SSH or SSM, or a baked image) decides which outbound access it needs.

---

## Roadmap

| Phase | Scope | Status |
|---|---|---|
| 1 | Local app with Docker Compose | ✅ Done |
| 2 | Manual deploy via AWS CLI: VPC, subnets, IGW, routes, SGs, RDS, EC2, ALB | ✅ Done and verified |
| 3a | CI: tests against real PostgreSQL, lint, GitHub Actions gate, protected `main` | ✅ Done |
| 4 | IaC: Terraform (cloud resources) + Ansible (instance configuration) | ✅ Done on Floci: network, security groups, RDS, ALB, key pair, app instance, IMDSv2 and the app's IAM role; Ansible deploy (release, environment, systemd unit, health check), the release cutover behind the ALB and a one-command session start (`shortify_session`) working on Floci, tested from a cold boot |
| 3b | CD: immutable blue/green deploys on the Terraform-managed infrastructure, with the app tier moved to private subnets (SSM access; NAT gateway or VPC endpoints) | 🔄 In progress: releases launched by the pipeline (option B), decided from Floci's Auto Scaling tests (edge cases #57, #58); `scripts/release.sh` replaces the serving instance with zero failed requests (#61); Terraform no longer manages an app instance (#62) |
| 5 | Containers: EKS (Kubernetes), emulated by Floci | ⏳ |
| 6 | Observability and security: CloudWatch, X-Ray, WAF | ⏳ |

---

## Quick start (Phase 1, local)

```bash
docker compose up --build
curl http://localhost:8000/health
curl -X POST http://localhost:8000/shorten -H "Content-Type: application/json" -d '{"url":"https://github.com"}'
curl -v http://localhost:8000/<code>        # 302 + Location header
curl http://localhost:8000/metrics
docker compose down -v
```

| Method | Path | Purpose |
|---|---|---|
| GET | `/health` | Liveness check used by the ALB |
| GET | `/metrics` | Total link count |
| POST | `/shorten` | Create a short code |
| GET | `/{code}` | Redirect (302) and count the click |

Phase 2 (the AWS environment on Floci) is operated through **[docs/runbook.md](docs/runbook.md)**.

---

## Verification: what the emulator can and can't prove

Phase 2 ended with a round of controlled tests: one variable at a time, a written prediction before each test, and a restore after each one. The headline results:

| Question | Result |
|---|---|
| Are security groups enforced by Floci? | **No**, not by default, and the opt-in firewall flag had no observable effect on WSL2/Docker Desktop |
| Are network ACLs enforced? | **No**: a deny-all NACL changed nothing |
| Why did ALB health checks time out while the app was fine? | The emulator's container had lost its attachment to the VPC network; reconnecting fixed it |
| Does an instance survive a reboot or stop/start? | Its filesystem does, but not sshd or the app; recovery means replacing the instance |
| Does a port-80 listener work? | Yes; an earlier failure was a broken backend, not the port |

**Consequence:** the security group and NACL design is documented and reasoned, but it is only truly validated on real AWS. That's stated openly rather than claimed as tested.

Full test table, hypotheses and corrections: **[docs/lessons-learned.md](docs/lessons-learned.md)**.

---

## Known limitations

- The Phase 2 deploy is manual (`scp` plus `nohup`), so it doesn't survive a restart. This is by design for the manual phase; automation arrives in Phases 3 and 4.
- `/health` is a shallow check: it doesn't touch the database. Liveness vs readiness is planned for Phase 6.
- `short_url` in the API response is hardcoded to `localhost:8000`. It needs a `BASE_URL` setting.
- Demo credentials (`shortify`/`shortify`) are local-only. Secrets move to Secrets Manager in Phase 5.

---

## Repository layout

```
shortify/
├── .github/workflows/    # CI: lint → test, terraform fmt/validate, shellcheck + script tests (GitHub-hosted runners)
├── app/                  # FastAPI app: routes, SQLAlchemy model, DB session
├── tests/                # pytest suite against real PostgreSQL; tests/scripts: the scripts against fake CLIs
├── infra/terraform/      # Phase 4: network, security groups, RDS, ALB, key pair and the app's launch template as code
├── infra/ansible/        # Phase 4: playbook (app.yml), Floci inventory, config and templates
├── Dockerfile            # Multi-stage build, non-root user
├── docker-compose.yml    # Phase 1 local stack (app + Postgres)
├── requirements.txt      # runtime dependencies (requirements-dev.txt: test and lint tools)
└── docs/
    ├── runbook.md        # Operating the Floci environment, rebuild script
    ├── edge-cases.md     # Gotchas, Floci vs AWS differences, production notes
    ├── lessons-learned.md# Hypothesis → test → finding log, verification results, open questions
    └── knowledge-base.md # Networking and AWS concepts, Q&A style
```
