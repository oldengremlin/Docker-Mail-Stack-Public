# Design decisions

Comments in the code refer to these by number («рішення №31» —
"decision 31"). The numbering is stable and matches the working
repository; a decision that is only relevant to migrating from the
original servers is kept as a short note so the numbers stay valid.

The yardstick for all of them is the project goal from the
[README](README.md): **three manual operations** (set up a group, add or
remove a user, change a password). A decision that adds a fourth is wrong.

---

### 1. All mail services are built from `debian:trixie-slim`

Postfix, Dovecot, OpenDKIM, OpenDMARC, Postgrey, SpamAssassin and ClamAV
have no official images from their own projects, only community images
with their own layout. Building from Debian gives the same packages and
paths as on a plain Debian host. MariaDB and Roundcube use their official
images.

### 2. trixie, not bookworm

Dovecot 2.4 in trixie has a very different configuration syntax from 2.3
in bookworm. The configuration is rewritten anyway, so there is no reason
to stay on the older release.

### 3. Public network: ipvlan L3

Not macvlan (one MAC per container on the switch port, port security on
someone else's switch), not bridge + NAT (hand-made SNAT/DNAT that is
easy to forget when adding a domain). On dedicated servers the public
block is usually already routed to the host, so L3 needs no ARP for the
whole block, and the traffic stays under the host's nftables control.

### 4. Full isolation between groups

Each group gets the full set of services — Postfix, Dovecot, MariaDB,
Roundcube, SpamAssassin, ClamAV, OpenDKIM, OpenDMARC, Postgrey — from one
parameterized `_template/docker-compose.yml`, stamped as a separate
Compose project (`-p <group>`). Only the images are shared.

### 5. All mail of a group on one set of addresses

SMTP, POP3, IMAP and ManageSieve listen on the same addresses; there is
never a separate address per service. Implemented with
`network_mode: "service:postfix"` for Dovecot: Postfix owns the ipvlan
attachment. A group may have more than one address (see 27), but the set
is shared by all mail services.
**Exception — webmail.** Roundcube lives outside that namespace on the
`internal` bridge and is served by a shared nginx. Inside the namespace it
would also listen on `:80` of the public address, bypassing the proxy.

### 6. Mailboxes are moved as they are; configs are rewritten

Compatibility with old `dovecot.conf`/`main.cf` syntax is not a goal.

### 7. Password hashes are migrated byte for byte

No password resets and no forced re-hashing: Dovecot still supports the
old schemes (`{CRAM-MD5}`, `{PLAIN}`, crypt variants). See also 25.

### 8. Maildir, `/var/mail/<domain>/<localpart>`, `mail_path = %{home}`

The `vmail-data` volume is mounted at `/var/mail`. `home` is computed in a
database view from the email address, and Dovecot takes it ready-made —
`maildir:/var/mail/%d/%n` would break as soon as a login is not an email
address (the domain part is empty). uid/gid of the mailbox owner differ
between installations (`mail` 8:8 on one, a custom 5000:5000 on another),
so they are group parameters (`VMAIL_UID`, `VMAIL_GID`) and are always
used as **numbers**, never as names.

### 9. Services talk TCP, not Unix sockets

There is no shared filesystem between containers.

### 10. OpenDMARC is enabled

Order of milters: OpenDKIM first, then OpenDMARC (DMARC needs the DKIM
result). General principle: do it right rather than reproduce the gaps of
the servers being replaced.

### 11. LMTP and SASL between Postfix and Dovecot on `127.0.0.1`

An agreed exception to "names only": the pair shares one network stack,
so loopback is the exact description. SASL is then not visible to the
rest of the `internal` network, including the proxy guest.

### 12. Submission on 587

STARTTLS + SASL, even where the original servers only had port 25.

### 13. Adaptive SMTP delays are mandatory

`postscreen` (`postscreen_greet_wait`, pregreet test),
`smtpd_error_sleep_time` with error limits, and `anvil` rate limits. No
exceptions based on reverse DNS — it trusts DNS controlled by someone
else.

### 14. Only `PLAIN` and `LOGIN`, under TLS

Every client supports them, and the server compares the received password
against any storage scheme. CRAM-MD5 and DIGEST-MD5 are not advertised:
they are challenge-response and need the cleartext (or a `{CRAM-MD5}`
derivative) on the server — with crypt hashes the server cannot answer the
challenge, and a client that picked the mechanism fails without fallback.
In Dovecot 2.4 the switch is `auth_allow_cleartext` (inverted meaning
compared to the old `disable_plaintext_auth`).
`auth_allow_cleartext` is a **group parameter** (`CLEARTEXT_NETWORKS`): a
small group keeps `no`, an office can allow its LAN, and an ISP-style group
whose subscribers connect from dynamic addresses all over the country may
need the separate word `any`. `any` is a word, not `0.0.0.0/0`: the three
network lists of a group share a format but have opposite meanings, and in
`MYNETWORKS` `0.0.0.0/0` would be an open relay. The price is stated: inside
an allowed network passwords travel in cleartext.

### 15. Login by short login or by full email

