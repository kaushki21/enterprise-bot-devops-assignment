# ==========================================
# Stage 1: Build / Preparation stage
# ==========================================
FROM node:22.11.0-alpine3.20 AS builder

WORKDIR /app

# Copy package manifests and application source
COPY package.json ./
COPY server.js ./

# Verify syntax / tests if applicable
RUN node -c server.js

# ==========================================
# Stage 2: Minimal, secure runtime stage
# ==========================================
FROM node:22.11.0-alpine3.20 AS runner

# Create dedicated non-root user and group with explicit UID/GID
RUN addgroup -g 10001 appgroup && \
    adduser -u 10001 -G appgroup -s /sbin/nologin -D -H appuser

WORKDIR /app

# Set production environment defaults
ENV NODE_ENV=production \
    PORT=8080

# Copy application artifacts from builder with correct ownership
COPY --from=builder --chown=10001:10001 /app/package.json ./package.json
COPY --from=builder --chown=10001:10001 /app/server.js ./server.js

# Switch to non-root user
USER 10001:10001

EXPOSE 8080

CMD ["node", "server.js"]
