# Lessons learned

A record of hypotheses that turned out wrong, how each was tested, and what was actually true. Several "fixes" early in Phase 2 worked for the wrong reasons. The verification round at the end of the phase replaced guesses with tested facts.

## Method

- **Baseline first.** No test runs until the environment passes the baseline checks. A test on a broken environment produces a wrong conclusion.
- **One variable at a time.** Changing two things at once made one of the early fixes impossible to attribute.
- **Prediction before execution.** Every test had a written expected result; a surprise is where the learning is.
- **Restore after each test,** and re-check the baseline before the next one.
- **Destructive tests last.**
- **Debug hop by hop from the outside in:** load balancer → instance → process → network path.

---

## The ALB health-check outage

| | |
|---|---|
| **Symptom** | Target `unhealthy / Target.Timeout` while the app was running and answering locally |
| **Hypotheses tried** | (1) Port 80 is blocked by WSL2 privileged-port rules. (2) EC2 containers only sit on Docker's default bridge, so the ALB can't reach them. (3) A leftover empty-ID target "poisons" the group. (4) Registering without `Port` breaks health checks. |
| **What happened** | A combination of changes appeared to fix it on day 1, and hypotheses 3 and 4 were credited. On day 2 the same symptom returned. |
| **Test** | `curl` from inside the Floci container to the instance's private IP exited `28` (timeout). `docker inspect` showed Floci attached only to `floci_default`, not to the VPC network. |
| **Finding** | The ALB runs inside the Floci container, which must be attached to the VPC's Docker network. A recreated Floci container loses that attachment. After `docker network connect`, the target turned healthy within the expected threshold time (5 × 30 s). |
| **Hypotheses disproved** | (1) A port-80 listener works (Docker allows low ports inside containers). (2) Instances are on the bridge, the VPC network *and* `floci_default`. (3) Empty-ID and stale targets are ignored; health is per target. (4) Portless registration falls back to the target group port. |
| **Takeaway** | A fix without a root cause is a coincidence. Look at the network path before theorizing about configuration. |

## Environment regressions after a reboot

| | |
|---|---|
| **Symptom** | The next morning: the ALB returned `Service unavailable`, `psql` got "server closed the connection unexpectedly", and SSH got "connection closed" |
| **Initial explanation** | "`docker compose up` was used instead of `start`, so the containers are gone." |
| **Test** | `docker ps -a` showed every container present. The Floci log showed `No Docker daemon is reachable from Floci`. |
| **Finding** | Docker had restarted and recreated its socket with default permissions, undoing an earlier `chmod 666`. Floci started without Docker access and couldn't restore RDS or instances. |
| **Fix** | `group_add` with the socket's gid, which survives restarts |
| **Takeaway** | A setup that only works until the next reboot is a snowflake, and that's exactly what IaC and configuration management exist to eliminate. |

## Instance lifecycle

| Hypothesis | Test | Finding |
|---|---|---|
| Starting the stopped containers from Docker Desktop restores the instance | Checked the processes inside with `docker exec` | Only `tail -f /dev/null` was running: no sshd, no app. Floci wasn't told. |
| An API reboot restores sshd | `aws ec2 reboot-instances` | It's a `docker restart`: still no sshd |
| An API stop/start restores sshd | `stop-instances`, then `start-instances` | It's a `docker stop`/`start` of the same container: still no sshd. A first attempt raced because a fixed `sleep 15` was shorter than the 30 s stop. |
| SSH failing right after launch meant a firewall block | Waited, then checked Floci's logs | sshd starts 34 s after `running`; it was timing |
| The enforcement flag killed an instance during a Floci recreate | Compared the container exit time with Floci's start time | The instance died 9 s *before* the new Floci started, so it was the old Floci's shutdown |

**Reboot test (end of Phase 2):** stop the stack, restart Docker and WSL, then recover using only the runbook. Four predictions held: `compose stop` stops the instance, `group_add` survives the restart, RDS returns with its data, and a `stop`/`start` keeps the VPC network attachment. One missed: the API reported the dead instance as `terminated`, not `running`. The environment went from a cold start to a healthy `/health` by following the runbook step by step.

