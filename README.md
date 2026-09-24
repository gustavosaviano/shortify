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

**Known simplifications (planned for Phase 4):** EC2 sits in a public subnet for direct SSH. The production pattern is private subnets plus SSM or a bastion, with a NAT gateway for outbound traffic. Private subnets also use the main route table implicitly; an explicit private route table is safer.

---

## Roadmap

| Phase | Scope | Status |
|---|---|---|
| 1 | Local app with Docker Compose | ✅ Done |
| 2 | Manual deploy via AWS CLI: VPC, subnets, IGW, routes, SGs, RDS, EC2, ALB | ✅ Done and verified |
| 3 | CI/CD: GitHub Actions, ECR, automated deploy | ⏳ Next |
| 4 | IaC: Terraform (cloud resources) + Ansible (instance configuration) | ⏳ |
| 5 | Containers: ECS Fargate or EKS, Secrets Manager | ⏳ |
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
├── app/                  # FastAPI app: routes, SQLAlchemy model, DB session
├── Dockerfile            # Multi-stage build, non-root user
├── docker-compose.yml    # Phase 1 local stack (app + Postgres)
├── requirements.txt
└── docs/
    ├── runbook.md        # Operating the Floci environment, rebuild script
    ├── edge-cases.md     # Gotchas, Floci vs AWS differences, production notes
    ├── lessons-learned.md# Hypothesis → test → finding log, verification results, open questions
    └── knowledge-base.md # Networking and AWS concepts, Q&A style
```
