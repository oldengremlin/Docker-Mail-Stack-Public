# Pitfalls

Things that break **silently** or point you in the wrong direction. Most
of them were stepped on for real; several are now caught by `mailctl
check`, `health` or an entrypoint guard, and are listed anyway so you
know why those guards exist.

## Docker and networking

- **The host cannot reach its own ipvlan/macvlan slaves.** Pinging a group
  address from the host fails by design. Test from outside. The same
  applies to names: a host-side tool that resolves `mail.example.org` to
  the group address cannot reach it.
- **`up` does not re-read configs.** Configs are bind-mounted and read at
  container start; Compose sees no change and recreates nothing. Use
  `mailctl reload`.
- **`docker compose up -d` on an existing container is a no-op** even if a
  mounted directory changed. The same is true for the proxy;
  `mailctl proxy reload` runs `nginx -t` and reloads.
- **Restart back-off grows to about a minute.** A container that "fixed
  itself" a minute after your fix was simply restarted on schedule.
- **`network_mode: service:X` forbids `extra_hosts`, `hostname`, `dns`,
  `ports`, `mac_address`** on that container. Put them on the namespace
  owner; `/etc/hosts` is physically shared.
- **`hostname:` is published in Docker's embedded DNS, and the public
  ipvlan network is shared by all groups on the host.** If a container's
  hostname is the group's public FQDN, *other groups* resolve that FQDN to
  the local container, bypassing public DNS. This is harmless when the MX
  already points to the group and fatal during a migration window, when
  the group is up but MX still points to the old server: neighbours
  deliver to the new, not-yet-live group. That is why Postfix's container
  hostname is `<group>-postfix` and `myhostname` is set explicitly.
  `health` compares the public A record of `MAIL_HOSTNAME` with the group
  address.
- **Slaves of one shared ipvlan/macvlan network talk to each other inside
  the driver**, bypassing the host's nftables. Isolation between groups on
  the same network currently relies on Docker, not on your firewall.
- **`INTERNAL_PREFIX` colliding with a real prefix** in your routed
  network makes that prefix unreachable from the containers (the
  connected route wins).
- **Never publish proxy ports without an address.** `80:80` binds
  `0.0.0.0`, i.e. every host address, including ones used by other
  services. `proxy.bind` in `host.json` is mandatory for this reason.

## Shell and entrypoints

- **Backticks in an unquoted heredoc are executed.** A comment with
  `` `postconf` `` inside `cat <<EOF` runs the command and splices its
  output (or nothing) into the generated file. `build.sh` has a guard for
  this.
- **`exec 3<&- 2>/dev/null` without a command redirects the shell itself,
  forever.** Every later error message goes to `/dev/null`, and the
  container dies without a word in its log.
- **A comment inside an `apt-get install a \ b \ c` line is not a
  comment.** Lines are joined before the shell sees `#`, so it swallows
  the rest of the package list *and* the `rm -rf /var/lib/apt/lists/*`.
  The image builds; the package is missing.
- **With `--no-install-recommends`, Debian package splits remove binaries
  silently.** `spamd` is a separate package from `spamassassin`; Postgrey
  needs `libio-multiplex-perl`; `spamc` is separate too. Check for the
  binary or module you actually run, not for the package. `--help` output
  proves nothing: Postgrey prints help before the server starts.
- **Optional parameters break the group.env → compose → entrypoint →
  config chain silently.** A variable missing from the service's
  `environment:` reaches the entrypoint empty, and an empty optional value
  usually means "feature off". Add every new parameter to the template,
  not only to `group.env`.
- **A one-shot `docker run` gets no Compose defaults.** `${VAR:-x}`
  lives in the template; a container started without Compose receives
  an unset variable as empty. Every place that starts containers outside
  Compose (here: `mailctl config`) must carry the defaults itself, and
  must not filter variables through a separate list — a third list that
  has to agree with the template and the entrypoint drifts silently.
- **File permissions inside init directories.** MariaDB runs init scripts
  as the `mysql` user; a `0600` SQL file owned by you is unreadable to it,
  and the failure cascades into unrelated-looking errors elsewhere.

