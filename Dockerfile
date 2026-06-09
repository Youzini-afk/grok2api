# ── Builder ───────────────────────────────────────────────────────────────────
# Use Debian slim instead of Alpine for cloud builders (Zeabur, Render, Fly, etc.).
# The project depends on native wheels such as curl-cffi / tiktoken. On Alpine
# these may fall back to slow musl/Rust builds in constrained CI environments,
# which can look like a build hang with little or no output.
FROM python:3.13-slim-bookworm AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UV_PROJECT_ENVIRONMENT=/opt/venv \
    UV_LINK_MODE=copy

ENV PATH="$UV_PROJECT_ENVIRONMENT/bin:$PATH"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates \
       build-essential \
       libffi-dev \
       libssl-dev \
       pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Pin uv to a minor version for reproducible builds.
# Bump manually when you want to pick up a newer uv release.
COPY --from=ghcr.io/astral-sh/uv:0.6 /uv /uvx /bin/

COPY pyproject.toml uv.lock ./

RUN uv sync --frozen --no-dev --no-install-project --no-build \
    && find /opt/venv -type d \
         \( -name "__pycache__" -o -name "tests" -o -name "test" -o -name "testing" \) \
         -prune -exec rm -rf {} + \
    && find /opt/venv -type f -name "*.pyc" -delete \
    && (find /opt/venv -type f -name "*.so" -exec strip --strip-unneeded {} + 2>/dev/null || true) \
    && rm -rf /root/.cache /tmp/uv-cache

# ── Runtime ───────────────────────────────────────────────────────────────────
FROM python:3.13-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    TZ=Asia/Shanghai \
    VIRTUAL_ENV=/opt/venv \
    SERVER_HOST=0.0.0.0 \
    SERVER_PORT=8000 \
    SERVER_WORKERS=1 \
    DATA_DIR=/app/data \
    LOG_DIR=/app/logs

ENV PATH="$VIRTUAL_ENV/bin:$PATH"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       tzdata \
       ca-certificates \
       libffi8 \
       libssl3 \
       libsqlite3-0 \
       libgcc-s1 \
       libstdc++6 \
       libcurl4 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /opt/venv /opt/venv

COPY pyproject.toml config.defaults.toml ./
COPY app ./app
COPY scripts ./scripts

RUN mkdir -p /app/data /app/logs \
    && chmod +x /app/scripts/entrypoint.sh /app/scripts/init_storage.sh

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=45s --retries=3 \
    CMD ["sh", "-c", "python -c \"import os, urllib.request; port=os.getenv('SERVER_PORT') or os.getenv('PORT') or '8000'; urllib.request.urlopen(f'http://127.0.0.1:{port}/health', timeout=3).read()\""]

ENTRYPOINT ["/app/scripts/entrypoint.sh"]
CMD ["sh", "-c", "exec granian --interface asgi --host ${SERVER_HOST:-0.0.0.0} --port ${SERVER_PORT:-${PORT:-8000}} --workers ${SERVER_WORKERS:-1} app.main:app"]
