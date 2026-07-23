# NeoSecra Assessment Agent Handoff

This document is for the next engineering agent working on the live NeoSecra Assessment installer/release flow.

## Scope

- Product: NeoSecra Assessment
- Product ID: `neosecra-security-health`
- Edition: `security-health`
- Current release: `1.0.5`
- Assessment app repo: `/home/sirgloomy/projects/neosecra-assessment`
- Distribution repo: `/home/sirgloomy/projects/neosecra-distribution`
- Live install root: `/opt/neosecra/assessment`
- Live release path pattern: `/opt/neosecra/assessment/releases/<version>`

Do not mix this with SOC. SOC is a separate product/project and must not be added to the Assessment release unless explicitly requested.

Important operational rule:

- Do not instruct operators to run `neosecra upgrade`.
- Live install, upgrade, and repair must be done with the pinned `bootstrap.sh` command for the target distribution commit.
- The `neosecra` CLI may still be used for read-only checks such as `verify` and `status`.

## Current Known State

- Assessment app branch: `release/v1-security-health`
- Assessment app commit for `1.0.5`: `5ae9fe9`
- Distribution branch: `fix/assessment-live-installer`
- Distribution commit for `1.0.5`: pending until this release commit is pushed
- Backend image: `ghcr.io/sirgloomyy/neosecra-assessment/security-health-backend:1.0.5`
- Backend digest: `sha256:a26cc9dde1cab36208dbe74b6f3633379150c5ba765d60f4635c76edafa27ada`
- Frontend image: `ghcr.io/sirgloomyy/neosecra-assessment/security-health-frontend:1.0.5`
- Expected DB migration head: `056_findings_runtime_drift`

## Security Rules

- Never use or print tokens pasted in chat, shell history, logs, or previous commands.
- Never print `.env.v1` values, Docker auth config, Authorization headers, passwords, or tokens.
- Request tokens only through silent prompts.
- Server/customer GHCR token must be read-only: `read:packages`.
- Build/push token must have only the minimum needed GHCR package write scope.
- Do not place tokens in scripts, env files, Compose, Git, logs, reports, or docs.

Safe token handling pattern:

```bash
bash -lc 'read -rsp "GHCR token: " GHCR_TOKEN; echo; printf "%s" "$GHCR_TOKEN" | docker login ghcr.io --username SirGlooMyy --password-stdin; unset GHCR_TOKEN'
```

## Absolute No-Go Commands

Do not use:

- `rm -rf`
- `git reset --hard`
- `git clean`
- `docker system prune`
- `docker volume prune`
- `docker volume rm`
- `docker compose down -v`
- force push
- history rewrite
- blind `git add -A`

Never delete Docker volumes or reset the PostgreSQL database to "fix" an installer issue.

## Standard Work Loop

1. Reproduce locally or with a safe live diagnostic.
2. Fix the app repo first when runtime behavior is wrong.
3. Test locally before building an image.
4. Commit and push app changes.
5. Build a new exact backend image tag.
6. Verify the image contains the patch.
7. Push the image to GHCR.
8. Update the distribution repo to point to that exact version.
9. Validate shell syntax, Compose config, channel JSON, and stale version refs.
10. Commit and push distribution changes.
11. Give the operator a pinned one-line bootstrap install/upgrade/repair command.

Never tell the operator to use `neosecra upgrade` or an unpinned branch URL for a live customer install.

## App Repo Workflow

Repo:

```bash
cd /home/sirgloomy/projects/neosecra-assessment
git status --short
git rev-parse --abbrev-ref HEAD
```

Expected branch:

```text
release/v1-security-health
```

Before committing:

```bash
python -m py_compile backend/app/api/v1/customers.py backend/app/api/v1/scans.py backend/app/modules/jobs/worker.py
git diff --check
```

Build backend image with a new exact patch version. Do not reuse a pushed tag.

```bash
docker build -f backend/Dockerfile -t ghcr.io/sirgloomyy/neosecra-assessment/security-health-backend:<version> backend
```

Verify image content before push:

```bash
docker run --rm -e PYTHONDONTWRITEBYTECODE=1 ghcr.io/sirgloomyy/neosecra-assessment/security-health-backend:<version> python -c 'from pathlib import Path; print("image_check=PASS")'
```

Push:

```bash
docker push ghcr.io/sirgloomyy/neosecra-assessment/security-health-backend:<version>
docker image inspect ghcr.io/sirgloomyy/neosecra-assessment/security-health-backend:<version> --format '{{index .RepoDigests 0}}'
```

## Distribution Repo Workflow

Repo:

```bash
cd /home/sirgloomy/projects/neosecra-distribution
git status --short
git rev-parse --abbrev-ref HEAD
```

Expected branch:

```text
fix/assessment-live-installer
```

When releasing a new backend tag, update these files:

- `bootstrap.sh`
- `channels/assessment-stable.json`
- `deployment/VERSION`
- `deployment/v1/VERSION`
- `deployment/.env.v1.example`
- `deployment/v1/.env.v1.example`
- `deployment/release-manifest.yaml`
- `deployment/v1/release-manifest.yaml`

Also update:

- `build_commit` in both manifests to the app commit short hash.
- `database_revision` in both manifests if Alembic head changed.
- backend/worker image refs to the new exact backend tag.
- frontend image only if the frontend image was actually rebuilt.

Validation:

