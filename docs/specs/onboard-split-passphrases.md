# Spec: Split founder and issuing passphrases in pki-onboard

**Status:** accepted (implemented, with a follow-up correction — see ["Gates correction" below](#gates-correction))
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

## Gates correction

The original version of this spec claimed the separate `gate-felixboehm` and `gate-nantero1` jobs could be dropped because `pki-root`'s required reviewers would enforce 2-of-2. **That claim is wrong.** GitHub Environment required-reviewer rules only require **one** of the listed reviewers to approve; they do not enforce N-of-N. Listing both founders on `pki-root` alone allows either founder to approve a Root CA operation single-handedly.

True 2-of-2 requires two distinct gate environments, each with **exactly one unique required reviewer**:

- `pki-felixboehm` reviewed only by `felixboehm`
- `pki-nantero1` reviewed only by `Nantero1`

A `gate-felixboehm` job runs in the first env, `gate-nantero1` runs in the second, and the main `pki-root` job sets `needs: [gate-felixboehm, gate-nantero1]`. Both founders must each approve their own gate before the Root CA is touched. This is the same pattern already used by `pki-rotate`, `pki-export`, and the issuing-CA branch of `pki-revoke`.

This correction was applied in a follow-up PR:
- Gates restored on `pki-init` and `pki-onboard` (Job B depends on both gates).
- `pki-config.sh` updated so each founder env lists only its own founder as reviewer.
- The three-job passphrase-separation split (the substance of this spec) is unchanged — the partner's Issuing CA private key still stays in `pki-<partner>`.

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
