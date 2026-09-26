# Week 7 Guide — CI/CD Pipelines with GitHub Actions

Goal, per the milestone card: **every push to `main` should build, test, and
deploy itself — no manual steps, ever.**

This is a different pipeline from the Terraform one covered in `pipeline-
notes.md` — worth being clear about the distinction before anything else,
since the two are easy to conflate.

|               | Terraform pipeline (pipeline-notes.md)        | Week 7's pipeline (this doc)                                                         |
| ------------- | --------------------------------------------- | ------------------------------------------------------------------------------------ |
| Changes what? | The _infrastructure_ — VPC, EC2, IAM, S3      | The _application_ — Parse/Next.js code running on infrastructure that already exists |
| Triggered by  | A change to `.tf` files                       | A change to app code (`CRUD-nextjs-frontend/`, `CRUD-parse-server-backend/`)         |
| Ends with     | `terraform apply` — resources created/changed | New Docker images built, pushed to ECR, pulled onto the already-running EC2 instance |

Same underlying GitHub Actions concepts (workflows/jobs/steps, OIDC, secrets)
— genuinely new territory is: **dependency caching, running tests in CI,
building/pushing Docker images from a runner, and deploying to an EC2
instance that already exists** rather than provisioning one.

---

## 1. The pipeline shape, end to end

```
push to main
     │
     ▼
┌─────────┐    ┌───────────────┐    ┌──────────┐    ┌────────┐    ┌────────┐
│ lint /  │───▶│ build Docker  │───▶│ push to  │───▶│ deploy │───▶│ notify │
│ test    │    │ images        │    │ ECR      │    │ to EC2 │    │ Slack  │
└─────────┘    └───────────────┘    └──────────┘    └────────┘    └────────┘
```

Each arrow is a job dependency (`needs:`) — if `lint/test` fails, nothing
downstream runs at all. That's the actual point of putting these in order:
a broken build should never reach production just because a later step
happened to still work.

---

## 2. Dependency caching

