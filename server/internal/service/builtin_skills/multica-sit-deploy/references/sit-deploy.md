# SIT deployment reference

## Topology

- Host: one Alibaba Cloud ECS; reach it over ssh as root. The address is
  injected through the `SIT_HOST` environment variable (`root@<address>`);
  if the variable is unset, report the blocker instead of guessing a host.
- Compose directory on the host: `/www/server` + `/panel/data/compose/multica`
  (the string is split only to keep this payload free of repository-like
  paths; the directory is one contiguous path). A sibling compose directory
  belongs to a different product — do not touch it.
- Compose file name is non-default: `docker-compose.selfhost.yml`; every
  compose command must pass `-f`.
- Services that move together in a release: `backend`, `frontend`, `executor`.
  The `postgres` service stays pinned to its own image and is never part of a
  release.
- The executor container runs the multica daemon in the foreground with tini,
  registers itself against the backend, and executes agent tasks with the
  claude and dsh runtimes. It holds no docker control over the host — all
  deploy actions happen from the runtime you are on (the script sshs).

## Images and tags

- Registry images: `registry.cn-hangzhou.aliyuncs.com/nothing/multica-backend`,
  `.../multica-web`, `.../multica-executor(-base|-claude|-dsh)`, mirrored to
  GHCR under the fork namespace. The compose services reference the first
  three through the `MULTICA_*_IMAGE` variables and one shared
  `MULTICA_IMAGE_TAG` variable in the host's `.env`.
- Canonical release tag form is semver **without** a leading v (`0.4.41`).
  Every service image is published under it. The executor's internal build
  chain additionally receives v-prefixed twins for the base layers it pulls by
  git ref name — you never address those directly.
- Branch and commit tags also exist (`utter-main`, `sha-<short>`). They are
  for following the branch; releases and rollbacks use semver tags.
- `latest` is never published and must never be set as the desired tag.
- Changing the tag happens in the host `.env` (`MULTICA_IMAGE_TAG=...`); the
  deploy script backs the file up before writing.

## Why versions must match — the gate

- The backend's quick-create flow validates the version the executor daemon
  reports when it registers (stored on the runtime row). Missing, unparsable,
  or below-floor versions are rejected with 422
  (`daemon_version_unsupported`); the frontend surfaces the same check in the
  quick-create modal.
- The floor constants are compiled into the backend: 0.2.21 for basic
  quick-create and 0.4.3 for the optional priority/due-date fields. Code merged
  from upstream may raise them — a release tag must sit at or above whatever
  the merged backend declares.
- A daemon built past the nearest release tag reports the git-describe shape
  (`v0.4.40-1-g<sha>`), which the gate treats as a dev build and exempts. That
  is why branch-following images stay healthy. A stamp that is a bare commit
  sha or a branch name is neither a version nor the describe shape — the gate
  treats it as "not reported" and rejects.
- Because the executor image carries the backend image's own multica binary,
  executor and backend normally agree by construction. The dangerous states
  are hand-mixed tags: a backend newer than the executor, or an executor whose
  container still runs an image whose binary carries an unparsable stamp.

## The unified deploy script

Located at the repository root (`deploy-sit.sh`). Modes:

- `bash deploy-sit.sh` — deploy all three services at the tag currently in the
  host env file.
- `bash deploy-sit.sh --check` — read-only: prints the desired tag and images
  from the compose model, the running containers, and a local hint listing the
  newest fork release tag. No changes anywhere.
- `bash deploy-sit.sh --tag <tag>` — writes the tag into the host env file
  (with a timestamped backup) and deploys. A leading `v` is normalized away.

What a deploy does, in order: resolves the per-service images from the compose
model (postgres excluded), preflights each image on the registry with a
manifest inspect (nothing is pulled or restarted if any image is missing),
pulls, force-recreates the three services, waits for the backend readiness
endpoint to return 200 (the backend runs migrations on boot), checks the
frontend http status, waits for the executor container, and reads the executor
CLI stamp. The stamp line is flagged ok when it is a semver or a
git-describe shape and warned otherwise — a warning means quick-create will be
rejected, so do not treat the deploy as done until the stamp is ok and the
daemon status reports the release version.

The script is the single write path. Do not hand-edit the compose file or
recreate individual services behind its back.

## Sync and release playbook

Sync (only when the request implies a code change; a pure redeploy of an
existing tag skips it):

1. Fetch upstream `main` into a tracking ref:
   `git fetch https://github.com/multica-ai/multica.git main`
2. Fast-forward the fork `main` mirror to it and push. This also re-runs the
   upstream frontend and mobile verification workflows on the fork — expected
   noise; they are not the image build.
3. Merge `main` into `utter-main` (`git merge --no-ff`), push. Wait for the
   image workflow run on that branch to finish green before tagging.
4. Note the merged tree's quick-create floor constants (see "Why versions
   must match") and pick the release number above them and above the previous
   fork release.

Release:

1. Tag the branch tip: `git tag -a v0.4.41 -m "<what changed>"` and push the
   tag. The tag push triggers the image workflow again; this run builds and
   publishes the versioned images — wait for it green (executor jobs
   included) before deploying.
2. If any job fails, fix forward on the branch, re-merge if needed, and cut
   the next patch tag. Never amend or move the failed tag.

Deploy:

1. `bash deploy-sit.sh --tag 0.4.41` (no leading v).
2. Confirm the executor container was recreated from the release image and
   that the daemon status shows the release version (the daemon re-registers
   on start, so the runtime row's reported version refreshes by itself).

Rollback:

1. Pick the previous release tag (old images stay on the registry forever).
2. `bash deploy-sit.sh --tag <previous>` and re-verify exactly as above.

## Failure diagnosis

| Symptom | Meaning | Action |
|---|---|---|
| Script aborts in preflight: image not found | The tag was never built or pushed (or was mistyped with a `v`) | Check the tag's image workflow run; deploy only after it is green |
| Script prints an executor stamp warning | The container's binary reports a bare sha or branch name | The image predates the tag anchor or came from a pre-anchor build; pull the release image and recreate |
| Quick-create returns 422 `daemon_version_unsupported` | Runtime version missing/unparsable, or below the backend's floor | Check the executor stamp and daemon status; align executor with the backend tag; restart the executor to re-register |
| Backend readiness never returns 200 | Migration or startup failure on the new image | Read the backend container logs; the env file backup lets you redeploy the previous tag |
| Check mode shows containers on an old tag | The env file changed but nothing was recreated | Run the deploy (recreate is what applies the tag) |

Keep the timestamped env backup files: they are the record of the previous
desired tag. Report on the issue with the service table from the deploy
summary, the synced commit range, the release tag, and the rollback tag.
