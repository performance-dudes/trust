# Spec: Split founder / issuing passphrases in `pki-onboard`

**Status:** proposed
**Date:** 2026-04-13

## Problem

The current `pki-onboard` workflow runs a single job in `pki-root` that both decrypts the Root CA and encrypts the freshly-generated Issuing CA key. Because a GitHub Actions job can read secrets from only **one** environment, the partner's Issuing CA passphrase has to be duplicated into `pki-root` as `PKI_PASSWORD_<PARTNER>`. That collapses defense in depth for that partner: a single passphrase leak compromises **both** the founder's Root ceremony contribution and their Issuing CA.

The limitation was documented in the workflow header as "accepted for now" with a vague "multi-job handoff" future direction. This spec makes that handoff concrete.

## Key idea

A Certificate Signing Request (CSR) is **public data by definition** — it is designed to be sent over untrusted channels. The only secret in the Issuing-CA creation process is the new private key itself. So:

- Generate the Issuing CA private key in the **partner's** environment, where the partner's passphrase lives. Encrypt it there. It never leaves.
- Build a CSR for the Issuing CA and pass only **that** to the next job.
- Sign the CSR in `pki-root`, where the Root CA passphrases live.
- Come back to the partner's environment to produce the initial CRL (which requires re-decrypting the key — it has to be signed by the Issuing CA it belongs to).

Only public material crosses environment boundaries. No encrypted transport mechanism needed, no shared ephemeral key.

## New workflow shape

```
Job A  generate-issuing-key   env: pki-<partner>   needs: –
Job B  sign-csr               env: pki-root        needs: A
Job C  finalize-and-commit    env: pki-<partner>   needs: A, B
```

### Job A — `generate-issuing-key` (env: `pki-<partner>`)

Inputs: `partner` (workflow input).

Steps:
1. Verify `pki-<partner>` policy against `pki-config.sh`.
2. Validate `partner` is present in `.github/pki-partners.sh`.
3. Validate that `pki/issuers/<partner>/issuing-cert.pem` does **not** already exist.
4. Generate RSA-3072 keypair.
5. Build a CSR with subject `/CN=Performance Dudes Issuing CA - <partner>/O=Performance Dudes`.
6. Encrypt the private key with `PKI_PASSWORD` (this env's secret).
7. Upload artifacts:
   - `encrypted-keys/<partner>-issuing-key.enc` (for later sync into env secret via `sync-keys-from-workflow.sh`)
   - `csr/<partner>-issuing.csr` (for Job B)

### Job B — `sign-csr` (env: `pki-root`)

Steps:
1. Verify `pki-root` policy against `pki-config.sh` (requires 2-of-2 approval to enter this env).
2. Download CSR artifact from Job A.
3. Decrypt nested Root CA key using both founder passphrases (`PKI_PASSWORD_FELIXBOEHM`, `PKI_PASSWORD_NANTERO1`).
4. Sign the CSR as an Issuing CA cert (`CA:TRUE, pathlen:0`, `keyUsage=keyCertSign,cRLSign`, 1825 days).
5. Wipe the decrypted Root CA key.
6. Upload artifact: `signed-cert/<partner>-issuing-cert.pem`.
7. Verify chain: `openssl verify -CAfile pki/root/ca-cert.pem <new-cert>`.

### Job C — `finalize-and-commit` (env: `pki-<partner>`)

Steps:
1. Verify `pki-<partner>` policy (still intact).
2. Download encrypted key artifact from Job A, decrypt with `PKI_PASSWORD`.
3. Download signed cert artifact from Job B.
4. Generate empty CRL signed by the Issuing CA key.
5. Wipe the decrypted Issuing CA key.
6. Stage into `pki/issuers/<partner>/` and `pki/crl/<partner>-crl.pem`.
7. Commit, push branch, open PR.

The encrypted-key artifact from Job A remains available for 7 days and is consumed by `sync-keys-from-workflow.sh` after the PR is merged — unchanged from today.

## What crosses environment boundaries

| Between | Payload | Sensitivity |
|---|---|---|
| A → B | CSR (PEM) | public |
| B → C | Signed Issuing CA cert (PEM) | public |
| A → C | Encrypted Issuing CA key (passphrase-protected) | safe (attacker needs partner passphrase) |

No plaintext private key ever crosses a job boundary.

## Gates: removed

Current onboard has two `gate-*` jobs (one in `pki-felixboehm`, one in `pki-nantero1`) that run `verify_environment_policy` before the main job. They exist because in the old shape, the single-environment `pki-root` job did not naturally touch the founders' personal envs, so the gates served as a "both founders' envs still intact" check.

In the new shape:
- Job A verifies `pki-<partner>` before generating keys there.
- Job B verifies `pki-root` before touching the Root CA (and entering `pki-root` already requires both founders to approve).
- The 2-of-2 property comes from `pki-root`'s required reviewers, not from separate gate jobs.

Dropping the gate jobs removes two redundant approval clicks. The policy-verification side-check on each founder's personal env disappears — acceptable, because any tampering with those envs is already guarded by CODEOWNERS on `pki-config.sh` and branch protection on `main`.

The same simplification applies to `pki-init.yml` (also included in this refactor).

## Config changes

Adding a new partner still requires a PR to `.github/pki-partners.sh` **and** `.github/pki-config.sh` (to add `EXPECTED_PKI_<PARTNER>_*` entries) before `pki-onboard` can run. This PR is CODEOWNERS-protected, i.e. both founders approve it.

## Helper changes (`tools/pki.sh`)

Split the existing `create_issuing_ca` (which generates key **and** signs) into two helpers:

- `build_issuing_ca_csr <key> <csr> <partner>` — run in partner's env, only needs new key.
- `sign_issuing_ca_csr <csr> <root_key> <root_cert> <out_cert> <days>` — run in `pki-root`, only needs Root CA.

`create_issuing_ca` stays around as a thin wrapper for tests / ad-hoc use — not used by the workflow anymore.

## Cleanup after merge

- `PKI_PASSWORD_<PARTNER>` secrets in `pki-root` become unused. Remove them manually via `gh secret delete` or the UI.
- Update `setup-issuer-env.sh` comment: the partner's PKI_PASSWORD is now genuinely independent of their Root ceremony passphrase (for founders with both).

## Out of scope

- `pki-issue`, `pki-renew`, `pki-revoke` already run in a single env (`pki-<partner>`) and don't need this split — untouched.
- `pki-rotate`, `pki-export` are `pki-root`-only — gates could be dropped there too, but tracked separately.

## Rollout

One PR. No flag, no migration — `pki-onboard` has not yet been run for anyone in production (the Root CA itself hasn't been initialized yet). Land the refactor, then init + onboard use the new flow.
