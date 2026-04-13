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
#
# 2-of-2 note: each founder env is listed with ONLY that founder as
# reviewer. That is deliberate — GitHub Environment "required reviewers"
# only requires ONE of N listed reviewers to approve. To force both
# founders to each approve independently, the workflows use two gate jobs
# (gate-felixboehm + gate-nantero1), each running in a single-reviewer
# environment. Listing both founders on either gate env would silently
# downgrade 2-of-2 to 1-of-N.

# ── pki-felixboehm (also serves as gate-felixboehm for 2-of-2 ceremonies) ──

export EXPECTED_PKI_FELIXBOEHM_REVIEWERS="felixboehm"
export EXPECTED_PKI_FELIXBOEHM_PREVENT_SELF_REVIEW="false"
export EXPECTED_PKI_FELIXBOEHM_CAN_ADMINS_BYPASS="false"
# Production: identical to test — single reviewer is the point.
# prevent_self_review stays false so felixboehm can approve their own gate
# and their own pki-issue / pki-renew operations.

# ── pki-nantero1 (also serves as gate-nantero1 for 2-of-2 ceremonies) ───────
#
# Current test config: felixboehm is listed as reviewer so a solo
# developer can drive end-to-end tests without a second human.
# Production MUST set the actual env reviewer to Nantero1 only and flip
# this EXPECTED value to match. That is what makes the 2-of-2 real.

export EXPECTED_PKI_NANTERO1_REVIEWERS="felixboehm"
export EXPECTED_PKI_NANTERO1_PREVENT_SELF_REVIEW="false"
export EXPECTED_PKI_NANTERO1_CAN_ADMINS_BYPASS="false"
# Production:
# export EXPECTED_PKI_NANTERO1_REVIEWERS="Nantero1"

# ── pki-root (main ceremony env, entered after both gates have cleared) ─────
#
# 2-of-2 is enforced by the gate-felixboehm + gate-nantero1 jobs. pki-root's
# own required-reviewer rule is a redundant secondary gate — either founder
# approves. CAN_ADMINS_BYPASS=false is the property that actually matters
# here (admins can't silently skip past the gates or this env).

export EXPECTED_PKI_ROOT_REVIEWERS="felixboehm"
export EXPECTED_PKI_ROOT_PREVENT_SELF_REVIEW="false"
export EXPECTED_PKI_ROOT_CAN_ADMINS_BYPASS="false"
# Production:
# export EXPECTED_PKI_ROOT_REVIEWERS="felixboehm,Nantero1"
