# syntax=docker/dockerfile:1.7
# ============================================================
# Gobii Platform – RunPod Serverless / Pod Deployment
# All-in-one: Django + Celery Worker + Redis + Headless Chrome
# SQLite persistence on RunPod Network Volume
# ============================================================

# ── Stage 1: deps ───────────────────────────────────────────
FROM python:3.13-slim-bookworm AS deps

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PLAYWRIGHT_BROWSERS_PATH=/usr/local/share/pw-browsers \
    DEBIAN_FRONTEND=noninteractive

WORKDIR /app

# System packages: Chrome, Node.js, Redis, supervisor, SQLite
RUN --mount=type=cache,target=/var/cache/apt \
    apt-get update && \
    apt-get install --no-install-recommends -y \
        git procps curl wget gnupg ca-certificates \
        # X11/display libs (headless Chrome still needs these)
        xvfb x11-utils xauth libx11-6 libxext6 libxrender1 \
        libxtst6 libxi6 libxrandr2 libxfont2 \
        libpango-1.0-0 libpangoft2-1.0-0 libharfbuzz-subset0 \
        # Chrome dependencies
        libasound2 libatk-bridge2.0-0 libatk1.0-0 libcups2 libdbus-1-3 \
        libdrm2 libgbm1 libglib2.0-0 libnspr4 libnss3 libu2f-udev ffmpeg \
        libxcomposite1 libxdamage1 libxfixes3 libxkbcommon0 xdg-utils \
        fonts-liberation fonts-noto fonts-unifont \
        # Redis server (embedded)
        redis-server \
        # Process manager
        supervisor \
        # SQLite (latest from Debian repos)
        sqlite3 libsqlite3-dev && \
    # Install Node.js 22
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install --no-install-recommends -y nodejs && \
    # Install Google Chrome stable
    mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /etc/apt/keyrings/google-linux.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/google-linux.gpg] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list && \
    apt-get update && \
    apt-get install --no-install-recommends -y google-chrome-stable && \
    rm -rf /var/lib/apt/lists/*

RUN pip install --upgrade pip

# Python dependencies
COPY pyproject.toml poetry.lock* ./
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install .

# Global npm packages (MCP servers used by browser agents)
RUN npm install -g @brightdata/mcp@2.5.0 && \
    npm install -g exa-mcp-server && \
    npm cache clean --force

# ── Stage 2: builder ────────────────────────────────────────
FROM deps AS builder

ARG VITE_BUILD_BASE_URL
ENV IN_DOCKER=1 \
    GOBII_RELEASE_ENV=build \
    DEBUG=0 \
    VITE_BUILD_BASE_URL=${VITE_BUILD_BASE_URL}

# Frontend build
COPY frontend/package.json frontend/package-lock.json ./frontend/
RUN --mount=type=cache,target=/root/.npm \
    npm ci --prefix frontend

COPY frontend ./frontend
RUN --mount=type=cache,target=/root/.npm \
    npm run build --prefix frontend

# Full source
COPY . .

RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --editable .

ENV USE_EPHEMERAL_XVFB=true

# Collect static files (uses dummy env vars for build only)
RUN DJANGO_SECRET_KEY=dummy-build-key \
    DEBUG=0 \
    GOBII_RELEASE_ENV=build \
    POSTGRES_DB=dummy \
    POSTGRES_USER=dummy \
    POSTGRES_PASSWORD=dummy \
    POSTGRES_HOST=dummy \
    POSTGRES_PORT=5432 \
    AWS_ACCESS_KEY_ID=dummy \
    AWS_SECRET_ACCESS_KEY=dummy \
    AWS_STORAGE_BUCKET_NAME=dummy \
    AWS_S3_REGION_NAME=dummy \
    AWS_S3_ENDPOINT_URL=http://dummy:9000 \
    REDIS_URL=redis://dummy:6379/0 \
    GS_BUCKET_NAME=dummy \
    SEGMENT_WRITE_KEY=dummy \
    GRAFANA_API_KEY=dummy \
    POSTMARK_SERVER_TOKEN=dummy \
    POSTMARK_INCOMING_WEBHOOK_TOKEN=dummy \
    MAILGUN_INCOMING_WEBHOOK_TOKEN=dummy \
    GOOGLE_API_KEY=dummy \
    EXA_SEARCH_API_KEY=dummy \
    python manage.py collectstatic --noinput --clear

# ── Stage 3: runtime ────────────────────────────────────────
FROM deps AS runtime

WORKDIR /app

ENV STATIC_ROOT=/app/staticfiles \
    USE_EPHEMERAL_XVFB=true \
    NPM_CONFIG_CACHE=/tmp/.npm \
    # Chrome headless config
    BROWSER_HEADLESS=true \
    CHROME_BIN=/usr/bin/google-chrome \
    CHROME_FLAGS="--headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage --disable-software-rasterizer --remote-debugging-port=0" \
    # SQLite on network volume
    GOBII_DB_ENGINE=sqlite3 \
    GOBII_SQLITE_PATH=/runpod-volume/data/gobii.db \
    # Redis embedded
    REDIS_URL=redis://127.0.0.1:6379/0 \
    # Django
    GOBII_RELEASE_ENV=oss \
    DEBUG=0 \
    DJANGO_SETTINGS_MODULE=config.settings \
    # RunPod network volume mount point
    RUNPOD_VOLUME=/runpod-volume \
    # Port
    GOBII_PORT=3000 \
    # Proxy placeholders (user configures)
    HTTP_PROXY="" \
    HTTPS_PROXY="" \
    NO_PROXY="localhost,127.0.0.1" \
    BRIGHT_DATA_TOKEN="" \
    BRIGHT_DATA_WEB_UNLOCKER_ZONE="" \
    # XDG dirs for Chrome profile
    XDG_DATA_HOME=/tmp/.chrome \
    XDG_CONFIG_HOME=/tmp/.chrome \
    XDG_CACHE_HOME=/tmp/.chrome

# Copy built application
COPY --from=builder /app /app

# Copy deployment configs
COPY deploy/supervisord.conf /etc/supervisor/conf.d/gobii.conf
COPY deploy/entrypoint.sh /entrypoint.sh
COPY deploy/sqlite_settings_patch.py /app/deploy/sqlite_settings_patch.py

# Create required directories
RUN mkdir -p /runpod-volume/data /runpod-volume/media /runpod-volume/logs /tmp/.npm /tmp/.chrome \
        /var/log/supervisor /var/run/redis && \
    chmod +x /entrypoint.sh

# Install runpod SDK for serverless handler
RUN pip install runpod

# Copy serverless handler
COPY deploy/handler.py /app/deploy/handler.py

EXPOSE 3000

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -fsS http://localhost:3000/healthz/ || exit 1

ENTRYPOINT ["/entrypoint.sh"]
CMD ["supervisord", "-n", "-c", "/etc/supervisor/conf.d/gobii.conf"]
