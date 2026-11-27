# TODO

Open items that are known and not yet done. Ordered roughly by how much
they matter to someone running the stack.

- **Isolation between groups on a shared ipvlan network.** Slaves of one
  Docker ipvlan/macvlan network reach each other inside the driver,
  bypassing the host's nftables. `"mode": "l3s"` and `"isolate": true` in
  `host.json` are accepted but not yet verified.
- **Translated code comments.** Comments are in Ukrainian; an English
  pass over the most important ones (`main.cf`, `dovecot.conf`, the
  Postfix and Dovecot entrypoints) would help.
- **`mailctl sieve <group> <email>`**: list scripts, show the active one,
  check every `fileinto` target against existing folders, show the tail
  of `~/sieve/.active.log`.
- **ARC.** Forwarding keeps the original `From:`; with a strict DMARC
  policy on the sender's side, forwarded mail can still be rejected.
- **`mailctl export` / `import`** of a group for moving it between hosts
  (secrets, DKIM keys, volumes).
- **New domain still needs `reload <group> opendkim`** — the KeyTable is
  built at container start. `mailctl` says so, but it is formally a
  fourth manual step.
- **Retention policies** (expunging old mail per folder) via
  `doveadm expunge`, never `find -delete` on a Maildir.
- **Cloudflare token scope**: document the minimal per-zone token.
