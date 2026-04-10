#!/usr/bin/env bash
#
# PKI Policy Configuration
#
# Expected state of GitHub Environment protection rules. Workflows verify
# actual config matches before any cryptographic operation. Mismatch → fail.
#
# Protected by CODEOWNERS. Changes require a reviewed PR.
#
# Slugs = GitHub usernames (from pki-partners.sh).
# Environment names: pki-<slug>
# Variable pattern: EXPECTED_PKI_<SLUG_UPPER>_*

# ── pki-felixboehm ──────────────────────────────────────────────────────────

export EXPECTED_PKI_FELIXBOEHM_REVIEWERS="felixboehm"
export EXPECTED_PKI_FELIXBOEHM_PREVENT_SELF_REVIEW="false"
export EXPECTED_PKI_FELIXBOEHM_CAN_ADMINS_BYPASS="false"
# Production:
# export EXPECTED_PKI_FELIXBOEHM_REVIEWERS="Nantero1,felixboehm"
# export EXPECTED_PKI_FELIXBOEHM_PREVENT_SELF_REVIEW="true"

# ── pki-nantero1 ────────────────────────────────────────────────────────────

export EXPECTED_PKI_NANTERO1_REVIEWERS="felixboehm"
export EXPECTED_PKI_NANTERO1_PREVENT_SELF_REVIEW="false"
export EXPECTED_PKI_NANTERO1_CAN_ADMINS_BYPASS="false"
# Production:
# export EXPECTED_PKI_NANTERO1_REVIEWERS="Nantero1,felixboehm"
# export EXPECTED_PKI_NANTERO1_PREVENT_SELF_REVIEW="true"

# ── pki-root (bootstrap only) ───────────────────────────────────────────────

export EXPECTED_PKI_ROOT_REVIEWERS="felixboehm"
export EXPECTED_PKI_ROOT_PREVENT_SELF_REVIEW="false"
export EXPECTED_PKI_ROOT_CAN_ADMINS_BYPASS="false"
# Production:
# export EXPECTED_PKI_ROOT_REVIEWERS="Nantero1,felixboehm"
# export EXPECTED_PKI_ROOT_PREVENT_SELF_REVIEW="true"
