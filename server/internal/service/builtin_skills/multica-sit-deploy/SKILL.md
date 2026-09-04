---
name: multica-sit-deploy
description: "Use when asked to deploy, upgrade, check, or roll back the SIT self-host environment, sync upstream main into the fork deployment branch, cut a multica release tag, or confirm which version SIT runs. One tag drives backend, web, and executor together."
user-invocable: false
allowed-tools: Bash(multica *), Bash(git *), Bash(gh *), Bash(ssh *), Bash(bash deploy-sit.sh *)
---

# Deploy the SIT environment

SIT runs the fork's self-hosted stack — backend, web, and the agent executor —
from one compose directory on one Alibaba Cloud host. All three services move
together on a single image tag; the executor's multica CLI is the same binary
the backend image carries, so a mixed-tag pair can trip the server's
quick-create version gate and every quick-create on that executor starts
failing with 422. Your job is the fork's release-and-deploy loop: sync, tag,
wait for CI, deploy, verify, report.

## Fixed points — never bend these

- **Never rewrite history.** Sync into `utter-main` by merge only. A rebase or
  reset orphans the release tags, the version stamp loses its anchor, and
  every daemon built afterwards reports a version the gate cannot parse.
- **Tags are the version anchor and never move.** Cut a new annotated tag per
  release; never delete, move, or force-push one. Old tags stay forever — they
  are the rollback set.
- **One tag drives all three services.** Deploy via the unified script with the
  release tag; never deploy the executor at a different tag than the backend.
- **Never deploy `latest`.** The image workflow never publishes it; rolling
  tags defeat rollback.
- **Deploy only what CI built.** A release tag is deployable only after its own
  image workflow run is green (executor jobs included). Never deploy from an
  unmerged or untagged tree.
- **Claim success only with evidence.** The deploy script's verification lines
  and the daemon registration state are the evidence; paste them into the
  issue.

## Release-and-deploy loop

1. **Inspect (read-only).** Run the unified script in check mode: it compares
   the tag in the server's env file against what the three containers actually
   run. Also list the newest release tag on the origin.
2. **Sync when the request implies code.** Advance the fork's `main` mirror to
   upstream's `main` (fast-forward), then merge it into `utter-main`. Push and
   wait for the image workflow run on the branch to finish green.
3. **Cut the release tag.** Annotated, patch number above the previous fork
   release and at least as high as the quick-create floor constants the merged
   code declares. Push it and wait for that run green — it builds and publishes
   the versioned images.
4. **Deploy.** Run the unified script against the release tag (the tag form
   without the leading v). It preflights the images on the registry, pulls,
   recreates all three services, waits for backend readiness, and checks the
   executor CLI stamp.
5. **Verify registration.** The daemon re-registers on container start; confirm
   its reported version matches the release.
6. **Report.** Comment the issue with the service table, the synced commit
   range, the release tag, and the rollback tag (the previous release).

Open the reference below for the environment facts, exact commands, and the
troubleshooting table — one file, read it when the task is deploy-shaped.

- `references/sit-deploy.md` — topology, image/tag rules, the version gate,
  the sync/release/deploy/rollback playbook, and failure diagnosis.