## Postfix

- **Postfix does not complain about unknown parameter names** — it treats
  them as user macros. A typo in a limit disables the limit. The Postfix
  entrypoint compares `postconf -n` against known names and refuses to
  start on unknown ones (with a self-test so the guard cannot go quiet).
- **`smtpd_client_event_limit_exceptions` defaults to `$mynetworks`**, i.e.
  `anvil` limits do not apply exactly where a wide `mynetworks` needs
  them. It is set explicitly here.
- **Rate-limit rejections are `450`**, not `454`. A test that greps for
  the wrong code reads "limit does not work" exactly when it fires.
- **`OK` from the restriction list does not skip the implicit "unknown
  recipient" check** (`smtpd_reject_unlisted_recipient`). It runs after
  the list; but a `450` from greylisting earlier in the list wins first.
- **`postmap -q` on a map with `%d` and a key without `@` returns
  "not found" without running the query** — on a working map and on a
  broken one alike. Probe with a full address and read stderr, not the
  exit code.
- **`250 Ok: queued` is not delivered.** Check by queue ID; `mailctl
  headers <g> <email> <queue-id>` waits for it.
- **Without `inet_protocols` matching your addresses**, Postfix resolves
  AAAA and tries IPv6 it does not have — ~1 s per message to large
  providers. It is derived from `ADDRESSES`.
- **Non-ASCII in values that go into DSNs** (e.g. `error:` transport
  texts) is invalid without SMTPUTF8. Comments may be in any language;
  values must be ASCII.
- **Do not put comments inside multi-line Postfix values.** Whether an
  indented `#` is a comment there is ambiguous; if it is not, `#` becomes
  a restriction.
- **postscreen verdicts are cached for a day.** After a `PASS NEW` the next
  connection is `PASS OLD` and has no delay — measuring the delay then
  measures nothing. A dash in the banner (`220-`) means the test is
  running.
- **A backup MX without recipient verification is a backscatter
  generator**, and an MX name that differs from `myhostname` is a mail
  loop.
- **`postmaster@<domain>` must exist for every local domain.** Postfix's
  own notices go to explicit addresses, so internally everything looks
  fine, while the outside world (abuse reports, DMARC, blocklist delisting)
  writes to `postmaster@` and gets 550. `health` checks it.
- **DMARC aggregate reports to another domain need consent.** With
  `rua=` pointing to a different domain, receivers send nothing until that
  domain publishes `<domain>._report._dmarc.<rua-domain>`. `mailctl dns`
  prints these records.

## Dovecot 2.4

- **Many 2.3 names are gone** and 2.4 refuses them ("Unknown setting"):
  `disable_plaintext_auth` → `auth_allow_cleartext` (inverted),
  `default_pass_scheme` → `default_password_scheme`, `inet_listener
  { address }` → `listen`, flat `imapsieve_mailbox1_*` → `imapsieve_from`
  and `sieve_script` blocks. The packaged `conf.d/*.conf` inside the
  image is the reliable reference.
- **`auth_allow_cleartext = yes` with `ssl = required` is fatal** in 2.4.
  Both are generated from the same parameter here, and the entrypoint
  checks the effective values before starting.
- **Scalar settings: the last one wins.** A static value after
  `!include generated.conf` silently overrides the generated one.
- **`MD5-CRYPT`/`DES-CRYPT` are refused by default**
  (`auth_allow_weak_schemes`), and the failure looks like `temp_fail` /
  internal error — it sends you to the database and network, not to
  password schemes.
- **`doveconf` validates syntax, not plugin semantics.** It accepts any
  string for `cause` in `sieve_script`; the imapsieve plugin knows only
  `APPEND`, `COPY`, `FLAG`, `MOVE`.
- **`cause = copy` also catches MOVE — and deleting from Junk is a MOVE to
  Trash.** A ham-learning script that does not check the destination
  teaches the filter that all the spam you just deleted was legitimate.
  `report-ham.sieve` checks `imap.mailbox`.
