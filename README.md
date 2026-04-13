# Trust

Self-managed PKI for Performance Dudes and its partners — fast, transparent, cooperatively operated.

## Why this exists

**Performance Dudes is a cooperative.** We are independent partners who run our own businesses and come together on engagements. When we sign an offer or a contract, it needs to be:

- **Fast** — signed in minutes, from a laptop, not days of email-back-and-forth
- **Professional** — cryptographically verifiable, not "here's a PDF attachment and you'll just have to trust us"
- **Transparent** — the customer can inspect who signed and how the trust is rooted, without taking any third party's word for it

This repository is the trust infrastructure that makes that possible. It is **public by design** — our trust chain is open for anyone to audit, clone, and verify.

## How it plays out

Every partner in the cooperative operates their own **Issuing CA** under a shared **Root CA**. When a partner signs a document, the certificate chain inside the signature proves three things:

1. **Who** signed — a specific person, identified by their end-entity certificate
2. **Which partner** they belong to — the Issuing CA that signed their personal cert
3. **That the partner belongs to the cooperative** — the Root CA that signed the Issuing CA

A customer verifies the Performance Dudes Root CA certificate **once**. From then on, every signed document from any partner in the cooperative verifies instantly. Second partner joins the engagement? Their signature appends to the same document. The customer sees both partners vouched for the work.

No commercial CA. No external authority in the loop. No monthly subscription fee. No vendor lock-in. The cooperative owns its trust root.

## The partners

The list of active partners lives in [`.github/pki-partners.sh`](.github/pki-partners.sh). Each entry is a GitHub username and corresponds to one Issuing CA whose public certificate lives under [`pki/issuers/<username>/`](pki/). Adding a new partner requires 2-of-2 approval from both founders via the `pki-onboard` workflow, and appears here as a pull request — the whole cooperative is transparent.

**Longer read:** [docs/cooperative.md](docs/cooperative.md) — how partners join, leave, sign, and how customers verify.

**What each partner controls:**
- Their own Issuing CA private key (encrypted, never exported)
- Issuing end-entity certificates to people signing on their behalf
- Revoking their own team's certificates

**What requires 2-of-2 (both founders):**
- Onboarding a new partner
- Rotating the Root CA
- Revoking another partner's Issuing CA

This is the cooperative operating model encoded as X.509.

## What this repo is (technical)

A self-managed PKI (Public Key Infrastructure) that lets the Performance Dudes cooperative issue X.509 certificates and cryptographically sign documents (PDFs, commits, etc.) without depending on a commercial certificate authority. Anyone can verify signatures against the public certificates in this repo.

Private keys never enter this public repo.

## Directory layout

```
.github/
  pki-partners.sh    Partner GitHub usernames + display names
  pki-config.sh      Expected environment protection rules
  workflows/         Seven PKI management workflows (init, issue, renew, revoke, rotate, onboard, export)
tools/pki.sh         Shared helper functions (OpenSSL wrappers)
scripts/
  setup-root-env.sh           One-time per-founder: Root CA ceremony passphrase
  setup-issuer-env.sh         One-time per-partner: Issuing CA passphrase
  sync-keys-from-workflow.sh  Post-init sync helper
pki/
  root/ca-cert.pem                 Root CA public certificate
  issuers/<github-username>/       Per-partner Issuing CA public certs
  certs/                           End-entity public certs
  csrs/                            Certificate Signing Requests (for audit)
  crl/                             Certificate Revocation Lists
```

## Workflows

| Workflow | Environment | Access | Purpose |
|---|---|---|---|
| `pki-init` | `pki-root` | 2-of-2 | Initialize the CA hierarchy (one-time) |
| `pki-issue` | `pki-<github-username>` | 1-of-N | Sign a CSR to issue an end-entity certificate |
| `pki-renew` | `pki-<github-username>` | 1-of-N | Re-sign a CSR for renewal |
| `pki-revoke` | tiered | 1-of-N or 2-of-2 | Revoke a cert or Issuing CA |
| `pki-onboard` | `pki-root` | 2-of-2 | Add a new partner (new Issuing CA) |
| `pki-rotate` | `pki-root` | 2-of-2 | Rotate the Root CA key |
| `pki-export` | `pki-root` | 2-of-2 | Export Root CA for escape hatch |

**PDF signing is NOT a workflow.** It happens locally via the `pd` plugin (coming soon). Signing images and private end-entity keys live on the signer's laptop and never touch GitHub.

## How it works (brief)