The schema keeps both `login` and `email`; `password_query`/`user_query`
accept either. In groups where the login is the address, they coincide.

### 16. New passwords: `ARGON2ID` (fallback `BLF-CRYPT`)

In Dovecot 2.4 the setting is `default_password_scheme` inside
`passdb sql { }`. Postfix is not involved: it passes the password to
Dovecot over SASL.

### 17. No `X-Original-To` via `header_checks`

Postfix already uses that name for the envelope recipient, and sieve
relies on it. Two sources under one name cannot be diagnosed later.

### 18. Postfix policies in SQL, not `hash:` maps

`hash:` needs `postmap` after every change — a manual operation. SQL
takes effect immediately and adds no new dependency (Postfix already reads
domains and mailboxes from the database). Lookups go through `proxy:` to
avoid connection storms.

### 19. Recipient-domain blocking: a table, domain plus subdomains

`recipient_policy (domain, include_subdomains, action, source, comment)`,
checked with `check_recipient_access` at RCPT time.
- `source` separates manual rows from imported lists, so an external list
  (tens of thousands of domains) can be resynced without touching manual
  rows. Import is a sync within one source, not `TRUNCATE`.
- Lookup generates the candidate parent domains from the name and hits the
  primary key; a `LIKE` suffix search would scan the table on every RCPT.
  The tempting "largest key ≤ input" single index scan is **wrong**
  (counterexample: `ua.com` and `ua.com.exam` with input `example.com.ua`).
- Default action is `REJECT` with a text, not `DISCARD`: the check sits
  above `permit_mynetworks`, so it mostly affects our own users' outgoing
  mail, and a silently eaten message cannot be diagnosed. `REJECT` at RCPT
  also means *we* never generate a bounce. `WARN` is not a "soft start":
  it delivers the mail.
- The map is enabled by the entrypoint only after probing it: a dead map
  would mean 451 on every RCPT.

### 20. Wide `mynetworks` is compensated by time-limited blocks

An ISP-style group must let subscribers send without authentication.
Compensation is not narrowing it but `abuse_block (scope, key, action,
reason, expires_at)` — by client IP/prefix or by sender — checked
**above** `permit_mynetworks`. Postfix tries `a.b.c.d`, `a.b.c`, `a.b`,
`a` itself, so `/8`–`/32` octet prefixes need no casts. No `OK`/`PERMIT`
rows ever. There is no "unblock" operation: the row expires.

### 21. On an ISP-style group, enable filtering in stages

First marking only (`X-Spam-*`), greylisting with a wide whitelist, then
tighten based on statistics. DKIM/DMARC are on outgoing mail and do not
affect subscribers.

### 22. Defects found on the old servers are fixed in the new stack

Not on the running servers. *(Migration note.)*

### 23. Groups may live on different hosts — but nothing is built for that

The stack is designed for one host. Nothing may *rely* on a neighbouring
group being on the same host, and nothing is built *for* distribution
until it exists. Consequences: the shared nginx serves only groups of its
own host; `INTERNAL_PREFIX` is kept globally unique anyway (free, and
moving a group becomes a copy). Rule: a decision that saves a resource
shared by two groups is wrong until shown to work when they are on
different machines.

### 24. The public ipvlan network is per host, not per group

Docker refuses a second ipvlan network on the same parent interface. So
`mailctl net up` creates host networks, and groups attach to them as
`external`. Separate networks over the same interface would add no
isolation anyway; separation between groups is done on the host's
nftables.

### 25. On migration every hash gets an explicit `{SCHEME}` prefix

Different servers had different `default_pass_scheme`, so unprefixed rows
meant different things. `$1$…` → `{MD5-CRYPT}`, 13 chars without `$` →
`{DES-CRYPT}`, unprefixed cleartext → `{PLAIN}`. Dovecot 2.4 supports them
but **refuses `MD5-CRYPT` and `DES-CRYPT` unless
`auth_allow_weak_schemes = yes`** (group parameter
`AUTH_ALLOW_WEAK_SCHEMES`). `{DISABLE}` is not a scheme: disabling is a
flag in the table.

### 26. Our own `dovecot.conf`, no `!include conf.d/*.conf`

With the packaged includes, new defaults from a Dovecot update would take
effect silently. A major upgrade is reviewed consciously.

### 27. A group may have a second, private address in an office LAN

Used where clients have an IP (not a name) configured and the address
must keep working. ipvlan L3 cannot do it (no broadcast, no ARP), so the
office network is ipvlan L2 or macvlan on the office interface — a second
host network. The host cannot see these slaves either. Decision 5 is not
weakened: the set of addresses simply has two elements.

### 28. `mailctl` is Perl, not bash

Database commands with parameter binding (DBI) instead of SQL glued
together with shell quoting; `Socket` instead of bit shifts; one env-file
parser. Core modules only, except DBI for the database commands. Env files
are **read, never executed**. External commands are run as lists, without
a shell.

### 29. Networks are described as data

