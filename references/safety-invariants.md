# Safety Invariants & Failure Mode Prevention

Every rule below prevents a real production outage observed during live panel-to-Coolify migrations.

## 1. Protected Services & Directories (Never Touch Without Separate Migration)

An AI agent running this skill MUST NEVER stop, disable, uninstall, truncate, or `rm -rf` any of the following:

- **Databases**: `mysql`, `mysqld`, `mariadb`, `postgresql`, `postgresql@*`, `redis`, `redis-server`, `mongodb`, `/var/lib/mysql`, `/var/lib/postgresql`
- **Mail**: `exim`, `exim4`, `postfix`, `dovecot`, `opendkim`, `spamassassin`, `/var/mail`, `/var/vmail`
- **FTP**: `proftpd`, `pure-ftpd`, `vsftpd`
- **Access & Security**: `sshd`, `ssh`, `/root/.ssh`, `/etc/ssh`, `ufw`, `iptables`, `nftables`, `fail2ban`
- **Site & Cert Data**: `/var/www`, `/home/*/public_html`, `/etc/letsencrypt`, `/etc/nginx/ssl-certs`, `/data/coolify`

## 2. Prevent Split-Brain & Duplicate Side Effects (Cron / Email / Webhooks)

If a Node.js, Python, or PHP worker runs scheduled jobs (`@Cron`, `node-cron`, Celery beat, queue consumers):
- Never run the Coolify container and the host process (`forever`, `pm2`, `supervisor`, `systemd`) against the same DB/port simultaneously.
- Wrap container entrypoints with `flock -n /run/coolify-api-locks/<service>.lock` AND `scripts/start-guard.js --port <PORT>`.
- Keep `restart: no` or stop the legacy process **immediately before** starting the container during Phase 4 cutover.

## 3. Prevent Silent Auth / JWT Breakage

- Inspect existing `.env`, `pm2` ecosystem files, `forever` logs, and compose configs **before** building containers.
- If an existing API fell back to a default secret (e.g., `process.env.SECRET_KEY || 'default'`), changing `SECRET_KEY` during migration will invalidate every long-lived client/device JWT stored in the database.
- Keep the effective secret identical during migration; rotate secrets only in a planned post-migration maintenance window.
- Always test authenticated API routes using a real token or login flow before declaring cutover complete.

## 4. Prevent Code Drift Overwrites

Production servers managed via panels often contain emergency hotfixes edited directly on disk or built in `dist/` without being pushed to `main`:
- Run `git status`, `git diff`, and `diff -rq <live-dist> <candidate-dist>` (ignoring `.map`/`.d.ts`) in Phase 1.
- If live runtime code differs from Git, **stop and reconcile** (commit/patch or mount the verified runtime artifact) before switching traffic.

## 5. Prevent Let's Encrypt Rate Limits & Failed Renewals

- Legacy panels accumulate parked, expired, or external-DNS domains.
- Run DNS resolution (`A`/`AAAA`) against every discovered vhost and compare with the server's public IP before configuring `certbot` or Traefik ACME.
- Only request certificates for domains actively resolving to this server.
- Migrate working certs and ACME webroots out of panel directories (`/etc/nginx/ssl-certs/<group>-letsencrypt/`, `<group>-acme-challenge/`) so `certbot` renewal survives panel removal.

## 6. Prevent Bind-Mount & SPA Fallback Regressions

- Static SPAs (React/Vue/Vite/Angular) moved from Apache/Nginx vhosts to container Nginx need `try_files $uri $uri/ /index.html;` — otherwise refreshing `/dashboard` returns `404`.
- If a site relies on `.htaccess` rewrites, proxy through an Apache container (`httpd` + `mod_rewrite`) rather than guessing Nginx rewrites.
- Verify `/uploads/` and runtime `data/` bind-mounts resolve to the **exact same host directory** for both API writes and static HTTP reads.

## 7. SSH Lockout & Rollback Discipline

- Never change SSH port/keys or run `ufw reset` during migration.
- Never reboot the server before confirming `systemctl disable` on legacy `nginx`, `apache2`, `httpd`, `litespeed`, and `php*-fpm` — otherwise a reboot restarts the host web server and breaks Coolify (`:80/:443` conflict).
- Always keep the `/var/backups/coolify-migration-<TS>` snapshot intact for at least 7–14 days after migration.
