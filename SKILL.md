---
name: panel-to-coolify
description: Safely migrate live production servers from hosting control panels (FastPanel / FastPanel2, cPanel / WHM, Plesk, ISPmanager) to Coolify with zero-downtime staging, atomic cutover, automatic dead-man's rollback, and strict isolation of databases, mail, FTP, and user data. Use whenever the user asks to migrate a server off FastPanel, cPanel, Plesk, or ISPmanager to Coolify, replace host nginx/apache/php-fpm/forever/pm2 with Coolify/Traefik containers, move panel SSL/ACME certificates, safely remove a hosting panel after migration, or perform a guarded SSH server migration.
---

# Panel-to-Coolify Safe Migration Skill

Migrate a live production server from **FastPanel2**, **cPanel/WHM**, **Plesk**, or **ISPmanager** to **Coolify** using a strict, fail-safe state machine. Designed for direct SSH execution by AI agents with maximum blast-radius isolation and minimal token/SSH overhead.

## Non-Negotiable Safety Invariants

Read [references/safety-invariants.md](references/safety-invariants.md) before touching any live server. Hard rules:

1. **Read-only first**: Never modify files, packages, or services before running `scripts/preflight-inventory.sh` and showing the user the inventory & migration plan.
2. **Snapshot before mutate**: Never install, stop, or edit configs before running `scripts/backup-state.sh` (requires >= 15% and >= 5 GB free disk).
3. **Never touch protected stateful services**: NEVER stop, disable, uninstall, or delete `mysql`, `mariadb`, `postgresql`, `redis`, `exim*`, `postfix`, `dovecot`, `proftpd`, `pure-ftpd`, `sshd`, `ufw`/`nftables`/`iptables`, `/var/www`, `/home/*/public_html`, `/var/vmail`, or `/etc/letsencrypt` unless the user explicitly runs a separate DB/mail migration task.
4. **Shadow/Stage on loopback first**: Bind candidate containers (`nginx`, `apache`, SSR, APIs) to `127.0.0.1:1808x` / `18443`. Never bind `:80` or `:443` until stage verification passes.
5. **Single-instance guard on stateful APIs**: Any app running `@Cron`, webhooks, queues, or mailers MUST be wrapped with `flock` + `scripts/start-guard.js` so old (`forever`/`pm2`/systemd) and new Coolify containers never run simultaneously.
6. **Verify live DNS & local code drift before build**:
   - Only request Let's Encrypt certs for domains whose DNS actually resolves to this server's public IP.
   - Diff running server build (`dist/` / `build/`) and working tree (`git status` / `git diff`) against GitHub `main` before deploying from Git; never silently overwrite hotfixes or rotate `SECRET_KEY`/`JWT_SECRET` without auditing active DB tokens.
7. **Atomic cutover + auto-rollback**: Cut over using `scripts/cutover-and-rollback.sh --dry-run` then `--apply`. Any failed critical HTTPS/API/upload check must trigger automatic rollback to the legacy stack.
8. **Gated panel cleanup**: Only run `scripts/purge-panel-safe.sh` after live traffic verification passes and `grep` confirms zero Coolify/Nginx references to panel directories.
9. **SSH lockout protection**: Never reload firewall rules or alter SSH daemon configs without keeping an active session open and verifying `sshd` on the current port.

## Token & SSH Economy Rules

1. **One SSH call = one batched script**: Pipe bundled scripts via `ssh user@host 'bash -s' < scripts/...` instead of running dozens of small commands.
2. **Never dump full logs or configs**: Use `head`, `tail`, `grep -n`, `diff -rq`, and `--format`.
3. **No interactive tailing or polling loops**: Never run `docker logs -f`, `tail -f`, or `sleep` loops.
4. **Keep migration state in one place**: Store Coolify dynamic configs and migration artifacts under `/data/coolify/` and `/var/backups/coolify-migration-*`.

---

## Execution State Machine

Follow these 5 phases in strict order. Do NOT skip a gate.

```
[1. Preflight (RO)] -> [2. Backup Snapshot] -> [3. Shadow Stage + Verify] -> [4. Atomic Cutover] -> [5. Soak + Gated Purge]
         |                       |                          |                         |
         +-> Abort if dirty/     +-> Abort if disk < 5GB    +-> Fix before cutover    +-> Auto-rollback on failure
             unknown state
```

### Phase 1 — Read-Only Preflight & Inventory

Run `scripts/preflight-inventory.sh` in a single SSH call:

```bash
ssh -i <key> root@<host> 'bash -s' < scripts/preflight-inventory.sh
```

