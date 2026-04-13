# The Performance Dudes Cooperative

A longer read on how our trust infrastructure works in practice.

## Why this exists

Trust, between people who do business, usually rests on three things: **who you are, what you promised, and whether anyone can prove it later.** For most of history that was a handshake, a witness, and a piece of paper. The digital version has never been as clean.

When a customer receives a signed offer from us, they should be able to answer three questions without picking up the phone:

- **Did a real Performance Dude sign this?**
- **Is that person still authorized to sign on our behalf today?**
- **Has the document been altered since?**

The usual answers are unsatisfying. A scanned signature on a PDF proves nothing — anyone with Photoshop can produce one. A commercial e-signature service (DocuSign, Adobe Sign) answers the questions, but only because the customer is asked to trust *a third company* sitting between us and them. We pay that company per document. They hold the keys. If they change their terms, raise their prices, or disappear, our trust story goes with them.

We wanted a cleaner answer: **the cooperative itself is the trust anchor.** No middleman, no subscription, no external dependency. A customer who verifies our public certificate once can verify every signature from every Dude, forever, with tools they already have.

That's what this repository is: the cryptographic backbone that lets a cooperative of independent partners vouch for each other's signatures — transparently, cheaply, and without asking anyone else's permission.

## How it works

We run our own PKI. Our Root Certificate Authority is cooperatively owned — neither founder alone controls it. Every partner operates an Issuing CA underneath. Every person signing on behalf of a partner has a personal end-entity certificate, issued by their partner's Issuing CA.

When you sign a document:

```
document.pdf
  └─ PKCS#7 signature
       └─ your end-entity cert (Common Name: your GitHub username)
            └─ signed by your partner's Issuing CA
                 └─ signed by the Performance Dudes Root CA
```

The customer's PDF reader (Adobe Acrobat, Foxit, pyHanko, openssl...) can walk this chain and verify every link. Once they trust the Root CA, they trust every signature from every partner. Automatically. Forever.

## The cooperative model encoded as X.509

| Authority level | Who holds it | What it can do |
|---|---|---|
| **Root CA** | The cooperative (2-of-2 founders) | Onboard new partners, rotate, revoke at partner level |
| **Issuing CA** | Each partner individually | Issue / renew / revoke certs for people signing on their behalf |
| **End-entity** | Each signing person | Sign documents, commits, email |

Note the mapping:
- **Cooperative governance** = 2-of-2 Root CA operations. Both founders must approve. No one partner can change the membership of the cooperative unilaterally.
- **Partner autonomy** = 1-of-N Issuing CA operations. A partner issues and manages certs for their own team without asking anyone's permission.
- **Personal signing authority** = end-entity cert. Each person's cert has their GitHub username as the Common Name — the same identity they use everywhere else.

## The signing flow (fast)

```
1. Partner runs: pd sign contract.pdf
2. macOS asks for Touch ID / passphrase
3. PDF is signed locally, filename becomes contract_<username>.pdf
4. PR is opened in the relevant project repo
5. Co-signer (another partner) pulls and runs: pd sign contract_<username>.pdf
6. Filename becomes contract_<username>_<cosigner>.pdf
7. Delivered to customer
```

Elapsed time: under two minutes. No emails bouncing around. No web portal logins. No monthly subscription. No third party involved.

## The verification flow (for customers)

```
1. Customer opens the PDF in Adobe Acrobat Reader or any PDF viewer with signature support
2. They see the signature panel: two signatures, chained to the Performance Dudes Root CA
3. First time: they trust our Root CA certificate (fetched from this public repo once)
4. Every future signed PDF from any partner: instant green checkmark
```

The Root CA certificate is at [pki/root/ca-cert.pem](../pki/root/ca-cert.pem). It is public. Anyone can fetch it. Anyone can verify.

## Adding a partner

Joining the cooperative is a deliberate act — it expands the set of people who can sign in the name of Performance Dudes. Both founders must agree. The process:

1. The partner candidate creates a GitHub account (or provides their existing username)
2. Both founders approve the decision (outside of this repo — trust, conversation, founder agreement)
3. One founder triggers the `pki-onboard` workflow with the partner's GitHub username
4. The workflow requires 2-of-2 environment approval (both founders)
5. A new Issuing CA is generated, signed by the Root CA, and committed to this repo
6. The new partner appears in [`pki-partners.sh`](../.github/pki-partners.sh)
7. The new partner runs the setup locally to get their own end-entity cert
8. They can now sign on behalf of Performance Dudes

All of this is visible in this public repo. Commits, PRs, cert files. The cooperative's trust is auditable from the outside.

## Leaving the cooperative

Partners leave. Engagements end. The cooperative must be able to revoke a partner's authority crisply:

1. Both founders trigger `pki-revoke` with the partner's Issuing CA as the target
2. The Root CA adds the Issuing CA serial to the Revocation List (CRL)
3. Every certificate previously issued by that partner becomes untrusted instantly
4. The partner's Issuing CA is removed from `pki-partners.sh`

Customers verifying old signatures after revocation: the PDFs remain cryptographically valid (the signatures are self-contained), but the CRL shows the revoker cert was withdrawn at a known date. Context matters.

## Transparency as a feature

The `trust` repo is public not by accident but by design. Customers, auditors, future partners, competitors, anyone curious — all can:

- See exactly who signs under Performance Dudes
- Verify the cryptographic chain of any signed document
- Watch new partners join (PRs in this repo)
- See the workflows that govern the trust — every single bit of the governance code
- Fork this repo and set up their own cooperative PKI

There is nothing hidden in the trust model. The only private pieces are:
- **Individual passphrases** that each partner holds (encrypts their Issuing CA key)
- **Personal end-entity private keys** (on each signer's laptop, protected by Touch ID / keychain)
- **The audit trail of encrypted CA keys** (in the [`trust-keys`](https://github.com/performance-dudes/trust-keys) private repo, for disaster recovery)

Everything else is in the open.

## Why this matters for customers

When a Performance Dudes partner signs your offer, you are not trusting any single Dude as an individual. You are trusting:

- A cooperative that has cryptographically pinned its own membership
- A trust root that cannot be silently altered (neither founder alone can change partners, rotate, or revoke)
- A process that is publicly auditable at every level
- Signatures that verify in ten seconds with any off-the-shelf PDF tool

This is what professional signing should feel like. Not a PDF scan. Not another SaaS subscription. Just: cryptographic trust, quickly, cooperatively, transparently.
