# Security Policy

zifiri claims that no one can tell who wrote what, and that deletion is real. If either
claim is false, that is a security bug — the most serious kind this project has.

## Reporting

Use GitHub's private vulnerability reporting: open the repository's **Security** tab and
choose **Report a vulnerability**. If that form is not available, contact the maintainer
through their [GitHub profile](https://github.com/c1tymorgu3) and ask for a private
channel first.

There is no security email address and no PGP key. Please do not open a public issue,
discussion, or mirror for a security report: a public report tells an attacker what to
look at before a fix exists. Do not test against an instance you do not operate yourself.

A useful report names the commit you tested, gives a reproducer, states what the design
promises (with the section of `docs/spec.md`), states what actually happened, and explains
how you found it. A proof of concept against `main` is worth more than a description.

## Response

Best effort, no bounty, no fixed timeline. We aim to acknowledge a report within a week and
to say whether we accept it shortly after. We will not ask you to sign anything or to
identify yourself, and we will not name you in a changelog or advisory without your
consent — anonymity is the product's default, so we assume you want none.

## In scope

- **Anonymity claims.** Any path that links a post to its author, tells a real envelope
  from a decoy, or narrows the anonymity set below what `docs/spec.md` states.
- **Deletion.** Content that outlives its deletion window in the database, the SQLite WAL,
  a backup, or client storage.
- **Logs and metadata.** Anything that writes a request, address, timestamp, user agent, or
  correlation handle to disk, stdout, a crash dump, or a core file where the design says
  nothing is kept.
- **Client.** Stored XSS, CSP bypass, seed theft, or a third-party request the browser makes
  on the user's behalf.
- **Cryptography.** Key derivation, ownership tokens, session keys, replay protection, and
  signature coverage.

## Out of scope

- Content complaints and moderation decisions; these are not vulnerabilities.
- Hosting providers, network operators, and the deployment an operator runs.
- The operator's own anonymity. The design assumes the operator complies; it does not
  protect the operator from their own mistakes.
- Denial of service, including flooding a bucket.
- Physical access to a device, or memory capture while traffic is flowing.
- Missing hardening on a deployment that ignored `infra/`.

## What happens to a report

We reproduce it, write a failing test, fix it, and keep the test. If the fix changes a
promise in `docs/spec.md`, the document changes in the same commit.