```bash
bash -lc 'set -Eeuo pipefail; for f in bootstrap.sh deployment/install/install.sh deployment/install/preflight.sh deployment/install/postflight.sh deployment/upgrade/upgrade.sh deployment/lib/common.sh deployment/lib/docker.sh deployment/lib/state.sh deployment/lib/manifest.sh deployment/v1/install/install.sh deployment/v1/install/preflight.sh deployment/v1/install/postflight.sh deployment/v1/upgrade/upgrade.sh deployment/v1/lib/common.sh deployment/v1/lib/docker.sh deployment/v1/lib/state.sh deployment/v1/lib/manifest.sh; do bash -n "$f"; done; printf "bash_n=PASS\n"'
git diff --check
jq . channels/assessment-stable.json >/dev/null
rg -n "old_version|old_backend_tag|old_commit" bootstrap.sh channels/assessment-stable.json deployment deployment/v1
```

Compose config check:

```bash
bash -lc 'set -Eeuo pipefail; TMPD=$(mktemp -d); cp -a deployment/. "$TMPD/"; cp "$TMPD/.env.v1.example" "$TMPD/.env.v1"; docker compose --project-directory "$TMPD" --env-file "$TMPD/.env.v1" -f "$TMPD/docker-compose.v1.yml" config -q; printf "compose_config=PASS\n"'
```

Use selective staging only:

```bash
git add -- bootstrap.sh channels/assessment-stable.json deployment/.env.v1.example deployment/VERSION deployment/lib/common.sh deployment/release-manifest.yaml deployment/v1/.env.v1.example deployment/v1/VERSION deployment/v1/lib/common.sh deployment/v1/release-manifest.yaml
git commit -m "release assessment <version> <short reason>"
git push origin fix/assessment-live-installer
git rev-parse HEAD
```

## Installer Pitfalls

The installer must preserve live secrets on existing installs.

Important behavior:

- Fresh install may generate a strong initial admin password.
- Existing install must not rotate `FIRST_ADMIN_PASSWORD` automatically.
- Rotate initial admin only when explicitly requested with `NEOSECRA_ROTATE_INITIAL_ADMIN=1`.
- Upgrade must copy the active release `.env.v1` into the target release, even if a stale target `.env.v1` exists from a failed attempt.
- Do not print `.env.v1`.
- `reconcile_postgres_password` may sync PostgreSQL user password to the existing `.env.v1`; it must not delete/reset persistent data.

Known credential file:

```text
/opt/neosecra/assessment/credentials/initial-admin
```

The operator may read it on the server. Do not paste its values into chat or logs.

## Runtime Pitfalls

### Schema Drift

The app has had ORM/model columns missing from Alembic migrations. If endpoints return 500 after scans, check DB schema vs models before blaming Compose.

Current repair migration:

```text
backend/alembic/versions/056_findings_runtime_schema_drift.py
revision = 056_findings_runtime_drift
```

It covers missing `findings` and `reports` runtime columns.

### FortiGate Asset Scans

FortiGate assets must report:

```text
asset_type = fortigate
```

Do not derive asset type from `vdom`; that caused UI labels like `(root)` and wrong scan routing.

FortiGate saved API tokens are encrypted with `SECRET_KEY`. If `SECRET_KEY` changed during a bad installer run, existing saved device tokens cannot be decrypted. The correct behavior is:

- Return a clear `409`.
- Ask the operator/user to edit the asset and re-save the API token.
- Do not rotate secrets or modify DB secrets automatically.

### Frontend API Origin

The frontend API client uses relative `/api/v1`. If browser logs show calls to `http://<host>/api/v1/...` without the configured frontend port, suspect browser cache, proxy, or a stale frontend bundle before changing backend code.

## Live Bootstrap Command Template

After distribution is pushed, always give a pinned bootstrap command. Do not use `neosecra upgrade`.

```bash
curl -fsSL https://raw.githubusercontent.com/SirGlooMyy/neosecra-distribution/<distribution_commit>/bootstrap.sh | sudo env NEOSECRA_DISTRIBUTION_ARCHIVE_URL=https://github.com/SirGlooMyy/neosecra-distribution/archive/<distribution_commit>.tar.gz bash
```

Current pinned `1.0.5` command:

```bash
curl -fsSL https://raw.githubusercontent.com/SirGlooMyy/neosecra-distribution/<final_1.0.5_distribution_commit>/bootstrap.sh | sudo env NEOSECRA_DISTRIBUTION_ARCHIVE_URL=https://github.com/SirGlooMyy/neosecra-distribution/archive/<final_1.0.5_distribution_commit>.tar.gz bash
```

Post-upgrade checks may use the CLI for verification only:

```bash
sudo neosecra verify --timeout 120
sudo neosecra status
sudo cat /opt/neosecra/assessment/credentials/initial-admin
```

If a FortiGate asset scan returns a `409` about decrypting the device token, edit that asset in the UI and re-save the API token. That is expected after a prior `SECRET_KEY` change.

## Live 500 Debugging

Backend global exception responses include a short ref:

```text
Beklenmeyen bir hata olustu. (Ref: abc12345)
```

Use the ref to find the real error in backend logs. Redact logs before sharing:

```bash
cd /opt/neosecra/assessment/current
docker compose --project-name neosecra-assessment --project-directory "$PWD" --env-file "$PWD/.env.v1" -f "$PWD/docker-compose.v1.yml" logs --tail=300 backend
```

Do not print Docker auth config or `.env.v1`.

## Release Acceptance Checklist

Before giving the operator a live command, confirm:

- App syntax checks pass.
- Local or image-level smoke test covers the actual bug.
- Backend image built with a new exact tag.
- Image patch check passes.
- Image pushed to GHCR.
- Distribution version refs are all updated.
- Compose config passes.
- Channel JSON parses.
- No old version/image refs remain.
- Distribution commit pushed.
- No secrets printed.
- No destructive Docker or filesystem cleanup performed.