1. **Two-tier CA hierarchy.** A 2-of-2 Root CA signs per-partner Issuing CAs, which sign end-entity certificates. Each partner operates autonomously within their own Issuing CA branch.
2. **Encrypted at rest.** All CA private keys are encrypted with passphrases that only the respective partners know. The Root CA requires both founders' passphrases combined (nested encryption); each Issuing CA requires only its respective partner's passphrase.
3. **Approval gates.** 2-of-2 for Root CA ceremonies is enforced by two gate jobs, each running in a single-reviewer GitHub Environment (`pki-felixboehm` reviewed only by `felixboehm`; `pki-nantero1` reviewed only by `Nantero1`). Both gates must be approved by their respective unique reviewer before the Root CA is touched. GitHub's stock "required reviewers" mechanism only enforces one-of-N, so the dual single-reviewer gates are the real 2-of-2 layer.
4. **Local signing.** End-entity private keys are generated locally by each member. Only a CSR (public material) is submitted to this repo for signing. Members never upload a private key.
5. **Public certs, everywhere verifiable.** The Root CA cert is published in this repo. Anyone can fetch it and verify a signature without trusting a third party.
6. **Defense in depth.** CODEOWNERS prevents unilateral workflow modification. Environment approval gates prevent unilateral operations. Strong passphrases provide the last cryptographic backstop.

See [docs/cooperative.md](docs/cooperative.md) for the longer read on partner onboarding, signing/verification flows, and the transparency-as-a-feature stance.

## Customization

Partners are identified by their **GitHub username**. Each partner gets:
- A directory under `pki/issuers/<github-username>/`
- A GitHub Environment named `pki-<github-username>`
- An entry in `.github/pki-partners.sh`

To use this repo for your own team:
1. Edit `.github/pki-partners.sh` with your GitHub usernames and display names
2. Edit `.github/pki-config.sh` with the expected reviewer lists
3. Follow the setup steps below

## Setup (one-time)

Runs once at the start of a deployment. The current `main` of this repo is production-configured: `pki-config.sh` declares the production reviewer lists, CODEOWNERS protects the sensitive code paths, and no Root CA or Issuing CAs exist yet.

This walks through every step, who does it, and when. Founder = felixboehm or Nantero1.

### 1. Configure the three GitHub Environments (one founder, via API or UI)

| Environment | Required reviewers | `prevent_self_review` |
|---|---|---|
| `pki-felixboehm` | `felixboehm` only | false |
| `pki-nantero1` | `Nantero1` only | false |
| `pki-root` | `felixboehm, Nantero1` | false |

