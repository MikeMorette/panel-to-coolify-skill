# Panel-to-Coolify — Безопасный AI-скилл для миграции серверов

> **Русский (README.md)** | **[English (README_EN.md)](./README_EN.md)**

Универсальный, отказоустойчивый **AI-скилл** для переноса живых боевых серверов с панелей управления **FastPanel / FastPanel2**, **cPanel / WHM**, **Plesk** и **ISPmanager** на **Coolify** — со строгой изоляцией действий ИИ, теневым staging без простоя, автоматическим откатом (dead-man's rollback) и экономией токенов/SSH-вызовов.

Скилл соответствует открытому стандарту **Agent Skills (`SKILL.md`)** и совместим с **Claude Code, OpenAI Codex, Cursor, Gemini CLI, OpenCode, Antigravity** и любыми другими ИИ-ассистентами.

---

## Зачем нужен этот скилл

Пускать ИИ-ассистента по SSH на боевой сервер с произвольными bash-командами опасно. Этот скилл ограничивает действия ИИ **строгой 5-фазной state-машиной** и зашитыми в скрипты предохранителями:

1. **Только чтение на старте (`scripts/preflight-inventory.sh`)**
   - Выполняется **одним пакетным SSH-вызовом** без единого изменения на сервере.
   - Автоматически определяет панель (`fastpanel2`, `cpanel`, `plesk`, `ispmanager`), активные веб/БД/почта/FTP-сервисы, процессы `forever`/`pm2`/`supervisor`, зависимости SSL от каталогов панели, расхождение локального кода на проде и Git (`git status`, `dist/`) и **проверяет живой DNS против мёртвых/парковочных доменов** (чтобы не словить rate-limit Let's Encrypt).
2. **Обязательный снэпшот перед изменениями (`scripts/backup-state.sh`)**
   - Проверяет запас места на диске (`>= 5 ГБ` и `>= 15%` свободно).
   - Архивирует `/etc/nginx`, `/etc/apache2`, `/etc/httpd`, `/etc/php*`, `/etc/letsencrypt`, конфиги панелей, `cron`, `systemd`-юниты, правила фаервола и список пакетов в `/var/backups/coolify-migration-<TS>/` + формирует `MANIFEST.env`.
3. **Теневой staging и защита от двойного запуска (`scripts/stage-verify.sh`, `scripts/start-guard.js`)**
   - Не трогает публичные `:80`/`:443`, пока отвязывает SSL-сертификаты и ACME webroot-каталоги от панели в `/etc/nginx/ssl-certs/`.
   - Поднимает контейнеры-кандидаты (статика/SPA, PHP, Node/Python API) строго на loopback (`127.0.0.1:1808x`).
   - Оборачивает stateful API в `flock` + `start-guard.js`: старый процесс (`forever`/`pm2`) и новый контейнер Coolify **никогда не запустятся одновременно** (исключает дублирование `@Cron`, рассылок и вебхуков).
4. **Атомарный cutover с автооткатом (`scripts/cutover-and-rollback.sh`)**
   - Требует `--dry-run` предпросмотра перед `--apply`.
   - Останавливает легаси-воркеры и хостовый HTTP (`nginx`/`apache2`/`httpd`/`php*-fpm`) ровно в момент старта `coolify-proxy` на `:80/:443`.
   - Прогоняет живые HTTPS-пробы по всем активным доменам; если любая критичная проверка падает — **автоматически откатывает сервер** обратно к старому веб-стеку из `MANIFEST.env`.
5. **Шлюзованное удаление панели (`scripts/purge-panel-safe.sh`)**
   - По умолчанию работает в режиме `dry-run`; отказывается выполнять очистку без флагов `--confirm-verified --apply` и прохождения **4 обязательных проверок**:
     1. Контейнер `coolify-proxy` запущен и работает.
     2. Легаси-HTTP остановлен, а `:80/:443` обслуживаются прокси.
     3. Есть свежий файл подтверждения проверки (`< 24 часов`) от `stage-verify.sh`.
     4. В конфигах Coolify (`/data/coolify/`) не осталось ни одной ссылки на каталоги панели.

### Жёсткий список защищённых ресурсов (неприкосновенны)

Все скрипты запрещают остановку, отключение или удаление критичной инфраструктуры и пользовательских данных:
- **Базы данных**: `mysql`, `mysqld`, `mariadb`, `postgresql`, `redis`
- **Почта**: `exim`, `exim4`, `postfix`, `dovecot`
- **FTP**: `proftpd`, `pure-ftpd`, `vsftpd`
- **Доступ и сеть**: `sshd`, `ufw`, `iptables`, `nftables`
- **Данные и сертификаты**: `/var/www`, `/home/*/public_html`, `/var/vmail`, `/etc/letsencrypt`, `/etc/nginx/ssl-certs`

---

## Установка (для любых ИИ-агентов)

### Вариант 1: Универсальный CLI (`npx skills`)

```bash
npx skills add MikeMorette/panel-to-coolify-skill
```

### Вариант 2: Прямое клонирование для нужного агента

```bash
# Универсальный путь (.agents)
git clone https://github.com/MikeMorette/panel-to-coolify-skill.git ~/.agents/skills/panel-to-coolify

# Claude Code
git clone https://github.com/MikeMorette/panel-to-coolify-skill.git ~/.claude/skills/panel-to-coolify

# OpenAI Codex
git clone https://github.com/MikeMorette/panel-to-coolify-skill.git ~/.codex/skills/panel-to-coolify

# Gemini CLI / Antigravity
git clone https://github.com/MikeMorette/panel-to-coolify-skill.git ~/.gemini/skills/panel-to-coolify
```

Либо положите репозиторий прямо в проект в папку `.agents/skills/panel-to-coolify/`.

---

## Быстрый старт (пример промпта)

После установки отправьте вашему ИИ-ассистенту:

```text
Используй скилл panel-to-coolify для миграции сервера root@203.0.113.10 (ключ ~/.ssh/prod_key)
с FastPanel2 на Coolify. Начни с Фазы 1 (read-only preflight) и Фазы 2 (бэкап),
и покажи мне план миграции до внесения любых изменений.
```

---

## Структура репозитория

```text
.
├── SKILL.md                          # Основная state-машина и правила безопасности для ИИ
├── agents/
│   └── openai.yaml                   # Метаданные для Codex / OpenAI
├── scripts/
│   ├── preflight-inventory.sh        # Фаза 1: read-only аудит панелей, портов, DNS и git
│   ├── backup-state.sh               # Фаза 2: неизменяемый снэпшот конфигов, SSL и firewall
│   ├── start-guard.js                # Фаза 3: защита от двойного запуска по TCP-порту
│   ├── stage-verify.sh               # Фазы 3 и 5: проверка loopback/live HTTPS, TLS, SPA, uploads
│   ├── cutover-and-rollback.sh       # Фаза 4: атомарное переключение и автооткат
│   └── purge-panel-safe.sh           # Фаза 5: 4-ступенчатая безопасная очистка панели
├── references/
│   ├── panels-matrix.md              # Матрица путей и особенностей FastPanel2, cPanel, Plesk, ISPmanager
│   ├── safety-invariants.md          # Неприкосновенные правила продакшен-безопасности
│   └── coolify-templates.md          # Шаблоны Traefik, Nginx, Certbot, flock и panel-tools
├── README.md                         # Документация (на русском)
├── README_EN.md                      # Документация (на английском)
└── LICENSE                           # MIT
```

## Лицензия

MIT