**The problem it solves**: every job gets a completely fresh runner (see
`pipeline-notes.md` section 2 if this fact isn't already second nature). That
means `npm install` re-downloads every package, from zero, on every single
run — for a Next.js + Parse Server monorepo, that's a genuinely slow, wasted
few minutes on every push.

**The fix — `actions/setup-node`'s built-in cache**, the simplest version:

```yaml
- uses: actions/setup-node@v4
  with:
    node-version: 20
    cache: "npm"
    cache-dependency-path: CRUD-nextjs-frontend/package-lock.json
```

This caches `~/.npm` (npm's own download cache, not `node_modules` itself),
keyed automatically off the hash of `package-lock.json`. Change a dependency
version → the lockfile hash changes → cache miss → fresh install. Don't
change dependencies → cache hit → `npm ci` pulls from the cache instead of
the network, dramatically faster.

Since this repo has **two** apps (frontend + backend, each with their own
`package-lock.json`), each needs its own `cache-dependency-path` — a single
cache key can't sensibly cover two unrelated lockfiles.

**Docker layer caching is a separate, second kind of caching** — worth not
conflating with the npm one above. Docker's own build cache (which layers
can be reused between builds) also gets wiped every run on a fresh runner,
independent of whether npm's cache hit or missed. The fix:

```yaml
- uses: docker/build-push-action@v7
  with:
    context: ./CRUD-parse-server-backend
    push: true
    tags: ${{ steps.login-ecr.outputs.registry }}/crud-parse-server-backend:${{ github.sha }}
    cache-from: type=gha
    cache-to: type=gha,mode=max
```

`cache-from`/`cache-to: type=gha` tells BuildKit to store/retrieve layer
cache using GitHub's own Actions cache backend instead of losing it every
run. **One real limit worth knowing**: GitHub gives each repo 10GB of total
Actions cache, shared across _everything_ cached in that repo (npm cache,
Docker cache, anything else) — a repo with large images can blow past that,
at which point GitHub starts evicting older entries and cache-hit rates
drop. Not a problem at this project's scale, but the reason this exists.

---

## 3. Running lint/tests in CI

Straightforward once caching is set up — just ordinary commands, run in a job
before anything build-related:

```yaml
- run: npm ci
  working-directory: CRUD-nextjs-frontend
- run: npm run lint
  working-directory: CRUD-nextjs-frontend
- run: npm test -- --ci
  working-directory: CRUD-nextjs-frontend
```

`--ci` on the test command isn't universal across every test runner, but for
Jest specifically it disables interactive watch mode and a few
developer-convenience behaviors that make no sense on a runner with no
human attached — same category of reasoning as `-input=false` for Terraform.

**If this repo doesn't actually have tests written yet** — worth being
honest about, rather than faking a green checkmark — a lint-only step is a
legitimate, real starting point:

```yaml
- run: npm run lint
```

An empty/fake `test` script that always exits 0 defeats the entire purpose
of a required status check (section 8) — it would "pass" regardless of
whether the code actually works.

---

## 4. Building and pushing Docker images to ECR from CI

The full pattern, per image (repeated once for frontend, once for backend):

```yaml
- name: Configure AWS credentials
  uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: ${{ vars.AWS_ROLE_ARN }}
    aws-region: eu-north-1

- name: Login to Amazon ECR
  id: login-ecr
  uses: aws-actions/amazon-ecr-login@v2

- uses: docker/setup-buildx-action@v3

- name: Build and push frontend
  uses: docker/build-push-action@v7
  with:
    context: ./CRUD-nextjs-frontend
    push: true
    tags: |
      ${{ steps.login-ecr.outputs.registry }}/crud-nextjs-frontend:${{ github.sha }}
      ${{ steps.login-ecr.outputs.registry }}/crud-nextjs-frontend:latest
    cache-from: type=gha
    cache-to: type=gha,mode=max
```

**Tagging with `github.sha` in addition to `latest` matters, and connects
directly back to the Week 3/4 semantic-versioning gap** — `latest` alone
means you can never point at a _specific_ previously-working build if a new
one turns out broken. Tagging every image with the exact commit SHA that
produced it means "roll back" can mean something concrete: redeploy the
image tagged with the last known-good SHA, not a `latest` that's already
been overwritten.

`aws-actions/amazon-ecr-login@v2`'s output (`steps.login-ecr.outputs.registry`)
resolves to the full registry hostname (`<account-id>.dkr.ecr.eu-north-
1.amazonaws.com`) — this is what avoids hardcoding the account ID directly
into the workflow file.

**The IAM permissions this specific role needs for the push to succeed** —
this is the part the guide you found flagged as commonly-missed:

```
ecr:GetAuthorizationToken
ecr:BatchCheckLayerAvailability
ecr:InitiateLayerUpload
ecr:UploadLayerPart
ecr:CompleteLayerUpload
ecr:PutImage
```

Missing any one of these fails the push with an auth-shaped error that
doesn't obviously point back at IAM as the cause — worth remembering this
exact list if that happens.

---

## 5. The OIDC IAM role for this pipeline — Terraform

**This needs to be a _different_ role from `ec2-repository-role`** (the one
attached to the EC2 instance itself, from Week 5/6). That role is assumed by
the **EC2 service** — its trust policy says "`ec2.amazonaws.com` may assume
me." This new role is assumed by **GitHub Actions** — a completely different
principal, needing the OIDC trust policy pattern instead:

```hcl
# github-actions-role.tf

# One-time per AWS account — if this already exists from an earlier
# exercise, skip creating a duplicate.
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

resource "aws_iam_role" "github_actions_deploy" {
  name = "github-actions-deploy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:EbotProg/Learning-Devops-Week-3-Docker-Deep-Dive:*"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_actions_ecr_push" {
  name = "ecr-push"
  role = aws_iam_role.github_actions_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"   # this specific action does not support resource-level restriction
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
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

# Lets this role trigger a deploy via SSM (section 6, option B)
resource "aws_iam_role_policy" "github_actions_ssm_deploy" {
  name = "ssm-deploy"
  role = aws_iam_role.github_actions_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:SendCommand", "ssm:GetCommandInvocation"]
      Resource = "*"
    }]
  })
}
```

**The `sub` condition scopes this role to one specific repo** — same
reasoning as `pipeline-notes.md` section 4: without it, any GitHub repo
anywhere could present a valid token and assume this role.

**Where this file lives**: not inside `modules/month1-infra/` (that module
is about the app's own infrastructure, not CI tooling), and not really part
of Week 5/6's environments either, since this role isn't per-environment the
way `dev`/`staging` secrets are — one GitHub Actions role, used regardless of
which environment it's deploying to. A small standalone Terraform config
(its own state, applied once, rarely touched again) is the cleanest home for
it — the same category of "small, separate, one-time" config as the state
backend bootstrap from Week 5 section 2.

---

## 6. Deploying to the EC2 instance — three options, one clear pick

The milestone card mentions two options ("SSH deploy action, or trigger a
Terraform apply"). Worth evaluating both honestly, plus a third that fits
this project's own established pattern better than either.

### Option A — SSH deploy action (`appleboy/ssh-action`)

```yaml
- uses: appleboy/ssh-action@v1
  with:
    host: ${{ vars.APP_PUBLIC_IP }}
    username: ubuntu
    key: ${{ secrets.SSH_PRIVATE_KEY }}
    script: |
      cd /home/ubuntu/app
      docker compose pull
      docker compose up -d
```

Simple, widely used — but it requires **port 22 open to GitHub's runner IP
range** (a large, changing set of addresses — you can't scope this security
group rule to "just GitHub" precisely) and a **private key stored as a
GitHub Secret**, permanently. Given this entire course's running theme of
"stop using long-lived credentials and open ports where an IAM-based
alternative exists" (Week 1's SSH hardening, Week 2's bastion pattern, every
OIDC discussion so far) — this option works, but sits awkwardly against
everything already learned.

### Option B — AWS SSM Send-Command (recommended)

The instance already has an attached IAM role (`ec2-repository-role`) and,
on Ubuntu, the **SSM Agent ships preinstalled** — nothing new to install.
Extend that role with one more managed policy:

```hcl
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_repository_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
```

Then, from the workflow (using the `ssm-deploy` policy from section 5):

```yaml
- name: Deploy via SSM
  run: |
    aws ssm send-command \
      --instance-ids ${{ vars.APP_PUBLIC_INSTANCE_ID }} \
      --document-name "AWS-RunShellScript" \
      --parameters commands='["cd /home/ubuntu/app","docker compose pull","docker compose up -d"]' \
      --query "Command.CommandId" --output text
```

**Why this fits better**: no inbound port 22 needed _at all_ — the SSM Agent
makes an _outbound_ connection from the instance to AWS, so the security
group's SSH rule could theoretically be removed entirely for deploy purposes
(you'd keep it only if you still want to SSH in yourself for debugging,
scoped to your own IP as it already is). No SSH key to store anywhere,
long-lived or otherwise. Every command run this way is logged in CloudTrail
— a genuine audit trail, for free. Access is revoked by removing an IAM
permission, not by hunting down and deleting a key from `authorized_keys`.

### Option C — trigger a Terraform apply

**Worth explaining why this doesn't actually fit**, rather than defaulting
to it just because it's the more familiar tool at this point: a new app
version doesn't change _any_ Terraform-managed resource — the EC2 instance,
its security group, its IAM role are all unchanged. `terraform plan` against
a new Docker image tag would show **zero changes**, because nothing in
`.tf` files references a specific image tag at all (recall `IMAGE_TAG=latest`
in `user_data.sh.tpl` — that's evaluated once, at boot, not on every deploy).
Running `apply` wouldn't actually deploy anything new. This option only
makes sense if the infrastructure _itself_ changes on every deploy, which
isn't the actual situation here.

**Recommended: Option B.**

---

## 7. Notifications — Slack/Discord on success or failure

Both platforms work the same way: a webhook URL, stored as a secret, posted
to with a simple HTTP request. Discord example (no extra action needed, just
`curl`):

```yaml
- name: Notify Discord
  if: always()
  run: |
    STATUS="${{ job.status }}"
    curl -H "Content-Type: application/json" \
      -d "{\"content\": \"Deploy ${STATUS} for commit ${{ github.sha }}\"}" \
      ${{ secrets.DISCORD_WEBHOOK_URL }}
```

`if: always()` is the important part — without it, this step (like every
step by default) only runs if every _previous_ step succeeded, meaning
you'd only ever get a success notification and never hear about a failure
at all, which defeats the point of a failure notification existing.

---

## 8. Branch protection and required status checks

This part lives entirely in GitHub's UI, not the workflow YAML — **Settings
→ Branches → Add branch protection rule**, targeting `main`:

- **Require a pull request before merging** — turns off the ability to push
  directly to `main` at all, forcing every change through review.
- **Require status checks to pass before merging** — once this workflow has
  run at least once, its job names (`lint-test`, `build-and-push`, etc.)
  become selectable here. Check the ones that must pass. This is what makes
  a red CI run actually _block_ a merge, rather than just being a warning
  someone could ignore.
- **Require branches to be up to date before merging** — optional, but worth
  it: without this, a PR could pass CI against an old version of `main`,
  then merge into a _newer_ `main` that never actually got tested together
  with this change.

---

## 9. The full workflow, combined

```yaml
name: Deploy

on:
  push:
    branches: [main]

permissions:
  id-token: write
  contents: read

env:
  AWS_REGION: eu-north-1

jobs:
  lint-test:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        app: [CRUD-nextjs-frontend, CRUD-parse-server-backend]
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: "npm"
          cache-dependency-path: ${{ matrix.app }}/package-lock.json
      - run: npm ci
        working-directory: ${{ matrix.app }}
      - run: npm run lint
        working-directory: ${{ matrix.app }}

  build-and-push:
    needs: lint-test
    runs-on: ubuntu-latest
    outputs:
      sha: ${{ steps.sha.outputs.sha }}
    steps:
      - uses: actions/checkout@v4
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

      - name: Deploy via SSM
        run: |
          aws ssm send-command \
            --instance-ids ${{ vars.APP_PUBLIC_INSTANCE_ID }} \
            --document-name "AWS-RunShellScript" \
            --parameters commands='["cd /home/ubuntu/app","docker compose pull","docker compose up -d"]'

  notify:
    needs: [lint-test, build-and-push, deploy]
    if: always()
    runs-on: ubuntu-latest
    steps:
      - name: Notify Discord
        run: |
          STATUS="${{ needs.deploy.result }}"
          curl -H "Content-Type: application/json" \
            -d "{\"content\": \"Deploy ${STATUS} for commit ${{ github.sha }}\"}" \
            ${{ secrets.DISCORD_WEBHOOK_URL }}
```

**Reading the shape**: `lint-test` uses a matrix so both apps get linted in
parallel, on separate runners. `build-and-push` only starts once _both_
matrix instances of `lint-test` succeed. `deploy` only starts once both
images are pushed. `notify` uses `if: always()` and `needs:` on every prior
job so it fires exactly once at the end, regardless of where in the chain
something failed, and can report which stage failed via `needs.<job>.result`.

---

## 10. Deliverables checklist, mapped to the milestone card

- [ ] `.github/workflows/deploy.yml` — the workflow above, adapted to this
      repo's real paths
- [ ] Terraform for the OIDC IAM role (section 5), applied, with its ARN
      stored as `vars.AWS_ROLE_ARN`
- [ ] `ec2-repository-role` extended with `AmazonSSMManagedInstanceCore`
- [ ] A required status check + branch protection rule on `main`
- [ ] A recorded end-to-end run: a real commit, timed from push to live

---

## Key concepts to be ready to explain

- Why this pipeline is a fundamentally different thing from the Terraform
  pipeline, even though both are "GitHub Actions" — one changes
  infrastructure, one changes application code running on infrastructure
  that doesn't change
- The difference between npm's dependency cache and Docker's layer cache —
  two separate caching problems, solved by two separate mechanisms
- Why tagging images with `github.sha` in addition to `latest` matters —
  `latest` alone has no way to express "roll back to the last known-good
  version"
- Why the GitHub Actions IAM role and the EC2 instance's IAM role must be
  two separate roles, trusting two different kinds of principal
- Why SSM Send-Command is the better fit here over an SSH-based deploy
  action, specifically in terms of what it removes (open port, long-lived
  key) rather than just "because it's more modern"
- Why triggering `terraform apply` on every app deploy doesn't actually
  work, given nothing in the Terraform config references a specific image
  tag
- Why `if: always()` is required on a notification step, and what silently
  breaks without it