`host.json` lists host networks (`driver`, `mode`, `iface`, `vlan`,
`subnet`, `gateway`); `group.env` has `ADDRESSES=<label>:<address>,...`
and `PRIMARY_NET`. `PRIMARY_NET` is the single source of the outgoing
address (default route via `gw_priority`, and `smtp_bind_address`).
Compose has no loops, so `mailctl` generates `networks.yml` and
`.compose.env` per group — the template does not start with plain
`docker compose`. A native and a tagged network on the same NIC coexist
(for Docker they are different parents).

### 30. `mynetworks` is a group parameter, unrelated to its addresses

Having an address in a network is not trusting it. If trust were derived
from addresses, every new address would silently grant relaying.

### 31. SpamAssassin as a milter, not a `content_filter` pipe

A content filter runs **after** the message is accepted: rejecting is no
longer possible, so you either drop silently or bounce to a (likely
forged) sender — backscatter. A pipe also re-injects through `sendmail`.
Consequences: `report_safe = 0` (a milter edits headers, not the body);
`-i <trusted> -I` so outgoing mail is not scanned with an external
recipient's preferences; `-u`/`-e` so per-user preferences are keyed by
the full address. Loopback is always in `-i`: sieve redirects re-inject
through `127.0.0.1:25`.

### 32. ClamAV as a milter

Same reason as 31. `clamd` per group (≈1 GB RSS each), with
`ConcurrentDatabaseReload no` so a database reload does not double the
peak. Antivirus applies to outgoing mail too: on `submission` the milters
are OpenDKIM and ClamAV, not SpamAssassin or OpenDMARC.

### 33. SpamAssassin state is a separate database with its own user

Otherwise the SpamAssassin container would have access to the mail
database, i.e. to every password hash. The schema is taken from the
packaged SQL files **inside the image**, never written by hand. AWL is not
enabled (deprecated in SpamAssassin 4).

### 34. Learning: Dovecot tells `spamd` via `spamc`

A user moves a message into `Junk` → `imapsieve` → `spamc -L spam`. No
second SpamAssassin installation inside Dovecot, and Dovecot gets no
access to the SpamAssassin database. The price: `spamd` runs with
`--allow-tell` and trusts the username the client sends, so it is
restricted with `--allowed-ips` to loopback and Postfix's internal address
(where Dovecot's traffic comes from — shared netns). `imapsieve` fires on
user IMAP actions, not on delivery, so there is no feedback loop.
The Dovecot 2.4 syntax was taken from the packaged
`conf.d/90-sieve.conf` in the image, not from upstream (pigeonhole's main
branch was still 2.3).

### 35. Roundcube: three database users, and Dovecot listens on `internal`

- `roundcube` (its own database), `rcpasswd` (column-level
  `SELECT (user, domain)` and `UPDATE (passwd)` — it can change a hash
  but not read it), `rcprefs` (SpamAssassin `userpref` only).
- Dovecot also listens on `${INTERNAL_PREFIX}.10`: Roundcube is in a
  different netns and cannot use loopback or the public address. LMTP and
  SASL stay on loopback.
- The image is pinned to the `1.7.x-apache` line, not `latest`.
- `markasjunk_move_spam`/`_move_ham = true` are required: by default the
  plugin only sets a keyword, and learning listens to COPY/MOVE.
- `ROUNDCUBE_DES_KEY` is required: otherwise the image generates a new key
  on every container creation, while sessions survive in the database —
  everyone gets silently logged out on every `up`.

### 36. MariaDB for all groups

One schema, one DBI driver. *(The original servers partly ran PostgreSQL;
converting them was a one-off migration task.)*

### 37. Forwarding mailboxes do not forward spam

A sieve `redirect` leaves from *our* address, so forwarded spam ruins
*our* reputation (large receivers start rejecting the whole domain). The
generated forwarding scripts skip `X-Spam-Flag: YES` (optionally a lower
`X-Spam-Level` threshold). The message is still kept in the mailbox;
nothing is rejected at SMTP time.

### 38. No manual mail routing; DNS decides

No `transport` table. Every hand-made transport on the original servers
turned out to be redundant or harmful (pinned to the second-best MX,
pointing at dead domains, at servers that had moved). What a transport
was sometimes covering for — being a backup MX — is a different mechanism
(39).

### 39. Backup MX is a capability of any group

- One source: `domains.type='RELAY'`.
- Delivery by DNS/MX. Postfix drops itself and every MX of equal or worse
  priority, so the bearing condition is that **the MX name equals the
  group's `myhostname`**, otherwise mail loops.
- Backscatter is prevented with `reject_unverified_recipient`, not a
  shared recipient list (that would need access to another group's
  database or synchronization). Positive results are cached for 31 days,
  so during an outage of the primary, known recipients are still accepted;
  unknown ones get **450**, never 550.
- One SQL map serves both `relay_domains` and `check_recipient_access`;
  the key is `%s`, not `%d`.
- The map is attached by the entrypoint after probing it, because a dead
  `relay_domains` map stops *all* mail of the group.
- The Postfix queue (`/var/spool/postfix`) and `/var/lib/postfix` (the
  verification cache) are volumes: `reload` recreates the container.
