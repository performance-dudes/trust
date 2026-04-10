#!/usr/bin/env bash
#
# Sync encrypted keys from a workflow run into GitHub Environment Secrets
# and the trust-keys private repo.
#
# Run this locally after pki-init, pki-onboard, or pki-rotate completes.
# The workflow uploads an 'encrypted-keys' artifact containing the new
# encrypted private keys. This script:
#   1. Downloads the artifact from the specified workflow run
#   2. Sets each encrypted key as a Base64 GitHub Environment Secret
#   3. Commits the encrypted keys to the trust-keys repo (opens a PR)
#   4. Wipes the local copies
#
# Usage:
#   ./scripts/sync-keys-from-workflow.sh <run-id>
#
# Requires:
#   - gh CLI authenticated with access to both trust and trust-keys repos
#   - The trust-keys repo cloned as a sibling directory (../trust-keys)
#     or set TRUST_KEYS_PATH env var

set -euo pipefail

TRUST_REPO="${TRUST_REPO:-performance-dudes/trust}"
TRUST_KEYS_REPO="${TRUST_KEYS_REPO:-performance-dudes/trust-keys}"
TRUST_KEYS_PATH="${TRUST_KEYS_PATH:-../trust-keys}"

usage() {
  cat <<EOF
Usage: $0 <run-id>

Download the 'encrypted-keys' artifact from a workflow run, set the
encrypted keys as GitHub Environment Secrets, and commit them to the
trust-keys repo.

Examples:
  $0 24236651531

Environment variables:
  TRUST_REPO        (default: $TRUST_REPO)
  TRUST_KEYS_REPO   (default: $TRUST_KEYS_REPO)
  TRUST_KEYS_PATH   (default: $TRUST_KEYS_PATH)

Required: gh CLI authenticated. trust-keys repo cloned locally.
EOF
  exit 1
}

RUN_ID="${1:-}"
[ -z "$RUN_ID" ] && usage

# Sanity checks
if ! gh auth status >/dev/null 2>&1; then
  echo "Error: gh CLI not authenticated. Run 'gh auth login' first." >&2
  exit 1
fi

if [ ! -d "$TRUST_KEYS_PATH/.git" ]; then
  echo "Error: trust-keys repo not found at $TRUST_KEYS_PATH" >&2
  echo "Clone it first: git clone git@github.com:${TRUST_KEYS_REPO}.git $TRUST_KEYS_PATH" >&2
  exit 1
fi

echo "=== Sync encrypted keys from workflow run $RUN_ID ==="
echo "Trust repo:      $TRUST_REPO"
echo "Trust-keys path: $TRUST_KEYS_PATH"
echo ""

# Create working directory
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# Download the artifact
echo "Downloading artifact 'encrypted-keys' from run $RUN_ID..."
gh run download "$RUN_ID" \
  --repo "$TRUST_REPO" \
  --name encrypted-keys \
  --dir "$WORKDIR"

# List what was downloaded
BLOBS=("$WORKDIR"/*.enc)
if [ ! -f "${BLOBS[0]}" ]; then
  echo "Error: no .enc files found in downloaded artifact" >&2
  exit 1
fi

echo ""
echo "Found encrypted blobs:"
for blob in "${BLOBS[@]}"; do
  echo "  $(basename "$blob")"
done
echo ""

# Map each blob to its target environment + secret name
# Naming convention from the workflows:
#   root-ca-key.nested.enc   → pki-root / ROOT_CA_KEY_NESTED_B64 (nested 2-of-2)
#   <slug>-issuing-key.enc   → pki-<slug> / ISSUING_KEY_ENC_B64

set_secret_for_blob() {
  local blob="$1"
  local filename secret_name env_name
  filename="$(basename "$blob")"

  case "$filename" in
    root-ca-key.nested.enc)
      secret_name="ROOT_CA_KEY_NESTED_B64"
      env_name="pki-root"
      ;;
    *-issuing-key.enc)
      local slug
      slug="${filename%-issuing-key.enc}"
      secret_name="ISSUING_KEY_ENC_B64"
      env_name="pki-${slug}"
      ;;
    *)
      echo "  WARN: unknown blob filename: $filename (skipping)" >&2
      return
      ;;
  esac

  echo "Setting ${env_name} / ${secret_name}..."
  base64 < "$blob" | gh secret set "$secret_name" \
    --env "$env_name" \
    --repo "$TRUST_REPO"
  echo "  ✓ ${env_name} / ${secret_name}"
}

echo "Setting GitHub Environment Secrets..."
for blob in "${BLOBS[@]}"; do
  set_secret_for_blob "$blob"
done
echo ""

# Copy blobs to trust-keys repo structure
echo "Copying blobs to ${TRUST_KEYS_PATH}..."
mkdir -p "${TRUST_KEYS_PATH}/pki/root" "${TRUST_KEYS_PATH}/pki/issuers"

for blob in "${BLOBS[@]}"; do
  filename="$(basename "$blob")"
  case "$filename" in
    root-ca-key.nested.enc)
      cp "$blob" "${TRUST_KEYS_PATH}/pki/root/ca-key.root.nested.enc"
      echo "  ✓ pki/root/ca-key.root.nested.enc"
      ;;
    *-issuing-key.enc)
      slug="${filename%-issuing-key.enc}"
      mkdir -p "${TRUST_KEYS_PATH}/pki/issuers/${slug}"
      cp "$blob" "${TRUST_KEYS_PATH}/pki/issuers/${slug}/issuing-key.enc"
      echo "  ✓ pki/issuers/${slug}/issuing-key.enc"
      ;;
  esac
done
echo ""

# Commit and open PR in trust-keys
cd "$TRUST_KEYS_PATH"
BRANCH="sync/run-${RUN_ID}-$(date +%Y%m%d-%H%M%S)"
git checkout -b "$BRANCH"
git add pki/

if git diff --staged --quiet; then
  echo "No changes to commit in trust-keys (keys are already up to date)."
  cd - >/dev/null
  git checkout - 2>/dev/null || true
else
  git commit -m "sync: encrypted keys from ${TRUST_REPO} run ${RUN_ID}

Auto-synced via scripts/sync-keys-from-workflow.sh from workflow run
${RUN_ID}. These encrypted blobs are also stored as GitHub Environment
Secrets in ${TRUST_REPO} for runtime use by the PKI workflows."

  git push -u origin "$BRANCH"
  gh pr create \
    --title "sync: encrypted keys from run ${RUN_ID}" \
    --body "Automatic sync of encrypted PKI keys from a workflow run in ${TRUST_REPO}.

Review and merge to keep the audit trail up to date. The keys are already live as GitHub Environment Secrets — this repo is the versioned backup."
  cd - >/dev/null
fi

echo ""
echo "=== Sync complete ==="
echo ""
echo "Next: review and merge the PR in ${TRUST_KEYS_REPO}."
