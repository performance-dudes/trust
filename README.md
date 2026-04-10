# Trust

Self-managed PKI for document signing — generic, reusable trust infrastructure.

**Full technical concept:** [orga/concepts/pki-certificate-authority.md](https://github.com/performance-dudes/orga/blob/main/concepts/pki-certificate-authority.md) (private)
**Decision record:** [orga/decisions/011-pki-certificate-authority.md](https://github.com/performance-dudes/orga/blob/main/decisions/011-pki-certificate-authority.md) (private)

## What this repo is

A self-managed PKI (Public Key Infrastructure) that lets a team issue X.509 certificates and cryptographically sign documents (PDFs, commits, etc.) without depending on a commercial certificate authority. Anyone can verify signatures against the public certificates in this repo.

## The 3-repo architecture

| Repo | Visibility | Contents |
|---|---|---|
| `performance-dudes/trust` (this repo) | public | Workflows, public certificates, tooling, usage docs |
| `performance-dudes/trust-keys` | private | Encrypted CA private keys (audit trail + disaster recovery) |
| `performance-dudes/orga` | private | Strategy, decisions, full technical concept |

Private keys never enter this public repo. They live:
- **At runtime** as Base64-encoded values in GitHub Environment Secrets
- **As audit/backup** as versioned files in the `trust-keys` private repo

## Directory layout

```
.github/
  pki-partners.sh    Partner GitHub usernames + display names
  pki-config.sh      Expected environment protection rules
  workflows/         Seven PKI management workflows (init, issue, renew, revoke, rotate, onboard, export)
tools/pki.sh         Shared helper functions (rage install, OpenSSL wrappers)
scripts/
  setup-environments.sh       Creates GitHub Environments, sets password secrets
  sync-keys-from-workflow.sh  Syncs encrypted keys from workflow artifact to secrets + trust-keys
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
2. **Encrypted at rest.** All CA private keys are encrypted with age using passphrases stored as GitHub Environment Secrets. The Root CA uses a 2-of-2 combined passphrase; Issuing CAs use the respective partner's password.
3. **Approval gates.** GitHub Environments with required reviewers enforce 2-of-2 at the operational level. All partners must approve before `pki-root` secrets are exposed to a workflow runner.
4. **Local signing.** End-entity private keys are generated locally by each member. Only a CSR (public material) is submitted to this repo for signing. Members never upload a private key.
5. **Public certs, everywhere verifiable.** The Root CA cert is published in this repo. Anyone can fetch it and verify a signature without trusting a third party.
6. **Defense in depth.** CODEOWNERS prevents unilateral workflow modification. Environment approval gates prevent unilateral operations. Strong passphrases provide the last cryptographic backstop.

See the [full concept in orga](https://github.com/performance-dudes/orga/blob/main/concepts/pki-certificate-authority.md) for hierarchy details, threat model, encryption scheme, and limitations (including the analysis of CGGMP24 threshold signing and nested age encryption).

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

Run from a local clone of this repo.

### 1. Create environments and set password secrets

Each partner runs from their own machine, passing their GitHub username:

```bash
./scripts/setup-environments.sh felixboehm    # felixboehm runs this
./scripts/setup-environments.sh nantero1      # nantero1 runs this
```

Each partner types their own PKI password. Secrets are write-only — **save the password in a password manager first.**

For testing, you can run the script once per partner from one account.

### 2. Initialize the PKI

```bash
gh workflow run pki-init.yml --repo performance-dudes/trust
```

The workflow generates the Root CA and per-partner Issuing CAs, encrypts the private keys, uploads them as the `encrypted-keys` artifact, commits public certificates via a PR.

### 3. Sync encrypted keys to secrets and trust-keys

After `pki-init` completes successfully, sync the encrypted keys:

```bash
# Clone trust-keys next to this repo (first time only)
git clone git@github.com:performance-dudes/trust-keys.git ../trust-keys

# Sync from a workflow run ID
./scripts/sync-keys-from-workflow.sh <run-id>
```

The script downloads the artifact, sets each encrypted key as a GitHub Environment Secret, and commits the blobs to `trust-keys` (opens a PR).

### 4. Review and merge both PRs

- The public certs PR in this repo
- The encrypted keys backup PR in `trust-keys`

After merging, all subsequent workflows (`pki-issue`, `pki-renew`, etc.) can read the encrypted keys from the Environment Secrets and operate.

### 5. (Production only) Harden the setup

Once testing is complete and you're ready for production:

- Enable required reviewers on all environments (all partners)
- Enable `prevent_self_review` on all environments
- Uncomment the entries in `.github/CODEOWNERS`
- Enable branch protection on `main`: require PR reviews, require CODEOWNERS review, prevent force pushes

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
