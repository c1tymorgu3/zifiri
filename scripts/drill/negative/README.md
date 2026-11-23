# Negative control — why this file exists

`plant.sh` is the most important script in this directory. The reason is one
sentence:

> A green scan proves nothing. A scanner that cannot show red when it should,
> saying "clean", is an untested claim.

## The problem

When `canary_scan.sh` returns zero hits, two different worlds look the same:

1. There really is no leak. That is what we want.
2. The scanner is broken: wrong root, wrong pattern, nothing at all instead of
   `grep`, a permission error, an empty `find` list, the WAL file not read,
   no `/proc`.

In the second case the output is still "RESULT: GREEN". And that is the drill's
most expensive mistake: false confidence is worse than no confidence — because
the report gets written, the claim is marked "verified" in `docs/verify.md`, and
nobody looks again.

## The solution

Produce a controlled leak, and see that the scanner finds it. If it does not, the
scanner is blind, so no green result taken on that machine is evidence.

`plant.sh` deliberately writes the canary into **three separate transport paths**
and requires all three to be found:

| # | plant | path | why this one |
|---|---|---|---|
| A | plain text | `var/log/nginx/access.log` | the most common leak: the access record |
| B | JSON log | `var/lib/docker/containers/…/…-json.log` | the docker json-file driver; the IP inside an escaped `\n` |
| C | environment variable | `/proc/<pid>/environ` | never written to disk; it lives only in the process environment |

C matters especially: an application can put the `X-Forwarded-For` value into an
environment variable and forget it there. That is invisible to a file scan; if
`/proc` is not scanned, the leak stays silently green.

On top of that there is a **false positive** check: `172.31.77.70` is written
into an innocent file (the canary is `172.31.77.7`). If the pattern does no
boundary check, it is caught here; if it is not caught, the scanner turns red on
every `172.31.77.7x` address and becomes unusable from the noise.

## Usage

```bash
./negative/plant.sh          # run the control, clean up the plants
./negative/plant.sh -v       # run the scanner verbosely too
./negative/plant.sh --keep   # leave the plants, inspect by hand
```

Output:

```
  [PASS] no false positive: the innocent file (172.31.77.70) produced no hit
  [PASS] the scanner came back red (exit 1)
  [PASS] A plain text (access.log)    found (ip-plain)
  [PASS] B JSON log (docker)          found (ip-plain)
  [PASS] C environment (/proc/PID/environ)  found (ip-plain)

RESULT: CONTROL PASSED — the scanner found all three plants and missed the innocent file.
```

## Exit codes

| code | meaning | what to do |
|---|---|---|
| `0` | control passed | the `canary_scan.sh` result on this machine can count as evidence |
| `1` | control failed, the scanner is blind | look at `scan.log`; report no green result until the scanner is fixed |
| `2` | the control could not run | environment missing (no bash/grep, the directory cannot be created) |

## No Docker needed

The whole control runs on the host: writing files, a `sleep` process, `grep`.
Docker only imitates *the shape of the plant* (the json-file format); it does not
need a running docker. So it can run on a development machine too — and it
should: after every change that touches the scanner.

`run-all.sh` runs this control as the first step and, if it fails, treats the
result of the remaining steps as void.

## What it does not prove

- **It does not prove the inside of the container.** The plants are written to
  the host file system. The layer `docker diff` sees and the directory this
  control sees are not the same thing; for an in-container leak you need
  `write_allowlist.sh`.
- **It does not prove journald.** The plants are not written to the journal; the
  journald leg is reported separately inside `canary_scan.sh`
  (`journald: SKIPPED`).
- **It does not prove the memory leg.** That is `memdump_scan.sh`'s job; the same
  reasoning applies there (if there is no canary in the dump, maybe no dump was
  taken).
- **It does not prove the network leg.** §4.2's `n` measurement is a separate
  piece of work.

The only thing the control proves is narrow but critical: *this scanner, on this
machine, sees a deliberately planted canary on all three transport paths.*