**Takeaways:**
- **Replace, don't repair.** Only a fresh launch gives a usable instance on this image.
- **`running` doesn't mean ready.**
- **Wait for state with waiters, never with fixed sleeps.**
- **Operate through the API, never behind it.**

## Security group and NACL enforcement

| Hypothesis | Test | Finding |
|---|---|---|
| A `psql` timeout from the host proves the private subnet isolates RDS | Published the proxy ports | It was just an unpublished port; Floci doesn't enforce subnets |
| Floci can't enforce security groups at all | Read the docs | There's an opt-in firewall flag |
| With the flag on, SSH from the host would be denied because the source isn't the admin IP | SSH to a freshly launched instance, then again with the port-22 rule removed | SSH worked both times |
| With the flag on, removing the ALB → EC2 rule would break health checks | Revoked the rule, then opened a fresh connection from Floci to the instance | Still allowed |
| NACLs are ignored | Associated a deny-all NACL with the instance's subnet | Confirmed: nothing changed |

**Takeaway:** the emulator can't validate network security controls on this setup. The honest position is "designed and reasoned, validated only on real AWS", not "tested".

## The shell start-up line

| | |
|---|---|
| **Symptom** | After a reboot, opening a terminal didn't start the stack |
| **Hypotheses** | (1) Docker wasn't ready when the shell started. (2) `.bashrc` held an outdated line |
| **Test** | `grep -n floci ~/.bashrc` |
| **Finding** | (2): the line started an obsolete stack in another directory, with all output sent to `/dev/null`. The same line explained a mysterious second Floci instance earlier |
| **Takeaway** | Don't silence errors in automation, and prefer an explicit start step over a hidden side effect |

## The false-success pattern

The same failure mode showed up in different places: a call reports success and nothing changed.

