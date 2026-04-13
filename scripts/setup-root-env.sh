#!/usr/bin/env bash
#
# setup-root-env.sh — Founder-only Root CA ceremony passphrase setup.
#
# Sets PKI_PASSWORD_<FOUNDER> in the pki-root environment. This passphrase
# is used ONLY during 2-of-2 Root CA ceremonies (pki-init, pki-rotate,
# pki-onboard, pki-revoke issuing-ca, pki-export).
#
# Run this separately from setup-issuer-env.sh. Use DIFFERENT passphrases
# for each — the Root ceremony passphrase is rare-use (years), while the
# Issuer passphrase is used regularly. Separating them limits blast radius
# of an accidental leak.
#
# Usage:
#   ./scripts/setup-root-env.sh <your-github-username>
#
# Run YOURSELF — Claude never sees the passphrase (read via `read -rs`).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

[ -f "${REPO_ROOT}/.github/pki-partners.sh" ] || {
  echo "Error: .github/pki-partners.sh not found" >&2; exit 1; }
source "${REPO_ROOT}/.github/pki-partners.sh"

REPO="${PKI_REPO:-performance-dudes/trust}"

FOUNDER="${1:-}"
if [ -z "$FOUNDER" ]; then
  valid=$(IFS=', '; echo "${PARTNERS[*]}")
  cat <<EOF >&2
Usage: $0 <your-github-username>

Sets PKI_PASSWORD_<FOUNDER> in the pki-root environment. Only founders
run this. Partners who are not founders do NOT need to run this script.

Founder usernames must be in .github/pki-partners.sh: ${valid}
EOF
  exit 1
fi

# Validate
valid=false
for slug in "${PARTNERS[@]}"; do
  [ "$slug" = "$FOUNDER" ] && valid=true
done
if [ "$valid" != "true" ]; then
  echo "Error: '$FOUNDER' is not in pki-partners.sh" >&2; exit 1
fi

gh auth status >/dev/null 2>&1 || { echo "Error: gh not authenticated" >&2; exit 1; }

echo "=== Root CA Ceremony Passphrase Setup ==="
echo "Repository: $REPO"
echo "Founder:    $FOUNDER"
echo ""

# Ensure pki-root environment exists (idempotent)
gh api --method PUT "/repos/${REPO}/environments/pki-root" --silent
echo "✓ pki-root environment exists"
echo ""

echo "Enter the Root CA ceremony passphrase for $FOUNDER."
echo ""
echo "⚠️  This passphrase is ONLY used in 2-of-2 ceremonies (init, rotate,"
echo "   onboard, revoke-ca, export). It's meant to be rare-use and very"
echo "   strong. Store it in your password manager."
echo ""

read -rs -p "Passphrase: " PW
echo ""
read -rs -p "Confirm:    " PW2
echo ""

[ -z "$PW" ] && { echo "Error: empty passphrase" >&2; exit 1; }
[ "$PW" != "$PW2" ] && { echo "Error: passphrases do not match" >&2; PW=""; PW2=""; exit 1; }
PW2=""

FOUNDER_UPPER=$(echo "$FOUNDER" | tr '[:lower:]-' '[:upper:]_')
printf '%s' "$PW" | gh secret set "PKI_PASSWORD_${FOUNDER_UPPER}" \
  --env pki-root --repo "$REPO"
PW=""
echo "✓ pki-root / PKI_PASSWORD_${FOUNDER_UPPER}"

echo ""
echo "Done. The other founder must run this script with their own username"
echo "to set their half of the 2-of-2 ceremony passphrases."
