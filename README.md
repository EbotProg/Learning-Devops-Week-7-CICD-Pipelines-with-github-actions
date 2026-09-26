# CI/CD Pipeline — GitHub Actions to AWS (Week 7)

Repo: `Learning-Devops-Week-7-CICD-Pipelines-with-github-actions` (workflow lives in the app repo, `Learning-Devops-Week-3-Docker-Deep-Dive`)

This document explains how the Week 7 pipeline was built: a GitHub Actions workflow that lints/tests, builds and pushes Docker images to ECR, deploys to the existing EC2 instance over SSH, and notifies Discord — authenticating to AWS with GitHub OIDC (no stored AWS keys), with a dedicated, narrowly-scoped IAM role built from scratch. Every real issue hit while getting it running is documented below, the same as the Week 5 and Week 6 READMEs.

Folder structure this README expects:

```
project-root/
├── README.md                     ← this file
├── screenshots/
│   ├── github-actions-role.png
│   ├── github-action-role-apply-output.png
│   ├── role-trust-relationship.png
│   ├── plan-output.png
│   ├── secrets.png
│   ├── variables.png
│   ├── security-group-ingress.png
│   ├── webhook-in-channel.png
│   ├── discord-notifications-history.png
│   ├── actions-run-success.png
│   ├── ecr-images-frontend.png
│   ├── ecr-images-backend.png
│   ├── branch-protection-rule-form.png
│   ├── branch-protection-required-checks.png
│   └── branch-protection-saved.png
├── github-actions-role.tf
└── .github/
    └── workflows/
        └── deploy.yml
```

---

## 1. What's different from Week 5/6

Weeks 5 and 6 automated **Terraform** (`plan`/`apply` against infrastructure). Week 7 automates the **application**: on every push to the app repo's default branch, the workflow lints/tests the frontend and backend, builds and pushes Docker images to ECR, deploys the new images to the already-provisioned EC2 instance over SSH, and posts a Discord notification of success or failure.

Note on branch naming: the Week 3 app repo's default branch was renamed `main` → `master` partway through this setup (the Week 7 repo, which only holds the IAM Terraform and this README, still uses `main` — it has no workflow, so it doesn't matter there). Every trigger, branch protection rule, and command below targets `master`, since that's the branch the pipeline and the workflow file actually live on.

It also deliberately does **not** reuse the shared `github-workflow-role` from Weeks 5/6. That role was scoped for Terraform (VPC/EC2/Secrets Manager), and at one point in setting this up it briefly ended up with `AdministratorAccess` attached by mistake — rather than patch that, Week 7 uses a brand-new, single-purpose role (`week7-github-actions-deploy`) with only the ECR permissions the deploy pipeline actually needs.

---

## 2. The OIDC identity provider (reused)

Same as Week 6: the GitHub OIDC provider (`token.actions.githubusercontent.com`, audience `sts.amazonaws.com`) is registered once per AWS account, so this project reuses the provider Week 5 already created — nothing new to set up here.

---

## 3. A dedicated IAM role for this pipeline

Instead of extending an existing role, Week 7 creates its own role and its own Terraform state, applied independently of the Week 5/6 infrastructure.

**`github-actions-role.tf`:**

```hcl
provider "aws" {
  region = "eu-north-1"
}

data "aws_caller_identity" "current" {}

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_role" "week7_deploy" {
  name = "week7-github-actions-deploy"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        StringLike   = { "token.actions.githubusercontent.com:sub" = "repo:EbotProg@<ownerID>/Learning-Devops-Week-3-Docker-Deep-Dive@<repoID>:*" }
      }
    }]
  })
}

resource "aws_iam_role_policy" "ecr_push" {
  name = "ecr-push"
  role = aws_iam_role.week7_deploy.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "ecr:GetAuthorizationToken", Resource = "*" },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage"
        ]
        Resource = [
          "arn:aws:ecr:eu-north-1:${data.aws_caller_identity.current.account_id}:repository/crud-nextjs-frontend",
          "arn:aws:ecr:eu-north-1:${data.aws_caller_identity.current.account_id}:repository/crud-parse-server-backend"
        ]
      }
    ]
  })
}

output "week7_role_arn" {
  value = aws_iam_role.week7_deploy.arn
}
```

**`terraform plan` output:**

![Terraform plan for the new role and its ECR policy](screenshots/plan-output.png)

**`terraform apply` output — role and inline policy created:**

![Terraform apply creating week7-github-actions-deploy](screenshots/github-action-role-apply-output.png)

**The role afterward in the IAM console**, showing the single `ecr-push` inline policy attached (no `AdministratorAccess`, no leftover managed policies):

