# Production safety invariants

## Protect the running server

- Do not stop, disable, purge or remove database, mail, FTP, SSH, firewall or monitoring services without a separately authorized migration. Preserve their data and configuration, including panel-generated include files. Preserve `/var/www`, application volumes, upload paths, home directories, mail data and certificates. Panel-owned package conffiles can themselves live inside these paths.
- Apache, PHP-FPM, nginx and legacy configurations can still be live upstreams after Coolify takes ports 80/443. Identify the actual listeners and dependency graph; disable only units known to be unused. Preserve their previous running and enabled state for recovery.
- A running container or listening port is not proof of a working application. A 200, existing upload read, or TLS handshake is not an authenticated API, upload write, WebSocket or database consistency test. A user may directly confirm a real workflow; record that as user-reported evidence without unnecessarily requesting their token. Report other untested behavior precisely.
- Respect the user's scope, selected backup, downtime and staging decisions. Config snapshots may contain secrets; a host DB dump is not a backup of a separate container. If a requested operation is unsafe or recovery cannot be established, explain the specific unresolved risk rather than claiming readiness.

## Before changing public traffic

- Record current domains/aliases (IDNs as actual hostnames and ASCII/Punycode where necessary), DNS A and AAAA, certificate SAN/expiry, redirects/status baselines, active and intentionally stopped routes, TCP and UDP listeners, and the owners of the web ports. Discovery is heuristic; DNS timeout does not imply a dead domain. Account for CDN/NAT and check publicly before requesting a certificate.
- Compare the running image/build and live mutable data with the intended source. Do not silently replace divergent code, secrets, bind mounts, writable container layers, uploads or databases. Preserve exact values; never copy tokens into logs, reports, tests or command-line arguments.
- Avoid duplicate workers, scheduled jobs and webhook consumers. A shared lock prevents duplicates only if **every** old and new writer actually takes the same host-visible lock for its full lifetime. A port check releases the socket before spawn and is advisory, subject to races and namespace differences.
- Stage using low-impact checks appropriate to the server and user preferences, or an approved short outage with a real recovery mechanism. A heavyweight VM on the user's workstation is not a universal prerequisite.
- A concurrent Coolify deployment can recreate a proxy or cause transient connection errors. Keep the first result, correlate it with deployment/container state, and retry transient errors a bounded number of times. Do not mask the original failure or allow retries to outlast the rollback deadline.
- The repository's generic cutover helper is **planning-only**; it has no independent production watchdog and refuses mutation. A real server-specific implementation must be reviewed and able to recover after SSH disconnect, shell termination, partial Docker operations and relevant reboot states. Record intended phase transitions and prevent a stale watchdog from reverting a confirmed migration. Explicitly test the failure path where practical and do not promise a fixed downtime. Docker command timeouts do not necessarily cancel the daemon action.

## Certificates and Coolify lifecycle

- Copy or retain certificate material only within the agreed scope; keep private keys private. Map every selected cert to names, chain, actual serving proxy and renewal owner. Certbot symlinks and Docker bind mounts need careful handling: bind a directory whose new generations remain visible, then validate the files actually served after reload/publish.
- Check public ACME routing and DNS before using production issuance. Use the staging ACME service for an appropriate real issuance/renewal exercise, and avoid unnecessary forced production renewal and rate limits. Distinguish a successful timer/no-op from an issued certificate. Account for existing native Coolify HTTP-01/TLS-ALPN resolvers.
- Coolify may restore its saved proxy compose over disk-only edits. Preserve the desired configuration using the supported Coolify UI/API and compare saved content with what is running. Verify the expected mounts, private-origin addresses, published ports, dynamic routes and trusted headers. If proxy recreation changes an ID, renewal must safely revalidate the replacement or clearly refuse and alert; don't equate an old ID with proof of current health.

## Before removing a panel

- `scripts/purge-panel-safe.sh` is planning-only and refuses apply. Inspect the relevant panel's tasks, mail/webmail/FTP, certs, generated vhosts, users and data. Preserve necessary generated configuration even if its pathname contains the old panel's name.
- Simulate the **exact** explicitly selected package set and inspect reverse dependencies, maintained scripts, package-owned conffiles and affected paths. Do not use wildcard purge or autoremove. `apt remove` can still execute maintainer scripts and remove owned files; even `apt purge` can remove an apparently unrelated config or data path. Review the real local package behavior, and stop only confirmed-unused panel control services.
- Check panel-related cron/timers and logrotate after disabling control services. Preserve or remove only jobs shown to be obsolete. Confirm services, real routes, HTTPS, data/config integrity and certificate renewal after removal; report any retained panel files or untested paths.
