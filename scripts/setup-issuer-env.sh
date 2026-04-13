#!/usr/bin/env bash
#
# setup-issuer-env.sh — Per-partner Issuing CA passphrase setup.
#
# Sets PKI_PASSWORD in the pki-<partner> environment. This passphrase
# is used for regular 1-of-N operations (pki-issue, pki-renew, pki-revoke
# end-entity) on the partner's own Issuing CA.
#
# Every partner runs this for themselves — founders AND new partners.
# Use a DIFFERENT passphrase than the Root CA ceremony one (if you're
# a founder and have both).
#
# Usage:
#   ./scripts/setup-issuer-env.sh <your-github-username>
#
# Run YOURSELF — Claude never sees the passphrase (read via `read -rs`).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

[ -f "${REPO_ROOT}/.github/pki-partners.sh" ] || {
  echo "Error: .github/pki-partners.sh not found" >&2; exit 1; }
source "${REPO_ROOT}/.github/pki-partners.sh"

REPO="${PKI_REPO:-performance-dudes/trust}"

PARTNER="${1:-}"
if [ -z "$PARTNER" ]; then
  valid=$(IFS=', '; echo "${PARTNERS[*]}")
  cat <<EOF >&2
Usage: $0 <your-github-username>

Sets PKI_PASSWORD in the pki-<partner> environment. Used by the partner
themselves for regular 1-of-N Issuing CA operations.

Partner usernames must be in .github/pki-partners.sh: ${valid}
EOF
  exit 1
fi

# Validate
valid=false
for slug in "${PARTNERS[@]}"; do
  [ "$slug" = "$PARTNER" ] && valid=true
done
if [ "$valid" != "true" ]; then
  echo "Error: '$PARTNER' is not in pki-partners.sh — ask founders to add you first" >&2
  exit 1
fi

gh auth status >/dev/null 2>&1 || { echo "Error: gh not authenticated" >&2; exit 1; }

echo "=== Issuing CA Passphrase Setup ==="
echo "Repository: $REPO"
echo "Partner:    $PARTNER"
echo ""

# Ensure the environment exists (idempotent)
gh api --method PUT "/repos/${REPO}/environments/pki-${PARTNER}" --silent
echo "✓ pki-${PARTNER} environment exists"
echo ""

echo "Enter the Issuing CA passphrase for $PARTNER."
echo ""
echo "This passphrase protects your Issuing CA private key. It is used"
echo "whenever you issue, renew, or revoke end-entity certificates under"
echo "your branch of the PKI."
echo ""
echo "⚠️  Use a DIFFERENT passphrase than your Root CA ceremony one"
echo "    (if applicable). Store both in your password manager."
echo ""

read -rs -p "Passphrase: " PW
echo ""
read -rs -p "Confirm:    " PW2
echo ""

[ -z "$PW" ] && { echo "Error: empty passphrase" >&2; exit 1; }
[ "$PW" != "$PW2" ] && { echo "Error: passphrases do not match" >&2; PW=""; PW2=""; exit 1; }
PW2=""

printf '%s' "$PW" | gh secret set "PKI_PASSWORD" \
  --env "pki-${PARTNER}" --repo "$REPO"
PW=""
echo "✓ pki-${PARTNER} / PKI_PASSWORD"

echo ""
echo "Done. Founders can now onboard you via:"
echo "  gh workflow run pki-onboard.yml --repo ${REPO} -f partner=${PARTNER}"
