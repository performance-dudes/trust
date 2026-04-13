# Claude Code Instructions — trust repo

This is the public PKI repository for Performance Dudes. You are helping a partner, member, or external contributor operate on the trust infrastructure. Read carefully — this repo has specific rules.

## Ground rules

- **This repo is public.** Anything committed here is visible to the world. Never commit plaintext secrets, private keys, passphrases, or anything that should not be public.
- **Private keys never live here.** The CA private keys are encrypted and stored as GitHub Environment Secrets and (optionally) in the private `trust-keys` repo. End-entity private keys live only on each signer's laptop.
- **Workflows are protected.** Changes to `.github/workflows/`, `.github/pki-config.sh`, `.github/pki-partners.sh`, `tools/pki.sh`, and `scripts/` require CODEOWNERS approval (see `.github/CODEOWNERS`) and must go via PR. Do not push directly to `main`.
- **Secret values are never visible to you.** GitHub environment secrets are write-only. You cannot read them via any API. Do not attempt.

## What you can do

- Help the user generate a CSR (via the `pd` plugin's `setup.py` if they have it)
- Help commit a CSR to `pki/csrs/<username>.csr` via a branch + PR (CODEOWNERS must approve)
- Trigger workflows via `gh workflow run` (the user's `gh` auth is used)
- Approve pending environment deployments via `gh api .../pending_deployments` **only for the user whose `gh` is authenticated** — never on behalf of someone else
- Read public certificates in `pki/` for chain validation
- Run `scripts/sync-keys-from-workflow.sh` after a write-operation workflow (downloads the encrypted-keys artifact and sets them as Environment Secrets; the blobs are already encrypted, safe in your context)

## What you must NEVER do

- **Read or prompt for any PKI passphrase.** The user runs `scripts/setup-root-env.sh` or `scripts/setup-issuer-env.sh` themselves and types into their `read -rs` prompt — the passphrase does not pass through your context. Never ask for it, never log it, never store it anywhere.
- **Commit encrypted or plaintext private keys** to this repo. Encrypted CA keys live as Env Secrets. Any `.key` or `.pem` private-key file in a commit is a bug.
- **Approve workflow runs for the other founder/partner.** Their approval goes through their own `gh` auth, not yours.
- **Change `.github/pki-config.sh` expected values** without understanding the ceremony implications. That file declares the policy that the workflows self-verify against. Mismatch = workflow fails.

## Typical user flows

### "I need to get my cert signed"
1. User has run `pd/scripts/setup.py` and has a CSR at `~/.config/pd/signing.csr`
2. Copy it to `pki/csrs/<their-username>.csr`
3. Branch + commit + push + PR (CODEOWNERS review required)
4. After PR is merged: trigger `pki-issue` workflow with their chosen issuer
5. User approves their own environment gate (or the relevant partner's gate)
6. Cert PR opens — review and merge (CODEOWNERS)

### "I need to set up my environment secrets"

Two scripts, split by role:

- **Founder**: runs BOTH scripts. Root ceremony passphrase (rare use, set via `setup-root-env.sh`) and Issuing CA passphrase (regular use, set via `setup-issuer-env.sh`). For the current onboard workflow these must be the SAME value per founder — stored in two env secrets.
- **Non-founder partner**: runs ONLY `setup-issuer-env.sh` (no Root CA access).

```bash
./scripts/setup-root-env.sh <username>     # founder only
./scripts/setup-issuer-env.sh <username>   # every partner
```

User types their passphrase into the `read -rs` prompt themselves — you never see it.

### "Initialize the PKI" (2-of-2)
- Only after both founders have completed env setup and policy is production-hardened
- Trigger `pki-init` workflow
- Both founders approve the three gates (`gate-<each-partner>`, `init`)
- Public certs PR opens → merge (CODEOWNERS)
- Run `scripts/sync-keys-from-workflow.sh <run-id>` — this sets encrypted blob secrets
- Optionally commit the blobs to `trust-keys` for audit trail

## File layout (what's where)

```
.github/
  workflows/*.yml            PKI management workflows
  pki-config.sh              Expected environment policy (CODEOWNERS-protected)
  pki-partners.sh            List of active partner GitHub usernames
  CODEOWNERS                 Who must review workflow/tooling changes
tools/pki.sh                 Shared helper functions
scripts/
  setup-root-env.sh          Founder-only: Root CA ceremony passphrase
  setup-issuer-env.sh        Every partner: Issuing CA passphrase
  sync-keys-from-workflow.sh Run after write-ops to set encrypted-key secrets
pki/
  root/ca-cert.pem           Root CA public certificate
  issuers/<partner>/         Per-partner Issuing CA public certs
  certs/                     End-entity public certs
  csrs/                      Submitted CSRs
  crl/                       Certificate Revocation Lists
docs/
  github-app-setup.md        How to register the "PKI Guard" app
  cooperative.md             Partner/signing/verification story
```

## Reference

- [README.md](README.md) — why this exists, the cooperative story
- [docs/cooperative.md](docs/cooperative.md) — longer read: joining, leaving, signing, verifying
- [docs/github-app-setup.md](docs/github-app-setup.md) — PKI Guard GitHub App setup
