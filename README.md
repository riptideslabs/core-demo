# Riptides core capability demo

**Riptides gives plain TCP sockets a cryptographic identity and mutual TLS with no changes to the application** - no sidecar, no SDK, no certificates in your code. Interception happens in a Linux kernel module, so workloads are not modified, relinked or reconfigured. On top of that, Riptides can inject credentials into outbound requests and enforce policy on the traffic it sees.

This repository demonstrates that on a single Linux machine - a local VM or a
cloud instance, whichever you have - in four short acts, using
five **unmodified upstream containers** — nginx, go-httpbin, redis, redis-cli and curl. They
speak plaintext and hold no keys, certificates or tokens; everything the demo
shows is added underneath them. Each act pauses between steps so you can talk
over it, and prints the evidence for what it claims — packet captures, the
kernel's own connection table, and what the application itself sent.

Expect about fifteen minutes end to end once you have a control plane and a
joined node.


| Act | Shows                                                                                                  | Runs                    |
| --- | ------------------------------------------------------------------------------------------------------ | ----------------------- |
| 1   | **Augmentation** — identity derived from a running process, before any policy exists                   | `make act1`             |
| 2   | **mTLS between internal services** — one HTTP leg, one Redis leg, neither app touched                  | `make act2`             |
| 2b  | **Passthrough** — the app brings its own TLS; riptides authenticates it and steps out of the data path | `make act2-passthrough` |
| 3   | **Secret injection on egress** — a GitHub PAT the workload never holds                                 | `make act3`             |


Policy is authored the way a customer authors it: CRDs applied with
`riptides-cli ctl` against a real control plane. Nothing here uses a
developer-only shortcut, so what you demo is what ships.

## 1. Get a control plane and the CLI

