# Multi-stage build for the WhatIsIt backend (Rust + whatsapp-rust).
# Produces a tiny static binary — no CGO, no runtime deps.
#
# Build locally (Linux host):
#   docker build -t whatisit-server .
#
# Build from Windows:
#   docker buildx build --platform linux/amd64 -t whatisit-server .

# ---- Stage 1: build ----
FROM rust:1-slim AS builder
WORKDIR /app

# Rust 1.94+ is required (whatsapp-rust MSRV).
RUN rustup default stable

COPY Cargo.toml ./
# Cache dependency builds first (fake src so cargo can fetch+compile deps).
RUN mkdir -p src && echo 'fn main() {}' > src/main.rs \
  && cargo build --release || true

COPY src/ ./src/
RUN touch src/main.rs \
  && cargo build --release

# ---- Stage 2: runtime ----
FROM debian:bookworm-slim AS runtime
WORKDIR /srv/whatisit

COPY --from=builder /app/target/release/whatisit-server /usr/local/bin/whatisit-server

# Runtime data dirs (session db + media cache + history snapshot).
RUN mkdir -p /srv/whatisit/data && chmod -R 755 /srv/whatisit

ENV PORT=18770
ENV DB_PATH=/srv/whatisit/data/whatsmeow.db
ENV MEDIA_DIR=/srv/whatisit/data/media

EXPOSE 18770

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD wget -qO- http://127.0.0.1:18770/status >/dev/null 2>&1 || exit 1

# WHATSAPP_TOKEN must be provided at runtime (secret).
ENTRYPOINT ["whatisit-server"]
