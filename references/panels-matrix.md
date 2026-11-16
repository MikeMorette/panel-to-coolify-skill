# Hosting Panels Reference Matrix

Quick reference for paths, services, SSL stores, and safe cleanup rules across **FastPanel2**, **cPanel/WHM**, **Plesk**, and **ISPmanager**.

## 1. Panel Comparison Table

| Dimension | FastPanel2 | cPanel / WHM | Plesk (Obsidian) | ISPmanager (5/6) |
|---|---|---|---|---|
| **Core Package / Unit** | `fastpanel2` (`fastpanel2.service`) | `/usr/local/cpanel` (`cpanel.service`, `cpsrvd`) | `psa`, `plesk-*` (`sw-cp-server`, `psa.service`) | `ispmanager-*`, `ihttpd` (`ihttpd.service`) |
| **Web Stack** | `nginx` + `apache2` + `php*-fpm` | `httpd` (EasyApache4) / `nginx` (engintron/cPanel) / `lshttpd` | `nginx` + `apache2`/`httpd` + `plesk-php*-fpm` | `nginx` + `apache2`/`httpd` + `php*-fpm` / `lsphp` |
| **Vhost Configs** | `/etc/nginx/fastpanel2-sites/*/*.conf`, `/etc/apache2/fastpanel2-sites/*/*.conf` | `/etc/apache2/conf/httpd.conf` + `/var/cpanel/userdata/<user>/*` | `/var/www/vhosts/system/*/conf/nginx.conf`, `httpd.conf` | `/etc/nginx/vhosts/<user>/*.conf`, `/etc/apache2/vhosts/<user>/*.conf` |
| **Site Docroots** | `/var/www/<user>/data/www/<domain>` | `/home/<user>/public_html` (and addon roots) | `/var/www/vhosts/<domain>/httpdocs` | `/var/www/<user>/data/www/<domain>` |
| **Panel SSL / ACME** | `/usr/local/fastpanel2/web/letsencrypt`, `/var/www/httpd-cert/` | `/var/cpanel/ssl/apache_tls/`, `/etc/letsencrypt/` | `/usr/local/psa/var/certificates/`, `/opt/psa/var/modules/letsencrypt/` | `/var/www/httpd-cert/<user>/`, `/etc/letsencrypt/` |
| **Databases (PROTECTED)** | `mysql` / `mariadb`, `postgresql` | `mysql` / `mariadb`, `postgresql` | `mysql` / `mariadb`, `postgresql` | `mysql` / `mariadb`, `postgresql` |
| **Mail (PROTECTED)** | `exim4`, `dovecot` | `exim`, `dovecot`, `mailman` | `postfix` / `qmail`, `dovecot` | `exim4` / `postfix`, `dovecot` |
| **FTP (PROTECTED)** | `proftpd` | `pure-ftpd` / `proftpd` | `proftpd` (`psa-proftpd`) | `proftpd` / `vsftpd` |
| **Webmail / PMA** | Roundcube + phpMyAdmin on `:8888` | Roundcube + PMA on `:2096` / `:2083` | Roundcube/Horde + PMA via `plesk` | Roundcube + PMA via `/webmail`, `/phpmyadmin` |
| **Panel Cleanup Strategy** | `apt-get purge fastpanel2*` + remove `/usr/local/fastpanel2` | **Disable panel services only** (`cpsrvd`, `cpanel`); avoid RPM purge | Stop/disable `sw-cp-server`, `psa`; remove only unused `plesk-*` web packages after full verification | Stop/disable `ihttpd`, `mgr5`; optionally remove `ispmanager-*` packages |

## 2. Panel-Specific Gotchas

### FastPanel2
- Vhosts often embed cert paths under `/var/www/httpd-cert/` or ACME webroots inside `/usr/local/fastpanel2/web/letsencrypt`. Always migrate certs and ACME webroots to `/etc/nginx/ssl-certs/` before stopping or removing FastPanel.
- FastPanel runs its own UI + Roundcube + phpMyAdmin on `:8888`. Replace with an isolated `panel-tools` container restricted to localhost or allowlisted admin IPs.

### cPanel / WHM
- **Do NOT blindly `yum/dnf remove cpanel*`**. cPanel heavily replaces system Perl, EasyApache, Exim, and PAM/user layouts. Removing cPanel RPMs can break `exim`, `dovecot`, SSH auth, or `/home/*` permissions.
- Safe migration path: stop and mask cPanel's own web/panel daemons (`cpanel`, `tailwatchd`, `httpd`, `nginx`, `ea-php*-php-fpm`) after moving workloads to Coolify, while leaving `mysql`/`mariadb`, `exim`, `dovecot`, `pure-ftpd`, and `/home/*` untouched.
- If DNS was served locally by `named`/`powerdns`, verify whether the server is authoritative DNS before touching DNS daemons.

### Plesk
- Plesk uses `sw-cp-server` and `sw-engine` for its control plane (`:8443`), plus `plesk-php*-fpm` pools.
- Certificates live in `/usr/local/psa/var/modules/letsencrypt/` or `/opt/psa/var/certificates/` with random hashes (`cert-*`). Resolve the exact symlink/file targets using `nginx -T` or `httpd -S` before copying them to `/etc/nginx/ssl-certs/`.
- Do NOT remove `psa-mail-*`, `postfix`, or `dovecot` if mail remains on the host.

### ISPmanager (5 / 6)
- ISPmanager binds its UI via `ihttpd` (typically `:1500`).
- Sites follow `/var/www/<user>/data/www/<domain>` and certs in `/var/www/httpd-cert/<user>/` (very similar to FastPanel2).
- Watch out for ISPmanager `cron` entries (`/var/spool/cron/crontabs/*`) that trigger panel billing/cert renewals or `logrotate` scripts calling `nginx -s reload`. Update or disable panel-specific cron jobs after cutover.