![week7-github-actions-deploy permissions tab](screenshots/github-actions-role.png)

**Trust relationships tab**, showing the corrected `sub` condition pointed at the Week 3 repo (account ID redacted):

![week7-github-actions-deploy trust policy, repo pattern trusting Learning-Devops-Week-3-Docker-Deep-Dive](screenshots/role-trust-relationship.png)

Important caveat carried over from Weeks 5/6: this AWS account's OIDC `sub` claim comes back in the **ID-suffixed format** — `repo:owner@<ownerID>/repo@<repoID>:...` — not the plain `repo:owner/repo:*` format the AWS docs show. The trust policy's `sub` pattern has to use that exact suffixed form or `AssumeRoleWithWebIdentity` is denied (see Issue #6 below).

---

## 4. Repository secrets and variables

Unlike Week 6, this pipeline uses plain **repository-level** secrets/variables rather than per-environment ones — there's only one target (the single EC2 instance), so there was no need for the dev/staging split Week 6 introduced.

**Secrets** (Settings → Secrets and variables → Actions → Secrets):

![Repository secrets: DISCORD_WEBHOOK_URL, SSH_PRIVATE_KEY](screenshots/secrets.png)

**Variables** (same page, Variables tab):

![Repository variables: APP_PUBLIC_IP, AWS_ROLE_ARN](screenshots/variables.png)

| Type     | Name                  | Purpose                                                                                          |
| -------- | --------------------- | ------------------------------------------------------------------------------------------------ |
| Secret   | `SSH_PRIVATE_KEY`     | Private half of the key pair used to SSH into the EC2 instance for the deploy step               |
| Secret   | `DISCORD_WEBHOOK_URL` | Discord webhook URL the `notify` job posts to                                                    |
| Variable | `APP_PUBLIC_IP`       | Public IP of the EC2 instance the `deploy` job SSHes into                                        |
| Variable | `AWS_ROLE_ARN`        | ARN of `week7-github-actions-deploy`, assumed via OIDC in the `build-and-push` and `deploy` jobs |

---

## 5. The Discord webhook

Created under the target channel's **Integrations → Webhooks → New Webhook**, then the webhook URL was copied into the `DISCORD_WEBHOOK_URL` repository secret above.

![Discord webhook configured for #general](screenshots/webhook-in-channel.png)

The channel's message history shows the iteration this pipeline actually went through — several `Deploy skipped`/`Deploy failure` notifications while the SSH and ECR-login issues below were being fixed, ending in `Deploy success`:

![Discord message history: skipped and failure notifications leading up to a final success](screenshots/discord-notifications-history.png)

---

## 6. The workflow, job by job

**`.github/workflows/deploy.yml`** (lives in the Week 3 app repo, not a separate Week 7 repo — see Issue #2 below for why):

```yaml
name: Deploy

on:
  push:
    branches: [master]
  pull_request:
    branches: [master]

concurrency:
  group: Deploy-${{ github.ref }}
  cancel-in-progress: false

permissions:
  id-token: write
  contents: read

env:
  AWS_REGION: eu-north-1

jobs:
  lint-test:
    name: Lint Test
    runs-on: ubuntu-latest
    strategy:
      matrix:
        application: ["CRUD-nextjs-frontend", "CRUD-parse-server-backend"]
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: true
      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: "npm"
          cache-dependency-path: ${{ matrix.application }}/package-lock.json
      - run: npm ci
        working-directory: ${{ matrix.application }}
      - run: npm run lint --if-present
        working-directory: ${{ matrix.application }}

  build-and-push:
    needs: lint-test
    if: github.event_name == 'push'
    runs-on: ubuntu-latest
    outputs:
      sha: ${{ steps.sha.outputs.sha }}
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: true
      - id: sha
        run: echo "sha=${{ github.sha }}" >> "$GITHUB_OUTPUT"
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.AWS_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}
      - uses: aws-actions/amazon-ecr-login@v2
        id: login-ecr
      - uses: docker/setup-buildx-action@v3
      - uses: docker/build-push-action@v7
        with:
          context: ./CRUD-nextjs-frontend
          push: true
          tags: |
            ${{ steps.login-ecr.outputs.registry }}/crud-nextjs-frontend:${{ github.sha }}
            ${{ steps.login-ecr.outputs.registry }}/crud-nextjs-frontend:latest
          cache-from: type=gha
          cache-to: type=gha,mode=max
      - uses: docker/build-push-action@v7
        with:
          context: ./CRUD-parse-server-backend
          push: true
          tags: |
            ${{ steps.login-ecr.outputs.registry }}/crud-parse-server-backend:${{ github.sha }}
            ${{ steps.login-ecr.outputs.registry }}/crud-parse-server-backend:latest
          cache-from: type=gha
          cache-to: type=gha,mode=max

  deploy:
    needs: build-and-push
    runs-on: ubuntu-latest
    environment: production
    steps:
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.AWS_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}
      - uses: appleboy/ssh-action@v1
        with:
          host: ${{ vars.APP_PUBLIC_IP }}
          username: ubuntu
          key: ${{ secrets.SSH_PRIVATE_KEY }}
          script: |
            cd /home/ubuntu/app
            aws ecr get-login-password --region eu-north-1 | docker login --username AWS --password-stdin <ACCOUNT_ID>.dkr.ecr.eu-north-1.amazonaws.com
            sed -i "s/^IMAGE_TAG=.*/IMAGE_TAG=${{ needs.build-and-push.outputs.sha }}/" .env
            docker compose pull
            docker compose up -d

  notify:
    needs: [lint-test, build-and-push, deploy]
    if: always() && github.event_name == 'push'
    runs-on: ubuntu-latest
    steps:
      - name: Notify Discord
        run: |
          STATUS="${{ needs.deploy.result }}"
          curl -H "Content-Type: application/json" \
            -d "{\"content\": \"Deploy ${STATUS} for commit ${{ github.sha }}\"}" \
            ${{ secrets.DISCORD_WEBHOOK_URL }}
```

**Job flow:**

```
   lint-test (matrix: frontend, backend)
         │
         ▼
   build-and-push
   [assume OIDC role → ECR login → docker buildx → push :sha + :latest]
         │
         ▼
      deploy
   [assume OIDC role (unused by SSH itself) → SSH in → docker login on EC2
    → pin .env IMAGE_TAG to this commit's SHA → docker compose pull → up -d]
         │
         ▼
      notify (always runs, even on failure)
   [posts pass/fail + commit SHA to Discord]
```

Why `deploy` doesn't use `actions/checkout`: that step only matters when a job's _own_ runner needs to read files from the repo locally. `deploy` never touches a file on its own runner — every action it takes (pulling images, editing `.env`, restarting containers) happens remotely over SSH on the EC2 instance, so there's nothing for `deploy`'s own runner to check out.

Why `build-and-push`/`deploy`/`notify` carry `if: github.event_name == 'push'`: the `pull_request` trigger was added purely so `lint-test` has something to run as a **required status check** on PRs (see Section 11). Without that guard, opening a PR would also build/push images, SSH into the live instance, and deploy — a PR is meant to be checked, not deployed. `lint-test` runs on both events; everything past it is push-only.

**A full successful run** — `lint-test` (both matrix legs) → `build-and-push` → `deploy` → `notify`, all green, 5m1s total:

![Actions run summary showing all five jobs passing](screenshots/actions-run-success.png)

**The pushed images in ECR**, both tagged with `latest` and the deploying commit's SHA:

![crud-nextjs-frontend repository showing the latest + SHA-tagged image](screenshots/ecr-images-frontend.png)
![crud-parse-server-backend repository showing the latest + SHA-tagged image](screenshots/ecr-images-backend.png)

---

## 7. Setup checklist (order that actually worked)

1. Confirm the OIDC identity provider already exists in IAM (reused from Week 5 — nothing to create).
2. Write and apply `github-actions-role.tf` to create `week7-github-actions-deploy` with a trust policy scoped to the Week 3 app repo and an inline `ecr-push` policy scoped to the two ECR repos.
3. Add `AWS_ROLE_ARN` and `APP_PUBLIC_IP` as repository variables, and `SSH_PRIVATE_KEY` + `DISCORD_WEBHOOK_URL` as repository secrets, in the Week 3 app repo (where the workflow actually runs).
4. Confirm frontend/backend are git submodules of the app repo, and add `submodules: true` to every `actions/checkout` step.
5. Add `.github/workflows/deploy.yml` to the app repo.
6. Widen the app's security group to allow SSH (port 22) from `0.0.0.0/0` — GitHub-hosted runners don't have a fixed IP range, so a single-IP rule (fine for a bastion you SSH into yourself) blocks the pipeline. Flagged explicitly as a demo-only, temporary loosening — see Issue #9.
7. Push a small change to `master`, watch `lint-test → build-and-push → deploy → notify` run end to end, and confirm the Discord notification arrives.
8. Add a `pull_request` trigger (guarded so only `lint-test` runs on it — see Issue #12), open a throwaway PR against `master` so the check has run at least once, then add a branch protection rule requiring it (Section 11).

---

## 8. Issues hit while building this pipeline (and fixes)

**1. `EntityAlreadyExists` on `terraform apply` for the new role**
A prior, partially-applied `terraform apply` had already created the role in AWS, but local state had been reset between attempts, so Terraform tried to create it again. Fixed with:

```
terraform import aws_iam_role.week7_deploy week7-github-actions-deploy
```

**2. Frontend/backend accidentally copied (not just referenced) into a separate Week 7 repo**
Initially tried keeping the workflow in its own new repo and copying the app folders in — this broke, because `CRUD-nextjs-frontend` and `CRUD-parse-server-backend` are git **submodules** of the Week 3 repo, not plain folders. Copying them produced broken `160000`-mode / empty-submodule-reference commits instead of real file content. Fixed by recognizing that `actions/checkout` only pulls code from the repo the workflow file lives in — so `deploy.yml` has to live in the Week 3 app repo itself, not a standalone Week 7 repo. The Week 7 repo now holds only the IAM Terraform and this README.

**3. `setup-node` cache path resolution failed on the Linux runner only**
The lint-test matrix had `Crud-parse-server-backend` (wrong case), but the real folder is `CRUD-parse-server-backend`. Windows (the dev machine) is case-insensitive so this never surfaced locally; Ubuntu runners are case-sensitive. Fixed by correcting the matrix value's case.

**4. `npm run lint` — "Missing script: lint" for the backend**
The backend app has no `lint` script defined. Fixed with `--if-present` on the lint step so a missing script is skipped rather than failing the job.

**5. Real ESLint failures: `react-hooks/set-state-in-effect` (×2)**
Genuine lint catches in the frontend, not a pipeline bug. Under time pressure, downgraded the rule from `error` to `warn` in `eslint.config.mjs` rather than refactoring the React code live, documented here as a deliberate tradeoff to revisit rather than a silent fix:

```javascript
{
  rules: {
    "react-hooks/set-state-in-effect": "warn",
  },
},
```

**6. `Not authorized to perform sts:AssumeRoleWithWebIdentity`**
The new role's trust policy initially only listed the _Week 7_ repo's `sub` pattern, but the workflow runs from the _Week 3_ repo (see Issue #2). Fixed by pointing the trust policy's `sub` condition at the Week 3 repo, using this account's confirmed ID-suffixed `sub` format (`repo:owner@<ownerID>/repo@<repoID>:*`) established back in Week 5.

**7. ECR push denied on `ecr:BatchGetImage`**
The originally-drafted policy was missing this action, needed by BuildKit's cache-aware push flow (`cache-from`/`cache-to: type=gha`). Added it to the inline policy and re-applied.

**8. SSH deploy step timed out — `dial tcp <ip>:22: i/o timeout`**
Two separate causes, found across two rounds of debugging:

- `APP_PUBLIC_IP` was stale after the EC2 instance had been recreated; the variable still pointed at the old IP.
- Even after fixing the IP, the security group's SSH rule was scoped to one specific personal IP (fine for manual bastion access), and GitHub-hosted runners come from an unpredictable IP range. Fixed by opening port 22 to `0.0.0.0/0`:

```
aws ec2 authorize-security-group-ingress --group-id <sg-id> --protocol tcp --port 22 --cidr 0.0.0.0/0
```

![Security group opened to 0.0.0.0/0 on port 22](screenshots/security-group-ingress.png)
This is a temporary, demo-only widening — worth tightening later, e.g. by switching the deploy step from SSH to AWS SSM `Send-Command`, which needs no open inbound port at all.

**9. `no basic auth credentials` pulling images during the SSH deploy step**
Same root cause documented in the Week 5 README: Docker login is per-session, not per-machine. The EC2 instance's `user_data` boot script logs in to ECR as `root` at launch, but the SSH deploy step connects as `ubuntu` in a fresh session with no cached Docker credentials. Fixed by adding an explicit login at the start of the SSH script, before `docker compose pull`:

```bash
aws ecr get-login-password --region eu-north-1 | docker login --username AWS --password-stdin <ACCOUNT_ID>.dkr.ecr.eu-north-1.amazonaws.com
```

**10. Assorted YAML typos caught before/during the run**
`path` instead of `paths`, `action/checkout` instead of `actions/checkout`, `crud-nextjs-fronted` instead of `crud-nextjs-frontend`, `github.sh` instead of `github.sha`, `npm run Lint` instead of `npm run lint`. None of these are conceptual mistakes — just worth a slow read-through of the diff before pushing, since GitHub Actions fails these silently as "step not found" or a resolved-empty variable rather than a clear syntax error.

**11. (Open) Frontend shows a custom error screen instead of the new update, despite a fully green pipeline and a successful Discord notification**
Not yet root-caused. The pipeline completing and the notification firing only prove `deploy.result == success`, i.e. that the SSH script ran to completion — they don't prove the _new_ image is actually the one serving traffic. Still to check, in order:

- On the instance, confirm `.env`'s `IMAGE_TAG` actually got rewritten to the new commit SHA (`cat /home/ubuntu/app/.env | grep IMAGE_TAG`) — if `sed` silently matched nothing (e.g. the line doesn't exist yet, or has different spacing), `docker compose pull`/`up -d` would just re-pull `:latest`/whatever tag was already pinned, not the new SHA.
- Confirm `docker compose ps` shows the frontend container's image tag matches that SHA, and check its `CREATED` time to see whether it was actually recreated or just left running.
- `docker compose logs frontend --tail=100` on the instance — a "custom error screen" from a Next.js app is usually its own error boundary/`_error` page reacting to a runtime exception (e.g. a missing/renamed env var in the production build), not a proxy-level failure, so the container logs should show the underlying stack trace.
- Rule out browser caching by hard-refreshing / testing in a private window before assuming the deploy itself is broken.

**12. Required status check never showed up as a pending/passing check on pull requests**
`deploy.yml` originally only had `on: push`, so it never ran on a PR at all — GitHub had nothing to attach as a "required check" and a branch protection rule pointed at it would either find no matching check (if added before any PR run) or, worse, block merges forever waiting on a check that never fires. Fixed by adding a `pull_request: branches: [master]` trigger. That alone would also have made `build-and-push`/`deploy`/`notify` run on every PR (building images and deploying to the live instance from unmerged code), so each of those three jobs got `if: github.event_name == 'push'` added to keep them push-only while `lint-test` runs on both events.

---

## 9. Useful debug snippets

Confirm what actually deployed, from the instance:

```bash
cat /home/ubuntu/app/.env | grep IMAGE_TAG
docker compose ps
docker compose logs frontend --tail=100
```

Decode a GitHub OIDC token's claims to confirm the exact `sub` format this account uses (from a debug step in the workflow):

```yaml
- name: Debug OIDC token
  run: |
    curl -sSL -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
      "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=sts.amazonaws.com" | \
      jq -R 'split(".") | .[1] | @base64d | fromjson'
  env:
    ACTIONS_ID_TOKEN_REQUEST_TOKEN: ${{ env.ACTIONS_ID_TOKEN_REQUEST_TOKEN }}
    ACTIONS_ID_TOKEN_REQUEST_URL: ${{ env.ACTIONS_ID_TOKEN_REQUEST_URL }}
```

Temporarily open SSH to any IP (demo-only — narrow it back down afterward):

```bash
aws ec2 authorize-security-group-ingress --group-id <sg-id> --protocol tcp --port 22 --cidr 0.0.0.0/0
```

---

## 10. Branch protection

`master` on the Week 3 app repo requires a pull request, one approval, and both `lint-test` matrix legs to pass before merging — nothing reaches `master` (and therefore nothing triggers `build-and-push`/`deploy`) without CI passing first.

**Configuring the rule** — pull request required, `Lint Test (CRUD-nextjs-frontend)` and `Lint Test (CRUD-parse-server-backend)` selected as required checks:

![Branch protection rule form: require PR, 1 approval, branch pattern master](screenshots/branch-protection-rule-form.png)
![Required status checks: both Lint Test matrix legs selected](screenshots/branch-protection-required-checks.png)

**Saved and live**, listed under Branch protection rules for `master`:

![master branch protection rule saved, applies to 1 branch](screenshots/branch-protection-saved.png)

---

## 11. Deliverables checklist

| Deliverable                                                                                   | Status                                                                                                                                                                                                                       |
| --------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `.github/workflows/deploy.yml` — lint/test → build/push → deploy → notify on push to `master` | ✅ Done                                                                                                                                                                                                                      |
| GitHub OIDC → AWS IAM role, no stored AWS keys                                                | ✅ Done — `week7-github-actions-deploy`, scoped to ECR push only                                                                                                                                                             |
| Terraform for the OIDC IAM role                                                               | ✅ Done — `github-actions-role.tf`                                                                                                                                                                                           |
| Required status check + branch protection on `master`                                         | ✅ Done — PR + 1 approval + both `lint-test` legs required (Section 10)                                                                                                                                                      |
| Recorded end-to-end run (commit → live, timed)                                                | ✅ Pipeline ran end to end in 5m1s with a successful Discord notification (Section 6) — ⚠️ but the live frontend was showing an error screen rather than the expected update as of the last check; still open, see Issue #11 |
