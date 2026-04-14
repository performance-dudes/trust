#!/usr/bin/env bash
set -euo pipefail

# Shared PKI helper for GitHub Actions workflows.
# Source this file: source .github/pki.sh
#
# Encryption uses OpenSSL (AES-256-CBC with PBKDF2, 600k iterations).
# OpenSSL is pre-installed on all GitHub runners and macOS/Linux.
# No additional tools need to be installed.

# ── Public URL base for CRL/AIA extensions ──────────────────────────────────
#
# Embedded into every issued certificate so verifiers (Adobe, pyHanko, etc.)
# can fetch the relevant CRL and parent cert directly without out-of-band
# knowledge. Anchored to the public trust repo on the main branch.

PD_TRUST_REPO_URL_BASE="https://raw.githubusercontent.com/performance-dudes/trust/main"

# ── Symmetric encryption (single layer, passphrase mode) ─────────────────────

pki_encrypt() {
  local input="$1" output="$2" passphrase="$3"
  printf '%s' "$passphrase" | openssl enc -aes-256-cbc -salt -pbkdf2 -iter 600000 \
    -pass stdin -in "$input" -out "$output"
}

pki_decrypt() {
  local input="$1" output="$2" passphrase="$3"
  printf '%s' "$passphrase" | openssl enc -d -aes-256-cbc -salt -pbkdf2 -iter 600000 \
    -pass stdin -in "$input" -out "$output"
}

# ── Nested encryption (2-of-2, two layers) ───────────────────────────────────
#
# Convention: outer layer = PARTNERS[0], inner layer = PARTNERS[1].
#   nested blob = encrypt(outer_pw, encrypt(inner_pw, plaintext))
#
# To decrypt: first remove outer, then remove inner.
# To encrypt: first add inner, then add outer.
#
# In multi-phase workflows, each phase has only ONE password:
#   Encrypt: Phase 1 (pki-nantero1) → inner, Phase 2 (pki-felixboehm) → outer
#   Decrypt: Phase 1 (pki-felixboehm) → outer, Phase 2 (pki-nantero1) → inner
#
# For pki-init (bootstrapping), both passwords are available in a single
# gated job. Use nested_encrypt_both to create the nested blob in one step.

nested_encrypt_both() {
  local input="$1" output="$2" inner_pw="$3" outer_pw="$4"
  local intermediate
  intermediate="$(mktemp)"
  pki_encrypt "$input" "$intermediate" "$inner_pw"
  pki_encrypt "$intermediate" "$output" "$outer_pw"
  secure_wipe "$intermediate"
}

nested_decrypt_outer() {
  local input="$1" output="$2" outer_pw="$3"
  pki_decrypt "$input" "$output" "$outer_pw"
}

nested_decrypt_inner() {
  local input="$1" output="$2" inner_pw="$3"
  pki_decrypt "$input" "$output" "$inner_pw"
}

nested_encrypt_inner() {
  local input="$1" output="$2" inner_pw="$3"
  pki_encrypt "$input" "$output" "$inner_pw"
}

nested_encrypt_outer() {
  local input="$1" output="$2" outer_pw="$3"
  pki_encrypt "$input" "$output" "$outer_pw"
}

# ── RSA key generation ───────────────────────────────────────────────────────

generate_rsa_key() {
  local bits="$1" output="$2"
  openssl genpkey -algorithm RSA -pkeyopt "rsa_keygen_bits:${bits}" -out "$output" 2>/dev/null
}

# ── Certificate creation ─────────────────────────────────────────────────────

create_root_ca() {
  local key="$1" cert="$2" days="$3"
  openssl req -new -x509 -key "$key" -out "$cert" -days "$days" \
    -subj "/CN=Performance Dudes Root CA/O=Performance Dudes" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:1" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash" \
    -addext "crlDistributionPoints=URI:${PD_TRUST_REPO_URL_BASE}/pki/crl/root-crl.pem"
}

build_issuing_ca_csr() {
  local ca_key="$1" csr_out="$2" partner_name="$3"
  openssl req -new -key "$ca_key" -out "$csr_out" \
    -subj "/CN=Performance Dudes Issuing CA - ${partner_name}/O=Performance Dudes"
}