| Where | Symptom | How it was caught |
|---|---|---|
| Design of the deploy (Phase 3) | A new app version fails to bind port 8000 in the background, the old one keeps answering `/health`, the deploy "succeeds" | Reasoned out before building: verify the *new* version via `/version`, not just any answer |
| Floci revoke (Phase 4) | `RevokeSecurityGroupEgress` returns `true`; the default rule stays | Checked the actual rules with `describe-security-groups`, then the request in the Terraform debug log |
| Floci rule modification (Phase 4) | `Modifications complete`, yet the next plan shows the old value; the rule points at a deleted group | Reading the plan after apply instead of trusting the apply, then repeating the call with the CLI to rule out the provider |
| Floci key pair import (Phase 4) | `Creation complete`; the next plan wants to add every tag | `plan -detailed-exitcode` right after the apply, then `describe-key-pairs` to rule out the provider |
| The key pair tag workaround itself (Phase 4) | `Creation complete`, no error, but the check had iterated over an empty map and verified nothing | Reading the `Executing:` line: `--tags` was empty and the check lines were missing. Expected values now come from the configuration, and a precondition refuses an empty set |
| Floci IMDS (Phase 4) | A `GET` with an IMDSv2 token returns `200`: the token flow "works" | A negative control written into the test: a made-up token also returned `200`. Floci 2.1.0 doesn't check tokens (edge case #49) |
| The instance check itself (Phase 4) | `sshd no` for an instance we had just logged into: a false *negative* | A known-good run before hooking the check into `shortify_up`. `docker top -o comm` is rejected (Docker needs the PID column) and `2>/dev/null` hid the error; the check now matches the sshd listener's process title |
| Floci instance-profile tags (Phase 4) | `Modifications complete` and `tag-instance-profile` exit `0`; the next plan still wanted the tags | `plan -detailed-exitcode` after the apply, then `get-instance-profile` (`Tags: null`) and `ListInstanceProfileTags` (`UnsupportedOperation`) (edge case #51) |
| Floci Auto Scaling launch (Phase 3b) | `InService`, the instance usable, every other setting as in the launch template; `HttpTokens` silently `optional` | Reading the instance next to the Terraform-launched one, a known-good control, instead of trusting the launch (edge case #57) |
| `ansible-playbook` with no inventory (Phase 4) | Warnings, an empty recap, exit `0`: a deploy to nobody | A known-bad run with `ANSIBLE_CONFIG` unset after a play had matched no hosts; the playbook now fails without hosts (edge case #50) |
| The Floci stop/status check (Phase 4) | A zombie counted as alive: `start` said `running` for a dead app, `stop` waited 20 s | Running the script by hand next to the raw `ps` output: the regex's `[^Z]` matched the space (edge case #53) |

**Takeaway:** verify the effect, not the return code. A check compares against the intended value from the configuration, never against the resource's own read-back, and it must fail when it has nothing to check. Before anything relies on a check, run it on a known-good case and on a known-bad one. Compare parsed fields, not patterns over text.

## CI gate (Phase 3a)

| Hypothesis | Test | Finding |
|---|---|---|
| A red CI run blocks merging | Opened a PR with a deliberate lint error | CI turned red and skipped the tests, but the merge button stayed active; a ruleset was needed |
| SQLite would be fine for tests | Reasoned | Different dialect and behaviour: tests could pass while PostgreSQL fails. Tests run on real PostgreSQL 16 |
| The tests catch real bugs | Broke click counting on purpose | Exactly the right test failed (`assert 0 == 3`) |
| The ruleset required both `Lint` and `Test` | The PR page showed `Required` only on `Lint`; checked the rules API | `Test` had never been added. After adding it, PR #4 with a deliberate lint-clean failure was blocked; removing the failure made it mergeable |
| A new Terraform job proves itself by being green | Misaligned one `=` in `variables.tf` on PR #5 | `Terraform` turned red at `fmt` (exit 3). A job pointed at the wrong folder would have stayed green |

## Smaller corrections

| Initial claim | What's actually true |
|---|---|
| Floci's `CreateKeyPair` returns dummy keys | It returns real keys; the key was most likely saved with literal `\n` characters |
| The default VPC makes RDS publicly accessible by default | The default VPC has only public subnets; `PubliclyAccessible` is a separate setting |
| The default security group exposes resources to the internet | It allows traffic from members of the same group plus all outbound; the risk is unintended access |
| A VPC CIDR can never be changed | The primary can't; secondary CIDR blocks can be added (5 per VPC by default) |
| A /16 holds about 251 usable /24 subnets | 256 /24s fit; the 5 reserved addresses are per subnet. The default quota is 200 subnets per VPC. |
| Build order is IGW → VPC → subnets | That's the traffic flow. Build order is VPC → subnets → IGW → routes → SGs → resources |
| An EC2 instance in a private subnet can't be reached by the ALB | The ALB reaches private targets; that's the recommended production pattern |
| The ALB → EC2 egress rule is required | It's redundant while the default allow-all egress rule exists |
| Tags don't appear in table output | They do; the wrong resource ID had been tagged |
| Floci's ALB is metadata only | It forwards real traffic once a target is healthy |
| The `latest` image fails because of a hostname difference | The floci-ui init hook needs the AWS CLI, which only `latest-compat` includes |
| An ALB DNS name resolves to `127.0.0.1` | It resolves to `::1` |
| `ss` showing nothing inside Floci was a mystery | `ss` isn't installed in the image |
| Ignoring `.terraform.lock.hcl` in git | The lock file must be committed |
| A job log shows which runner label the job requested | It shows the image and OS version only; the requested label comes from the jobs API (edge case #32) |
| Terraform removes the default egress rule, so it would be gone on Floci too | Terraform tries; Floci ignores the request (edge case #34) |
| Replacing a group replaces every rule that references it | Rules *on* the group are replaced; rules that only *point at* it are updated in place |
| `terraform plan` would flag an extra security group rule | Not with standalone rule resources (edge case #35) |
| `Modifications complete` means the setting changed | Floci ignored deletion protection and gp3 on create and on modify (edge case #43) |
| A plan blocked by `prevent_destroy` leaves no plan file | It saves a partial plan marked `errored`, which can't be applied (edge case #44) |
| A green `Terraform` CI job means the code will apply | It means well-formed: `validate` treats every variable as unknown and calls no API. Only a `plan` against the API proves more |
| A clean plan proves the key pair's type | `key_type` is computed and never compared with the code; only `describe-key-pairs` shows it (edge case #47) |
| An anchor check makes an edit script safe to re-run | It only proves the anchor exists. A block run twice inserted the `instance_id` output and `INSTANCE_ID` twice, and Python silently kept the last duplicate dict key. Edit scripts now also refuse when the new text is already present |
| A `panic` count above 0 in a Terraform debug log means a crash | `provider: plugin exited` is the provider's normal shutdown; a crash shows `panic:` and a goroutine trace (edge case #48) |
| An instance that accepts the SSH login has the Terraform key | Login proves that *some* accepted key matches; comparing `ssh-keygen -lf /root/.ssh/authorized_keys` with the local `.pub` proves which (edge case #48) |
| A green CI means the PR's change was tested | `Test` runs `pytest`; the shell scripts of #21–#27 were checked only in a sandbox, where nobody could rerun the tests. Since 2026-10-04 the required `Scripts` job runs a pinned ShellCheck and 17 fake-CLI cases, each guarantee mutation-tested |
| A `grep` over a plan's text finds every planned action | A `removed` block's line is indented by one space, and `grep '^  # '` missed it; `terraform show -json tfplan` lists every change with its action (edge case #62) |
| Floci's docs describe the Floci we run | The docs site is built from `main`: the IMDSv2 token validation it documents was committed 9 days after the 2.1.0 release we run (edge case #49). Compare the running version (`/_floci/health`) with the release history before trusting a documented behavior |
| Floci's instances are bare `ubuntu:24.04`, so there's no `curl` or `python3` | The image is bare, but Floci installs the IMDS proxy and `openssh-server` at launch, and `python3` arrives as a side effect (edge case #9) |
| A clean `terraform plan` means the instance is alive | Terraform sees only the API. After a PC restart Floci said `running` for a dead container and the plan was clean (edge case #48) |
| A `fix(...)` commit after our release means the feature is missing in it | Floci 2.1.0 already issued role credentials through IMDS, although a fix for exactly that came later (edge case #51). A commit title is a claim about a change, not about what the release lacks: test the release |
| `default=Undefined` makes an env lookup fail when the variable is missing | In ansible-core 2.21 that name doesn't exist; `undef(hint=...)` works (edge case #52) |
| `git archive` ships git's recorded file modes | It applies `tar.umask` (default `002`): set it in the command (edge case #54) |
| `start-stop-daemon --stop` works in any container | It waits for the PID to vanish; under a PID 1 that never reaps, a stopped process stays a zombie (edge case #53) |
| `ANSIBLE_CONFIG` follows the branch you're on | It's a shell variable: a shell started on another branch lacks it until `shortify-env.sh` is sourced again (edge case #50) |
| A playbook that passes on rerun was a transient failure | The first run on a fresh instance failed deterministically: a handler called a script installed later; the rerun passed only because the script then existed (edge case #56). Reproduce on a fresh instance before calling anything flaky |
| `ansible-playbook … \| tail -3 && next` stops on a failed play | The pipeline's exit status is `tail`'s, so `next` ran anyway. Send the output to a file and check `$?` (edge case #56) |
| A fresh instance's first deploy always reports `changed=11` | 11 or 12: packaging the release runs on the laptop and is skipped when its tarball is already in `/tmp`. Judge a deploy by `failed=0` and the health check, not by the count (edge case #56) |
| The warm session path reports `changed=0` when the instance is healthy | Only when the instance already runs `main`'s commit. On 2026-10-04, after two merges, it reported `changed=8`: the packaging, a new release directory, its unpack and venv, a re-rendered unit and control script (both embed the release's full path, `release_dir` in `app.yml`), and a restart in place (a few seconds of possible 503, parked). The packaging task is delegated to localhost but counted under the app host in the recap, so `localhost changed=0` doesn't mean nothing was packaged. The old release directory stays on the instance; that only happens on the warm path, because a release replaces the instance |
| `svc.sh` ships with the runner | `config.sh` generates it from `bin/systemd.svc.sh.template` when the runner is registered |
| The laptop's WSL is Ubuntu 24.04 | It's Ubuntu 26.04 LTS. Without ICU, `Runner.Listener` aborts with exit 134; the runner's `bin/installdependencies.sh` found no `libicu80` or `libicu79` and installed `libicu78` (plus `liblttng-ust1t64`) |
| A job on the runner sees none of the shell's `AWS_` variables | It inherits the environment of the shell that ran `./run.sh` (edge case #65) |
| `gh run view --log \| cut -f3-` keeps the step name | Its fields are job, step and line; the step is field 2, so filter on `$2` before dropping it |
| A PC restart keeps WSL's `/tmp` | It clears it: the release tarballs were gone, so the first deploy packages again (`changed=12`) |
| Only `list-object-versions` breaks on the distro CLI | `list-objects-v2` breaks too: the control failed (edge case #66) |
| `shortify-env.sh` sets the shell's `AWS_` variables | It set none: `eval "$(floci env)"` in `~/.bashrc` did, so the target depended on a file outside the repo. The script now sets them (edge case #68) |
| The S3 backend needs path-style URLs against an emulator | On Floci it needed nothing but the environment's endpoint (edge case #67) |
| A successful `terraform init` proves the backend works | It may write nothing. A write proves it: an apply that stores an output, then `head-object` on the state and on the lock (edge case #67) |
| Moving local state to S3 keeps its lineage and serial | The content was identical, but both were reset; restoring the old backup needs `state push -force` (edge case #69) |
| The checkpoint's marker count was current | It said `clicks` 3; it was already 4. One more redirect added exactly one, so the write path was fine and the note was stale |

---

## Verification results

The end-of-phase test round, run on a healthy baseline:

| Test | Question | Prediction | Result |
|---|---|---|---|
| Baseline | Does the stack survive a reboot? | — | ❌ Floci lost Docker access; app and sshd gone |
| G | What do reboot, stop/start and Docker Desktop start do to an instance? | No sshd after any of them | ✓ Confirmed |
| ALB | Why `Target.Timeout` with a healthy app? | Floci not on the VPC network | ✓ Curl exit 28 → reconnect → healthy |
| A1 | Are SGs enforced by default? | No | ✓ No: zero RDS rules, everything worked |
| B | Are NACLs enforced? | No | ✓ No: a deny-all NACL changed nothing |
| C | Does a port-80 listener work? | Yes | ✓ Yes |
| D1 | Is `Port` required at registration? | No | ✓ No: the target group port is used |
| D2 | Does an empty-ID target break the others? | No | ✓ No |
| E | Does the ALB DNS name work? | Yes, via `127.0.0.1` | ~ Yes, but via `::1` |
| F | Does the init hook need the compat image? | Yes | ✓ Yes: it calls the AWS CLI |
| A2 | Does the opt-in SG firewall enforce the design? | SSH denied; ALB path unknown; RDS open | ✗ SSH allowed without a rule; ALB path allowed without a rule; RDS open |
| — | Why did SSH fail on a fresh launch? | Timing | ✓ sshd appears after 34 s |
| — | Why did the control instance die during a recreate? | The new flag | ✗ The old Floci's shutdown |
| — | Does `http://localhost/` reach the ALB? | Yes | ✓ Yes |
| Reboot | Stop the stack, restart Docker/WSL, recover by the runbook | Instance stopped; `group_add` holds; RDS back; network kept; API says `running` | ✓ ✓ ✓ ✓ ✗ (API said `terminated`) |
| Cold boot | Restart the PC, then only `shortify_session` (Floci 2.1.0, 2026-10-03) | Network kept; dead instance replaced; first deploy passes (#56); one healthy target, `/health` 200; marker row and its `clicks` intact; unknown code `404` | ✓ ✓ ✓ ✓ ✓ ✓ (API said `pending`; `changed=12`, not about 11: the packaging ran too, #56) |
| Release | Replace the serving instance with `scripts/release.sh` while sampling `/health` once a second (2026-10-04) | No failed sample; the old instance leaves only after the new one is healthy | ✓ 178 samples, 0 failed |
| Cold path by release | Stop the serving instance through the API, then `shortify_session` | Not usable → a release; packaging skipped (`changed=11`); the stopped instance retired with its container | ✓ ✓ ✓ |
| Cold boot by release | Restart the PC, then only `shortify_session` (2026-10-04) | Dead instance → a release; the dead one terminated; the old leftover container collected at the Floci start | ✓ ✓ ✓ |
| Retire `aws_instance.app` | A `removed` block with `destroy = false`, applied behind a gate on the plan's JSON (2026-10-04) | Forgotten, not destroyed; then terminated through the API; every plan clean | ✓ ✓ ✓ |

---

## Open questions

1. Does Floci's enforcement flag filter instance-to-instance traffic, while leaving its own traffic and published SSH unfiltered? Test: two instances, with the rule revoked between them.
2. Why does Floci report a stopped instance as `terminated` after a restart, but `running` after a recreate? (`compose stop` stopping instances is now confirmed.)
3. Is there a durable fix for Floci's VPC network attachment after a recreate? *(Mitigated: `scripts/floci-network-check.sh` reconnects and verifies it at session start, edge case #11.)*
4. Does real AWS reject `--targets Id=`? (Probably, with a validation error.)
5. Does `restart: unless-stopped` let the stack recover by itself after a reboot?
6. `down`/`up` behavior with the socket fix in place (deliberately not re-tested).
7. Does the systemd AMI (`ami-ubuntu2404-cloud`, listed arm64-only) run on x86_64 and survive reboots?
8. Can the SSH and RDS port ranges be narrowed? Does `create-db-instance --port` affect Floci's proxy?
9. Why did Floci report `PreviousState: stopped` right after an API reboot?
10. Could `dockerd` run inside a Floci instance?
11. An HTTPS listener and 80 → 443 redirect with a Floci ACM certificate.
12. Current AWS free-tier and pricing figures (not verified here).
14. Report both Floci bugs (edge cases #34 and #36) with the evidence.
15. *(Resolved: CI runners pinned to `ubuntu-24.04`, edge case #32.)*
16. What mounts `/mnt/e` a second time? Test: `findmnt /mnt/e` before and after one `docker run -v "$PWD":/src`.
17. Does real AWS delete the RDS-managed secret together with the instance? (Floci leaves it behind: edge case #42.)
18. After the next Floci release: does a fake IMDSv2 token get `401` and a TTL of `0` get `400` (fix #4303)? Is `HttpTokens=required` still unenforced? (Edge case #49.)
19. *(Resolved: after a PC restart the API said `running` and the plan was clean, edge case #48.)* Still open: does a plan after `compose stop` (API `terminated`) show a create? And why does an abrupt stop leave `running` (question 2)?
20. Where exactly do `python3` and `wget` come from on a Floci instance? (`apt-cache rdepends --installed python3`.)
21. *(Answered 2026-10-03: yes, from a launch template, but without its metadata options (edge case #57), and its instance refresh terminates before it launches (#58). Phase 3b uses option B: pipeline-launched instances.)*
22. *(Resolved 2026-10-01: after an overnight restart the check reported `container exited, sshd no`, exit 1, with the API saying `pending`, edge case #26.)*
23. Why did `groups.get('app', [])` evaluate to `false` once in the playbook guard? Not reproduced (edge case #52).
24. Does the ALB reach instances while Floci is attached only to `floci_default`, not to the VPC network (edge case #51)? *(Answered 2026-10-01: no. The ALB uses the private IP only; health checks timed out until Floci was connected to the VPC network, edge case #11.)*
25. *(Answered 2026-10-04: yes. After a PC restart, the Floci start removed the leftover container of `i-99e01efdfd65d74a7`, terminated the day before (edge case #59).)*
26. *(Answered 2026-10-04: yes. After a PC restart, `shortify_session` found the dead release instance not usable, replaced it by a release and terminated it: `session exit=0`, `/health` 200 (edge case #61).)*
27. Does GitHub support its runner on Ubuntu 26.04? (It runs, 2.337.0.)
28. Why does the runner mask log lines containing `pwd=` (edge case #65)?
29. Did both versions of the S3 canary survive the restarts (edge case #64)? Answerable once the CLI is fixed (#66).
30. Does the S3 backend reach Floci with virtual-hosted or path-style URLs (edge case #67)?
31. Why did the migration to S3 reset the state's lineage and serial (edge case #69)?
32. Does Floci enforce an S3 public access block, or only store it? (The state bucket's four settings read back `True`.)
