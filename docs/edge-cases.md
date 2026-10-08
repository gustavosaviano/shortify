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

`scripts/release-register.sh` applies both rules: it deregisters each other target in the form `describe-target-health` reports it (with `Port`, or without when it shows `None`) and ends by checking that exactly the new instance is `healthy` and that `/health` answers through the ALB. On Floci 2.1.0 both `wait target-in-service` and `wait target-deregistered` work *(tested 2026-10-02)*: the cutover from a dead target to a new instance exited 0 and a rerun changed nothing. Its failure paths (the new instance never healthy, a deregister that changes nothing, the ALB not answering) are tested against a fake AWS CLI only: on Floci the in-service waiter takes about 10 minutes to give up.

**8. `Port` is optional at registration.** *(tested)*
A portless registration falls back to the target group's port (8000) and goes `healthy`, as on AWS. `Target.Port: None` means "not set explicitly". Passing `Port=8000` is still good hygiene because it makes deregistration predictable. Two reason codes worth knowing:
- `Elb.InitialHealthChecking`: a new target, checks in progress. Allow about 5 passes × 30 s.
- `Elb.RegistrationInProgress` that never changes: the instance behind the target is gone. After a Floci restart, a target whose instance had died was reset to `initial / Elb.RegistrationInProgress`, not `unhealthy`; once replaced instances came and went it showed `unhealthy / Target.FailedHealthChecks` *(tested 2026-10-02)*. A release must deregister every target that isn't the new instance, whatever its state, never only the `unhealthy` ones.

