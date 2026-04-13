# PKI Architecture

This document describes the implementation of the Performance Dudes PKI: certificate hierarchy, encryption scheme, environment layout, workflow shapes, helpers, and certificate profiles. For the product-level framing (why this exists, the cooperative model, customer verification story), see [`orga/concepts/pki-certificate-authority.md`](https://github.com/performance-dudes/orga/blob/main/concepts/pki-certificate-authority.md).

> Note: one-off implementation plans for individual refactors live alongside this document in [`docs/specs/`](specs/).

## What this repo contains

```
.github/
  workflows/            Seven PKI management workflows (init, onboard, issue, renew, revoke, rotate, export)
  pki-config.sh         Expected GitHub Environment protection rules (CODEOWNERS-protected)
  pki-partners.sh       Active partner GitHub usernames (CODEOWNERS-protected)
  CODEOWNERS            Required reviewers for workflow/tooling changes
tools/
  pki.sh                Shared OpenSSL helper functions (sourced by every workflow)
scripts/
  setup-root-env.sh            Founder-only: sets PKI_PASSWORD_<FOUNDER> in pki-root
  setup-issuer-env.sh          Every partner: sets PKI_PASSWORD in pki-<partner>
  sync-keys-from-workflow.sh   Post-workflow: pulls encrypted-key artifacts and stores as env secrets
pki/
  root/ca-cert.pem             Root CA public certificate
  issuers/<partner>/           Per-partner Issuing CA public certs + serial counters
  certs/                       End-entity public certs
  csrs/                        Submitted CSRs (for audit)
  crl/                         Certificate revocation lists (root-crl.pem + <partner>-crl.pem)
docs/
  architecture.md       This file
  cooperative.md        Partner / signing / verification narrative
  github-app-setup.md   PKI Guard GitHub App registration
  specs/                Implementation specs for individual refactors
```

Private key material is never committed here. See [Encryption scheme](#encryption-scheme) for where keys actually live.

## Certificate hierarchy

```
Root CA                (RSA-4096, 10-year validity, 2-of-2 founders)
  |
  +- Issuing CA felixboehm    (RSA-3072, 5-year validity, felixboehm only)
  |    +- end-entity certs issued by felixboehm (RSA-2048, 1-year validity)
  |
  +- Issuing CA nantero1      (RSA-3072, 5-year validity, nantero1 only)
  |    +- end-entity certs issued by nantero1
  |
  +- (future) Issuing CA <partner>   (issued by Root via 2-of-2 onboard)
```

Three tiers. Root CA is touched only during 2-of-2 ceremonies: `pki-init`, `pki-onboard`, partner-level `pki-revoke`, `pki-rotate`, `pki-export`. Issuing CAs are touched during 1-of-N operations: `pki-issue`, `pki-renew`, end-entity `pki-revoke`. End-entity keys never touch GitHub at all — they are generated locally on each signer's laptop.

Separating Issuing CAs per partner means a passphrase leak reaches exactly one branch of the tree. The 2-of-2 Root CA can revoke the compromised Issuing CA without affecting other partners.

## Identity and naming

Partners are identified by their **GitHub username**. This is the single canonical identifier across the entire PKI.

| Thing | Pattern | Example |
|---|---|---|
| Partner directory | `pki/issuers/<username>/` | `pki/issuers/felixboehm/` |
| Partner CRL | `pki/crl/<username>-crl.pem` | `pki/crl/felixboehm-crl.pem` |
| Partner environment | `pki-<username>` | `pki-felixboehm` |
| End-entity cert Common Name | `<username>` | `CN=felixboehm` |

Active partners are listed in [`.github/pki-partners.sh`](../.github/pki-partners.sh). Adding a partner is a CODEOWNERS-protected PR against that file plus the matching `EXPECTED_PKI_<USERNAME>_*` entries in [`.github/pki-config.sh`](../.github/pki-config.sh).

## Encryption scheme

All CA key encryption uses **OpenSSL AES-256-CBC with PBKDF2**, 600,000 iterations, HMAC-SHA-512 as the PRF. (We previously evaluated age/rage but switched after pinentry issues on GitHub Actions runners.) OpenSSL is pre-installed on every runner and macOS/Linux laptop, so no additional tooling is required.

### Per-key encryption

| Key | Encryption | Where stored |
|---|---|---|
| Root CA private key | Nested: `openssl(outer_pw, openssl(inner_pw, plaintext))` | Env secret `ROOT_CA_KEY_NESTED_B64` in `pki-root` |
| Issuing CA private key | Single layer with partner's passphrase | Env secret `ISSUING_KEY_ENC_B64` in `pki-<partner>` |
| End-entity private key | PKCS#8 AES-256-CBC, HMAC-SHA-512 KDF, 600k iter | `~/.config/pd/private-key.pem` on signer's laptop |

The nested Root CA scheme means the outer layer is decrypted with one founder's passphrase and the inner layer with the other's. By convention: outer = `felixboehm`, inner = `nantero1`.

Encrypted CA key blobs are also mirrored into the private [`performance-dudes/trust-keys`](https://github.com/performance-dudes/trust-keys) repo as an audit/disaster-recovery trail. They remain encrypted in both places; decryption requires the respective partner(s) to supply passphrases.

### Nested encryption details

`tools/pki.sh` provides four helpers for the nested scheme:

```
nested_encrypt_both <plain> <nested.enc> <inner_pw> <outer_pw>
nested_decrypt_outer <nested.enc> <inner.enc> <outer_pw>
nested_decrypt_inner <inner.enc> <plain> <inner_pw>
nested_encrypt_inner / nested_encrypt_outer     # for multi-phase flows
```

`pki-init` uses `nested_encrypt_both` once (both passphrases available in one job). Decryption in `pki-onboard` Job B, `pki-rotate`, `pki-export` uses `_outer` then `_inner` sequentially.

### Shared-runner property for 2-of-2 operations

Both founder passphrases are required to reassemble a plaintext Root CA key. For the duration of a 2-of-2 ceremony, they are both present in the same runner. This is an acknowledged residual risk, mitigated by:

- Two-of-two GitHub Environment gates that must be approved before the runner boots
- `verify_environment_policy` at the start of each job that asserts the expected protection rules are intact
- CODEOWNERS on workflow code and `pki-config.sh`
- Branch protection on `main` that prevents bypassing PR review
- Rare operation cadence (init once, onboard a few times ever, rotate rarely)

The long-term path to eliminate this property entirely is threshold ECDSA signing (e.g. CGGMP24) where the Root CA private key is never reconstructed anywhere. That is not a short-term plan — it requires building a signer service, transport layer, and orchestration, with careful audit. The current scheme is documented, not silently assumed to be MPC.

## GitHub environments

Three kinds of environment, all named with the `pki-` prefix.

| Environment | Required reviewers (prod) | Secrets |
|---|---|---|
| `pki-felixboehm` | `felixboehm` only | `PKI_PASSWORD` (Issuing CA), `ISSUING_KEY_ENC_B64`, `PKI_GUARD_APP_ID`, `PKI_GUARD_PRIVATE_KEY` |
| `pki-nantero1` | `Nantero1` only | Same as above, per partner |
| `pki-root` | `felixboehm, Nantero1` (secondary) | `PKI_PASSWORD_FELIXBOEHM`, `PKI_PASSWORD_NANTERO1`, `ROOT_CA_KEY_NESTED_B64`, `PKI_GUARD_APP_ID`, `PKI_GUARD_PRIVATE_KEY` |

Note the single-reviewer pattern on the founder envs. It is deliberate. GitHub Environment "required reviewers" only requires one of the listed reviewers to approve — it does not enforce N-of-N. So if both founders were listed on `pki-root` alone, either one could approve a Root CA operation single-handedly. To actually require both founders to each approve, every Root-CA-touching workflow goes through two gate jobs — `gate-felixboehm` running in `pki-felixboehm` (where only `felixboehm` is allowed to approve) and `gate-nantero1` running in `pki-nantero1` (where only `Nantero1` is allowed to approve) — before the `pki-root` job itself starts. That is what makes 2-of-2 real.

`pki-root`'s own required-reviewer list is a secondary safety net; the actual 2-of-2 enforcement is in the two gate jobs.

Secrets are **write-only** — neither the UI nor any API surface reads them back. They are injected into runner memory after environment approval and destroyed with the ephemeral runner when the job ends. Each partner sets their own secrets using the local scripts in [`scripts/`](../scripts/); no one ever types another partner's passphrase.

### Production vs test configuration

In the current test config, `pki-nantero1` and `pki-root` are temporarily configured with `felixboehm` as reviewer so a solo developer can drive end-to-end tests without a second human. Production MUST flip these to the real values (`pki-nantero1` reviewed only by `Nantero1`; `pki-root` reviewed by both founders) and update `pki-config.sh` accordingly. The production values are documented alongside the current test values in `pki-config.sh`.

## Policy verification via GitHub App

The **PKI Guard** GitHub App is installed on the `trust` repo and exists solely to mint short-lived tokens with `Administration:Read` permission. Every workflow job starts by:

1. Minting a PKI Guard token via `actions/create-github-app-token`.
2. Calling `verify_environment_policy <env_name>` from `tools/pki.sh`.
3. The helper queries `/repos/<repo>/environments/<env_name>` and asserts three properties against `pki-config.sh`:
   - `can_admins_bypass` matches the expected value
   - Required reviewers match the expected list (sorted, unique)
   - `prevent_self_review` matches the expected value

If any check fails, the job aborts before touching cryptographic material. This is the runtime defense against someone silently relaxing environment protection rules in the web UI. Expected values live in [`.github/pki-config.sh`](../.github/pki-config.sh); modifying them requires a CODEOWNERS-approved PR.

See [`docs/github-app-setup.md`](github-app-setup.md) for registering the app on a fresh deployment.

## Workflows

All seven workflows are `workflow_dispatch` only. Passphrases and encrypted key blobs come from environment secrets, never from workflow inputs. Every workflow that mutates the PKI opens a PR to `main`; none push directly.

### `pki-init` — Initialize Root CA (2-of-2)

Runs once at the start of a deployment.

| Job | Environment | Role |
|---|---|---|
| `gate-felixboehm` | `pki-felixboehm` | Reviewer = `felixboehm` only. felixboehm must approve. Verifies env policy. |
| `gate-nantero1` | `pki-nantero1` | Reviewer = `Nantero1` only. Nantero1 must approve. Verifies env policy. |
| `init` | `pki-root` | `needs: [gate-felixboehm, gate-nantero1]`. Generates Root CA (RSA-4096, 10 years, `CA:TRUE`, `pathlen:1`), empty Root CRL. Nested-encrypts the key with both founder passphrases. Uploads encrypted blob as artifact. Commits public cert + CRL and opens PR. |

The two gate jobs are where 2-of-2 is actually enforced (see [Tampering protection](#tampering-protection) for why this gate pattern exists).

### `pki-onboard` — Create Partner Issuing CA (2-of-2)

Used for the initial founders and every future partner. No special case. Three-job passphrase-split described in [`docs/specs/onboard-split-passphrases.md`](specs/onboard-split-passphrases.md), plus the same gate pattern as `pki-init`.

| Job | Environment | Role |
|---|---|---|
| `gate-felixboehm` | `pki-felixboehm` | 2-of-2 gate. |
| `gate-nantero1` | `pki-nantero1` | 2-of-2 gate. |
| `generate-issuing-key` (A) | `pki-<partner>` | Generate RSA-3072 keypair, build CSR, encrypt key with partner's `PKI_PASSWORD`. Upload both as artifacts. |
| `sign-csr` (B) | `pki-root` | `needs: [gate-felixboehm, gate-nantero1, generate-issuing-key]`. Decrypt nested Root CA, sign CSR as Issuing CA cert (5-year, `CA:TRUE`, `pathlen:0`). Upload signed cert. |
| `finalize-and-commit` (C) | `pki-<partner>` | `needs: sign-csr`. Re-decrypt Issuing CA key, build empty CRL, commit cert + CRL, open PR. |

Only the CSR (public) and the signed cert (public) cross environment boundaries. The Issuing CA private key is generated, used, and encrypted inside `pki-<partner>` and never enters `pki-root`.

### `pki-issue` — Sign an End-Entity Cert (1-of-N)

Env: `pki-<issuer>`. Run whenever a new person joins a partner's team.

1. Verify CSR exists at the path given as input (relative to repo root, conventionally `pki/csrs/<name>.csr`).
2. Verify `pki-<issuer>` policy.
3. Decrypt the Issuing CA key using the partner's `PKI_PASSWORD` and the stored `ISSUING_KEY_ENC_B64` blob.
4. Sign the CSR as an end-entity cert (2-year validity, `CA:FALSE`, `keyUsage=digitalSignature,nonRepudiation`, `extendedKeyUsage=emailProtection,documentSigning`).
5. Commit the signed cert to `pki/certs/` and open PR.

No private key material is generated on the runner. The submitter's key stays local.

### `pki-renew` — Re-sign an End-Entity CSR (1-of-N)

Same env and shape as `pki-issue`; accepts a new CSR (same or fresh key) and produces a new cert.

### `pki-revoke` — Revoke a Certificate (tiered)

Two jobs gated by the `target_type` input:

- `end-entity` target: env `pki-<issuer>`, 1-of-N. Decrypt Issuing CA key, add serial to `<issuer>-crl.pem`, re-sign, delete cert. Open PR.
- `issuing-ca` target: env `pki-root`, 2-of-2. Decrypt Root CA, add Issuing CA serial to `root-crl.pem`, re-sign, remove `pki/issuers/<partner>/`. Open PR.

### `pki-rotate` — Rotate the Root CA (2-of-2)

Env: `pki-root`. Takes new passphrases as inputs (temporary — used only for re-encrypting the new Root CA key at the end of the run; each founder updates their env secret afterward).

1. Decrypt old Root CA key (2-of-2).
2. Generate new Root CA key and self-signed cert.
3. Re-sign all existing Issuing CA certs with the new Root.
4. Nested-encrypt new Root CA key with the new passphrases.
5. Archive the old Root cert under `pki/root/archive/`. Commit and open PR.

End-entity certs are unchanged — they chain to Issuing CAs, not directly to Root.

### `pki-export` — Escape Hatch (2-of-2)

Env: `pki-root`. No inputs. Produces a one-time-passphrase-encrypted copy of the Root CA key as a workflow artifact (1-hour expiry); the one-time passphrase is written to the workflow summary (visible only to repo admins). This is the mechanism for reconstituting the PKI outside GitHub if we ever need to leave.

## Helper functions (`tools/pki.sh`)

```
# Symmetric crypto (AES-256-CBC + PBKDF2 600k, HMAC-SHA-512)
pki_encrypt <plain> <out.enc> <passphrase>
pki_decrypt <in.enc> <out> <passphrase>

# Nested (2-of-2)
nested_encrypt_both <plain> <out.enc> <inner_pw> <outer_pw>
nested_decrypt_outer <in.enc> <intermediate.enc> <outer_pw>
nested_decrypt_inner <intermediate.enc> <plain> <inner_pw>
nested_encrypt_inner / nested_encrypt_outer    # multi-phase builds

# Keys and certs
generate_rsa_key <bits> <out.pem>
create_root_ca <key> <cert_out> <days>
build_issuing_ca_csr <key> <csr_out> <partner_name>
sign_issuing_ca_csr <csr> <root_key> <root_cert> <cert_out> <days>
create_issuing_ca <root_key> <root_cert> <new_key> <cert_out> <partner> <days>   # wrapper
create_empty_crl <ca_key> <ca_cert> <crl_out> <days>

# Governance
verify_environment_policy <env_name>       # reads pki-config.sh, queries GitHub API

# Cleanup
secure_wipe <file>                         # shred or /dev/urandom overwrite
```

All helpers are idempotent and fail loudly with `set -euo pipefail` (sourced from the top of the file).

## Certificate profiles

### Root CA

- `Subject: CN=Performance Dudes Root CA, O=Performance Dudes`
- `BasicConstraints: critical, CA:TRUE, pathlen:1`
- `KeyUsage: critical, keyCertSign, cRLSign`
- `SubjectKeyIdentifier: hash`
- RSA-4096, 10-year validity

### Issuing CA

- `Subject: CN=Performance Dudes Issuing CA - <partner>, O=Performance Dudes`
- `BasicConstraints: critical, CA:TRUE, pathlen:0`
- `KeyUsage: critical, keyCertSign, cRLSign`
- `SubjectKeyIdentifier: hash`
- `AuthorityKeyIdentifier: keyid:always` (links to Root)
- RSA-3072, 5-year validity

### End-entity

- `Subject: CN=<github-username>, emailAddress=<email>, O=Performance Dudes`
- `BasicConstraints: CA:FALSE`
- `KeyUsage: digitalSignature, nonRepudiation`
- `ExtendedKeyUsage: emailProtection, documentSigning`
- `AuthorityKeyIdentifier` linking to the issuing partner's Issuing CA
- RSA-2048, 1–2-year validity

## Tampering protection

Four layers stack to prevent any single actor (including a founder with a compromised account) from silently weakening the PKI:

1. **CODEOWNERS** (`.github/CODEOWNERS`) requires both founders to approve changes to `.github/workflows/`, `.github/pki-config.sh`, `.github/pki-partners.sh`, `tools/pki.sh`, `scripts/`.
2. **Branch protection on `main`** requires PR review and blocks force pushes.
3. **Dual single-reviewer gate jobs.** Every Root-CA-touching workflow (`pki-init`, `pki-onboard`, `pki-rotate`, `pki-export`, and the issuing-CA branch of `pki-revoke`) declares two explicit gate jobs: `gate-felixboehm` in env `pki-felixboehm` (required reviewer = `felixboehm` only) and `gate-nantero1` in env `pki-nantero1` (required reviewer = `Nantero1` only). The main `pki-root` job `needs:` both. This is what actually enforces 2-of-2 — stock GitHub required-reviewers would only require one of the listed reviewers to approve, so a single env listing both founders is not enough.
4. **Runtime `verify_environment_policy`** asserts that the environment's protection rules actually match `pki-config.sh` *at the moment the job runs*, including the single-reviewer constraint on each gate env. An in-UI loosening between PR merge and workflow dispatch is caught here.

A successful attack requires compromising both founders' accounts **and** bypassing CODEOWNERS **and** evading the runtime policy check. Not impossible; not cheap.

## Known limitations and threat model

- **Both Root CA passphrases meet in one runner during 2-of-2 ceremonies.** Discussed above under [Encryption scheme](#shared-runner-property-for-2-of-2-operations). Mitigations in place; threshold-signing upgrade is a long-term option.
- **GitHub as a trusted third party.** GitHub can theoretically read secrets in runner memory. Accepted for the current team size and operation cadence. `pki-export` is the escape hatch.
- **Password loss.** If a founder loses their Root passphrase, 2-of-2 operations freeze until the PKI is re-initialized. Partner Issuing CA passphrases are independently recoverable only by the partner themselves; loss means revoking and re-onboarding that partner via 2-of-2.
- **Workflow tampering via malicious PR.** CODEOWNERS blocks it; a two-account compromise is required to merge a workflow change. Covered under [Tampering protection](#tampering-protection).
- **Log exfiltration.** GitHub masks secrets in logs. Helpers avoid `set -x` around key material. Plaintext keys exist only in memory and `secure_wipe`-protected temp files.

## References

- [`orga/concepts/pki-certificate-authority.md`](https://github.com/performance-dudes/orga/blob/main/concepts/pki-certificate-authority.md) — product view.
- [`orga/decisions/011-pki-certificate-authority.md`](https://github.com/performance-dudes/orga/blob/main/decisions/011-pki-certificate-authority.md) — the decision to build it.
- [`docs/cooperative.md`](cooperative.md) — partner narrative (joining, signing, verifying).
- [`docs/github-app-setup.md`](github-app-setup.md) — PKI Guard app registration.
- [`docs/specs/`](specs/) — implementation specs for individual refactors.
