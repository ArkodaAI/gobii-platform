#!/usr/bin/env bash
set -euo pipefail

echo "=========================================="
echo " Gobii Platform – RunPod Startup"
echo "=========================================="

# ── Ensure network volume directories exist ─────────────────
VOLUME="${RUNPOD_VOLUME:-/runpod-volume}"
mkdir -p "$VOLUME/data" "$VOLUME/media" "$VOLUME/logs"

# ── Generate secrets if not provided ─────────────────────────
if [ -z "${DJANGO_SECRET_KEY:-}" ]; then
    # Persist generated key on network volume so it survives restarts
    SECRET_FILE="$VOLUME/data/.django_secret_key"
    if [ -f "$SECRET_FILE" ]; then
        export DJANGO_SECRET_KEY=$(cat "$SECRET_FILE")
        echo "[init] Loaded DJANGO_SECRET_KEY from network volume"
    else
        export DJANGO_SECRET_KEY=$(python -c "import secrets; print(secrets.token_urlsafe(64))")
        echo "$DJANGO_SECRET_KEY" > "$SECRET_FILE"
        chmod 600 "$SECRET_FILE"
        echo "[init] Generated and saved DJANGO_SECRET_KEY"
    fi
fi

if [ -z "${GOBII_ENCRYPTION_KEY:-}" ]; then
    ENC_FILE="$VOLUME/data/.gobii_encryption_key"
    if [ -f "$ENC_FILE" ]; then
        export GOBII_ENCRYPTION_KEY=$(cat "$ENC_FILE")
        echo "[init] Loaded GOBII_ENCRYPTION_KEY from network volume"
    else
        export GOBII_ENCRYPTION_KEY=$(python -c "import secrets; print(secrets.token_urlsafe(64))")
        echo "$GOBII_ENCRYPTION_KEY" > "$ENC_FILE"
        chmod 600 "$ENC_FILE"
        echo "[init] Generated and saved GOBII_ENCRYPTION_KEY"
    fi
fi

# ── Apply SQLite settings patch ──────────────────────────────
export GOBII_SQLITE_PATH="${GOBII_SQLITE_PATH:-$VOLUME/data/gobii.db}"
echo "[init] SQLite database: $GOBII_SQLITE_PATH"

# ── Set media root to network volume ─────────────────────────
export MEDIA_ROOT="$VOLUME/media"

# ── Export display for Chrome ────────────────────────────────
export DISPLAY=:99

# ── Redis config ─────────────────────────────────────────────
export REDIS_URL="${REDIS_URL:-redis://127.0.0.1:6379/0}"
export CELERY_BROKER_URL="$REDIS_URL"
export CELERY_RESULT_BACKEND="$REDIS_URL"

# ── Wait for Redis to be ready (started by supervisord) ──────
wait_for_redis() {
    echo "[init] Waiting for Redis..."
    for i in $(seq 1 30); do
        if redis-cli -h 127.0.0.1 -p 6379 ping >/dev/null 2>&1; then
            echo "[init] Redis is ready"
            return 0
        fi
        sleep 1
    done
    echo "[init] WARNING: Redis not ready after 30s, continuing anyway"
    return 1
}

# ── Run migrations ───────────────────────────────────────────
run_migrations() {
    echo "[init] Running database migrations..."
    cd /app
    python manage.py migrate --noinput 2>&1 | tail -5
    echo "[init] Migrations complete"
}

# ── Detect run mode ──────────────────────────────────────────
# RUNPOD_SERVERLESS=1 → serverless handler mode (no web server)
# Default → full stack via supervisord
if [ "${RUNPOD_SERVERLESS:-0}" = "1" ]; then
    echo "[init] RunPod Serverless mode – starting handler"

    # Start Redis in background
    redis-server --port 6379 --save 60 1 --dir "$VOLUME/data" --daemonize yes
    wait_for_redis

    # Start Xvfb in background
    Xvfb :99 -screen 0 1920x1080x24 -ac +extension GLX +render -noreset &

    # Migrations
    run_migrations

    # Start Celery worker in background
    cd /app && celery -A config worker -l info --pool=threads --concurrency=2 &

    # Run the serverless handler
    exec python /app/deploy/handler.py

else
    echo "[init] Pod mode – starting full stack via supervisord"

    # Start supervisord which manages Redis, then run migrations after
    # We use a background job to wait for Redis and run migrations
    (
        sleep 5  # Give supervisord time to start Redis
        wait_for_redis
        run_migrations
        echo "[init] All services ready on port ${GOBII_PORT:-3000}"
    ) &

    exec "$@"
fi
