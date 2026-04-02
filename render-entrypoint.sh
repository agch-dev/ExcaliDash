#!/bin/sh
set -e

# =============================================================================
# Combined entrypoint for Render deployment (PostgreSQL).
# 1. Handles secrets and runs Prisma migrations against PostgreSQL.
# 2. Starts the backend (Node.js) in the background.
# 3. Configures nginx to proxy to the local backend.
# 4. Starts nginx in the foreground on the Render-assigned port.
# =============================================================================

# -- Backend configuration --
BACKEND_INTERNAL_PORT=8000
export PORT="${BACKEND_INTERNAL_PORT}"
export NODE_ENV=production
export TRUST_PROXY="${TRUST_PROXY:-true}"

# DATABASE_URL must be set via Render environment variables
# e.g. postgresql://user:password@host:5432/dbname
if [ -z "${DATABASE_URL:-}" ]; then
    echo "ERROR: DATABASE_URL is required. Set it in Render environment variables." >&2
    exit 1
fi

# Render exposes a single port; nginx will listen on it.
RENDER_PORT="${RENDER_PORT:-10000}"

# -- Secrets --
JWT_SECRET_DIR="/app/.secrets"
JWT_SECRET_FILE="${JWT_SECRET_DIR}/.jwt_secret"
CSRF_SECRET_FILE="${JWT_SECRET_DIR}/.csrf_secret"
mkdir -p "${JWT_SECRET_DIR}"

if [ -z "${JWT_SECRET:-}" ]; then
    echo "JWT_SECRET not provided, generating a new secret..."
    JWT_SECRET="$(openssl rand -hex 32)"
fi
export JWT_SECRET

if [ -z "${CSRF_SECRET:-}" ]; then
    echo "CSRF_SECRET not provided, generating a new secret..."
    CSRF_SECRET="$(openssl rand -base64 32)"
fi
export CSRF_SECRET

# -- Fix permissions --
echo "Fixing filesystem permissions..."
chown -R nodejs:nodejs /app/uploads
chown -R nodejs:nodejs "${JWT_SECRET_DIR}"
chmod 755 /app/uploads

# -- Database migrations --
RUN_MIGRATIONS="${RUN_MIGRATIONS:-true}"
if [ "${RUN_MIGRATIONS}" = "true" ] || [ "${RUN_MIGRATIONS}" = "1" ]; then
    echo "Running database migrations against PostgreSQL..."
    su-exec nodejs npx prisma migrate deploy
else
    echo "Skipping database migrations (RUN_MIGRATIONS=${RUN_MIGRATIONS})"
fi

# -- Start backend in background --
echo "Starting backend on port ${BACKEND_INTERNAL_PORT}..."
su-exec nodejs node dist/index.js &
BACKEND_PID=$!

# Wait for backend to be ready
echo "Waiting for backend to be ready..."
for i in $(seq 1 30); do
    if node -e "require('http').get('http://127.0.0.1:${BACKEND_INTERNAL_PORT}/health', (r) => process.exit(r.statusCode === 200 ? 0 : 1))" 2>/dev/null; then
        echo "Backend is ready."
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "ERROR: Backend failed to start within 30 seconds"
        exit 1
    fi
    sleep 1
done

# -- Configure nginx --
export BACKEND_URL="127.0.0.1:${BACKEND_INTERNAL_PORT}"
echo "Configuring nginx with BACKEND_URL: ${BACKEND_URL}, listening on port ${RENDER_PORT}"

ESCAPED_BACKEND_URL=$(printf '%s\n' "$BACKEND_URL" | sed 's/[\/&]/\\&/g')
sed "s/__BACKEND_URL__/${ESCAPED_BACKEND_URL}/g" /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf
sed -i "s/listen 80;/listen ${RENDER_PORT};/" /etc/nginx/nginx.conf

echo "Validating nginx configuration..."
if ! nginx -t -c /etc/nginx/nginx.conf; then
    echo "ERROR: nginx configuration validation failed" >&2
    exit 1
fi

# -- Start nginx in foreground --
trap "kill ${BACKEND_PID} 2>/dev/null; exit 1" INT TERM
echo "Starting nginx on port ${RENDER_PORT}..."
nginx -g 'daemon off;' &
NGINX_PID=$!

# Wait for either process to exit, then stop the other
wait -n ${BACKEND_PID} ${NGINX_PID} 2>/dev/null || true
echo "A process exited unexpectedly. Shutting down..."
kill ${BACKEND_PID} ${NGINX_PID} 2>/dev/null || true
exit 1
