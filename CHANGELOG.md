# Changelog

This repository receives periodic exports from a private working
repository (see "About this repository" in the README). Each entry here is
one export; `.public-sync/state` holds the exact source revision.

## Export 3 — 2026-11-28

No code changes since export 2. All three source servers are now
migrated; documentation updated accordingly:

- `PITFALLS.md`: new section "Migrating Maildir from a live server" —
  watchdogs restarting a "stopped" source, stale snapshots, copy unit
  vs. delta cost, empty folders after an interrupted wiping pass,
  truncated files invisible to name-based comparison, keeping
  `dovecot-uidlist`, stdin and pipe-status traps in copy loops,
  pre-existing broken sieve scripts, `sieve-test` running `execute`.
- `TODO.md`: `health` does not count `redirect` in included sieve
  scripts.

## Export 2 — 2026-11-27

- `mailctl config <group> <service>` passes every known variable to the
  one-shot container, with the same defaults as the Compose template.
  It used to pass a hand-maintained list per service, which had drifted
  from the entrypoints: `config <group> dovecot` failed on variables
  added later.

## Export 1 — 2026-11-27

First public export. The stack as it runs in production for several
groups:

- Postfix 3.10 with postscreen, submission, `anvil` limits, policies in
  SQL (recipient-domain blocking, time-limited abuse blocks, aliases),
  backup MX for any group;
- Dovecot 2.4 (IMAP, POP3, ManageSieve, LMTP), login by short name or
  email, ARGON2ID for new passwords, compatibility with migrated hashes;
- OpenDKIM (keys generated automatically), OpenDMARC, ClamAV and
  SpamAssassin as milters, per-user Bayes learning from IMAP moves;
- Postgrey, Roundcube 1.7 with password change, ManageSieve,
  mark-as-junk and per-user SpamAssassin preferences;
- Let's Encrypt via HTTP-01 or DNS-01 (Cloudflare, CNAME delegation);
- `mailctl`: validation, generation of per-group Compose fragments,
  health checks, user/domain/alias/policy/block management, DNS records.

Removed from the export: a site-specific integration (daily report
forwarding via `vnd.dovecot.execute`), migration tooling for the original
servers, and a DNS check script for specific domains.
