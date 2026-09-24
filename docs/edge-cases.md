# Edge cases, gotchas and Floci vs AWS

Each entry covers what happens, why, and what to do about it. "Tested" means it was reproduced on this setup (WSL2 + Docker Desktop, Floci `latest-compat`). Operating procedures live in [runbook.md](runbook.md). Entry numbers are stable IDs used for cross-references, so the entries are grouped by topic rather than listed in numeric order.

## Building the network

**1. `--dry-run` creates the resource in Floci.**
`aws ec2 create-subnet --dry-run` created a real subnet, and the next attempt failed with a CIDR conflict. Don't use `--dry-run` against Floci.

**2. Availability zones are not spread automatically.**
Without `--availability-zone`, all four subnets landed in the same AZ (seen in the AWS console), which defeats the purpose of two AZs. A subnet's AZ can't be changed afterwards, so the fix is delete and recreate. Always pass the AZ and verify with `describe-subnets`.

**3. Save the private key correctly.**
The first SSH attempt failed with `error in libcrypto`. It was initially blamed on "dummy keys" from Floci, but the Floci docs say `CreateKeyPair` returns real RSA key material. The likely cause is that the key was copied by hand out of the JSON `KeyMaterial` field, leaving literal `\n` sequences in the file. Either of these works:
```bash
aws ec2 create-key-pair --key-name shortify-app --query 'KeyMaterial' --output text > ~/.ssh/shortify-app.pem && chmod 600 ~/.ssh/shortify-app.pem
ssh-keygen -t ed25519 -f ~/.ssh/shortify-real -N "" && aws ec2 import-key-pair --key-name shortify-real --public-key-material fileb://~/.ssh/shortify-real.pub
```
Floci returned an RSA key even when `--key-type ed25519` was requested.

**4. `MapPublicIpOnLaunch` only applies to future instances.**
Enable it on public subnets before launching. Existing instances are not retroactively given a public IP; relaunch them instead.

**5. Security groups must exist before they can be referenced.**
Rules reference other groups by ID, so create all three shells first (RDS, EC2, ALB), then add rules.

**6. RDS needs a DB subnet group.**
RDS can't be placed in a subnet directly; it takes a DB subnet group listing subnets in at least two AZs. Use only the private subnets.

**17. Tags at creation time.**
`create-vpc` has no `--tags`, but it does have `--tag-specifications`, e.g. `'ResourceType=vpc,Tags=[{Key=Name,Value=shortify-vpc}]'`. This project uses a separate `create-tags` call; both work on AWS. `--tag-specifications` hasn't been tested on Floci.

**23. Every association replace creates a new association ID.** *(tested)*
A subnet always has exactly one NACL. It can't be added or removed, only replaced, and each replace returns a new `NewAssociationId` (`aclassoc-32f5…` → `aclassoc-6cdd…` → `aclassoc-4330…`). Capture it in order to undo the change.

## Load balancer and target groups

**7. Stale and empty targets don't break the group.** *(tested)*
A terminated, portless target stuck at `initial / Elb.RegistrationInProgress` did not stop a new target from going `healthy`. An empty-ID target (`--targets Id=`) is accepted silently and goes `unhealthy / FailedHealthChecks`, while the real target stays `healthy` and traffic keeps flowing. Health is tracked per target. Two rules do matter:
- **Deregister in the same form the target was registered.** `--targets Id=X,Port=8000` doesn't remove a target registered without a port. The call succeeds and removes nothing.
- Check `describe-target-health` after every register or deregister.

**8. `Port` is optional at registration.** *(tested)*
A portless registration falls back to the target group's port (8000) and goes `healthy`, as on AWS. `Target.Port: None` means "not set explicitly". Passing `Port=8000` is still good hygiene because it makes deregistration predictable. Two reason codes worth knowing:
- `Elb.InitialHealthChecking`: a new target, checks in progress. Allow about 5 passes × 30 s.
- `Elb.RegistrationInProgress` that never changes: the instance behind the target is gone.