sign_issuing_ca_csr() {
  local csr="$1" root_key="$2" root_cert="$3" cert_out="$4" days="$5"
  openssl x509 -req -in "$csr" -CA "$root_cert" -CAkey "$root_key" \
    -set_serial "0x$(openssl rand -hex 16)" \
    -out "$cert_out" -days "$days" \
    -extfile <(printf '%s\n' \
      "basicConstraints=critical,CA:TRUE,pathlen:0" \
      "keyUsage=critical,keyCertSign,cRLSign" \
      "subjectKeyIdentifier=hash" \
      "authorityKeyIdentifier=keyid:always" \
      "crlDistributionPoints=URI:${PD_TRUST_REPO_URL_BASE}/pki/crl/root-crl.pem" \
      "authorityInfoAccess=caIssuers;URI:${PD_TRUST_REPO_URL_BASE}/pki/root/ca-cert.pem")
}

create_issuing_ca() {
  local issuer_key="$1" issuer_cert="$2" ca_key="$3" ca_cert="$4" partner_name="$5" days="$6"
  local csr
  csr="$(mktemp)"
  build_issuing_ca_csr "$ca_key" "$csr" "$partner_name"
  sign_issuing_ca_csr "$csr" "$issuer_key" "$issuer_cert" "$ca_cert" "$days"
  rm -f "$csr"
}

# CRL state files (index.txt and crlnumber) live next to the CRL itself
# under pki/crl/, so revocations accumulate across runs instead of being
# overwritten. Naming convention: <crl_basename>-index.txt and
# <crl_basename>-crlnumber. Public material — CRLs are public anyway.

_crl_state_paths() {
  local crl_out="$1"
  local crl_dir crl_base
  crl_dir="$(dirname "$crl_out")"
  crl_base="$(basename "$crl_out" .pem)"
  echo "${crl_dir}/${crl_base}-index.txt"
  echo "${crl_dir}/${crl_base}-crlnumber"
}

create_empty_crl() {
  local ca_key="$1" ca_cert="$2" crl_out="$3" days="$4"
  local index_file crlnumber_file
  read -r index_file <<< "$(_crl_state_paths "$crl_out" | head -n1)"
  read -r crlnumber_file <<< "$(_crl_state_paths "$crl_out" | tail -n1)"

  mkdir -p "$(dirname "$crl_out")"
  : > "$index_file"
  printf '1000\n' > "$crlnumber_file"

  openssl ca -gencrl -keyfile "$ca_key" -cert "$ca_cert" -out "$crl_out" \
    -crldays "$days" -config <(printf '%s\n' \
      "[ca]" \
      "default_ca = CA_default" \
      "[CA_default]" \
      "database = $index_file" \
      "crlnumber = $crlnumber_file" \
      "default_md = sha256")
}

# Append a revocation to the persistent index, increment crlnumber,
# regenerate the CRL covering all accumulated revocations.
add_to_crl() {
  local ca_key="$1" ca_cert="$2" crl_out="$3" days="$4" serial_hex="$5" subject_dn="$6"
  local index_file crlnumber_file
  read -r index_file <<< "$(_crl_state_paths "$crl_out" | head -n1)"
  read -r crlnumber_file <<< "$(_crl_state_paths "$crl_out" | tail -n1)"

  mkdir -p "$(dirname "$crl_out")"
  [ -f "$index_file" ] || : > "$index_file"
  [ -f "$crlnumber_file" ] || printf '1000\n' > "$crlnumber_file"

  # OpenSSL index.txt revoked-row format (tab-separated):
  #   R<TAB>expiry<TAB>revocation_date<TAB>serial<TAB>filename<TAB>DN
  local now expiry
  now="$(date -u +%y%m%d%H%M%SZ)"
  if expiry="$(date -u -d "+${days} days" +%y%m%d%H%M%SZ 2>/dev/null)"; then :; \
  else expiry="$(date -u -v+"${days}"d +%y%m%d%H%M%SZ)"; fi
  printf 'R\t%s\t%s\t%s\tunknown\t%s\n' \
    "$expiry" "$now" "$serial_hex" "$subject_dn" >> "$index_file"

  local n
  n=$(cat "$crlnumber_file")
  printf '%s\n' "$((n + 1))" > "$crlnumber_file"

  openssl ca -gencrl -keyfile "$ca_key" -cert "$ca_cert" -out "$crl_out" \
    -crldays "$days" -config <(printf '%s\n' \
      "[ca]" \
      "default_ca = CA_default" \
      "[CA_default]" \
      "database = $index_file" \
      "crlnumber = $crlnumber_file" \
      "default_md = sha256")
}

