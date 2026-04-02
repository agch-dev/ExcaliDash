# =============================================================================
# Combined Dockerfile for Render deployment (PostgreSQL)
# Runs both the backend (Node.js) and frontend (nginx) in a single container.
# =============================================================================

# --------------- Stage 1: Build frontend ---------------
FROM node:20-alpine AS frontend-builder

WORKDIR /app/frontend

COPY frontend/package*.json ./
RUN npm ci && npm cache clean --force

COPY frontend/ ./
COPY VERSION ../VERSION

ARG VITE_APP_VERSION
ARG VITE_APP_BUILD_LABEL
ENV VITE_APP_VERSION=$VITE_APP_VERSION
ENV VITE_APP_BUILD_LABEL=$VITE_APP_BUILD_LABEL

RUN npm run build

# --------------- Stage 2: Build backend ---------------
FROM node:20-alpine AS backend-builder

WORKDIR /app

RUN apk add --no-cache python3 make g++

COPY backend/package*.json ./
COPY backend/tsconfig.json ./
COPY backend/prisma.config.render.ts ./prisma.config.ts

RUN npm ci && npm cache clean --force

# Use PostgreSQL schema for Render
COPY backend/prisma ./prisma/
COPY backend/prisma/schema.render.prisma ./prisma/schema.prisma
RUN npx prisma generate

COPY backend/src ./src
RUN npx tsc

# --------------- Stage 3: Production ---------------
FROM node:20-alpine

RUN apk add --no-cache openssl su-exec nginx && \
    addgroup -g 1001 -S nodejs && \
    adduser -S nodejs -u 1001

WORKDIR /app

# -- Backend setup --
COPY backend/package*.json ./
RUN apk add --no-cache --virtual .build-deps python3 make g++ && \
    npm ci --omit=dev && \
    npm cache clean --force && \
    apk del .build-deps

# Use PostgreSQL schema and render Prisma config
COPY backend/prisma ./prisma/
COPY backend/prisma/schema.render.prisma ./prisma/schema.prisma
COPY backend/prisma.config.render.ts ./prisma.config.ts
COPY --from=backend-builder /app/dist ./dist
COPY --from=backend-builder /app/src/generated ./dist/generated
RUN mkdir -p /app/uploads

# -- Frontend / nginx setup --
COPY frontend/nginx.conf.template /etc/nginx/nginx.conf.template
COPY --from=frontend-builder /app/frontend/dist /usr/share/nginx/html

# -- Combined entrypoint --
COPY render-entrypoint.sh ./render-entrypoint.sh
RUN chmod +x render-entrypoint.sh

ENV PORT=8000
EXPOSE 80

ENTRYPOINT ["./render-entrypoint.sh"]
