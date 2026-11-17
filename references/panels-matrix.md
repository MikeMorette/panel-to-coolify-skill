# Panel-specific migration notes

Panel layouts vary by version and distribution. The paths below are discovery hints, not deletion lists. Inspect actual ownership and active references, including generated files outside panel directories.

| Panel | Common control units | Common web configuration | Important traps |
|---|---|---|---|
| FastPanel2 | `fastpanel2`, `faststat`, `fastpanel2-nginx`, `fastpanel2-apps` | `/etc/nginx/fastpanel2-sites`, `/etc/apache2/fastpanel2-sites`, `/var/www/httpd-cert` | Live sites can still need Apache/PHP and panel-generated include files; DB/SSH config can also reference panel-named files. |
| cPanel/WHM | `cpanel`, `cpsrvd`, `tailwatchd` | `/etc/apache2`, `/var/cpanel/userdata` | Deep integration with OS, mail and user data; do not blindly remove RPM packages. |
| Plesk | `sw-cp-server`, `sw-engine`, `psa` | `/var/www/vhosts/system`, `/usr/local/psa` | Keep mail, databases, vhosts and required PHP runtimes; do not assume a panel path is disposable. |
| ISPmanager | `ihttpd`, `mgr5` | `/etc/nginx/vhosts`, `/etc/apache2/vhosts`, `/var/www/httpd-cert` | Inventory cron, user roots, mail and renewal before retiring the panel. |

## FastPanel on Debian/Ubuntu

Inventory exact installed `fastpanel2*` packages, all panel units and active routes. Inspect the real package's `prerm`/`postrm`, dependencies and owned conffiles; for example a package may own `/var/www/index.html` while MySQL, PostgreSQL and SSH include unowned panel-generated files. `apt-get -s -o APT::Get::AutomaticRemove=false remove <explicit-packages>` is a simulation, not proof that maintainer scripts or conffiles are safe. Inspect those separately. Do not use `purge fastpanel2*`, `autoremove`, or `rm -rf` on panel/PHP directories.

Panel-managed scheduled backups and automatic renewal can stop with the control plane; inspect actual jobs and replace only those the user needs. Panel webmail/phpMyAdmin may disappear with panel nginx/PHP. Existing Apache/PHP, site users, `/var/www`, mail, FTP and database configs may need to remain even after the panel packages are removed.

## Other panels

Do not assume generic APT removal applies to RPM-based or integrated panel stacks. Review the vendor's current primary documentation and actual package scripts, service ownership, generated configuration and dependencies for the installed version. If these cannot be established, retain the relevant component and clearly report the blocker rather than deleting it.
