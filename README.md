# Panel-to-Coolify Safe Migration Skill

A production-hardened, cross-agent **AI Skill** for migrating live servers from **FastPanel / FastPanel2**, **cPanel / WHM**, **Plesk**, and **ISPmanager** to **Coolify** — engineered with strict isolation, zero-downtime shadow staging, automatic dead-man's rollback, and token/SSH efficiency.

Follows the open **Agent Skills (`SKILL.md`)** specification and works with **Claude Code, OpenAI Codex, Cursor, Gemini CLI, OpenCode, Antigravity**, and any Agent-Skills-compatible assistant.

---

## Why This Skill Exists

Letting an AI agent run commands directly on a live production server is risky if it wings ad-hoc shell commands. This skill turns server migration into a **5-phase guarded state machine** with hard-coded blast-radius limits:

1. **Read-Only Preflight (`scripts/preflight-inventory.sh`)**
   - Single batched SSH script (zero mutations).
   - Auto-detects `fastpanel2`, `cpanel`, `plesk`, or `ispmanager`, active web/DB/mail/FTP services, `forever`/`pm2`/systemd workers, SSL panel dependencies, local Git/build drift (`dist/` vs repo), and **live DNS vs dead/parked domains** (preventing Let's Encrypt rate limits).
2. **Mandatory Immutable Snapshot (`scripts/backup-state.sh`)**
   - Verifies disk headroom (`>= 5 GB` and `>= 15%` free).
   - Archives `/etc/nginx`, `/etc/apache2`, `/etc/httpd`, `/etc/php*`, `/etc/letsencrypt`, panel configs, cron jobs, systemd units, firewall rules, and package manifests into `/var/backups/coolify-migration-<TS>/` + `MANIFEST.env`.
3. **Shadow Staging & Decoupling (`scripts/stage-verify.sh`, `scripts/start-guard.js`)**
   - Keeps host `:80`/`:443` untouched while decoupling SSL certs/ACME webroots into `/etc/nginx/ssl-certs/`.
   - Stages static/SPA, PHP, and Node/Python containers on loopback (`127.0.0.1:1808x`).
   - Enforces **single-instance execution** via `flock` + `start-guard.js` so `@Cron` jobs, mailers, and webhooks never run twice across old (`forever`/`pm2`) and new Coolify containers.
4. **Atomic Cutover with Automatic Rollback (`scripts/cutover-and-rollback.sh`)**
   - Requires `--dry-run` preview before `--apply`.
   - Stops legacy workers and host HTTP (`nginx`/`apache2`/`httpd`/`php*-fpm`) right as `coolify-proxy` takes `:80/:443`.
   - Runs live HTTPS probes across all active domains; **automatically rolls back** to the legacy stack from `MANIFEST.env` if any probe fails.
5. **Gated Panel Cleanup (`scripts/purge-panel-safe.sh`)**
   - Defaults to dry-run; refuses execution unless `--confirm-verified --apply` is supplied **and** 4 safety gates pass:
     1. `coolify-proxy` is healthy and running.
     2. Legacy host HTTP is stopped and `:80/:443` are active.
     3. A fresh verification receipt (`< 24h`) exists from `stage-verify.sh`.
     4. Zero Coolify configs reference panel directories.

### Hard Protected Resources (Never Touched)

All scripts enforce an allowlist protecting stateful infrastructure and user data:
- **Databases**: `mysql`, `mysqld`, `mariadb`, `postgresql`, `redis`
- **Mail**: `exim`, `exim4`, `postfix`, `dovecot`
- **FTP**: `proftpd`, `pure-ftpd`, `vsftpd`
- **Access & Firewall**: `sshd`, `ufw`, `iptables`, `nftables`
- **Data & Certs**: `/var/www`, `/home/*/public_html`, `/var/vmail`, `/etc/letsencrypt`, `/etc/nginx/ssl-certs`

---

## Installation (All AI Agents)

### Option 1: Universal CLI (`npx skills`)

```bash
npx skills add MikeMorette/panel-to-coolify-skill
```

### Option 2: Direct Clone for Specific Agents

```bash
# Universal (.agents)
git clone https://github.com/MikeMorette/panel-to-coolify-skill.git ~/.agents/skills/panel-to-coolify

# Claude Code
git clone https://github.com/MikeMorette/panel-to-coolify-skill.git ~/.claude/skills/panel-to-coolify

# OpenAI Codex
git clone https://github.com/MikeMorette/panel-to-coolify-skill.git ~/.codex/skills/panel-to-coolify

# Gemini CLI / Antigravity
git clone https://github.com/MikeMorette/panel-to-coolify-skill.git ~/.gemini/skills/panel-to-coolify
```

Or drop it into any project under `.agents/skills/panel-to-coolify/`.

---

## Quick Start Prompt

Once installed, give your AI assistant a prompt like:

```text
Use the panel-to-coolify skill to migrate server root@203.0.113.10 (SSH key ~/.ssh/prod_key)
from FastPanel2 to Coolify. Start with Phase 1 read-only preflight and Phase 2 backup,
and show me the migration plan before making any changes.
```

---

## Repository Structure

```text
.
├── SKILL.md                          # Core state machine & agent guardrails
├── agents/
│   └── openai.yaml                   # Codex / OpenAI agent metadata
├── scripts/
│   ├── preflight-inventory.sh        # Phase 1: read-only multi-panel & DNS audit
│   ├── backup-state.sh               # Phase 2: immutable config/SSL/firewall snapshot
│   ├── start-guard.js                # Phase 3: single-instance TCP port guard
│   ├── stage-verify.sh               # Phase 3 & 5: loopback/live HTTPS, TLS, SPA, upload check
│   ├── cutover-and-rollback.sh       # Phase 4: atomic traffic switch + dead-man's rollback
│   └── purge-panel-safe.sh           # Phase 5: 4-gate protected panel cleanup
├── references/
│   ├── panels-matrix.md              # FastPanel2, cPanel, Plesk, ISPmanager paths & quirks
│   ├── safety-invariants.md          # Non-negotiable production safety rules
│   └── coolify-templates.md          # Traefik, Nginx, Certbot, flock, and panel-tools YAML
├── README.md
└── LICENSE                           # MIT
```

## License

MIT
