# Coolify routing and renewal notes

These are design checks, not drop-in production configurations. Inspect the installed Coolify/Traefik version, existing entrypoint names, networks, routing priorities, trusted headers and certificates first.

## Existing applications and host upstreams

Prefer an already-running Coolify workload when it serves the intended version. Route the desired hostname to that exact workload or to a reviewed internal host bridge; do not rebuild merely to change a domain. Apache can remain a loopback upstream for `.htaccess`/PHP sites. Restrict internal listeners to the expected proxy peer, and verify client-IP and forwarded-header trust instead of accepting spoofable headers.

Validate both HTTP and HTTPS/redirect behavior, actual Host and SNI, paths, WebSockets and HTTP/3/UDP if used. A route may intentionally be disabled. Preserve its prior status rather than automatically enabling it. Check Punycode and Unicode names as the same domain where appropriate, including certificates and Coolify's duplicate-domain checks.

## Config source of truth

Coolify can store its proxy configuration and rewrite `/data/coolify/proxy/docker-compose.yml` on a start or restart. Use the supported Coolify UI/API to save desired proxy configuration, compare it to the current compose and Docker inspection, and preserve required custom mounts, networks and addresses. Saving should not implicitly restart a production proxy. Validate any Coolify normalization of the saved configuration before relying on recreation.

## TLS and renewal

Map each certificate lineage to its SANs, public DNS, challenge entrypoint, files visible inside Traefik and reload/publish process. Avoid file mounts that permanently bind an old symlink target when Certbot rotates generations; mount an appropriate directory, keep keys read-only to the proxy, and verify the certificate actually served by SNI. Use staging ACME for safe issuance tests and avoid unnecessary production reissuance. Handle scheduled renewal, partial failure, concurrent jobs, process termination, rotation and proxy recreation. A timer that ran when nothing was due proves only a no-op.

## Workers

An advisory TCP port check is not a distributed lock: the socket is released before the application binds. A shared `flock` only helps when all old and new writers take the **same** lock across the relevant filesystem/container namespaces and hold it for the full lifecycle. Otherwise, explicitly stop and verify the previous writer before starting its replacement and prepare its restoration.