**10. A listener on port 80 works.** *(tested)*
With a healthy target, a port-80 listener answers exactly like 8080, both from inside Floci and from the host (with `"80:80"` published). Floci runs as non-root (`uid=1001`) and can still bind port 80, because Docker sets `net.ipv4.ip_unprivileged_port_start=0` inside containers. An early port-80 failure was caused by the broken backend (#11), not the port. On real AWS, use 80/443: the ALB security group doesn't allow 8080.

**11. The ALB can only reach instances if Floci is attached to the VPC network.** *(tested — root cause of the longest outage)*
Each VPC is backed by a real Docker network (`floci-vpc-{account}-{region}-{vpc-id}`), and each instance holds its real private IP there. The ALB runs inside the Floci container and forwards to that IP, so the Floci container must be attached to the VPC network. Floci attaches itself when it *creates* the network, at the first launch in that VPC. After the Floci container is recreated, it comes back attached only to `floci_default`, and launching into the existing VPC network doesn't reattach it.
- **Symptom:** target `unhealthy / Target.Timeout` while the app is fine; `curl` from inside Floci to the private IP exits `28`.
- **Fix:** `docker network connect <vpc-network> floci-ui-floci-1` (loop in the runbook). The target turned healthy about 2 minutes later, consistent with a healthy threshold of 5 × 30 s.
- **Durability:** the attachment survives `stop`/`start` but not a recreate. No durable fix in Floci is known; `scripts/floci-network-check.sh`, run by `shortify_up`, reconnects and verifies the attachment at every session start. A recreate in the middle of a session is caught by the release: its `target-in-service` waiter fails with `Target.Timeout`. A PC restart (Floci stop/start) kept the attachment on 2.1.0 *(tested 2026-10-02)*: Floci came back with `10.0.0.2` on the VPC network.
- **Re-confirmed on Floci 2.1.0** *(tested 2026-10-01)*: with Floci on `floci_default` only, the instance answered there (`172.19.0.6:8000` → `200`) but not on its private IP (`10.0.1.15` → exit `28`), and the registered target went `unhealthy / Target.Timeout`. The ALB forwards to the private IP only, even when another shared network would work. After `docker network connect`, Floci got `10.0.0.2` on the VPC network, the target turned `healthy` and `/health` through the ALB returned `200`. Known-bad test of `scripts/floci-network-check.sh` *(2026-10-02)*: after `docker network disconnect`, Floci → instance exited `28`; the script reconnected, Floci got `10.0.0.2` back, and `/health` and `/metrics` (which reads the database through that address, #55) returned `200`. The same address came back once; whether Docker guarantees it is unverified. If it ever changes, `DATABASE_HOST` in the env file is stale until the next deploy.

**20. `/health` is a shallow health check.**
It doesn't touch the database, so the ALB keeps a target `healthy` even when RDS is down and `/shorten` fails. The app also fails at startup if RDS is unreachable, because `create_all()` runs on import. Phase 6: separate liveness from readiness.

**24. The ALB DNS name resolves to IPv6 loopback.** *(tested)*
`getent hosts $ALB_DNS` returns `::1`, listed under `localhost.floci.io`. It works because Docker publishes the listener ports on IPv6 too (`[::]:80`). On real AWS an ALB name resolves to several public IPs that change over time: point a Route 53 alias record at the name and never hardcode IPs.

**46. ALB settings are stored; enforcement is untested.** *(tested)*
The Terraform-built ALB (`shortify-alb`, listener 80 → target group `shortify-app`) took 61 s to create, while the target group and listener took about 1 s. The provider waits for `active`, so Floci appears to simulate provisioning. The next plan was clean, and `describe-load-balancer-attributes` / `describe-target-group-attributes` returned exactly what was requested: `routing.http.drop_invalid_header_fields.enabled true`, `deletion_protection.enabled false`, `deregistration_delay.timeout_seconds 30`. That was checked through the API because a clean plan alone could have been a false success (#43). Stored doesn't mean enforced: whether Floci really drops invalid headers or waits 30 s while draining is untested. Blue/green deploys (Phase 3b) will exercise the deregistration delay. With no targets, `http://localhost/` returns `503` with the plain-text body `No targets available`. With a registered but unhealthy target, the body is `Service unavailable` *(tested 2026-10-01)*. The two bodies separate "nothing registered" (a release-process bug) from "registered but not healthy" (an app or network problem). After a full PC shutdown and `shortify_up`, the next plan was clean: the ALB, target group and listener were all restored.

## Instances

**9. Only a fresh launch gives a working instance.** *(tested)*
Floci's EC2 image (`ami-ubuntu2404-amd64`, which is plain `ubuntu:24.04`) runs `tail -f /dev/null` as PID 1. There's no systemd. Floci adds packages at launch *(observed on 2.1.0)*: `/var/log/apt/history.log` on the Terraform-built instance shows `apt-get install iproute2 socat curl ca-certificates` (the IMDS proxy) and, 8 s later, `openssh-server openssh-client`, both on launch day. `python3` and `wget` are present without being installed by name (probably pulled in by openssh's recommended packages; unverified). Don't build on them: Ansible needs Python on the host, and here it's there by accident.

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
From Floci's logs: the container is `running` → 16 s later the key is injected → 34 s later sshd starts (along with the IMDS `socat` proxy). The delay is most likely `apt-get` installing the IMDS proxy and then `openssh-server` (#9), so a Floci instance only gets sshd if it can reach an apt mirror. SSH right after the waiter returns fails with `Connection reset by peer`. The same holds on AWS: `running` only means the VM has started. Use `aws ec2 wait instance-status-ok` and retry SSH.

**26. A Floci shutdown stops its instances.** *(observed)*
During a Floci recreate, the instance container was SIGKILLed (`Exited (137)`) at 22:40:25, 9 seconds *before* the new Floci started at 22:40:34. So it was the old Floci stopping it on shutdown. An earlier recreate left the instance running only because that Floci had no Docker access. Afterwards, the API still reported `running`.
**Confirmed with a reboot test:** a plain `docker compose stop` also stops the instance (`Exited (137)` seconds after Floci itself), so every session starts with an instance replacement. After that stop and a full Docker/WSL restart, the API reported the instance as `terminated` rather than `running`. Why the two cases differ is unknown. In the same test, the RDS container was **removed** on shutdown and **recreated** on start with its data intact, and its proxy target moved onto the VPC network (`10.0.0.3:5432`). Floci also exits with 137 on `compose stop`: the default 10 s stop timeout is shorter than its shutdown work. *(Observed after a host shutdown:)* with the PC powered off while the stack ran, `docker inspect` next day showed `FinishedAt` 3 s after WSL booted and exit code `0`. Docker appears to record the stop when the daemon starts again, not when the host died, so `FinishedAt` doesn't tell when a container really stopped; compare `StartedAt` with `date` to tell whether the stack restarted. *(Observed 2026-09-29, PC restarted with the stack running, no `compose stop`:)* the instance container showed `Exited (255)`, not 137, and the API reported `running`, not `terminated` as in the reboot test above (which ran `compose stop` first). Hypothesis, untested: an orderly Floci shutdown marks instances `terminated`, an abrupt one leaves them `running`. *(2026-10-01, overnight PC restart:)* the API said `pending`, a third state. Only the container check (`scripts/floci-instance-check.sh`) is reliable after any Floci restart. *(2026-10-03, PC restart, Floci 2.1.0:)* the API said `pending` again. The database kept a marker row together with its updated `clicks` value, and a redirect through the replacement instance incremented it: the data and the write path both survive a restart.

**59. Terminating a dead instance can leave its container behind.** *(observed)*
After the cold boot of 2026-10-03, `shortify_session` replaced `i-99e01efdfd65d74a7`, whose container had died with the PC (`Exited (255)`). The API reports the instance `terminated`, yet `floci-ec2-i-99e01efdfd65d74a7` was still there, exited, about 10 hours later, and Floci's log had no line about the instance. Instances terminated while their containers were running (the Auto Scaling probes, #57, #58) lost their containers within seconds. In the 2.1.0 source, terminate removes the container by the ID recorded on the instance, and at startup Floci removes containers whose instance is `terminated` (`reconcileOrphanedContainers`). Prediction: the leftover is gone after the next `shortify_up`; it was left in place on purpose so that start tests it (open question 25). Why terminate skipped it is unverified. Narrowed on 2026-10-04: an instance stopped through the API and terminated within the same Floci run lost its container normally (#61), so the leak needs a Floci restart between the container's death and the terminate. Disproved the same day: after another PC restart, the release terminated `i-7428d38fd2af89a6a`, whose container had also died with the PC, and its container was removed; the Floci start also removed `i-99e01…`'s leftover (open question 25), so the leak didn't recur. One visible difference: after the leaking restart the API reported the dead instance `pending`, this time `running`. Unverified whether that's the cause. Another data point the same day: `i-6f55efbfe630f5e41` (died with the PC, API `running`, terminated after the restart, #62) lost its container within 5 s too.

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
`--targets Id=$INSTANCE_ID` with the variable unset becomes `--targets Id=`, which the API accepts. Use `set -u` in scripts and run `shortify_up` (it sources `scripts/shortify-env.sh`) in every new terminal.

**29. Silent auto-start in `.bashrc` started the wrong stack.** *(tested)*
The line `cd ~/workspace/floci && docker compose up -d > /dev/null 2>&1` pointed at an obsolete standalone Floci directory. Every new terminal tried to start that stack instead of `floci-ui`, and the redirect hid every error. That is also where a second Floci instance came from earlier. The fix is to keep only `eval "$(floci env)"` in `.bashrc` and to start sessions explicitly with a named command (`shortify_up`) that shows its errors. The obsolete stack was deleted.

**27. Don't keep misleading configuration.**
The enforcement flag is still set but does nothing on this machine. Configuration that claims a control that isn't there creates false confidence. Remove it at the next Floci recreate.

**28. `latest-compat` is required for the floci-ui stack.** *(tested)*
The stack's init hook (`init/ready.d/01-setup.sh`) calls the AWS CLI, which only the compat image contains. That's the best explanation for "Runtime unavailable" with `latest`. The TLS-permission warning that appears in the logs is non-fatal and shows up with both images. The image also has no `ss` or `netstat`, only `curl`.

**41. RDS-managed master passwords work, and passwords are enforced.** *(tested)*
`create-db-instance --manage-master-user-password` created a Secrets Manager secret (`rds!db-…`, 38-character password) and reported `MasterUserSecret.SecretStatus: active`. The password from the secret logged in with `psql` through Floci's proxy, and a wrong password was rejected (`password authentication failed`), so a successful login is real evidence. The create call returned `available` immediately; on AWS it says `creating` for minutes, so always use `aws rds wait db-instance-available`. Decision: the database uses `manage_master_user_password` in Terraform. Code, plans and state never see the password. Read it fresh from the secret for manual access, never save it: RDS rotates it, and on AWS reading the secret is the IAM access check.

**42. Deleting the instance orphans its managed secret.** *(tested)*
After `delete-db-instance` and the `db-instance-deleted` waiter, `describe-secret` still returned the secret with no `DeletedDate`. As far as known, AWS removes the RDS-managed secret together with the instance (not verified here). Cleanup: `aws secretsmanager delete-secret --secret-id <arn> --force-delete-without-recovery`, then confirm `describe-secret` returns `ResourceNotFoundException`. After any database destroy or replacement on Floci, check for leftovers: `aws secretsmanager list-secrets --query "SecretList[?starts_with(Name,'rds!')].Name"`.

**43. Floci doesn't implement RDS deletion protection, and only stores gp2.** *(tested)*
`shortify-db` was created with `deletion_protection = true` and `storage_type = "gp3"`; the next plan showed `false -> true` and `"gp2" -> "gp3"`. `describe-db-instances` returns `DeletionProtection: None` (the field is absent) and `StorageType: gp2`. The in-place update reported `Modifications complete` and changed nothing (false success, like #36). A throwaway instance created with `--deletion-protection` was deleted without complaint; on AWS that delete fails. Workaround: `emulator_rds_unsupported_settings` (off by default, set in `terraform.tfvars`) requests `deletion_protection = false` and `gp2`, so the plan is honest and clean. A postcondition fails the apply whenever the API doesn't report deletion protection on, unless the flag is set; tested with the flag off on Floci, the apply failed with that message. On Floci only `prevent_destroy` protects the database, and it disappears if the resource block is deleted.

## Application

**15. `short_url` is wrong behind the ALB.**
`main.py` hardcodes `http://localhost:8000/{code}`. It needs a `BASE_URL` setting.

**16. AWS CLI pager.**
Long output opens in `less`. Use `--no-cli-pager` or `export AWS_PAGER=""`.

## CI (Phase 3a)

**30. The laptop's Python differs from the project's.** *(tested)*
WSL on Ubuntu 26.04 ships Python 3.14; the project targets 3.12 everywhere else (Dockerfile, EC2, `ruff.toml`, CI). `psycopg2-binary==2.9.9` has no wheel for 3.14, so pip tries to compile it and fails on missing `pg_config`. Don't adapt the dependencies to the laptop: run the tests in a `python:3.12-slim` container on the Phase 1 database network (runbook section 8).

**31. Docker credential helper broken after a WSL integration crash.** *(tested)*
`docker run` of an image not yet pulled failed with `error getting credentials`. Docker's config pointed at the Windows helper (`credsStore`), which stopped working. Fix: restart Docker Desktop cleanly; if that isn't enough, back up `~/.docker/config.json` and remove `credsStore` (public images need no credentials).

**39. The repo lives on a Windows drive, and the shell's directory can vanish.** *(observed)*
`~/workspace` is a symlink to `/mnt/e/Workspace`, a Windows drive mounted into WSL through 9p (drvfs): every file shows `rwxrwxrwx` and directories are 512 bytes. After `docker run -v "$PWD":/src …` and `docker compose down`, every git command failed with `Unable to read current working directory`, while `ls` still worked. `findmnt -T .` then listed `/mnt/e` mounted twice: a second mount over the first hides the directory the shell was in, so its path can't be resolved. `cd` into the path again fixes it; nothing is lost. What creates the second mount is unverified (suspect: Docker Desktop bind-mounting a `/mnt/e` path). The same mount breaks file modes: git sets `core.fileMode = false` because the drive reports every file as executable, so `chmod` changes nothing git can see and new scripts are committed as `100644` (`scripts/floci-replace-instance.sh` was). Set the bit in the index with `git add --chmod=+x <file>` and check it with `git ls-files -s`; `ls -l` can't show it here. Sourced files (`scripts/shortify-env.sh`) stay `100644` on purpose.

**32. `ubuntu-latest` is a moving label.** *(done)*
GitHub's changelog (2026-09-17): `ubuntu-latest` moves from Ubuntu 24.04 to 26.04 in a gradual rollout between 2026-10-19 and 2026-11-19, and warns it may break builds that depend on tools or packages that changed. During a gradual rollout, the same commit could run on either OS, so a gate could flip red or green with no code change. All three jobs now use `runs-on: ubuntu-24.04`, the same OS as the EC2 hosts. Moving to 26.04 will be a deliberate PR, tested on `ubuntu-26.04` first. Effect verified on PR #7 through the jobs API (`gh api repos/<owner>/<repo>/actions/runs/<id>/jobs --jq '.jobs[] | [.name, (.labels | join(","))]'`): all three jobs requested `ubuntu-24.04` and ran Ubuntu 24.04.5. The job log alone can't prove this: it shows the image (`ubuntu-24.04`) and the OS version, but not the requested label, and while `ubuntu-latest` still points at 24.04 both labels produce the same log.

**33. CI reports, a ruleset enforces.** *(tested)*
A deliberately broken PR turned red (Lint failed, Test skipped) but the merge button stayed active until the `protect-main` ruleset existed (PR required, no force pushes, no bypass). The ruleset first required only `Lint`: `Test` had never been added, so a PR with failing tests could have been merged. Spotted on 2026-09-26 because only `Lint` showed a `Required` badge, confirmed with `gh api repos/gustavosaviano/shortify/rules/branches/main`, then fixed. Effect verified with PR #4: a deliberately failing, lint-clean test left `Test` red and `Required`, and the merge button disabled with no bypass option. Check the effective rules through the API, not the PR page. `Lint` stays required too: GitHub documents that jobs skipped because a job they depend on failed don't report a failure, so requiring only `Test` wouldn't block a lint failure. The ruleset now requires `Lint`, `Test` and `Terraform` (checked on 2026-09-26 via the API), and `Scripts` since 2026-10-04.

**40. A required check skipped by a `paths:` filter blocks the PR forever.** *(documented)*
GitHub's docs: if a workflow is skipped by path, branch or commit-message filtering, its checks stay `Pending` and a PR that requires them can't merge ("Waiting for status to be reported"). A job skipped by an `if:` condition instead reports `Success`, so a wrong "did `.tf` files change?" guess would pass a required check without running it. Decision: the `Terraform` job (`fmt -check`, `init -backend=false -lockfile=readonly`, `validate`) runs on every PR; it takes about 15 s. Effect tested on PR #5: a deliberately misaligned `=` in `variables.tf` turned `Terraform` red at the `fmt` step (exit 3) while `Lint` and `Test` stayed green; restoring it with `terraform fmt` turned it green.

**45. Ubuntu's `gh` package is broken: install it from GitHub's repository.** *(tested)*
The Ubuntu package (`gh` 2.46.0) failed on `gh pr edit` because it still queries the retired Projects (classic) API; that's why the title edit on PR #6 failed. GitHub's install docs confirm that the community-distributed `2.45.x`/`2.46.x` packages are broken by deprecated APIs and recommend the official apt repository. Installed `gh` 2.101.0 from `cli.github.com/packages` after checking the keyring file's published SHA256 and both key fingerprints (runbook section 1). The login in `~/.config/gh/hosts.yml` survived the upgrade. Effect verified on PR #7: `gh pr merge --squash --subject` set the commit title. Related practice: judge a pushed commit by its own run (`gh run list --json headSha,conclusion`), not by `gh pr checks` right after the push. On PR #7 that command printed exactly the previous run's timings; whether it was showing the old run is unverified.

## Terraform (Phase 4)

**34. Floci ignores the provider's removal of the default egress rule.** *(tested)*
Terraform documents that it removes AWS's default allow-all egress rule from groups it creates. The debug log (`TF_LOG=DEBUG`) shows the provider sending `RevokeSecurityGroupEgress` with `IpProtocol=-1, FromPort=0, ToPort=0`; Floci answers `true` and removes nothing, because it matches on ports and its default rule has none (AWS ignores ports for protocol `-1`). The same revoke without ports works. Workaround: `terraform_data.revoke_default_egress` in `security.tf`, which is off by default (`emulator_revoke_default_egress`), re-runs whenever a group is recreated, and fails the apply if the rule is still there. Tested by recreating a group with `-replace`. To report upstream.

**35. Standalone rules make unmanaged rules invisible.** *(tested)*
With `aws_vpc_security_group_*_rule` resources, `terraform plan` showed `No changes` while an extra allow-all rule existed. Refresh only reads what is in the state; nobody owns "the complete rule set". Inline rules would flag it, but create dependency cycles between groups that reference each other. Mitigation belongs to Phase 6 (AWS Config / audit).

**36. Floci ignores security group rule modifications.** *(tested)*
After replacing the database group, `app_to_db` reported `Modifications complete` twice, yet every plan still showed `referenced_security_group_id` pointing at the original, deleted group. Confirmed at the API level: `aws ec2 modify-security-group-rules` with a new `ReferencedGroupId` returns `true` and `describe-security-group-rules` still shows the old group. In Floci's data the app → database rule pointed at a group that no longer existed; on AWS that would cut the app off from its database.
Fix: every rule that references another group has `lifecycle { replace_triggered_by = [<that group>.id] }`, so replacing a group recreates the rules pointing at it instead of modifying them. Creating rules works on Floci, and the pattern is valid on AWS (a rule is briefly absent during a group replacement, which is disruptive anyway). The existing broken rule needed one `-replace`. Rebuild test: replacing the database group planned `4 to add, 0 to change, 4 to destroy` (`app_to_db will be replaced due to changes in replace_triggered_by`), and the following plan was `No changes`. To report upstream together with #34.

**38. Never press Ctrl+C twice on Terraform.** *(observed)*
One interrupt lets Terraform finish its current step and exit cleanly; a second one exits immediately and can leave the state half-written ("data loss may have occurred"). A pasted line accidentally started an apply that was interrupted twice; it had only loaded the provider, so nothing changed. Proof: the next `terraform apply tfplan` succeeded, and Terraform refuses to apply a saved plan whose state changed since it was made.

**37. The admin IP leaks into plans, state and debug logs.**
`terraform.tfvars` (git-ignored) keeps it out of the code, but `terraform plan` output, `terraform.tfstate`, `tfplan` and `tf-debug.log` all contain it. None of them is ever committed; watch CI logs once Terraform runs in the pipeline. Locally, `terraform fmt -check -recursive -diff` also checks the git-ignored `terraform.tfvars` and prints its contents, IP included, when it isn't formatted: don't paste that output anywhere public. CI never sees the file.

**44. A failed plan still writes its `-out` file.** *(tested)*
`terraform plan -destroy -out tfplan` failed on `prevent_destroy` (`Instance cannot be destroyed`, exit 1), yet `tfplan` existed: a partial plan with 22 changes. `terraform show -json tfplan` reports `errored: true`, and Terraform documents that an errored plan can't be applied (not tested by applying it). Check the exit code, never the file's existence, and delete leftover plan files. Automation must follow the same rule.

**47. Floci drops the tags sent with a key pair import, and returns no key type.** *(tested)*
`aws_key_pair.admin` (an ed25519 public key, imported) was created, yet the next plan wanted to add `Name`, `ManagedBy` and `Project`. `describe-key-pairs` returned `Tags: []` and `KeyType: null`. The fingerprint matched `ssh-keygen -lf` exactly (Floci shows it as base64 SHA-256 with `=` padding and no `SHA256:` prefix; AWS's format not verified here), so the key material itself was stored correctly. The in-place update (`CreateTags` on the key pair ID) did store the tags and the next plan was clean: only the tags inside `ImportKeyPair` (`TagSpecifications`) are dropped. `key_type` is a computed attribute, so no plan can reveal the missing type; nothing in this project reads it.
"Apply twice" isn't reproducible, and every create repeats the bug: a rebuild, and every key rotation, since a new key replaces the key pair. Rejected: `ignore_changes` on the tags (it would hide real drift on AWS) and dropping the tags (`default_tags` still applies). Workaround: `terraform_data.key_pair_tags` in `keypair.tf`, off by default (`emulator_key_pair_create_tags`). It runs `create-tags` right after the key pair is created, re-runs whenever the key pair is replaced (`triggers_replace = key_pair_id`), and checks each tag's value, failing the apply if one is missing. The expected tags come from the configuration (`local.default_tags` merged with the key pair's own), never from `tags_all`: after create that attribute holds the API's read-back, and the first version of the workaround looped over that empty map and verified nothing (lessons-learned, false-success pattern). A precondition now fails the apply if the expected set is ever empty. That first run also showed `create-tags` accepting an empty `--tags` without an error (CLI or Floci: unverified which).
Tested with `-replace=aws_key_pair.admin`: a single apply ran `create-tags` with three pairs plus three checks, and the next `plan -detailed-exitcode` returned `0`. The check's failure path (a tag still missing after `create-tags`) hasn't been exercised. To report upstream with #34, #36, #42 and #43.

**48. `aws_instance` works on Floci from Terraform.** *(tested)*
`aws_instance.app` (`ami-ubuntu2404-amd64`, `t3.micro`, `public-01`, the `app` SG, key pair `shortify-admin`) was created in 10 s, and the next `plan -detailed-exitcode` returned `0`: every attribute the provider reads back matched. The container was `Up` with SSH on host port 2200, sshd answered on the first try (the instance was already past the ~34 s delay, #25), and `/root/.ssh/authorized_keys` held exactly one key, whose fingerprint equals `ssh-keygen -lf` of the local `.pub`: Floci installs the Terraform key pair's key at launch. A login alone would only prove that *some* accepted key matches.
The earlier `aws_instance` provider crash didn't reproduce with provider 6.66.0 and this minimal configuration. Its log was never kept, so it's unexplained, not fixed. The two `provider: plugin exited` lines in the debug log are the provider's normal shutdown; a crash shows `panic:` and a goroutine trace.
Key rotation: `plan -replace=aws_key_pair.admin` planned the instance replacement `due to changes in replace_triggered_by` (3 to add, 3 to destroy; planned, not applied). IMDSv2 is now required (#49); user data is not set yet. Any Floci stop still kills the instance (#26): after a Floci restart, replace it with `-replace=aws_instance.app`. **A plan doesn't notice a dead instance** *(tested 2026-09-29)*: after a PC restart the container was `Exited (255)`, `describe-instances` said `running`, and `plan -detailed-exitcode` returned `0`. Terraform only sees what the API reports, so health is never inferred from a clean plan: `scripts/floci-instance-check.sh` (run by `shortify_up`) checks the container and the sshd listener, and on AWS the signals are EC2 status checks and ALB target health. `-replace=aws_instance.app` then destroyed the dead instance cleanly (10 s) and launched a working one.

**49. IMDSv2 on Floci 2.1.0: `required` is stored, tokens aren't checked.** *(tested)*
`aws_instance.app` now has `metadata_options { http_tokens = "required", http_put_response_hop_limit = 1 }`: users submit arbitrary URLs, so a future SSRF bug must not be able to read instance credentials with a plain `GET`. It planned as an in-place update (`"optional" -> "required"`, no replacement) and `ModifyInstanceMetadataOptions` took 10 s. Verified at four levels: a postcondition fails the apply unless the provider reads back `required`; `describe-instances` reports `State: applied`, `HttpTokens: required`, hop limit `1`; the next `plan -detailed-exitcode` returned `0`; the container's `StartedAt` didn't change (no hidden restart, #9).
From inside the instance, before and after the change, the token flow works (`PUT /latest/api/token` → `200` with a 32-character token, `GET` with it → `200` and the right ID). So do a tokenless `GET`, a made-up token, a random 32-hex token and a TTL of `0`: all `200`. Floci's docs say an unknown token gets `401`, a TTL outside 1–21600 gets `400`, and `HttpTokens=required` isn't enforced. The first two come from `fix(ec2): validate and expire IMDSv2 session tokens` (#4303), committed 2026-09-24; the running image is 2.1.0 (built 2026-09-15), still the latest release, and the docs site is built from `main`.
Consequences: on Floci, a `200` with a token proves only that the endpoint exists, not that the client sent a valid token, which is why the test included a fake-token control. That a tokenless request is refused can only be validated on AWS (expected `401`; not verified here). No emulator flag: nothing breaks, and a workaround can't create enforcement. Running an unreleased image was rejected (not pinned, not reproducible); after the next release, re-run the fake-token and TTL checks with a written prediction. IMDSv2 is also stored at launch, a different API path (RunInstances): a replacement instance passed the postcondition, and `describe-instances` reported `applied required 1`.

**51. IAM on Floci 2.1.0: roles work, instance profiles are partial.** *(tested)*
`iam.tf` gives the app instance a role that may call `secretsmanager:GetSecretValue` on the database secret only, through an instance profile: short-lived credentials via IMDSv2 instead of access keys. The role and its inline policy were stored as written (`get-role-policy` returned the secret's ARN, equal to the `db_master_secret_arn` output). Three gaps:
- **Attaching a profile to a running instance is unsupported:** `AssociateIamInstanceProfile` returns `UnsupportedOperation` (an honest error, not a false success). On AWS the provider does it in place. Workaround without code: replace the instance (`-replace=aws_instance.app`); a profile given at launch (`RunInstances`) is stored. The role is part of the instance's launch shape anyway (a launch template in Phase 3b).
- **Instance-profile tags can't be stored:** the provider's tag update reported `Modifications complete` and `aws iam tag-instance-profile` exited `0`, yet `get-instance-profile` returns `Tags: null` and `ListInstanceProfileTags` is `UnsupportedOperation`, so every plan wanted to add the default tags. Unlike #47 no API path exists for a self-verifying workaround, and `ignore_changes` can't be conditional, so the profile has `lifecycle { ignore_changes = [tags_all] }` everywhere. Cost on AWS: tags are set at creation; later `default_tags` changes won't reach this one resource. The role's tags were stored normally.
- **Enforcement is untested:** Floci accepts any credentials, so least privilege is validated on AWS only.
Role credentials *do* work: with the profile attached, `iam/security-credentials/shortify-app` through IMDSv2 returned `AccessKeyId`, `SecretAccessKey`, `Token`, `Expiration` and `Code: Success`, although the commit `fix(ec2): issue instance-profile role credentials through IMDS` (#3742) came after 2.1.0 (a "fix" in the history doesn't mean the feature was absent). So the app uses the standard AWS credential chain on both; on Floci only the endpoint differs. The instance reaches Floci's API by container name (`http://floci-ui-floci-1:4566`, `/_floci/health` → `200`) over Floci's compose network `floci_default`, which the instance is also on. Floci itself was attached only to `floci_default`, not to the VPC network (compare #11): whether the ALB still reaches instances is checked at the first registration.

## Ansible (Phase 4)

**50. Ansible ignores `ansible.cfg` in a world-writable directory, and then deploys to nobody.** *(tested)*
On the Windows drive every directory is `drwxrwxrwx` (#39). Ansible refuses a config file in a world-writable current directory (it warns, and `config file = None`); an explicit `ANSIBLE_CONFIG` loads it, so `scripts/shortify-env.sh` exports it. Relative paths inside it (`inventory`) resolve against the config file's directory: tested from `/tmp`. Without the config there is no inventory, the play matches no hosts, and `ansible-playbook` exits `0` with an empty recap: a deploy to nobody that "succeeds" (known-bad run with `ANSIBLE_CONFIG` unset). The playbook's first play now fails unless group `app` has hosts. The variable lives in the shell: a shell started on a branch whose `shortify-env.sh` lacks the export doesn't have it until the script is sourced again. CI and the pipeline clone onto a normal filesystem, where the current-directory lookup works.

**52. Ansible 2.21 templating differs from older docs and habits.** *(tested)*
- `lookup('ansible.builtin.env', 'X', default=Undefined)`, still shown in the docs, fails with `'Undefined' is undefined`; `default=undef(hint='...')` fails with the hint. The Floci inventory uses it for `INSTANCE_ID`.
- The guard's first form, `groups.get('app', []) | length > 0`, evaluated to `false` once in the playbook while the inventory was loaded. The same expression later passed in an ad-hoc `debug`, an ad-hoc `assert` and a throwaway playbook: not reproduced, cause unknown. The guard uses `groups['app'] | default([]) | length > 0`, which passed every test.
- Refuted: although every file on the Windows drive looks executable, Ansible didn't try to run `hosts.yml` as an inventory script, so no `enable_plugins` setting was added.
- Play `vars` override inventory variables: a default for `emulator_no_systemd` in the play's `vars` would silently switch off the Floci inventory's `true`, so the default sits in each `when:` (`emulator_no_systemd | default(false)`).

**53. No systemd on Floci's amd64 images: the playbook starts the unit's command itself.** *(tested)*
Floci 2.1.0's only image with systemd is `ami-ubuntu2404-cloud-arm64` (its ID changed since #9 was written, and its metadata name equals the plain arm64 image). Rejected for parity: CI and the AWS target are amd64. The playbook installs the systemd unit on both; with `emulator_no_systemd: true` (Floci inventory only), `/usr/local/sbin/shortify-floci start|stop|status` runs the unit's exact command (`app_command`, defined once) as `shortify` with the same environment file, through `start-stop-daemon` (detach, pidfile, user, directory). Restart on crash and start on boot are validated on AWS only.
Zombies: PID 1 in Floci's instance containers is `tail -f /dev/null`, which never reaps exited children, so a stopped app stays `<defunct>` until the container goes. `start-stop-daemon --stop` waits for the PID to vanish and fails (`refused to die`), and `--status` reports the zombie as running. The first redeploy failed that way and left the app down: the in-place deploy risk, on a disposable instance. The control script treats a zombie as stopped (it has released its port and memory) and requires the pidfile's process to belong to `shortify`, so a reused PID is never killed. Its first version used `grep '^shortify *[^Z]'`, which matches a zombie because `[^Z]` matches the space; it now compares `ps` fields with `awk`. Verified: a redeploy replaced the process (new PID, the new commit's release in `ps`, `/health` `200`), leaving one zombie per stopped process. Instances are replaced on every restart, so zombies never accumulate.

**54. A release is `git archive` of the commit, and git's own umask applies.** *(tested)*
The playbook packages `app/` and `requirements.txt` from `HEAD` on the laptop, refuses uncommitted changes in them (`git archive` would silently ship the old code), and unpacks into `/opt/shortify/releases/<commit>` with a venv per release. Code and venv are root-owned: `shortify` writing into them got `Permission denied`. `git archive` applies git's `tar.umask` (default `002`), so files came out `664` and directories `775`; `-c tar.umask=0022` makes the modes part of the command (`644`/`755` verified) instead of each machine's git config.

**55. The API's RDS endpoint is reachable from instances on Floci.** *(tested)*
`db_endpoint` is `172.19.0.2:7001`: Floci's own address on `floci_default` plus its proxy port. The instance, also on `floci_default`, reaches it (and `floci-ui-floci-1:7001`), so `DATABASE_HOST`/`DATABASE_PORT` come straight from Terraform on Floci and AWS alike. Only the laptop can't reach that address and uses `localhost` (#14). The app started with it and created the `links` table in the Terraform-built database. *(Updated 2026-10-02:)* after Floci was connected to the VPC network (#11), the endpoint became `10.0.0.2:7001`, Floci's address on that network: the next refresh reported `aws_db_instance.db has changed`, the next deploy wrote the new value, and the app connected with it. Floci reports one of its own addresses, so the endpoint follows its network attachments; the deploy must always read it from Terraform, never reuse an old env file. Which address Floci picks when it's on several networks is unverified.

**56. A fresh instance failed its first deploy, and a rerun hid it.** *(tested)*
On a fresh instance, unpacking the release, writing the env file and installing the unit all notify `Restart the app`, and the first `flush_handlers` runs its Floci handler `/usr/local/sbin/shortify-floci stop`. The playbook installed that script only after the flush: `fatal: … "cmd": "/usr/local/sbin/shortify-floci stop", "rc": 2` (`[Errno 2] No such file or directory`), the app never started and `/var/log/shortify/` stayed empty. A rerun passed with `changed=2` (install the script, start the app), so after every reboot, which forces a replace (#26), the first deploy failed and the second succeeded: it looked like flakiness. Reproduced on purpose on a fresh instance before fixing. Fix: the control script is installed before any task can notify the handler, and the second flush is gone. Verified on a fresh instance (`i-99e01efdfd65d74a7`): first run `exit=0`, no `fatal:`, `changed=11`; second run `changed=0`. After a PC restart (2026-10-03), `shortify_session` replaced the instance and its first deploy passed on the first try (`i-6f55efbfe630f5e41`: `failed=0`, `changed=12`). The count depends on the laptop too: packaging the release runs there and reports `changed` only when `/tmp/shortify-<commit>.tar.gz` is missing (`creates:`). That run's twelve were the packaging plus eleven tasks on the host; the earlier eleven are consistent with the packaging being skipped (that log wasn't kept). Confirmed on 2026-10-04: the same commit deployed to two fresh instances reported 12 the first time and 11 the second, with its tarball already built (#61). Judge a deploy by `failed=0` and the health check, not by the count. Phase 3b launches a fresh instance for every release, so this would have failed every release. The failure first went unnoticed because the run was piped through `tail`: a pipeline's exit status is the last command's, so the `&&` after it carried on. Send the output to a file and check `$?`.

## Release instances and Auto Scaling (Phase 3b)

**57. Floci's Auto Scaling launches real instances, and drops the launch template's metadata options.** *(tested)*
A one-instance group (`shortify-probe-asg`, from a launch template with the app instance's AMI, type, key pair, security group, instance profile and IMDSv2 settings) launched `i-7ab7e6e296f77bb17`: `Pending` about 15 s after the group was created, `InService` about 10 s later. On Floci, `InService` only means EC2 reports `running`, so the instance was checked like any launch: the instance check passed, `authorized_keys` held exactly one key with the local fingerprint, and subnet, key pair, instance profile and security group matched the template. `HttpTokens` came back `optional`, against `required` on the Terraform-launched instance read the same way (the known-good control); the hop limit was 1 on both, which may only be Floci's default. The 2.1.0 source agrees: the reconciler's `RunInstances` call passes no metadata options. Floci doesn't enforce the setting anyway (#49), so the loss shows only in the API; on AWS a launch template's metadata options apply to Auto Scaling launches (not verified here). Read in the 2.1.0 source, not tested: launches go to the group's first subnet only (no spread across AZs), an attached target group gets each instance registered as soon as EC2 reports `running`, and the health check type and lifecycle hooks are stored but nothing acts on them. Answers open question 21. A direct launch from the same template keeps them (#60).

**58. Floci's instance refresh terminates first.** *(tested)*
`start-instance-refresh` on the one-instance probe group with `MinHealthyPercentage=100`, `MaxHealthyPercentage=200` and `InstanceWarmup=0`, which on AWS mean "launch the replacement before terminating": at 5 s the old instance was `Terminating` with no replacement, at 10 s the new one was `Pending`, at 15 s it was `InService` and the refresh `Successful`. Two samples had no instance in service, which with one instance is an outage. The 2.1.0 source marks every instance `Terminating` at once and stores the preferences without using them. A zero-downtime release through an instance refresh can't be shown on Floci, and that decided Phase 3b (README, key decisions). `delete-auto-scaling-group --force-delete` removed the group's instance and its container within 10 s. To report upstream with #57 and the other Floci bugs (#34, #36, #42, #43, #47, #49, #51).

**60. A Terraform launch template works on Floci, and a direct launch from it keeps every setting.** *(tested)*
`aws_launch_template.app` (no image; instance type, key pair, security group, instance profile, IMDSv2 and instance tags) was created in 6 s, its `http_tokens` postcondition passed, and the next `plan -detailed-exitcode` returned `0`: Floci stored the template's own tags, unlike a key pair import's (#47). `run-instances --launch-template LaunchTemplateId=<id>,Version=1 --image-id ami-ubuntu2404-amd64 --subnet-id <public-01>`, the way a release launches, gave an instance with the launch's image and everything else from the template: `HttpTokens` `required`, the `shortify-app` instance profile, the app security group, and `shortify-admin` with exactly one key in `authorized_keys`, matching the local fingerprint. Its tags were exactly the template's instance tags (`ManagedBy = release`, `Name`, `Project`); Floci adds no `aws:ec2launchtemplate:*` tags, which AWS adds (not verified here). The same template data through an Auto Scaling group lost the metadata options (#57): in the 2.1.0 source, the `RunInstances` request handler merges the template's options, while the reconciler calls the EC2 service directly. Host SSH ports are reused after termination (this probe got 2202 again).

**61. A release replaces the serving instance with zero failed requests.** *(tested)*
`scripts/release.sh ami-ubuntu2404-amd64` (launch from the pinned template with a `Release=<commit>` tag, verify IMDSv2 and the tags on the instance, wait until it's usable and trusts exactly our key, deploy with Ansible, cut over with `release-register.sh`, terminate every other `ManagedBy=release` instance) replaced `i-6f55efbfe630f5e41` with `i-e0cfdcbd5aa3e3129` in about 3 minutes, while a loop requested `/health` through the ALB once a second: 178 samples, all `200`. `i-6f55…` was deregistered only after the new target was healthy, and left running: it is still in Terraform's state (`ManagedBy=terraform`), and terminating it behind Terraform's back would make the next plan recreate it. Cold path: with the serving instance stopped through the API (`stop-instances`, the state a PC restart leaves, #9), `shortify_session` found it not usable and ran a release: deploy `changed=11` (the commit's tarball was already built, #56), cutover, then the stopped release instance was terminated and its container removed. Failure paths (lost IMDSv2, invalid image, env not sourced) were tested against fake CLIs only. Cold boot (2026-10-04, PC restart): `shortify_session` found the serving release instance dead (`container exited`, API `running`), released `i-ca9d93492622a3a6c` (deploy `changed=12`: commit `0ede4f9` had never been packaged), then deregistered and terminated the dead one: `session exit=0`, `/health` 200 (open question 26). The failure paths are now tests in CI (`tests/scripts/run.sh`).

**62. `aws_instance.app` left Terraform without being destroyed.** *(tested)*
A `removed` block with `lifecycle { destroy = false }` replaced the resource (Terraform 1.16.4). The plan said `aws_instance.app will no longer be managed by Terraform, but will not be destroyed`, `Plan: 0 to add, 0 to change, 0 to destroy.` and a warning listing it; its JSON (`terraform show -json tfplan`) held exactly one change, `aws_instance.app` with the action `forget`, and the apply ran only behind a gate on that. Afterwards the state held no instance, `i-6f55efbfe630f5e41` still existed in the API, and the next plan was clean. The instance was then terminated through the API (its container was removed within 5 s) and the plan stayed clean: Terraform no longer owns an app instance, and its `instance_id` output, the `app_ami_id` variable and `scripts/floci-replace-instance.sh` are gone. The `removed` block stays as the record; on a state that never had the instance it does nothing. Read a plan's JSON before applying, not only its text: this line is indented by one space, and a `grep '^  # '` for planned actions missed it.

## Deploy pipeline (Phase 3b)

**63. Floci's S3 honours conditional writes.** *(tested)*
On a temporary bucket, the first `put-object --if-none-match '*'` wrote the key (exit 0), a second one to the same key failed with `PreconditionFailed` (exit 254, AWS's HTTP 412), and a plain overwrite, the control, succeeded (Floci 2.1.0, 2026-10-06). Terraform's S3 backend locks with `use_lockfile = true` by creating a lock object with a conditional write, so on Floci the lock is real, not just declared.

**64. Floci's S3 survives restarts in `persistent` storage mode.** *(tested)*
Floci's default storage mode is `memory`, which loses everything on restart. This stack runs with `FLOCI_STORAGE_MODE=persistent` and `FLOCI_STORAGE_PERSISTENT_PATH=/app/data`, a bind mount of `~/workspace/floci-ui/data`, with no per-service override (check: `docker inspect floci-ui-floci-1 --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^FLOCI_STORAGE'`). A versioned canary bucket written twice (`v1`, then `v2`) kept versioning `Enabled` and returned `v2` after a `docker compose stop` and `shortify_session`, and again after a PC restart. RDS data surviving proves nothing about S3: Floci's RDS mode covers only its RDS metadata, not the database volumes. Not confirmed yet: that both versions survived, because the listing command failed on the laptop (#66). The Terraform state survived one too: on 2026-10-08, after a PC restart, the session read every ID from the state in S3 (#67) and the release ran normally.

**65. A job on the self-hosted runner inherits the environment of whoever started the runner.** *(tested)*
A read-only probe workflow in `shortify-deploy` (run 37408524837, runner started with `./run.sh` in an interactive terminal) saw `AWS_ENDPOINT_URL`, the dummy credentials and the region, all exported by that terminal's `~/.bashrc`; a runner started as a service wouldn't have them. Its `PATH` also carried WSL's Windows directories (`/mnt/c/...`), and `ansible-playbook` was missing (it lives in `~/.venvs/shortify-ansible`). The job ran as `gus`, in the `docker` group, under `bash -e`, and found the Terraform state and the SSH key at their laptop paths. So the deploy workflow declares its own `env:` and `PATH`. The runner also masked as `***` every log line containing `pwd=`, the script line included. The cause isn't verified (no matching rule turned up in the runner 2.337.0 log masker), so don't use `pwd=` as a log label.

**66. Ubuntu 26.04's `awscli` package fails on some commands under Python 3.14.** *(tested)*
`awscli 2.31.35-1` (`/usr/bin/aws`; `aws --version` says `Python/3.14.4 ... source/`) exits 255 with `badly formed help string` on `s3api list-objects-v2` and `s3api list-object-versions`, with or without `--no-paginate`, before sending any request. `aws --debug` shows why: while building the command's options, `add_argument` reaches Python 3.14's `argparse._check_help`, which raises `ValueError`. The commands our scripts use (EC2, ELBv2, RDS, Secrets Manager, S3 put and get) work, and Terraform doesn't use the CLI. Planned fix (parked): AWS's official installer, pinned, with its PGP signature verified; it bundles its own Python and reports `exe/`. A laptop tooling problem, not a Floci one.

**67. Terraform's S3 backend works on Floci with nothing but the environment, and its lock blocks a second writer.** *(tested)*
A throwaway root with only `key`, `region`, `use_lockfile = true` and `encrypt = true` (bucket passed with `-backend-config`) initialized against Floci 2.1.0 with the shell's `AWS_ENDPOINT_URL` and no `endpoints`, `use_path_style` or `skip_*` setting (Terraform 1.16.4, 2026-10-07). The prediction was that it would need path-style URLs; it didn't. Whether the SDK used virtual-hosted URLs (`bucket.localhost.floci.io`) or path style isn't verified. `init` succeeding proves little, because it may write nothing, so the backend was judged by a write: an apply with one output stored the state (249 bytes, `ServerSideEncryption: AES256`, a version ID) and left no `<key>.tflock` behind (`head-object` exit 254). The known-bad control: while an apply held the lock at its approval prompt, a second `plan -lock-timeout=0s` failed with `Error acquiring the state lock`, and the lock was gone after the holder was cancelled. The real backend (`infra/terraform/backend.tf`) has the same settings; only the bucket, whose name contains the account ID, comes from a per-environment file (`backend-floci.hcl`). `AES256` shows that Floci recorded the encryption setting; whether its files on disk are encrypted isn't verified and doesn't matter here.

**68. The shell's AWS settings came from the Floci CLI, not from the repo.** *(tested)*
The provider and the backend read `AWS_ENDPOINT_URL`, the credentials and the region from the environment, but `scripts/shortify-env.sh` exported none of them: they came from `eval "$(floci env)"` in `~/.bashrc` (Floci CLI 0.2.3 in `/usr/local/bin`, separate from the Floci 2.1.0 server), which prints four `export` lines (endpoint `http://localhost.floci.io:4566`, region `us-east-1`, dummy credentials). So what Terraform targeted depended on an unversioned file, on the CLI being installed, and on its output, which could change with a CLI upgrade; it's also why the runner only worked when started from an interactive shell (#65). With remote state, even `terraform output` needs those settings. `shortify-env.sh` now exports the same four values itself before reading Terraform (checked equal to `floci env`'s output), and a test proves it overrides a different endpoint already set in the shell.

**69. Migrating the local state to S3 kept its content but reset its lineage and serial.** *(tested)*
`terraform init -force-copy -backend-config=backend-floci.hcl` (Terraform 1.16.4) moved the 32-resource state: afterwards `plan -detailed-exitcode` returned 0, and `resources`, `outputs`, the Terraform version and the format were identical to a backup taken just before. But the remote state had a new `lineage` and `serial` 1, where the local one had another lineage at serial 125; the prediction was that both would be kept. The cause isn't verified. Terraform left the local `terraform.tfstate` empty (0 bytes) next to a `terraform.tfstate.backup` with the old lineage. The consequence: restoring that backup is no longer a plain `terraform state push`, which refuses a different lineage; it needs `-force` (runbook section 9). Judge a migration by its effects (a clean plan and identical resources), not by its header.

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
| ALB with no healthy targets | `503`, plain-text body `No targets available` (none registered) or `Service unavailable` (registered, unhealthy) | `503` with an HTML body (not verified here) |
| Container IPs from the host | Not reachable (Docker Desktop) | N/A |
| Default egress removal by Terraform | Revoke with ports 0/0 is ignored (workaround needed) | Removed |
| Security group rule modification | Ignored (returns `true`, nothing changes) | Applied |
| Provisioning time | Seconds (an instance: about 10 s; an ALB: about 60 s) | Minutes |
| RDS create status | `available` immediately | `creating` for minutes |
| RDS-managed secret on instance delete | Left behind (orphaned) | Deleted with the instance (not verified here) |
| RDS deletion protection | Not implemented (field absent, delete succeeds) | Enforced |
| RDS storage type | Always gp2 | As requested |
| Key pair tags sent with `ImportKeyPair` | Dropped (`CreateTags` afterwards works) | Stored |
| Key pair `KeyType` | Not returned (`null`) | `rsa` or `ed25519` |
| IMDSv2 tokens (Floci 2.1.0) | Any token and any TTL accepted | Invalid token `401`, TTL outside 1–21600 `400` (per the docs) |
| `HttpTokens=required` | Stored, not enforced (tokenless `GET` → `200`) | Tokenless requests refused |
| Packages on a new instance | Floci installs the IMDS proxy and `openssh-server` with apt at launch | Whatever the AMI contains |
| Dead instance after a Floci restart | API says `running`, `pending` or `terminated`; `terraform plan` can be clean | A failed host shows in EC2 status checks |
| Attach an instance profile to a running instance | `UnsupportedOperation` (replace the instance) | In place |
| Instance-profile tags | Silently ignored; can't be read back | Stored |
| Role credentials through IMDS | Issued (`Code: Success`) | Issued |
| systemd | None on amd64 images; PID 1 is `tail`, which leaves zombies | PID 1: starts, restarts and reaps services |
| RDS endpoint from an instance | Floci's proxy on `floci_default`, reachable | Private DNS name, port 5432 |
| Auto Scaling launch from a launch template | Real instance; metadata options dropped (`HttpTokens` comes back `optional`); first subnet only | Template settings applied; instances spread across the group's AZs |
| Instance refresh | Terminates every instance at once; healthy-percentage preferences stored, not used | `MinHealthyPercentage`/`MaxHealthyPercentage` honored, so the replacement can launch first |
| Instance launched from a launch template | Template settings and instance tags applied; no `aws:ec2launchtemplate:*` tags | Template settings applied; `aws:ec2launchtemplate:id` and `:version` tags added (not verified here) |

## Production notes

These are the changes a production deployment would add:

- **RDS:** encryption at rest (`--storage-encrypted`), deletion protection, Multi-AZ.
- **HTTPS:** an ACM certificate on a 443 listener, with a redirect action on the port-80 listener.
- **Instance placement:** instances in a private app tier, SSM Session Manager instead of SSH, and a NAT gateway or VPC endpoints for outbound traffic (designed in Phase 3b).
- **Least-privilege egress:** revoke the default allow-all egress rule. That's when the explicit ALB → EC2 egress rule starts to matter.
- **Secrets:** move them to Secrets Manager.
