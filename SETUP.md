# Aperture setup runbook: Cloud Shell, GitHub, and Google Cloud

Start here. Every command in this document is copy-and-paste ready and is meant to be run
in Google Cloud Shell in the order given.

Total time: about 20 minutes for Part A and B, which leaves you with a working repository,
CI running on every push, and keyless deployment credentials.

---

## Read this first: what Cloud Shell can and cannot do

**Cloud Shell cannot build the iOS application.** Xcode is macOS-only, and SwiftUI,
SwiftData, AVFoundation, Core ML, and ARKit do not exist on Linux. No configuration
changes that, and any guide implying otherwise is wrong.

What Cloud Shell does handle is most of this project, including the part that matters most:

| Work | Cloud Shell | Note |
|---|---|---|
| Git, GitHub, branches, pull requests | Yes | |
| `ApertureCore`: domain, sync, conflict policy, hybrid logical clocks, retry schedule | **Yes** | Swift on Linux. The hardest and most valuable code in the product |
| Go backend, Postgres, Docker | **Yes** | Docker is preinstalled |
| Contracts, Protobuf, OpenAPI, code generation | Yes | |
| Terraform, infrastructure, Google Cloud | **Yes** | Cloud Shell's home ground |
| CI configuration, scripts, documentation | Yes | |
| `AperturePlatform` and the app target | **No** | macOS only |
| Simulator, XCUITest, snapshot tests | **No** | macOS only |
| Code signing, TestFlight, App Store | **No** | macOS only |

