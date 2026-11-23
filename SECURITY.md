# Security Policy

zifiri claims that no one can tell who wrote what, and that deletion is real. If either claim is
false, that is a security bug — the highest severity class we have.

## Reporting a vulnerability

Email **<security@example.invalid>**. Encrypt with our PGP key:

- Fingerprint: `0000 0000 0000 0000 0000  0000 0000 0000 0000`
- Key: not published yet. Ask in your first message and the armored key comes back in the reply.

If you cannot use PGP, send a short plain-text note saying only that you have a report; we will reply
with a key and move the details there. Do not open a public issue, do not post to a mirror, and do not
test against any instance you do not operate yourself.

A useful report contains: the commit you tested, a reproducer, what the design promises, what actually
happened, and how you found it. A PoC that works against `main` is worth more than a description.

## Disclosure timeline

- Acknowledgement: **72 hours**.
- Initial assessment, including whether we accept it: **7 days**.
- Fix target: **90 days** from the report. You may publish on day 90 whether or not a fix has shipped.
  If we ship earlier we will agree a date with you rather than publish first.
- Credit is opt-in. Anonymity is the product's default, so we assume you want none unless you say so.

We will not ask you to sign anything, will not require an identity, and will not name you in a
changelog or advisory without your consent.

## In scope

- **Cryptography.** Key derivation, ownership tokens and their derivation from the seed, batch
  publishing, chat session keys and their scope, replay protection, signature coverage, export/import
  of "Yok ol".
- **Log and metadata leakage.** Anything that writes a request, IP, timestamp, user agent, or a
  correlation handle to disk, stdout, a crash dump, swap, or a core file where the design says nothing
  is kept. `docker logs`, nginx access logs, BEAM crash dumps, and the client's own storage all count.
- **Deletion guarantees.** Content that outlives its deletion window in the database, in the SQLite
  WAL, in a backup, or in client storage.
- **Anonymity-set breakage.** A path that lets a passive observer link a post to its author without
  filling the batch pool (plan §4.2, §14).
- **Client-side seed theft.** Stored XSS, CSP bypass, a supply-chain substitution, or any third-party
  request the browser makes on our behalf.

## Out of scope

- Denial of service, volumetric or load-based, including attacks that starve or flood the batch pool.
- Physical access, seized hardware, cold-boot and live memory acquisition while traffic is flowing
  (threat model, plan §2).
- Compromise of the operator's host, container runtime, reverse proxy, or Tor daemon.
- Third-party platforms we do not run: Telegram, mirrors, forks, and any deployment that does not use
  this repository's defaults.
- Missing hardening on a deployment that ignored `infra/`.

## What we do with a report

We reproduce it, write a failing test, fix it, and keep the test. If the fix changes a promise in
`docs/plan.md`, the plan changes in the same commit — the document does not get to disagree with the
code.
