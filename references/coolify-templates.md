# Coolify & Hardened Container Templates

Generic, panel-agnostic production templates validated on live migrations. Replace `example.com`, `198.51.100.10`, and service names with values discovered in Phase 1.

## 1. Traefik Dynamic Routing (`/data/coolify/proxy/dynamic/migration.yml`)

Terminates TLS using decoupled certs under `/etc/nginx/ssl-certs/`, routes ACME challenges cleanly, and forwards traffic to containerized sites (`nginx-sites`) or Coolify API containers while preserving real client headers.

```yaml
http:
  routers:
    acme-well-known:
      rule: "PathPrefix(`/.well-known/acme-challenge/`)"
      entryPoints:
        - http
      priority: 1000
      service: sites-http

    site-example-https:
      rule: "Host(`example.com`) || Host(`www.example.com`)"
      entryPoints:
        - https
      tls: {}
      service: sites-http

    api-example-https:
      rule: "Host(`api.example.com`)"
      entryPoints:
        - https
      tls: {}
      service: api-example

  services:
    sites-http:
      loadBalancer:
        passHostHeader: true
        servers:
          - url: "http://host.docker.internal:18080"

    api-example:
      loadBalancer:
        passHostHeader: true
        servers:
          - url: "http://host.docker.internal:3000"

tls:
  certificates:
    - certFile: /etc/nginx/ssl-certs/group1-letsencrypt/live/example.com/fullchain.pem
      keyFile: /etc/nginx/ssl-certs/group1-letsencrypt/live/example.com/privkey.pem
```

Make sure `/etc/nginx/ssl-certs` is mounted read-only into `coolify-proxy` (`/etc/nginx/ssl-certs:/etc/nginx/ssl-certs:ro`).

## 2. Hardened Nginx Stage/Sites Container (`/data/coolify/sites-nginx/default.conf`)

Binds to `127.0.0.1:18080` on the host, handles ACME HTTP-01 challenges, SPA fallback, uploads, and optional Apache `.htaccess` passthrough:

```nginx
server {
    listen 80;
    server_name example.com www.example.com;

    location ^~ /.well-known/acme-challenge/ {
        alias /etc/nginx/ssl-certs/group1-acme-challenge/.well-known/acme-challenge/;
        default_type "text/plain";
        try_files $uri =404;
    }

    root /var/www/appuser/data/www/example.com;
    index index.html index.htm;

    location /uploads/ {
        alias /var/www/appuser/data/www/example.com/uploads/;
        try_files $uri =404;
    }

    location / {
        try_files $uri $uri/ /index.html;
    }
}
```

## 3. Single-Instance Guard for Stateful APIs (`docker-compose.yml` + `flock` + `start-guard.js`)

Prevents duplicate cron jobs/mailers/webhooks when migrating from `forever`, `pm2`, or `systemd`:

```yaml
services:
  api:
    image: node:20-alpine
    container_name: example-api
    restart: unless-stopped
    network_mode: host
    working_dir: /app
    volumes:
      - /var/www/appuser/data/www/api.example.com:/app
      - /var/www/appuser/data/www/api.example.com/uploads:/app/uploads
      - /run/coolify-api-locks:/run/coolify-api-locks
      - /usr/local/lib/coolify-guards/start-guard.js:/usr/local/bin/start-guard.js:ro
    entrypoint:
      - /bin/sh
      - -c
      - |
        mkdir -p /run/coolify-api-locks && \
        exec flock -n /run/coolify-api-locks/example-api.lock \
        node /usr/local/bin/start-guard.js --port 3000 -- node dist/main.js
```

## 4. Decoupled Certbot Auto-Renewal (`certbot/certbot` + `systemd .path`)

Run periodic certbot renewal via cron/timer and automatically reload containers only when certificates actually change:

```ini
# /etc/systemd/system/nginx-ssl-reload.path
[Unit]
Description=Watch decoupled SSL certs for renewal

[Path]
PathChanged=/etc/nginx/ssl-certs/group1-letsencrypt/archive

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/systemd/system/nginx-ssl-reload.service
[Unit]
Description=Reload sites nginx and touch Traefik dynamic config after SSL renewal

[Service]
Type=oneshot
ExecStart=/usr/bin/docker exec sites-nginx nginx -s reload
ExecStart=/usr/bin/touch /data/coolify/proxy/dynamic/migration.yml
```

## 5. Hardened `panel-tools` (Optional Roundcube + phpMyAdmin on `:8888`)

If users still rely on host `mysql` + `exim`/`dovecot`, bind `panel-tools` to `127.0.0.1:8888` (access via SSH tunnel) or protect `:8888` via firewall allowlist:

```yaml
services:
  panel-tools-nginx:
    image: nginx:1.27-alpine
    ports:
      - "127.0.0.1:8888:80"
    depends_on:
      - phpmyadmin
      - roundcube
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro

  phpmyadmin:
    image: phpmyadmin:5.2
    environment:
      PMA_SOCKET: /var/run/mysqld/mysqld.sock
    volumes:
      - /run/mysqld:/var/run/mysqld:ro

  roundcube:
    image: roundcube/roundcubemail:1.6-apache
    environment:
      ROUNDCUBEMAIL_DEFAULT_HOST: tls://127.0.0.1
      ROUNDCUBEMAIL_SMTP_SERVER: tls://127.0.0.1
```