- **`~/.dovecot.sieve` under `mail_path = %{home}` shows up as an IMAP
  folder** with separator `.`. The active script lives in `~/sieve/`.
- **`doveadm` without `-c` reads the packaged config**, answering
  confidently and wrongly. The entrypoint copies the effective config to
  the canonical location.
- **A sieve rule that did not match and a rule whose target folder does
  not exist look identical** in the main log (`stored mail into mailbox
  'INBOX'`). The user's `~/sieve/.active.log` tells them apart.
  `sieve-test` simulates a script against a real message without storing
  anything.
- **`sieve_max_redirects` exceeded fails the whole script**, so the
  message goes to nobody, not to "the first four".

## Filtering

- **`milter_default_action = accept` means a dead milter lets mail through
  unchecked and silently.** That is why `health` exists and why `reload`
  waits for ports.
- **`-f` means "fork into background" in `spamass-milter`** (the parent
  exits 0, a supervising entrypoint concludes it died). In `spamc` the
  same flag is "default, ignored".
- **`spamassassin --lint` passes when `spamd` is not installed at all.**
  Lint checks rules, not the daemon.
- **`RCVD_IN_VALIDITY_*_BLOCKED` adds ~3.6 points to every message**: the
  Validity lists are paid and answer "blocked". They are disabled in
  `local.cf`.
- **Per-user Bayes keys can become external addresses** if the milter does
  not treat loopback as internal: sieve redirects re-inject through
  `127.0.0.1:25` and get scanned a second time with the external
  recipient's (empty) preferences.
- **A disallowed setting in Roundcube's `sauserprefs` defaults** silently
  overrides group decisions (`report_safe`, DNSBL). Check against your own
  `local.cf`, not against memory.
- **A plugin copied (not composer-installed) has no default config**: its
  defaults live in `plugins/<name>/config.inc.php`. Missing table/column
  names produce an SQL syntax error that Roundcube reports as "cannot
  connect to the database".
- **Forwarded spam is sent by you.** Forwarding mailboxes must not forward
  `X-Spam-Flag: YES` (decision 37).

## TLS and certificates

- **A generated config with `ssl_certificate` needs a placeholder
  certificate generated with it.** Otherwise nginx cannot start, and the
  HTTP-01 challenge that would produce the real certificate arrives at
  that very nginx.
- **certbot issues ECDSA by default.** Some old clients (old The Bat!,
  Outlook) cannot do ECDSA and report it as "mail stopped working".
  `CERT_KEY_TYPE=rsa`.
- **A browser keeps an accepted exception for the self-signed placeholder**
  until the session ends; open a new tab after the real certificate.

## Database

- **`mysql-init` runs only on the first start of MariaDB.** A new table
  for a running group goes through `_schemas/upgrade/*.sql` and
  `mailctl db-load`.
- **`down --volumes` removes the database too**, not only mail — domains
  and users included. On a test group the next errors (`Relay access
  denied`, `authentication failed`) point nowhere near the cause.
- **`timestamp` columns under `explicit_defaults_for_timestamp=OFF` get
  `ON UPDATE CURRENT_TIMESTAMP`.** Editing a `reason` would reset an
  expiry to "now". Expiry columns are `datetime`.
- **`DBD::MariaDB` encodes on write and decodes on read.** Passing UTF-8
  bytes from `@ARGV` double-encodes them in the column; `mailctl`
  converts at the boundary.

## Method

- **A check without a negative control proves nothing.** A guard that is
  silent looks exactly like a guard with nothing to say. Several guards in
  this repository test themselves on a deliberately bad input first.
- **Grep patterns depend on locale and format.** `grep "Permission
  denied"` on a localized system finds nothing; `grep -F -f list` matches
  substrings (`user1` matches `user10`).
- **Mailbox state is changed by reading, not only by delivery.** A POP3
  client deletes, Dovecot moves `new/` → `cur/` and renames on first
  access. "Is the file where I put it" has a shelf life.
- **"Probably transient" in a diagnostic needs a bound.** A hint like
  "containers are young, wait" without an age limit will explain a real
  failure an hour later.