The *single* reviewer on each founder env is deliberate — that is how 2-of-2 is enforced. If you add both founders to either gate env, you silently downgrade to 1-of-2. See [`docs/architecture.md`](docs/architecture.md#github-environments) for the reasoning.

CLI shortcut (one founder runs, for each env):

```bash
gh api --method PUT /repos/performance-dudes/trust/environments/pki-felixboehm \
  -F 'reviewers[][type]=User' -F 'reviewers[][id]=<felixboehm-user-id>' \
  -F prevent_self_reviews=false

gh api --method PUT /repos/performance-dudes/trust/environments/pki-nantero1 \
  -F 'reviewers[][type]=User' -F 'reviewers[][id]=<Nantero1-user-id>' \
  -F prevent_self_reviews=false

gh api --method PUT /repos/performance-dudes/trust/environments/pki-root \
  -F 'reviewers[][type]=User' -F 'reviewers[][id]=<felixboehm-user-id>' \
  -F 'reviewers[][type]=User' -F 'reviewers[][id]=<Nantero1-user-id>' \
  -F prevent_self_reviews=false
```

Get user IDs via `gh api /users/<login> --jq .id`.

### 2. Enable branch protection on `main` (one founder, UI)

- Require a pull request before merging.
- Require approvals from CODEOWNERS.
- Block force pushes. Block deletions.

### 3. Register the PKI Guard GitHub App

See [`docs/github-app-setup.md`](docs/github-app-setup.md). Install it on this repo and set `PKI_GUARD_APP_ID` + `PKI_GUARD_PRIVATE_KEY` as secrets in **each** of the three environments. This is what every workflow uses for `verify_environment_policy`.

### 4. Each founder sets their Root CA ceremony passphrase (each founder, own machine)

Rare-use passphrase, stored in `pki-root` as `PKI_PASSWORD_<FOUNDER>`. Used during init, rotate, onboard, export.

```bash
./scripts/setup-root-env.sh felixboehm    # felixboehm runs this
./scripts/setup-root-env.sh nantero1      # Nantero1 runs this
```

Each founder types their own passphrase; no one else ever sees it. Save it in your password manager — GitHub secrets are write-only.

### 5. Each partner sets their Issuing CA passphrase (each partner, own machine)

Day-to-day passphrase, stored in `pki-<partner>` as `PKI_PASSWORD`. Used for `pki-issue`, `pki-renew`, `pki-revoke` (end-entity), and during the partner's `pki-onboard`.

```bash
./scripts/setup-issuer-env.sh felixboehm  # felixboehm runs this
./scripts/setup-issuer-env.sh nantero1    # Nantero1 runs this
```

**Use a different passphrase** than your Root CA one. The two live in different envs and no workflow reads both at once. Save both in your password manager.

### 6. Initialize the Root CA (either founder triggers, both approve)

```bash
gh workflow run pki-init.yml --repo performance-dudes/trust
```

The workflow is four jobs:

| Job | Env | Reviewer who must approve |
|---|---|---|
| `gate-felixboehm` | `pki-felixboehm` | felixboehm |
| `gate-nantero1` | `pki-nantero1` | Nantero1 |
| `init` | `pki-root` | either founder (secondary gate; gates above already enforced 2-of-2) |
| *(the init job creates the Root CA, nested-encrypts the key with both founder passphrases, uploads the encrypted blob as artifact, commits the Root cert + empty CRL)* | | |

Approve each gate from your own GitHub account. The workflow ends by opening a PR with the Root CA public cert. Both founders review and merge (CODEOWNERS requires both).

### 7. Post-init sync (either founder, own machine)

```bash
./scripts/sync-keys-from-workflow.sh <run-id>
```

This downloads the encrypted Root CA blob from the workflow artifact and sets it as `ROOT_CA_KEY_NESTED_B64` in `pki-root`. The blob is already encrypted with nested passphrases; neither Claude Code nor the runner ever holds plaintext during this sync. It also copies the blob into the private `trust-keys` repo as an audit trail (local commit only; push is up to you).

### 8. Onboard each founder as an Issuing CA (repeat for each founder)

Same flow for founders and for every future partner. `pki-onboard` uses the three-job passphrase split described in [`docs/specs/onboard-split-passphrases.md`](docs/specs/onboard-split-passphrases.md), plus the two 2-of-2 gates.

```bash
gh workflow run pki-onboard.yml -f partner=felixboehm
# approve: gate-felixboehm, gate-nantero1, Job A (pki-felixboehm), Job C (pki-felixboehm)
# then review + merge the PR the workflow opens
./scripts/sync-keys-from-workflow.sh <run-id>    # sets ISSUING_KEY_ENC_B64 in pki-felixboehm

gh workflow run pki-onboard.yml -f partner=nantero1
# approve: gate-felixboehm, gate-nantero1, Job A (pki-nantero1), Job C (pki-nantero1)
# merge PR
./scripts/sync-keys-from-workflow.sh <run-id>    # sets ISSUING_KEY_ENC_B64 in pki-nantero1
```

After both founders are onboarded, `pki-issue` and `pki-renew` are operational.

### 9. Onboarding a future partner

Add them to `.github/pki-partners.sh` and `.github/pki-config.sh` (with their own `EXPECTED_PKI_<USERNAME>_*` entries) via a CODEOWNERS-protected PR. Create the `pki-<username>` environment with only that user as reviewer. They run `setup-issuer-env.sh`. Either founder triggers `pki-onboard -f partner=<username>`. Same four-gate approval flow.

## Daily operations

### Issue a new end-entity certificate

A new member generates their key pair and CSR locally:

```bash
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out my-key.pem
openssl req -new -key my-key.pem -out my.csr \
  -subj "/CN=My Name/emailAddress=me@example.com/O=My Organization"
```

Commit the CSR to the repo (`pki/csrs/my-name.csr`), then trigger:

```bash
gh workflow run pki-issue.yml --repo performance-dudes/trust \
  -f issuer=felixboehm \
  -f csr_path=pki/csrs/my-name.csr
```

The workflow signs the CSR with the chosen Issuing CA and opens a PR with the new certificate.

### Verify a certificate

```bash
# Fetch the Root CA cert
curl -sO https://raw.githubusercontent.com/performance-dudes/trust/main/pki/root/ca-cert.pem

# Chain verification
cat pki/issuers/<github-username>/issuing-cert.pem ca-cert.pem > chain.pem
openssl verify -CAfile chain.pem pki/certs/<name>.pem
```

### Sign a PDF

See the `pd` plugin (separate repo, coming soon). Signing happens locally on the signer's laptop, never on a GitHub runner — the handwritten signature image and end-entity private key are private to the signer.
