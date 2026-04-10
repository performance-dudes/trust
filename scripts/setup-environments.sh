#!/usr/bin/env bash
#
# Set up GitHub Environments for PKI workflows.
#
# Each partner runs this script once, passing their own GitHub username.
# For testing, you can run it once per GitHub username to simulate all
# partners from a single account.
#
# Usage:
#   ./scripts/setup-environments.sh <github-username>
#
# Idempotent: safe to run multiple times. Secrets are write-only —
# GitHub does NOT allow reading them back. Store your password in a
# password manager before setting it here.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source partner definitions
if [ ! -f "${REPO_ROOT}/.github/pki-partners.sh" ]; then
  echo "Error: .github/pki-partners.sh not found" >&2
  exit 1
fi
source "${REPO_ROOT}/.github/pki-partners.sh"

REPO="${PKI_REPO:-performance-dudes/trust}"

usage() {
  local valid_slugs
  valid_slugs=$(IFS=', '; echo "${PARTNERS[*]}")
  cat <<EOF
Usage: $0 <github-username>

Sets up the GitHub Environments (pki-root + one per partner) and stores
your PKI password as write-only environment secrets for use by the PKI
workflows.

Valid GitHub usernames: ${valid_slugs}

Examples:
  $0 ${PARTNERS[0]}

Required: gh CLI authenticated (run 'gh auth status' to check).
Optional: PKI_REPO env var to override the target repo (default: $REPO).
EOF
  exit 1
}

PARTNER="${1:-}"
[ -z "$PARTNER" ] && usage

# Validate GitHub username against pki-partners.sh
valid=false
for slug in "${PARTNERS[@]}"; do
  if [ "$slug" = "$PARTNER" ]; then
    valid=true
    break
  fi
done
if [ "$valid" != "true" ]; then
  valid_slugs=$(IFS=', '; echo "${PARTNERS[*]}")
  echo "Error: unknown GitHub username '${PARTNER}'. Valid usernames: ${valid_slugs}" >&2
  exit 1
fi

# Verify gh CLI is authenticated
if ! gh auth status >/dev/null 2>&1; then
  echo "Error: gh CLI not authenticated. Run 'gh auth login' first." >&2
  exit 1
fi

echo "=== PKI Environment Setup ==="
echo "Repository: $REPO"
echo "Partner:    $PARTNER"
echo ""

# Create environments (PUT is idempotent — creates or updates)
echo "Creating environments..."
# Always create pki-root + all partner environments
for slug in "${PARTNERS[@]}"; do
  gh api --method PUT "/repos/${REPO}/environments/pki-${slug}" --silent
  echo "  ✓ pki-${slug}"
done
gh api --method PUT "/repos/${REPO}/environments/pki-root" --silent
echo "  ✓ pki-root"

# Prompt for password securely (no echo)
echo ""
echo "Enter PKI password for $PARTNER."
echo "This will be stored as a write-only GitHub environment secret."
echo ""
echo "!! IMPORTANT !!"
echo "GitHub does NOT allow reading secrets back. If you forget this"
echo "password, you will need to re-initialize the PKI from scratch."
echo "Store it in your password manager BEFORE continuing."
echo ""

read -rs -p "Password: " PW
echo ""
read -rs -p "Confirm:  " PW2
echo ""

if [ -z "$PW" ]; then
  echo "Error: password cannot be empty" >&2
  exit 1
fi

if [ "$PW" != "$PW2" ]; then
  echo "Error: passwords do not match" >&2
  exit 1
fi

# Set secrets
PARTNER_UPPER=$(echo "$PARTNER" | tr '[:lower:]-' '[:upper:]_')

echo ""
echo "Setting secrets..."

# In pki-root: named secret per partner (for 2-of-2 workflows)
printf '%s' "$PW" | gh secret set "PKI_PASSWORD_${PARTNER_UPPER}" \
  --env pki-root \
  --repo "$REPO"
echo "  ✓ pki-root / PKI_PASSWORD_${PARTNER_UPPER}"

# In pki-felixboehm: generic PKI_PASSWORD (for 1-of-N workflows)
printf '%s' "$PW" | gh secret set "PKI_PASSWORD" \
  --env "pki-${PARTNER}" \
  --repo "$REPO"
echo "  ✓ pki-${PARTNER} / PKI_PASSWORD"

# Clear from memory (best effort)
PW=""
PW2=""

echo ""
echo "=== Setup complete for $PARTNER ==="
echo ""
echo "Note: Required reviewers for environments are NOT set by this script."
echo "For testing, this is fine — the workflow runs without approval."
echo "For production, add all partners as required reviewers:"
echo "  Settings > Environments > pki-root > Required reviewers"
echo ""

# Determine if this is the last partner
remaining=()
for slug in "${PARTNERS[@]}"; do
  if [ "$slug" != "$PARTNER" ]; then
    remaining+=("$slug")
  fi
done

if [ ${#remaining[@]} -gt 0 ]; then
  echo "Next: Other partners should run this script with their GitHub username:"
  for slug in "${remaining[@]}"; do
    echo "      ./scripts/setup-environments.sh ${slug}"
  done
else
  echo "Next: Once all partners are set up, trigger the pki-init workflow:"
  echo "      gh workflow run pki-init.yml --repo $REPO"
  echo ""
  echo "After pki-init completes, download the artifact and run:"
  echo "      ./scripts/sync-keys-from-workflow.sh <run-id>"
  echo "to populate the encrypted-key secrets and the trust-keys repo."
fi