Sign up at **[https://console.riptides.io](https://console.riptides.io)** for a free account. You get a control
plane URL and a trust domain of your own — everything below points at them, and the
demo reads both off the live environment rather than hardcoding them.

**Install** `riptides-cli`**.** The demo drives every policy change through it, so it
is a hard prerequisite and `make check` fails without it:

```bash
# macOS
brew install --cask riptides-cli        # tap: riptides-packages/homebrew-tap

# Linux — .deb, .rpm and tarballs are on the releases page
# https://github.com/riptides-packages/daemon/releases
```

Then authenticate it against your control plane (this opens a browser for OIDC):

```bash
riptides-cli context add --url https://<your-env>.console.riptides.io
riptides-cli context status                 # confirm
```

Docs, including the rest of the getting-started path:
[https://docs.riptides.io](https://docs.riptides.io).

## 2. Get a node, and join it

The demo needs one Linux machine with riptides installed and joined. It **checks**
that and never installs it. Either target works, and both are verified:


| Target                                                     | `DEMO_TARGET`    | Notes                                                         |
| ---------------------------------------------------------- | ---------------- | ------------------------------------------------------------- |
| A local **Lima** VM                                        | `lima` (default) | The demo directory is a shared mount, so nothing is copied.   |
| **Any joined Linux machine** — EC2, bare metal, a VM elsewhere | `ssh`            | The demo is copied to the machine. Verified on Amazon Linux 2023. |


Joining is the documented one-liner, and how the node proves who it is depends on
what you have set up in the console first.

**A join token works anywhere, including EC2.** Create a JoinToken `Verifier`
(the control plane will not accept a token without one) and a `JoinToken`. The
token is single-use: it is deleted the moment a daemon authenticates with it.

- **On Console**: System → Daemons → Authentication Methods → Enable **Join
  Token**. Then Join Tokens → Create Join Token. Workload ID and expiration can
  stay empty.
- **Via Riptides CLI** — pick any secret string for `<token>` and use the same
  value in the installer below:

```bash
riptides-cli ctl apply -f - <<'EOF'
apiVersion: auth.riptides.io/v1alpha1
kind: Verifier
metadata:
  name: jointoken
  namespace: riptides-system
spec:
  joinToken: {}
---
apiVersion: auth.riptides.io/v1alpha1
kind: JoinToken
metadata:
  name: demo
  namespace: riptides-system
spec:
  token: "<token>"
EOF
riptides-cli ctl get verifiers
```

Then join the node:

```bash
curl -fsSL https://docs.riptides.io/install.sh | sudo bash -s -- \
  --controlplane-url https://<your-env>.console.riptides.io \
  --join-token       "<token>"
```

**On EC2 you can instead use instance identity**, which avoids handling a token
at all — the node authenticates with its AWS Instance Identity Document:

```bash
curl -fsSL https://docs.riptides.io/install.sh | sudo bash -s -- \
  --controlplane-url https://<your-env>.console.riptides.io --awsiid
```

That is **not** available out of the box: configure an **AWSIID verifier in the
console first** (Verifiers), or the join is rejected. Such a verifier also
requires `required_metadata` — the control plane enforces it — which is what
scopes *which* instances may join, by account, region and so on. Set that up
before running the installer; otherwise, use the join token above.

Detailed description of how to connect an ec2 node can be also found in our [docs](https://docs.riptides.io/guides/connect-aws-nodes/).

## 3. Point the demo at it

Everything is driven **from your laptop**: policy applies run there with
`riptides-cli`, and anything that has to see the kernel module, the containers or
the wire runs on the target over ssh (the `[vm] $` lines). Lima is reached with
the ssh config it generates itself, so there is one transport for both targets.

For a remote machine, set this in `.env` (see `.env.example`):

```bash
DEMO_TARGET=ssh
SSH_DEST=ec2-user@ec2-1-2-3-4.eu-central-1.compute.amazonaws.com
SSH_KEY=~/.ssh/demo.pem          # if not already in your agent or ssh config
```

Your `.env` — including the GitHub PAT — is **never copied to the target**:
policy templating happens on your laptop, so the token has no reason to leave it.

### What the machine needs

- **required** — `sudo` (passwordless), `curl`, `jq`, `pgrep`, `timeout`, and a
container runtime with compose support. `make check` names anything missing,
with the install line for that distro's package manager.
- **evidence tools** — `tcpdump`, and `ngrep` if it is available. The payload
counts prefer ngrep and fall back to tcpdump, so nothing is lost where ngrep is
not packaged — Amazon Linux 2023 has it in neither its repos nor EPEL.

`make prepare-target` installs what is missing, including the docker compose
plugin (Amazon Linux ships docker without it, and has no nerdctl). It is a
separate command on purpose, because it changes the machine:

```bash
make prepare-target
make check
```

## 4. Run it

```bash
cp .env.example .env    # add a GitHub PAT as GITHUB_PAT — act 3 needs it
make check              # verify both sides, resolve the policy values
make up                 # start the app: five containers, all plaintext

make act1               # augmentation
make act2               # mTLS on both legs
make act2-passthrough   # optional: the app's own TLS, passed through
make act2-plaintext     #   …and back, before act2 means anything again
make act3               # credential injection

make reset              # drop the demo policy, ready to run again
make down               # stop and remove the containers
```

A GitHub PAT with **no scopes at all** is enough: act 3 only calls
`GET /user`, which needs authentication and nothing else.

Each act clears its own policy first, so they are re-runnable in any order and
their opening evidence is always honest. `make check` resolves the two values every manifest needs — the trust domain
(from `/sys/module/riptides/config`) and this daemon's workload ID (from the
control plane, since it differs from the local daemon id). Manifests are
templates; `envsubst` fills them in at apply time, so the PAT is piped straight
to `apply -f -` and never written to disk.

Each act pauses between steps. `DEMO_NOPAUSE=1 make act2` runs straight through.

## The app

Five unmodified upstream containers, all on the host network, all plaintext:

```
        curl :8000                         ┌──────────────┐
  you ──────────────▶ nginx ──HTTP :8080──▶│   httpbin    │   the HTTP leg
                        │                  └──────────────┘
                        │
   redis-cli ──RESP :6379──▶ redis                             the not-HTTP leg

     client (curl) ──HTTPS :443──▶ api.github.com              the egress leg
```

`nginx`, `mccutchen/go-httpbin`, `redis`, `curlimages/curl`, pulled as-is. The
only authored pieces are a short nginx conf and the redis-cli loop, and neither
mentions TLS, certificates or tokens.

## Act 1 — augmentation

*No policy applied yet.* The commands below run on the machine, not on your laptop.

`sudo riptides daemon augment <pid>` prints every label the daemon collected for a
process. Those labels are the entire input to identity — the selectors in acts 2
and 3 match exactly this data. On a live run, the ones that matter are
`process:name=nginx` with `process:binary:path=/usr/sbin/nginx`, and
`process:name=redis-server` with `/usr/local/bin/redis-server`.

Meanwhile `/proc/riptides/connections` already lists both legs - each showing `tls: NONE` and `no spiffe_id` - the kernel traces everything by default, so the flows are visible before you've said anything about them.

The line to land: *nothing was configured to get here.*

## Act 2 — mTLS between two internal services

Applies `policies/02-mtls/`: two `Service` objects and four `WorkloadIdentity`
objects with `connection.tls.mode: MUTUAL` and reciprocal `allowedSPIFFEIDs`.
That is the whole change.

What to show, in order:

1. `tcpdump` **on `lo`, before.** `GET /get HTTP/1.1` on :8080 and
  `*3 $3 set $7 demo:ts` on :6379, in the clear.
2. **Search the wire for the payload itself, before and after.** The demo runs
   the same search both times: it captures every packet on the port and counts
   how many contain the text the application sent - `GET /get` on the HTTP leg,
   `demo:ts` on the Redis leg. Before, most packets contain it. After, none do,
   while the packet count stays the same, so "we found nothing" cannot be
   explained away as "there was no traffic". This is the strongest proof in the
   demo, because it is a count rather than a picture. Measured on a live run:

  |                                      | before  | after       |
  | ------------------------------------ | ------- | ----------- |
  | packets carrying `GET /get` on :8080 | 4 of 20 | **0 of 21** |
  | packets carrying `demo:ts` on :6379  | 2 of 12 | **0 of 73** |

   Exact counts vary per run; the shape does not. Roughly the same number of
   packets, and none of them carry the payload any more — so "no hits" cannot be
   waved away as "no traffic". The app still gets its 200s and OKs.
3. **The same count for** `spiffe://` **on the Redis leg, after.** 4–8 hits. The metadata
  exchange is in the clear ahead of the handshake — identity is asserted openly
   and then proven by the TLS that follows. The payload is what gets protected.
   It has to be the Redis leg: MDX runs once per *connection*, and redis-cli
   opens a new one every iteration. On the HTTP leg, nginx holds its upstream
   open, so a capture usually catches reuse rather than a handshake and finds
   nothing - which looks like a broken demo but is just a keepalive.
4. **The Redis leg specifically.** Redis ships its own TLS support and we did
  not switch it on (`config get tls-port` → `0`). This is a socket-level
   mechanism, not an HTTP proxy.
5. `/proc/riptides/connections`**.** Both legs come back
  `tls: TLS1.2, mtls: TLS1.3` with both SPIFFE IDs populated.
6. **The apps are untouched.** nginx still says `proxy_pass http://…`. No keys,
  no certs, no restarts.
7. **Revocation is a policy edit.** Re-applying redis's identity without
  redis-cli on the inbound allow-list flips `redis OK` to
   `redis FAIL Error: Connection reset by peer` within one reconnect; putting
   redis-cli back on the allow-list recovers Redis.
8. **Identity is the process.** The client container's curl holds no identity for
  :8080 and is reset, while nginx receives a 200 at the same moment.

## Act 2b — passthrough: their TLS, our identity

`make act2-passthrough`, then `make act2-plaintext` to put the leg back.

Answers the standard objection, "we already do our own TLS". Redis is
reconfigured to serve TLS itself on the *same* port 6379 (`--port 0 --tls-port 6379`), so the WorkloadIdentity CRDs and Services are unchanged —
only the application differs, and riptides changes behaviour on its own.

**It is automatic - there is nothing to configure.** Riptides notices that the
application is already starting its own TLS handshake, and that no policy asked
it to look inside the traffic. So it authenticates both ends, proves who they
are, and then steps out of the data path: the application's own encryption is
carried through untouched.

**Certificates are not automatic.** Redis needs `tls-port`, `tls-cert-file` and
`tls-key-file`, and riptides cannot supply them: credential propagation delivers
CONFIG/CREDENTIAL/TOKEN files, and there is no X.509 SVID-to-file path an app
could use as its own server certificate. `app/gen-redis-certs.sh` mints a
throwaway CA and server cert into `app/.certs/` (gitignored), with an IP SAN for
`127.0.0.1` so redis-cli verifies for real instead of using `--insecure`.

What to show:

1. **Before the policy**, `app/redis-probe.py` reports `riptides: not managing
  this connection`. The traffic is encrypted - by the application - and utterly
   anonymous. Nothing can be authorized because nobody knows who either end is.
2. **After**, the same probe prints `negotiated ALPN: riptides/passthrough` along
   with both SPIFFE IDs. The application is asking the kernel directly about its
   own connection, so this is the kernel's own answer rather than something
   inferred from a packet capture.
3. **On the wire**, the count finds `riptides/passthrough` in the ClientHello, in
  the clear. On the plaintext leg it reads just `riptides`.
4. **Revocation still bites.** Dropping redis-cli from the allow-list resets the
  connection within one reconnect, on a flow riptides never decrypted —
   authorization without visibility.

One honest limitation worth saying out loud: `/proc/riptides/connections` shows
`tls: TLS1.2, mtls: TLS1.3` and both SPIFFE IDs here — **identical** to act 2.
The connection table tells you riptides manages the socket and who the peers
are, but not which mode it chose. Only the sockopt distinguishes them.

The two modes are mutually exclusive on port 6379, so `make act2-plaintext` (or
`make reset`, which force-recreates rather than restarts) has to run before act 2
is meaningful again.

## Act 3 — secret injection on egress

Applies `policies/03-inject/` in two steps:

1. the `Service` for `api.github.com:443`, the `Secret`, the `CredentialSource`,
  **and the client's** `WorkloadIdentity`;
2. the `CredentialBinding`.

The order matters. The binding's admission webhook rejects it unless *both* its
`CredentialSource` **and** a `WorkloadIdentity` whose `workloadID` matches
already exist - the second requirement is not in the docs, and the error reads
`WorkloadIdentity.core.riptides.io "demo/client/curl" not found`. The file
numbering encodes the order.

What to show:

1. **The response message changes.** Before: `Requires authentication` — GitHub
  saw no `Authorization` header. After: the caller's user JSON. If the PAT is
   invalid you get `Bad credentials`, which still proves the header arrived; the
   act says so explicitly rather than claiming success.
2. `curl -v`**.** curl's own trace of the request it wrote has no
  `Authorization` line. The header was added after curl handed the bytes to the
   socket — which is why the connection had to be intercepted to be writable.
3. **The container is still clean.** Nothing credential-shaped in `env`.
4. **Rotation.** Re-apply the Secret with a broken value → the next request is
  rejected. Put the real one back → recovered. No restart, no redeploy.

### Why the client mounts a CA bundle, and needs `CURL_CA_BUNDLE`

Interception terminates the client's TLS with a certificate from the driver's own
CA (`CN=TLS intercept CA`). On the host, that is invisible — riptides rewrites the
system trust store in place. A container has its own, so `lib/preflight.sh`
copies the driver's bundle out of
`/sys/module/riptides/certs/ca-certificates.crt` and `compose.yaml` mounts it
over the client's `/etc/ssl/certs/ca-certificates.crt`.

Mounting it is necessary but **not sufficient**: this curl verifies against the
hashed CApath directory (`/etc/ssl/certs/*.0`), whose symlinks still point at the
image's original certs, so it fails with `unable to get local issuer certificate`. `CURL_CA_BUNDLE` forces it to read the bundle file instead. Worth
saying out loud — it is the one part of the demo that touches the workload.

## Diagram

Riptides capability demo — what sits where

What sits where, from the platform's point of view — your laptop drives it,
the node runs it: the control plane and the
CRDs, the daemon and the module on either side of `/dev/riptides`, the five
workloads inside the hooked region, and the one arrow that leaves the node.

The Redis leg is annotated with both modes it can run in — act 2 terminating
mTLS on plaintext RESP, act 2b negotiating `riptides/passthrough` once Redis
serves its own TLS — because that pair is the same policy and the same code
path, differing only in what the application does.

The dashed box at the top right is the part the demo does *not* exercise: the control
plane's CA self-signs here, but it can instead be chained to an external
upstream CA — it generates a CSR for its own signing key, has that CA sign it,
and serves the resulting chain — so Riptides can sit under an existing PKI
rather than being its own root.

Source: `[docs/riptides-demo-architecture.excalidraw](docs/riptides-demo-architecture.excalidraw)`
— open it at excalidraw.com or with the VS Code extension. It is a normal
hand-editable Excalidraw file, not a generated artefact to leave alone.

The `.preview.png` above (and the `.svg` beside it) is a plain-SVG
approximation: accurate geometry and text, none of Excalidraw's hand-drawn
styling, and it does **not** update when you edit the source. Re-export from
Excalidraw if you change the diagram and want the preview to match.

## Layout

```
demo/
├── app/          compose.yaml, the nginx conf, the redis-cli loop
├── policies/
│   ├── 02-mtls/  services and identities for the two internal legs
│   └── 03-inject/service, secret, credential source, client identity, binding
├── lib/          preflight.sh, demo.sh (step runner), vm-*.sh (VM-side helpers)
└── steps/        one script per act, plus up.sh and reset.sh
```

The three `lib/vm-*.sh` helpers run inside the VM so the
sample-while-generating dance has no quoting or timing to get wrong across the
host boundary. `vm-conns.sh` polls, because `/proc/riptides/connections` lists
*live* sockets only and the demo's connections are short-lived. `vm-count.sh`
captures every packet and counts the pattern in the rendered payload, so it can
report hits *out of* total packets — and it says which tool produced the numbers,
because it prefers ngrep and falls back to tcpdump where ngrep is unavailable.
Zero hits out of zero packets is reported as "NO PACKETS SEEN" rather than as a
result, since that means the leg is broken, not that the traffic was encrypted.

Files ending `-deny.yaml` are revocation variants — applied on demand by an act,
never by `apply_dir`.

## Why the redis-cli value goes in on stdin

A workload's identity is derived partly from its **command line**, so a loop that
ran `redis-cli set demo:ts $(date +%s)` looked like a brand new workload on every
iteration and filled the console with one-shot process entries. Measured over 12
invocations: **13 distinct identities**.

Passing the changing value on stdin instead —
`printf 'set demo:ts %s\n' "$(date +%s)" | redis-cli …` — keeps argv
byte-identical and brings that to **2** (one for the `set` client, one for the
`get`), while the round trip stays real: the log still shows a changing epoch
coming back out of Redis.

Worth knowing beyond the demo: any workload that puts variable data in argv —
timestamps, request ids, filenames — looks like a new workload on every
execution. Short-lived, CLI-shaped workloads are where this bites.

## Connection volume

Every connection is a full in-kernel mTLS handshake, a telemetry span, and a row
in the console's connection inventory, so the demo is deliberately frugal:


|                              | connections |
| ---------------------------- | ----------- |
| idle (the redis-cli loop)    | ~0.5/s      |
| one payload capture on :8080 | ~11         |
| one payload capture on :6379 | ~2–4        |
| one `conns` sample           | 1–2         |


Act 2 costs about 60 connections end to end. The
generators used to fire every 0.25s, which made a single capture open 33
connections — measure with `awk '/^Tcp:/ {n++; if (n==2) print $6}' /proc/net/snmp` (that is
`ActiveOpens`; do not add `PassiveOpens`, since loopback increments both for the
same connection). Turn the idle rate down further with `INTERVAL` on the
`redis-cli` service in `app/compose.yaml` — raise `INTERVAL` to keep the console
quiet, lower it for a snappier revocation demo.

## Teardown

```bash
make reset   # delete the demo policy, restart the app cleanly, ready to run again
make down    # also stop the containers; riptides itself is left alone
```

