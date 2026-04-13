# Spec: Split founder and issuing passphrases in pki-onboard

**Status:** accepted (implemented)
**Date:** 2026-04-13
**Product context:** [orga / concepts/pki-certificate-authority.md](https://github.com/performance-dudes/orga/blob/main/concepts/pki-certificate-authority.md)

## Problem

The previous `pki-onboard` workflow ran a single job in `pki-root` that both decrypted the Root CA and encrypted the freshly generated Issuing CA key. Because a GitHub Actions job can read secrets from only one environment, the partner's Issuing CA passphrase had to be duplicated into `pki-root` as `PKI_PASSWORD_<PARTNER>`. That collapsed defense in depth for that partner: a single passphrase leak compromised both the founder's Root ceremony contribution and their Issuing CA.

## Key idea

A Certificate Signing Request (CSR) is public data by definition — it is designed to be sent over untrusted channels. The only secret in the Issuing CA creation process is the new private key itself. So:

- Generate the Issuing CA private key in the partner's environment, where the partner's passphrase lives. Encrypt it there. It never leaves.
- Build a CSR for the Issuing CA and pass only that to the next job.
- Sign the CSR in `pki-root`, where the Root CA passphrases live.
- Come back to the partner's environment to produce the initial CRL, which must be signed by the Issuing CA key.

Only public material crosses environment boundaries. No encrypted transport mechanism needed, no shared ephemeral key.

## Workflow shape

```
Job A  generate-issuing-key   env: pki-<partner>   needs: none
Job B  sign-csr               env: pki-root        needs: A
Job C  finalize-and-commit    env: pki-<partner>   needs: A, B
```

### Job A — `generate-issuing-key` (env: `pki-<partner>`)

1. Verify `pki-<partner>` policy against `pki-config.sh`.
2. Validate `partner` is present in `.github/pki-partners.sh`.
3. Validate that `pki/issuers/<partner>/issuing-cert.pem` does not already exist.
4. Generate RSA-3072 keypair.
5. Build a CSR with subject `/CN=Performance Dudes Issuing CA - <partner>/O=Performance Dudes`.
6. Encrypt the private key with `PKI_PASSWORD` (this env's secret).
7. Upload artifacts:
   - `encrypted-keys/<partner>-issuing-key.enc` — consumed later by `sync-keys-from-workflow.sh`.
   - `csr/<partner>-issuing.csr` — input to Job B.

### Job B — `sign-csr` (env: `pki-root`)

1. Verify `pki-root` policy. Entering this env already requires 2-of-2 approval.
2. Download the CSR artifact from Job A.
3. Decrypt the nested Root CA key using both founder passphrases, `PKI_PASSWORD_FELIXBOEHM` and `PKI_PASSWORD_NANTERO1`.
4. Sign the CSR as an Issuing CA cert: `CA:TRUE, pathlen:0`, `keyUsage=keyCertSign,cRLSign`, 1825 days.
5. Wipe the decrypted Root CA key.
6. Upload artifact: `signed-cert/<partner>-issuing-cert.pem`.
7. Verify the chain: `openssl verify -CAfile pki/root/ca-cert.pem <new-cert>`.

### Job C — `finalize-and-commit` (env: `pki-<partner>`)

1. Verify `pki-<partner>` policy still intact.
2. Download encrypted key artifact from Job A, decrypt with `PKI_PASSWORD`.
3. Download signed cert artifact from Job B.
4. Generate empty CRL signed by the Issuing CA key.
5. Wipe the decrypted Issuing CA key.
6. Stage into `pki/issuers/<partner>/` and `pki/crl/<partner>-crl.pem`.
7. Commit, push branch, open PR.

The encrypted key artifact from Job A remains available for seven days and is consumed by `sync-keys-from-workflow.sh` after the PR is merged. Unchanged from before.

## What crosses environment boundaries

| Between | Payload | Sensitivity |
|---|---|---|
| A → B | CSR (PEM) | public |
| B → C | Signed Issuing CA cert (PEM) | public |
| A → C | Encrypted Issuing CA key (passphrase protected) | safe — attacker still needs the partner passphrase |

No plaintext private key ever crosses a job boundary.

## Gates removed

The previous onboard had two `gate-*` jobs (one in `pki-felixboehm`, one in `pki-nantero1`) that ran `verify_environment_policy` before the main job. In the old shape the single-environment `pki-root` job did not naturally touch the founders' personal envs, so the gates served as a "both founders' envs still intact" side check.

In the new shape:
- Job A verifies `pki-<partner>` before generating keys there.
- Job B verifies `pki-root` before touching the Root CA, and entering `pki-root` already requires both founders to approve.
- The 2-of-2 property comes from `pki-root`'s required reviewers, not from separate gate jobs.

The same simplification applies to `pki-init.yml` and is included in the same refactor.

## Helper changes (`tools/pki.sh`)

Split `create_issuing_ca` into:

- `build_issuing_ca_csr <key> <csr> <partner>` — run in partner's env, only needs the new key.
- `sign_issuing_ca_csr <csr> <root_key> <root_cert> <out_cert> <days>` — run in `pki-root`, only needs Root CA.

`create_issuing_ca` stays as a thin wrapper for ad-hoc use; workflows don't call it.

## Cleanup after merge

- For future non-founder partners, do not add `PKI_PASSWORD_<PARTNER>` to `pki-root`. The partner passphrase is only consumed via `PKI_PASSWORD` in `pki-<partner>`, set by `setup-issuer-env.sh`.
- `PKI_PASSWORD_FELIXBOEHM` and `PKI_PASSWORD_NANTERO1` in `pki-root` stay — they unlock the nested Root CA key in Job B and other `pki-root` ceremonies.

## Out of scope

- `pki-issue`, `pki-renew`, `pki-revoke` already run in a single env and do not need this split.
- `pki-rotate`, `pki-export` are `pki-root`-only. Gates could be dropped there too. Tracked separately.