**10. A listener on port 80 works.** *(tested)*
With a healthy target, a port-80 listener answers exactly like 8080, both from inside Floci and from the host (with `"80:80"` published). Floci runs as non-root (`uid=1001`) and can still bind port 80, because Docker sets `net.ipv4.ip_unprivileged_port_start=0` inside containers. An early port-80 failure was caused by the broken backend (#11), not the port. On real AWS, use 80/443: the ALB security group doesn't allow 8080.

**11. The ALB can only reach instances if Floci is attached to the VPC network.** *(tested — root cause of the longest outage)*
Each VPC is backed by a real Docker network (`floci-vpc-{account}-{region}-{vpc-id}`), and each instance holds its real private IP there. The ALB runs inside the Floci container and forwards to that IP, so the Floci container must be attached to the VPC network. Floci attaches itself when it *creates* the network, at the first launch in that VPC. After the Floci container is recreated, it comes back attached only to `floci_default`, and launching into the existing VPC network doesn't reattach it.
- **Symptom:** target `unhealthy / Target.Timeout` while the app is fine; `curl` from inside Floci to the private IP exits `28`.
- **Fix:** `docker network connect <vpc-network> floci-ui-floci-1` (loop in the runbook). The target turned healthy about 2 minutes later, consistent with a healthy threshold of 5 × 30 s.
- **Durability:** the attachment survives `stop`/`start` but not a recreate. No durable fix is known.

**20. `/health` is a shallow health check.**
It doesn't touch the database, so the ALB keeps a target `healthy` even when RDS is down and `/shorten` fails. The app also fails at startup if RDS is unreachable, because `create_all()` runs on import. Phase 6: separate liveness from readiness.

**24. The ALB DNS name resolves to IPv6 loopback.** *(tested)*
`getent hosts $ALB_DNS` returns `::1`, listed under `localhost.floci.io`. It works because Docker publishes the listener ports on IPv6 too (`[::]:80`). On real AWS an ALB name resolves to several public IPs that change over time: point a Route 53 alias record at the name and never hardcode IPs.

## Instances

**9. Only a fresh launch gives a working instance.** *(tested)*
Floci's EC2 image (`ami-ubuntu2404-amd64`, which is plain `ubuntu:24.04`) runs `tail -f /dev/null` as PID 1. There's no systemd.

| Action | What Floci does | Result |
|---|---|---|
| `run-instances` | Creates the container, injects the key, starts sshd, runs UserData | ✅ usable |
| `reboot-instances` | `docker restart` | Filesystem kept; no sshd, no app |
| `stop-instances` / `start-instances` | `docker stop` (30 s, then SIGKILL, exit 137) / `docker start`, same container | Filesystem kept; no sshd, no app |
| Start from Docker Desktop | Same, without telling Floci | Same, and Floci's state goes out of sync |

Recovery means replacing the instance. On real AWS a reboot restores sshd (systemd starts it), but a hand-started app would still be lost. Floci's own image tag (`latest` / `latest-compat`) is unrelated to instance boot. An experimental `ami-ubuntu2404-cloud` with systemd and cloud-init exists, but it's listed as arm64-only. Observed oddity: right after an API reboot, `stop-instances` reported `PreviousState: stopped`.

**19. The manual deployment isn't reboot-safe.**
The app is started with `nohup`, and any restart kills it, on AWS as well. The real fix (a systemd unit installed by UserData or Ansible) belongs to Phases 3–4. This is accepted for the manual phase.

**25. `running` doesn't mean ready.** *(tested)*
From Floci's logs: the container is `running` → 16 s later the key is injected → 34 s later sshd starts (along with the IMDS `socat` proxy). SSH right after the waiter returns fails with `Connection reset by peer`. The same holds on AWS: `running` only means the VM has started. Use `aws ec2 wait instance-status-ok` and retry SSH.

**26. A Floci shutdown stops its instances.** *(observed)*
During a Floci recreate, the instance container was SIGKILLed (`Exited (137)`) at 22:40:25, 9 seconds *before* the new Floci started at 22:40:34. So it was the old Floci stopping it on shutdown. An earlier recreate left the instance running only because that Floci had no Docker access. Afterwards, the API still reported `running`.
**Confirmed with a reboot test:** a plain `docker compose stop` also stops the instance (`Exited (137)` seconds after Floci itself), so every session starts with an instance replacement. After that stop and a full Docker/WSL restart, the API reported the instance as `terminated` rather than `running`. Why the two cases differ is unknown. In the same test, the RDS container was **removed** on shutdown and **recreated** on start with its data intact, and its proxy target moved onto the VPC network (`10.0.0.3:5432`). Floci also exits with 137 on `compose stop`: the default 10 s stop timeout is shorter than its shutdown work.

## Emulator platform

**12. `docker compose down` vs `stop`.**
- `stop` stops containers; `start` resumes them.
- `down` removes the containers and networks, so Floci is recreated (#11, #26).
- `down -v` also removes named volumes. This stack's state lives in a **bind mount** (`./data:/app/data`), which `-v` doesn't delete.

Prefer `stop`/`start`.

**13. Security groups and NACLs are not enforced.** *(tested)*
- **Default mode:** with **zero** inbound rules on `shortify-rds-sg`, `psql` from the host and the app's writes both kept working.
- **NACLs:** a deny-all NACL on the instance's subnet changed nothing.
- **With `FLOCI_NETWORK_SECURITY_GROUP_ENFORCEMENT_ENABLED=true`** and a freshly launched instance: SSH worked with no port-22 rule, a new connection to 8000 worked with no port-8000 rule, the instance was a plain `bridge` container, and nothing about enforcement appeared in the logs. On WSL2 + Docker Desktop the flag has no observable effect.
- **Not ruled out:** that Floci exempts its own traffic and published SSH but filters instance-to-instance traffic.

On real AWS, the missing RDS rule would make database calls hang, and the deny-all NACL would cut the instance off in both directions. Conclusion: the SG and NACL design can only be validated on real AWS.

With enforcement off, Floci also publishes CIDR-sourced TCP ingress ports of an instance on host ports 30000–30999 through `alpine/socat` sidecars. This project's SGs have none that qualify.

**14. "RDS unreachable" wasn't subnet isolation.**
The first `psql` from the host to the RDS endpoint timed out. That wasn't the private subnet at work (Floci doesn't enforce it). The RDS proxy ports simply weren't published, and on Docker Desktop, container IPs don't answer from the host. Publishing `7001-7099` fixed it.

**18. Docker socket access: `group_add`, not `chmod`.** *(tested)*
Floci runs as `uid=1001` and needs `/var/run/docker.sock` (`root:docker 660`) to manage EC2 and RDS containers. `sudo chmod 666` worked until Docker restarted and recreated the socket. Floci then started without Docker access:
- the log said `No Docker daemon is reachable from Floci`
- the RDS proxy accepted connections and then dropped them (`server closed the connection unexpectedly`)
- instances weren't restored

The durable fix is `group_add: ["<socket gid>"]` in compose. Verify with `docker exec floci-ui-floci-1 id`. If Docker is reinstalled, re-check the gid.

**21. Non-standard ports are by design.**
All Floci instances share `127.0.0.1` as their public IP, so SSH uses host ports 2200–2299. RDS sits behind Floci's proxy on 7001–7099 (Postgres itself listens on 5432 inside its container, and host 5432 is used by the Phase 1 compose). Read hosts and ports from the API, never hardcode them. Whether the ranges can be narrowed is untested.

**22. Unset shell variables expand to nothing.** *(tested)*
`--targets Id=$INSTANCE_ID` with the variable unset becomes `--targets Id=`, which the API accepts. Use `set -u` in scripts and re-source `shortify-ids.sh` in every new terminal.

**29. Silent auto-start in `.bashrc` started the wrong stack.** *(tested)*
The line `cd ~/workspace/floci && docker compose up -d > /dev/null 2>&1` pointed at an obsolete standalone Floci directory. Every new terminal tried to start that stack instead of `floci-ui`, and the redirect hid every error. That is also where a second Floci instance came from earlier. The fix is to keep only `eval "$(floci env)"` in `.bashrc` and to start sessions explicitly with a named command (`shortify_up`) that shows its errors. The obsolete stack was deleted.

**27. Don't keep misleading configuration.**
The enforcement flag is still set but does nothing on this machine. Configuration that claims a control that isn't there creates false confidence. Remove it at the next Floci recreate.

**28. `latest-compat` is required for the floci-ui stack.** *(tested)*
The stack's init hook (`init/ready.d/01-setup.sh`) calls the AWS CLI, which only the compat image contains. That's the best explanation for "Runtime unavailable" with `latest`. The TLS-permission warning that appears in the logs is non-fatal and shows up with both images. The image also has no `ss` or `netstat`, only `curl`.

## Application

**15. `short_url` is wrong behind the ALB.**
`main.py` hardcodes `http://localhost:8000/{code}`. It needs a `BASE_URL` setting.

**16. AWS CLI pager.**
Long output opens in `less`. Use `--no-cli-pager` or `export AWS_PAGER=""`.

---

## Floci vs real AWS

| Behavior | Floci (this setup) | Real AWS |
|---|---|---|
| EC2 SSH | Host port 2200–2299 on `127.0.0.1` | Port 22 on the instance's IP |
| RDS endpoint | Proxy, `localhost:7001` from the host | DNS name, port 5432, private only |
| `--dry-run` | Creates the resource | Validates only |
| `create-key-pair` | Real RSA key | Real key |
| Security groups | Not enforced (opt-in flag had no observable effect) | Enforced |
| NACLs | Never enforced | Enforced, stateless |
| Instance after reboot/stop/start | Filesystem kept; no sshd or app | sshd back via systemd; hand-started app lost |
| ALB → instance | Floci must be on the VPC Docker network | Native VPC routing |
| ALB DNS name | Resolves to `::1` | Several public IPs that change |
| Container IPs from the host | Not reachable (Docker Desktop) | N/A |
| Provisioning time | Seconds | Minutes |

## Production notes

These are the changes a production deployment would add:

- **RDS:** encryption at rest (`--storage-encrypted`), deletion protection, Multi-AZ.
- **HTTPS:** an ACM certificate on a 443 listener, with a redirect action on the port-80 listener.
- **Instance placement:** instances in private subnets, SSM Session Manager instead of SSH, and a NAT gateway for outbound traffic.
- **Least-privilege egress:** revoke the default allow-all egress rule. That's when the explicit ALB → EC2 egress rule starts to matter.
- **Secrets:** move them to Secrets Manager.
