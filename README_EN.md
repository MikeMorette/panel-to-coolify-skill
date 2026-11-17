# Panel-to-Coolify migration skill

[Русский](README.md) | **English**

This Agent Skill helps an AI assistant migrate a live server from FastPanel, cPanel/WHM, Plesk or ISPmanager to Coolify. It inventories dependencies, prepares routing and recovery checks, and guides panel retirement while preserving the services and data still in use. Compatible with Agent Skills clients including Codex and Claude Code.

Servers differ: a generic script cannot prove that package removal is safe or recover from an SSH failure. The bundled cutover and panel-removal helpers are **planning-only and refuse mutation**. Actual changes require a reviewed, tested plan tailored to the specific server.

## Install

```bash
npx skills add MikeMorette/panel-to-coolify-skill
```

Or clone into your agent's skill directory:

```bash
git clone https://github.com/MikeMorette/panel-to-coolify-skill.git ~/.agents/skills/panel-to-coolify
```

Example request:

> Use `panel-to-coolify` to migrate my server. First inventory live routes and dependencies, respect my downtime and backup preferences, then prepare the cutover and panel retirement.

## Workflow

The fast path batches the minimum required checks into one or two SSH calls per phase. Repeated audits, heavyweight stages and extra subagents require a specific reason or a user request; once the conditions pass, proceed with the already authorized action.

1. Collect a compact baseline of routes, DNS, TLS, running services, applications and data paths; investigate missing dependencies.
2. Agree on backup scope and a real recovery plan. Users can choose selected data or decline a full backup; communicate the resulting limitations. A configuration snapshot is not a database backup.
3. Verify current workloads and certificate renewal, preserve intentionally stopped projects, and respect an authorized short outage or a request to avoid a heavyweight staging environment.
4. Prepare and test server-specific cutover and independently controlled recovery, then compare public behavior to the baseline.
5. Before removing a panel, review its dependencies, package maintainer scripts, conffiles, exact transaction and required Apache/PHP, mail, FTP, SSH, site files and application data.

Zero downtime, universal support and business correctness from one HTTP response are not guaranteed. Unknown dependencies require investigation.

## Scripts

| Command | Purpose |
|---|---|
| `scripts/preflight-inventory.sh [--public-ip IP] [--dns-limit N] [--git-scan]` | Initial inventory with bounded DNS checks; does not invoke `pm2 list`/`forever list` or scan filesystem trees unless `--git-scan` is selected. |
| `scripts/backup-state.sh` | Optional config/certificate snapshot containing secrets; use only with authorization for that scope. Not a full backup or database dump. |
| `scripts/stage-verify.sh --domains example.com --target 127.0.0.1:443` | Route and TLS checks; verifies certificate identity/chain by default and does not follow redirects. |
| `scripts/cutover-and-rollback.sh --dry-run ...` | Plan only. `--apply` and `--rollback` are refused because no independent watchdog is bundled. |
| `scripts/purge-panel-safe.sh --panel fastpanel2` | Inventory and simulated package removal only. `--apply` is refused. |
| `scripts/start-guard.js` | Advisory port check; it does not provide single-instance exclusion. |

An explicitly requested `stage-verify.sh --write-receipt` records authenticated HTTPS route checks only. It is not proof of login, file writes or rollback, and does not authorize panel removal.

Transient route errors receive bounded retries, with the initial failure retained in the output. A user's direct confirmation of a workflow is recorded as user-reported evidence without requesting a token for that same test.

More detail: [safety invariants](references/safety-invariants.md), [panel notes](references/panels-matrix.md), [Coolify routing and certificates](references/coolify-templates.md).

## Development checks

```bash
bash tests/run.sh
```

Tests use local fixtures and do not contact a production server. Real cutover and recovery need separate verification.

License: [MIT](LICENSE).