Consult [references/panels-matrix.md](references/panels-matrix.md) for panel-specific paths. From the output, produce a concise migration map:
- Detected panel (`fastpanel2`, `cpanel`, `plesk`, `ispmanager`) and host OS.
- **LIVE DNS** domains vs **DEAD/EXTERNAL DNS** domains (never issue ACME certs for dead DNS).
- Workloads: static/SPA sites, PHP/CMS sites, Node/Python/Go backends (`forever`/`pm2`/systemd), databases, mail, FTP.
- **Code & Secret Audit**: Check if live app dirs have uncommitted changes, hotfixes in `dist/`, or fallback `SECRET_KEY` values, and verify upload/data directories for bind mounts.

Ask the user to confirm the migration plan before making any changes on the server.

### Phase 2 — Mandatory State Snapshot

Run `scripts/backup-state.sh` before any installation or config edit:

```bash
ssh -i <key> root@<host> 'bash -s' < scripts/backup-state.sh
```

Verify it exits `0`, prints the backup directory `/var/backups/coolify-migration-<TS>`, and records `MANIFEST.env`.

### Phase 3 — Shadow Stage & SSL Decoupling (Zero Downtime)

1. **Install/Verify Coolify** without disrupting `:80/:443`. Keep `coolify-proxy` stopped (or on stage ports) while host web server still owns `:80/:443`.
2. **Decouple SSL/ACME from the panel** using [references/coolify-templates.md](references/coolify-templates.md):
   - Copy active certs to `/etc/nginx/ssl-certs/<group>-letsencrypt/`.
   - Create `/etc/nginx/ssl-certs/<group>-acme-challenge/` webroots.
   - Ensure `migration.yml` for Traefik and stage `nginx` point ONLY to `/etc/nginx/ssl-certs/`, never `/usr/local/fastpanel2/`, `/var/cpanel/`, `/usr/local/psa/`, or `/usr/local/mgr5/`.
   - Provision `certbot` auto-renewal + `systemd .path/.service` reloaders.
3. **Stage workloads on loopback (`127.0.0.1:1808x` / `18443`)**:
   - **Static/SPA**: `nginx` stage container with `try_files $uri $uri/ /index.html;` (or proxy to `apache` if `.htaccess` rewrite rules are required).
   - **PHP/CMS**: `apache + php` container mounting exact host docroots and `uploads/`.
   - **Node/Python APIs**: Mount/deploy verified code; wrap entrypoint in `flock -n` + `scripts/start-guard.js`; keep exact `SECRET_KEY`/JWT secret and upload bind mounts; stage on alternate internal port if old process is still live on the prod port.
   - **Webmail / phpMyAdmin** (optional): Deploy hardened `panel-tools` bound to loopback or firewall-restricted port (e.g., `:8888`) with `/run/mysqld:/var/run/mysqld:ro`.
4. **Verify stage before cutover**:

```bash
ssh -i <key> root@<host> 'bash -s -- --domains "example.com,api.example.com" --target 127.0.0.1:18443 --scheme https' < scripts/stage-verify.sh
```

Do NOT proceed to Phase 4 until `stage-verify.sh` passes cleanly.

### Phase 4 — Atomic Cutover with Automatic Rollback

Preview first (`--dry-run`), then apply (`--apply`):

```bash
# 1. Dry-run preview
ssh -i <key> root@<host> 'bash -s -- --dry-run --backup-dir /var/backups/coolify-migration-<TS> --domains "example.com,api.example.com"' < scripts/cutover-and-rollback.sh

# 2. Atomic cutover (auto-rolls back on any probe failure)
ssh -i <key> root@<host> 'bash -s -- --apply --backup-dir /var/backups/coolify-migration-<TS> --domains "example.com,api.example.com" --stop-services "nginx,apache2,php8.2-fpm"' < scripts/cutover-and-rollback.sh
```

Pass `--stop-forever "<uid1,uid2>"` / `--stop-pm2 "<app1,app2>"` and `--start-containers "<api1,api2>"` when cutting over stateful Node/Python APIs so the old process stops right as the guarded container starts.

### Phase 5 — Verification & Gated Panel Removal

1. Re-run `scripts/stage-verify.sh` against live `:443` (`--target 127.0.0.1:443 --write-receipt`), plus verify authenticated API endpoints (using real existing tokens from DB), file uploads (`/uploads/...`), cron jobs, and `panel-tools` (if enabled).
2. Confirm all containers are `Up` (`docker ps -a --format '{{.Names}} | {{.Status}}'`).
3. **Only after explicit user approval**, run `scripts/purge-panel-safe.sh`:

```bash
# Dry-run check first
ssh -i <key> root@<host> 'bash -s -- --panel fastpanel2' < scripts/purge-panel-safe.sh

# Execute gated purge
ssh -i <key> root@<host> 'bash -s -- --panel fastpanel2 --confirm-verified --apply' < scripts/purge-panel-safe.sh
```

The script hard-refuses if `coolify-proxy` does not own `:80/:443`, no recent verification receipt exists, or any Coolify/Nginx file still references panel directories.
