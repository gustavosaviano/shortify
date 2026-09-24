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

---

## Open questions

1. Does Floci's enforcement flag filter instance-to-instance traffic, while leaving its own traffic and published SSH unfiltered? Test: two instances, with the rule revoked between them.
2. Does `docker compose stop` also stop instances (edge case #26)?
3. Is there a durable fix for Floci's VPC network attachment after a recreate?
4. Does real AWS reject `--targets Id=`? (Probably, with a validation error.)
5. Does `restart: unless-stopped` let the stack recover by itself after a reboot?
6. `down`/`up` behavior with the socket fix in place (deliberately not re-tested).
7. Does the systemd AMI (`ami-ubuntu2404-cloud`, listed arm64-only) run on x86_64 and survive reboots?
8. Can the SSH and RDS port ranges be narrowed? Does `create-db-instance --port` affect Floci's proxy?
9. Why did Floci report `PreviousState: stopped` right after an API reboot?
10. Could `dockerd` run inside a Floci instance?
11. An HTTPS listener and 80 → 443 redirect with a Floci ACM certificate.
12. Current AWS free-tier and pricing figures (not verified here).
