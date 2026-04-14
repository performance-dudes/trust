#!/usr/bin/env bash
# Partners are identified by their GitHub username.
# This is the single source of truth for who holds an Issuing CA.
#
# Used by:
#   - pki-init.yml (creates one Issuing CA per partner)
#   - setup-environments.sh (creates pki-<username> environments)
#
# To add or remove partners, edit this file via PR (protected by CODEOWNERS).

PARTNERS=("felixboehm" "nantero1")
# test comment added by Claude for branch-protection test on 2026-04-14T17:24:10Z