The workaround for the last three rows is the `ios.yml` GitHub Actions workflow, which
compiles the app on a GitHub-hosted macOS runner. Push a branch and CI reports in about
eight minutes. That is a slow loop for UI work and an acceptable one for Phases 1 through 3
and 6, which are domain logic, sync, and backend. Plan on Mac access before Phase 4. See
[Part E](#part-e-before-phase-4).

---

## Part A: repository, from ZIP to GitHub

### Step 1. Upload the ZIP to Cloud Shell

1. Download `aperture-phase-1.zip` from this conversation.
2. Open Cloud Shell at <https://shell.cloud.google.com>.
3. Upload the file: three-dot menu in the Cloud Shell toolbar, then **Upload**, then
   **Choose Files**. It lands in `$HOME`. Dragging the file onto the terminal window works
   too.

### Step 2. Unzip and set permissions

```bash
cd ~
unzip -q aperture-phase-1.zip
cd ~/aperture

# ZIP archives do not always preserve the executable bit across platforms.
# This is idempotent and costs nothing, so run it even if the bit survived.
chmod +x scripts/*.sh scripts/*.py

ls -la
```

You should see `README.md`, `SETUP.md`, `Makefile`, and the `ios/`, `backend/`,
`contracts/`, `scripts/`, `docs/`, and `infra/` directories.

If `unzip` is unavailable for any reason, Python is always present:

```bash
python3 -m zipfile -e ~/aperture-phase-1.zip ~/ && chmod +x ~/aperture/scripts/*.sh ~/aperture/scripts/*.py
```

### Step 3. Verify the archive before installing anything

These checks need no toolchain, so they work the moment the files land. They are the
fastest way to confirm the upload is intact.

```bash
cd ~/aperture
make check
```

Expected: module boundaries OK, thirteen schema assertions passing, configuration OK. If
any of that fails, the upload is corrupt. Re-upload before continuing.

### Step 4. Install the toolchain

This installs the Swift Linux toolchain and the GitHub CLI into `$HOME`, and writes
`~/.customize_environment` so system packages are restored whenever the Cloud Shell VM
recycles. It takes about four minutes, most of which is the Swift download.

```bash
cd ~/aperture
./scripts/cloudshell_setup.sh
source ~/.bashrc
```

Confirm:

```bash
cd ~/aperture
make doctor
```

You want `yes` next to `git`, `python3`, `swift`, `go`, `docker`, `gh`, and `gcloud`, and
`yes` next to `ApertureCore` under "What builds on this machine". `no` next to
`xcodebuild`, `xcodegen`, `AperturePlatform`, and `app target` is correct and expected on
Linux.

### Step 5. Run the Swift and Go test suites

This is the first real proof that the code compiles, since it was written in an
environment without a Swift toolchain.

```bash
cd ~/aperture
make core-test        # ApertureCore: domain and sync. Expect around 20 tests passing
make backend-test     # Go, with the race detector
```

First `swift test` compiles the whole package and takes two to three minutes. Subsequent
runs are seconds. If Swift reports an error, that is a genuine compile failure to fix
rather than an environment problem; paste the error back into the conversation.

### Step 6. Configure git and GitHub

Replace the two placeholder values on the first two lines. The email must match a verified
email on your GitHub account or your commits will not be attributed to you.

```bash
git config --global user.name  "Talif Pathan"
git config --global user.email "you@example.com"

git config --global init.defaultBranch main
git config --global pull.rebase true
git config --global push.autoSetupRemote true
git config --global core.editor nano

gh auth login
# Choose: GitHub.com  ->  HTTPS  ->  Login with a web browser
# Copy the one-time code, press Enter, paste it into the browser tab that opens

gh auth setup-git
gh auth status
```

HTTPS with the `gh` credential helper rather than an SSH key: the token is scoped,
revocable from the GitHub web interface, and refreshed without touching the filesystem.
Fewer long-lived secrets on a shared-tenancy VM is the better posture.

### Step 7. Create the repository and push

```bash
cd ~/aperture

git init
git add .
git commit -m "chore: phase 1 repository and build foundation

Repository structure, three build configurations, two Swift packages split on
Linux buildability, module boundary enforcement, sync queue schema with an
executable verifier, Go service skeleton, and the CI foundation."

gh repo create aperture \
  --private \
  --source=. \
  --remote=origin \
  --description "Offline-first field inspection platform for iOS, with a Go sync backend" \
  --push
```

Private to start. Make it public when Phase 5 lands, because the convergence test suite is
the thing worth showing.

### Step 8. Protect the main branch

```bash
cd ~/aperture
export GH_OWNER=$(gh api user --jq .login)
echo "export GH_OWNER=${GH_OWNER}" >> ~/.bashrc

gh api -X PUT "repos/${GH_OWNER}/aperture/branches/main/protection" --input - <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": [
      "Boundaries, schema, configuration",
      "ApertureCore on Linux",
      "Go service",
      "SwiftLint"
    ]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": 0,
    "dismiss_stale_reviews": true
  },
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON

gh api -X PATCH "repos/${GH_OWNER}/aperture" -f delete_branch_on_merge=true
```

`required_approving_review_count` is 0 because you are working alone and a self-approval
requirement is theater. Everything else is real: status checks must pass, history stays
linear, and `main` cannot be force-pushed or deleted. Raise the review count the moment a
second person joins.

### Step 9. Watch the first CI run

```bash
cd ~/aperture
gh run list --limit 3
gh run watch
```

The `pull-request` workflow runs on pull requests, so pushing `main` directly will show
only the `ios` workflow if `ios/` changed. To see the full gate, open a throwaway pull
request:

```bash
cd ~/aperture
git checkout -b chore/ci-smoke
echo "" >> README.md
git commit -am "chore(ci): verify the pull request gate"
git push
gh pr create --fill --base main
gh pr checks --watch
```

Four Linux jobs should pass in two to three minutes. The macOS `ios` job takes about eight
minutes and is currently your only compiler for the app target, so read its log rather
than assuming.

```bash
gh pr merge --squash --delete-branch
git checkout main && git pull
```

---

## Part B: Google Cloud

### Step 10. Project, billing, and APIs

```bash
export PROJECT_ID="aperture-$(date +%Y%m%d)"     # must be globally unique
export REGION="us-central1"

gcloud projects create "${PROJECT_ID}" --name="Aperture"
gcloud config set project "${PROJECT_ID}"

# Billing is required for Artifact Registry, Cloud Run, and Cloud SQL
gcloud billing accounts list
```

Copy the account id from that output into the next command, then run the block:

```bash
gcloud billing projects link "${PROJECT_ID}" --billing-account=XXXXXX-XXXXXX-XXXXXX

gcloud services enable \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  sqladmin.googleapis.com \
  secretmanager.googleapis.com \
  cloudresourcemanager.googleapis.com \
  iamcredentials.googleapis.com \
  iam.googleapis.com \
  storage.googleapis.com \
  cloudtrace.googleapis.com \
  monitoring.googleapis.com \
  logging.googleapis.com

# Persist across VM recycles
echo "export PROJECT_ID=${PROJECT_ID}" >> ~/.bashrc
echo "export REGION=${REGION}"         >> ~/.bashrc
```

Cloud Run rather than GKE, for the reason recorded in the architecture document: one
stateless Go binary with a managed database does not justify a Kubernetes control plane,
node lifecycle management, and the on-call surface that comes with them. The Kubernetes
design exists and is trigger-gated. This is below the trigger.

### Step 11. Artifact Registry

```bash
gcloud artifacts repositories create aperture \
  --repository-format=docker \
  --location="${REGION}" \
  --description="Aperture service images"

gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet
```

### Step 12. Connect GitHub to Google Cloud with Workload Identity Federation

**Do not create a service account key.** A JSON key in a GitHub secret is a long-lived
credential that does not expire, is awkward to rotate, and grants permanent access to
anyone who obtains the repository. Workload Identity Federation exchanges GitHub's OIDC
token for a short-lived Google credential, with no key to leak.

```bash
export PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')
export GH_REPO="${GH_OWNER}/aperture"

gcloud iam workload-identity-pools create "github" \
  --location="global" \
  --display-name="GitHub Actions"

gcloud iam workload-identity-pools providers create-oidc "github-provider" \
  --location="global" \
  --workload-identity-pool="github" \
  --display-name="GitHub OIDC" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner,attribute.ref=assertion.ref" \
  --attribute-condition="assertion.repository_owner == '${GH_OWNER}' && assertion.repository == '${GH_REPO}'"
```

**The attribute condition is not optional.** Without it, any GitHub repository in the world
can present a token to your pool. It is the first line of defense; the IAM binding below is
the second.

```bash
gcloud iam service-accounts create github-actions \
  --display-name="GitHub Actions deployer"

export SA="github-actions@${PROJECT_ID}.iam.gserviceaccount.com"

# Least privilege: push images, deploy Cloud Run, read the secrets the service needs
for ROLE in roles/artifactregistry.writer roles/run.developer roles/secretmanager.secretAccessor; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA}" --role="${ROLE}" --quiet
done

# Cloud Run deployment must be able to act as the service's runtime identity
gcloud iam service-accounts add-iam-policy-binding \
  "${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --member="serviceAccount:${SA}" \
  --role="roles/iam.serviceAccountUser" --quiet

# Allow ONLY this repository to impersonate the service account.
# Scoped to attribute.repository, not repository_owner: an organization-wide binding would
# let any repository you own deploy to this project.
gcloud iam service-accounts add-iam-policy-binding "${SA}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github/attribute.repository/${GH_REPO}" \
  --quiet
```

Publish the values to GitHub as repository **variables**, not secrets. Neither is
confidential, and variables appear in logs, which makes a failed authentication far easier
to debug.

```bash
cd ~/aperture
export WIF_PROVIDER="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github/providers/github-provider"

gh variable set GCP_WORKLOAD_IDENTITY_PROVIDER --body "${WIF_PROVIDER}"
gh variable set GCP_SERVICE_ACCOUNT            --body "${SA}"
gh variable set GCP_PROJECT_ID                 --body "${PROJECT_ID}"
gh variable set GCP_REGION                     --body "${REGION}"

gh variable list
```

Verify the provider:

```bash
gcloud iam workload-identity-pools providers describe github-provider \
  --location=global --workload-identity-pool=github \
  --format="yaml(attributeCondition, attributeMapping)"
```

Pool and provider changes take up to five minutes to propagate. A `permission denied` on
the first attempt right after creating them is usually propagation, not misconfiguration.

The workflow side, which Phase 11 adds as `.github/workflows/release.yml`. The shape is
fixed now so nothing has to be reworked later:

```yaml
permissions:
  contents: read
  id-token: write          # without this, no OIDC token is minted and auth fails

steps:
  - uses: actions/checkout@v4            # must come before auth

  - id: auth
    uses: google-github-actions/auth@v3
    with:
      workload_identity_provider: ${{ vars.GCP_WORKLOAD_IDENTITY_PROVIDER }}
      service_account: ${{ vars.GCP_SERVICE_ACCOUNT }}

  - uses: google-github-actions/setup-gcloud@v3

  - run: gcloud auth configure-docker ${{ vars.GCP_REGION }}-docker.pkg.dev
```

### Step 13. Database and secrets

Phase 6 needs these. Create them when you get there, not now, because a Cloud SQL instance
bills whether or not anything connects to it.

```bash
gcloud sql instances create aperture-staging \
  --database-version=POSTGRES_16 \
  --tier=db-f1-micro \
  --region="${REGION}" \
  --storage-auto-increase \
  --backup-start-time=07:00

gcloud sql databases create aperture --instance=aperture-staging

# Generate and store the password without it appearing in shell history or on disk
openssl rand -base64 32 | tr -d '\n' | gcloud secrets create aperture-db-password --data-file=-
```

The Postgres major version matches `infra/docker-compose.yml` deliberately. A local
database that differs by a major version produces bugs that only appear after deployment.

---

## Part C: daily workflow

### Start of a session

```bash
cd ~/aperture
source ~/.bashrc          # if the VM recycled since last time
git checkout main && git pull
make doctor               # confirms the toolchain survived
```

### Branch, work, verify

```bash
git checkout -b feat/sync-queue-persistence

# Fast loop, no toolchain needed, under a second
make check

# Swift, on Linux, seconds after the first build
make core-test

# Backend
make backend-test
make backend-up && curl -s localhost:8080/healthz
make backend-down
```

`make core-test` is the loop that matters in Cloud Shell. It covers the domain and sync
modules, which is where Phases 2, 3, and 5 spend their effort.

The local backend is reachable from a browser through Cloud Shell's authenticated proxy:

```bash
cloudshell get-web-preview-url -p 8080
```

### Commit

Conventional Commits, because the release tooling in Phase 11 derives version bumps and
changelogs from them, and retrofitting a convention across history is not worth doing.

```
feat(sync):     a user-visible capability
fix(security):  a bug fix
refactor(data): no behavior change
perf(capture):  a measured improvement, with the number in the body
test(sync):     tests only
docs(adr):      documentation
chore(ci):      tooling and infrastructure
```

```bash
git add ios/Packages/ApertureCore/Sources/ApertureSync
git commit -m "feat(sync): persist queue state across process termination

Operations left inFlight by a terminated process are re-driven on the next
launch with their original idempotency key, so the server replays the stored
response rather than applying the effect twice.

Adds the twelve-point fault injection harness and its first three cases."
```

Small, titled commits with a stated reason. A reviewer scrolling the history of a
portfolio repository learns as much from the commit log as from the code, and a single
commit called "final" teaches them something too.

### Push, review, merge

```bash
git push                       # push.autoSetupRemote handles the first push

gh pr create --fill --base main
gh pr checks --watch           # live CI status without leaving the terminal

gh run view --log-failed       # failing step output, in the terminal
gh pr view --web               # or open it in a browser

gh pr merge --squash --delete-branch
git checkout main && git pull
```

### Tag a completed phase

```bash
git tag -a phase-1 -m "Phase 1: repository and build foundation"
git push origin phase-1
gh release create phase-1 \
  --title "Phase 1: repository and build foundation" \
  --notes "Repository structure, three build configurations, two Swift packages split on Linux buildability, enforced module boundaries, executable sync queue schema verification, Go service skeleton, CI foundation."
```

Phase tags make the progression legible to anyone reviewing the repository later, which
matters when the audience is a hiring committee rather than a team.

---

## Part D: Cloud Shell specifics and troubleshooting

### What persists and what does not

| Thing | Persists | Detail |
|---|---|---|
| `$HOME`, 5 GB | **Yes** | Survives VM recycling. Deleted after 120 days of total inactivity |
| Anything outside `$HOME` | **No** | A system-level `apt install` is gone after the VM recycles |
| Running processes | **No** | The VM recycles after roughly an hour of inactivity |
| `~/.customize_environment` | Yes, and re-runs as root on every VM boot | The supported way to restore system packages. `cloudshell_setup.sh` writes it |
| Environment variables | Only through `~/.bashrc` | Which is why Steps 8, 10, and 12 append to it |

### Useful commands

```bash
cloudshell get-web-preview-url -p 8080     # open the local backend in a browser
cloudshell download ~/aperture/some-file   # download a file to your machine
cloudshell edit path/to/file               # open in the Cloud Shell editor

tmux new -s aperture                       # survive a browser disconnect
# detach: ctrl-b then d      reattach: tmux attach -t aperture

docker system prune -af                    # reclaim space in the 5 GB home
```

Boost Cloud Shell, from the toolbar menu, gives more CPU and memory for an hour and makes
Swift builds noticeably faster.

### Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Permission denied` running `./scripts/...` | ZIP did not preserve the executable bit | `chmod +x scripts/*.sh scripts/*.py` |
| `swift: command not found` after reconnecting | VM recycled, `$PATH` not reloaded | `source ~/.bashrc` |
| Swift or `gh` gone entirely | Installed outside `$HOME` at some point | Re-run `./scripts/cloudshell_setup.sh` |
| `$PROJECT_ID` empty after reconnecting | Shell restarted | `source ~/.bashrc` |
| `make check` fails right after unzipping | Corrupt upload | Re-upload the ZIP and unzip again |
| `swift test` fails to compile | A genuine code error | Paste the error into the conversation. The sources were written without a Swift toolchain available, so this is the expected place for a typo to surface |
| `permission denied` from the auth step, first attempt | WIF propagation delay | Wait five minutes, retry |
| `permission denied` from the auth step, consistently | Attribute condition or principalSet mismatch | `gcloud iam workload-identity-pools providers describe ...` and compare `attribute.repository` to `owner/repo` exactly |
| `Error: id-token: write permission required` | Missing `permissions:` block in the workflow | Add `id-token: write` to the job |
| Docker build runs out of disk | 5 GB `$HOME` | `docker system prune -af` |
| Long build killed when the browser closed | Session ended | Run it inside `tmux` |
| `xcodebuild: command not found`, `make ios-build` fails | Cloud Shell is Linux | Expected. Push and read the `ios` workflow |
| Postgres port already in use | Another stack is running | `make backend-down`, or change `POSTGRES_PORT` in `.env` |
| Status checks never appear on a pull request | Job names changed | The names in Step 8 must match the `name:` fields in `.github/workflows/pr.yml` |

---

## Part E: before Phase 4

Phase 4 builds the capture pipeline, which is AVFoundation, which needs macOS and a
physical device. Options, roughly in order of cost:

1. **Keep using the CI macOS runner** for compilation and accept a slow loop. Workable for
   Phase 4's non-capture parts, painful for the capture surface itself.
2. **A hosted Mac** by the hour or month: MacStadium, Scaleway, AWS EC2 Mac.
3. **Borrow a Mac** from the university lab for the capture phases specifically.
4. **Buy a used Apple silicon Mac mini.** Xcode 27 requires Apple silicon, so an Intel Mac
   is not an option at any price.

Phases 1 through 3 and 6 need none of them, which is roughly two months of work. Deferring
the decision is reasonable; deferring it past Phase 4 is not.

---

## Reference

- [README.md](README.md), what the project is and what Phase 1 contains
- [docs/guides/local-dev.md](docs/guides/local-dev.md), build matrix and common tasks
- [docs/adr/0001-two-swift-packages.md](docs/adr/0001-two-swift-packages.md), why the
  packages are split the way they are
- `make help`, every available target
