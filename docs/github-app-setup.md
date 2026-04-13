# GitHub App Setup: PKI Guard

## Why this app exists

Every 2-of-2 PKI workflow needs to verify that the GitHub Environment protection rules are correctly configured BEFORE doing any cryptographic work. This prevents an attack where a repo admin silently removes reviewers from an environment and then runs a protected workflow alone.

The verification step reads the environment config via GitHub's REST API:

```
GET /repos/performance-dudes/trust/environments/pki-felixboehm
→ { protection_rules: [{ reviewers: [...], prevent_self_review: true }], can_admins_bypass: false }
```

The default `GITHUB_TOKEN` that GitHub Actions provides to workflows does NOT have permission to read environment configuration (`Administration: Read` is required). A GitHub App solves this.

## What the app does

ONE thing: provides a short-lived token with `Administration: Read` permission so workflows can verify environment protection rules.

It does NOT:
- Modify environments
- Approve or reject deployments
- Modify repository settings
- Access code, issues, PRs, or any other resource
- Run a server or receive webhooks

## Setup (one-time, ~10 minutes)

### 1. Register the App

Go to: https://github.com/organizations/performance-dudes/settings/apps/new

Fill in:
- **Name:** `Performance Dudes PKI Guard`
- **Description:** `Verifies environment protection rules in PKI workflows`
- **Homepage URL:** `https://github.com/performance-dudes/trust`
- **Webhook:** **Uncheck** "Active" (no webhook needed)
- **Permissions:**
  - Repository permissions → Administration → **Read-only**
  - (leave everything else as "No access")
- **Where can this GitHub App be installed?** → "Only on this account"

Click "Create GitHub App".

### 2. Note the App ID

After creation, you'll see the App's settings page. Copy the **App ID** (a number like `123456`).

### 3. Generate a Private Key

On the same page, scroll to "Private keys" → "Generate a private key".

A `.pem` file downloads. This is the App's identity. Store it securely.

### 4. Install the App on the trust repo

Go to: https://github.com/organizations/performance-dudes/settings/installations

Find "Performance Dudes PKI Guard" → Configure → Select "Only select repositories" → Choose `trust` → Save.

### 5. Store credentials as repo secrets

```bash
# App ID (not sensitive but opaque — store as variable or secret)
gh secret set PKI_GUARD_APP_ID \
  --repo performance-dudes/trust \
  --body "YOUR_APP_ID_HERE"

# Private key (sensitive — must be a secret)
gh secret set PKI_GUARD_PRIVATE_KEY \
  --repo performance-dudes/trust \
  < path/to/downloaded-private-key.pem
```

Both are **repo-level secrets** (not environment-scoped) so all workflows can access them for the verification step.

### 6. Done

The workflows use `actions/create-github-app-token@v1` to generate a short-lived token (1h) from the App's credentials. The token has only `Administration: Read` permission on the trust repo. Each generated token is logged in GitHub's audit trail.

```yaml
# How it's used in workflows (already configured, no action needed):
- uses: actions/create-github-app-token@v1
  id: app-token
  with:
    app-id: ${{ secrets.PKI_GUARD_APP_ID }}
    private-key: ${{ secrets.PKI_GUARD_PRIVATE_KEY }}

- name: Verify environment policy
  env:
    GH_TOKEN: ${{ steps.app-token.outputs.token }}
  run: |
    source .github/pki.sh
    verify_environment_policy pki-felixboehm
```

## Maintenance

- **Private key rotation:** Generate a new key anytime via the App settings. Update the `PKI_GUARD_PRIVATE_KEY` secret. Old key is immediately revoked.
- **No expiration:** The App and its private key do not expire. Only the per-run tokens expire (1h, automatically).
- **Audit:** Each token generation appears in the organization's audit log.
- **Removal:** Uninstall the App from the repo to revoke all access instantly.

## Security properties

- The App has **read-only** access to environment configuration. It cannot modify anything.
- Tokens are short-lived (1h) and scoped to the trust repo only.
- The private key is stored as a GitHub Secret (write-only, not readable via UI/API).
- Even if the private key is compromised, the attacker can only READ environment config — no write access, no code access, no secret access.