# ── Environment policy verification ──────────────────────────────────────────
#
# Verifies that GitHub Environment protection rules are correctly configured
# BEFORE any cryptographic operation runs. Prevents an admin from silently
# removing reviewers and bypassing 2-of-2.
#
# Requires a GH_TOKEN with Administration:Read permission (GitHub App token).

verify_environment_policy() {
  local env_name="$1"
  local repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"

  if [ ! -f ".github/pki-config.sh" ]; then
    echo "::error::.github/pki-config.sh not found"
    return 1
  fi
  source .github/pki-config.sh

  # Dynamic variable lookup: env_name "pki-felixboehm" → key "PKI_FELIXBOEHM"
  local config_key
  config_key=$(echo "$env_name" | tr '[:lower:]-' '[:upper:]_')

  local expected_reviewers_var="EXPECTED_${config_key}_REVIEWERS"
  local expected_self_review_var="EXPECTED_${config_key}_PREVENT_SELF_REVIEW"
  local expected_admin_bypass_var="EXPECTED_${config_key}_CAN_ADMINS_BYPASS"

  local expected_reviewers="${!expected_reviewers_var:?${expected_reviewers_var} not set in pki-config.sh}"
  local expected_self_review="${!expected_self_review_var:?${expected_self_review_var} not set in pki-config.sh}"
  local expected_admin_bypass="${!expected_admin_bypass_var:?${expected_admin_bypass_var} not set in pki-config.sh}"

  echo "Verifying environment policy for '${env_name}'..."

  local api_response
  if ! api_response=$(gh api "/repos/${repo}/environments/${env_name}" 2>&1); then
    echo "::error::Failed to read environment '${env_name}' config."
    echo "::error::API response: ${api_response}"
    echo "::error::Ensure GH_TOKEN has Administration:Read permission (GitHub App token)."
    return 1
  fi

  local actual_admin_bypass
  actual_admin_bypass=$(echo "$api_response" | jq -r '.can_admins_bypass')
  if [ "$actual_admin_bypass" != "$expected_admin_bypass" ]; then
    echo "::error::${env_name}: can_admins_bypass is '${actual_admin_bypass}', expected '${expected_admin_bypass}'"
    return 1
  fi
  echo "  ✓ can_admins_bypass: ${actual_admin_bypass}"

  local expected_sorted actual_sorted
  expected_sorted=$(echo "$expected_reviewers" | tr ',' '\n' | awk 'NF' | sort -u | paste -sd, -)
  actual_sorted=$(echo "$api_response" | jq -r \
    '[.protection_rules[]? | select(.type == "required_reviewers") | .reviewers[]?.reviewer.login] | sort | unique | join(",")')

  if [ -z "$actual_sorted" ]; then
    echo "::error::${env_name}: NO required reviewers configured."
    echo "::error::Expected: ${expected_sorted}"
    return 1
  fi

  if [ "$actual_sorted" != "$expected_sorted" ]; then
    echo "::error::${env_name}: required reviewers mismatch."
    echo "::error::Expected: ${expected_sorted}"
    echo "::error::Actual:   ${actual_sorted}"
    return 1
  fi
  echo "  ✓ reviewers: ${actual_sorted}"

  local actual_self_review
  actual_self_review=$(echo "$api_response" | jq -r \
    '[.protection_rules[]? | select(.type == "required_reviewers") | .prevent_self_review] | first // false')
  if [ "$actual_self_review" != "$expected_self_review" ]; then
    echo "::error::${env_name}: prevent_self_review is '${actual_self_review}', expected '${expected_self_review}'"
    return 1
  fi
  echo "  ✓ prevent_self_review: ${actual_self_review}"

  echo "✓ ${env_name} policy verified"
}

# ── Secure cleanup ───────────────────────────────────────────────────────────

secure_wipe() {
  local f="$1"
  if command -v shred &>/dev/null; then
    shred -u "$f"
  else
    dd if=/dev/urandom of="$f" bs="$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f")" count=1 2>/dev/null
    rm -f "$f"
  fi
}
