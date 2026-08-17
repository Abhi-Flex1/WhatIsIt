#!/usr/bin/env bash
set -euo pipefail

# WhatIsIt Cloud Deployment Script
# Deploys WhatsMiau + Adapter stack on a fresh VPS for HarmonyOS HAP app cloud infra.

APP_DIR="/opt/whatisit"
WHATSMIAM_PORT="${WHATSMIAM_PORT:-8080}"
ADAPTER_PORT="${ADAPTER_PORT:-18770}"
INSTANCE_ID="${INSTANCE_ID:-default}"
API_KEY="${API_KEY:-}"
DOMAIN="${DOMAIN:-}"

echo "=== WhatIsIt Cloud Deploy ==="

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    echo "Docker already installed"
    return
  fi
  echo "Installing Docker..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
}

install_go() {
  if command -v go >/dev/null 2>&1; then
    echo "Go already installed: $(go version)"
    return
  fi
  echo "Installing Go 1.25..."
  GO_VERSION="1.25.0"
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tar.gz
  rm -rf /usr/local/go
  tar -C /usr/local -xzf /tmp/go.tar.gz
  rm /tmp/go.tar.gz
  export PATH="/usr/local/go/bin:$PATH"
  echo 'export PATH="/usr/local/go/bin:$PATH"' >> /etc/profile.d/go.sh
}

clone_repo() {
  echo "Cloning WhatIsIt..."
  if [ -d "$APP_DIR" ]; then
    echo "App dir exists, pulling latest..."
    cd "$APP_DIR"
    git pull || true
  else
    git clone https://github.com/verbeux-ai/whatsmiau.git "$APP_DIR/server-whatsmiau"
    mkdir -p "$APP_DIR/adapter"
    # Copy adapter files from local workspace if available
    if [ -d "./adapter" ]; then
      cp -r ./adapter/* "$APP_DIR/adapter/"
    fi
    cd "$APP_DIR"
    git init
    git remote add origin https://github.com/verbeux-ai/whatsmiau.git || true
  fi
}

setup_adapter() {
  echo "Building adapter..."
  cd "$APP_DIR/adapter"
  go mod tidy
  go build -o /usr/local/bin/whatisit-adapter ./main.go
}

setup_whatsmiau() {
  echo "Setting up WhatsMiau..."
  cd "$APP_DIR/server-whatsmiau"
  cp -f .env.example .env || true
  sed -i "s/^PORT=.*/PORT=${WHATSMIAM_PORT}/" .env || echo "PORT=${WHATSMIAM_PORT}" >> .env
  if [ -n "$API_KEY" ]; then
    sed -i "s/^API_KEY=.*/API_KEY=${API_KEY}/" .env || echo "API_KEY=${API_KEY}" >> .env
  fi
  go mod tidy
  go build -o /usr/local/bin/whatsmiau-server ./main.go
}

create_systemd_services() {
  echo "Creating systemd services..."

  cat > /etc/systemd/system/whatsmiau.service <<EOF
[Unit]
Description=WhatsMiau Server
After=network.target

[Service]
Type=simple
WorkingDirectory=$APP_DIR/server-whatsmiau
ExecStart=/usr/local/bin/whatsmiau-server
Restart=always
RestartSec=5
Environment="PORT=$WHATSMIAM_PORT"
Environment="API_KEY=$API_KEY"

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/whatisit-adapter.service <<EOF
[Unit]
Description=WhatIsIt Adapter
After=network.target whatsmiau.service

[Service]
Type=simple
WorkingDirectory=$APP_DIR/adapter
ExecStart=/usr/local/bin/whatisit-adapter
Restart=always
RestartSec=5
Environment="WHATSMIAM_URL=http://127.0.0.1:$WHATSMIAM_PORT"
Environment="INSTANCE_ID=$INSTANCE_ID"
Environment="API_KEY=$API_KEY"
Environment="LISTEN_ADDR=0.0.0.0:$ADAPTER_PORT"
Environment="STORE_PATH=$APP_DIR/history.json"
Environment="MEDIA_DIR=$APP_DIR/media"
Environment="MEDIA_PUBLIC_URL=http://127.0.0.1:$ADAPTER_PORT/files"
Environment="WEBHOOK_PUBLIC_URL=http://127.0.0.1:$ADAPTER_PORT/webhook/whatsmiau"

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now whatsmiau
  systemctl enable --now whatisit-adapter
}

setup_firewall() {
  echo "Configuring firewall..."
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "$ADAPTER_PORT"/tcp || true
    ufw allow 22/tcp || true
  elif command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${ADAPTER_PORT}"/tcp || true
    firewall-cmd --permanent --add-service=ssh || true
    firewall-cmd --reload || true
  fi
}

print_summary() {
  PUBLIC_IP=$(curl -s https://ifconfig.me || echo "YOUR_VPS_IP")
  echo ""
  echo "=== Deployment Complete ==="
  echo "Adapter:  http://$PUBLIC_IP:$ADAPTER_PORT"
  echo "Status:   http://$PUBLIC_IP:$ADAPTER_PORT/status"
  echo "WS:       ws://$PUBLIC_IP:$ADAPTER_PORT/ws"
  echo "Config:   http://$PUBLIC_IP:$ADAPTER_PORT/config/backend"
  echo ""
  echo "HarmonyOS app:"
  echo "  - Default backend_host: api.whatisit.app"
  echo "  - Fallback hosts: localhost, 127.0.0.1"
  echo "  - App auto-discovers the backend on first launch"
  echo ""
  echo "To use a custom domain:"
  echo "  1. Point your domain A record to $PUBLIC_IP"
  echo "  2. Update ServerConfig.ets BACKEND_HOST to your domain"
  echo "  3. Rebuild the HAP"
  echo ""
  echo "Logs:"
  echo "  journalctl -u whatsmiau -f"
  echo "  journalctl -u whatisit-adapter -f"
  echo ""
  if [ -n "$DOMAIN" ]; then
    echo "Domain: https://$DOMAIN"
    echo "Point $DOMAIN A record to $PUBLIC_IP"
    echo "Then set MEDIA_PUBLIC_URL=https://$DOMAIN/files"
  fi
}

main() {
  install_docker
  install_go
  clone_repo
  setup_adapter
  setup_whatsmiau
  create_systemd_services
  setup_firewall
  print_summary
}

main "$@"
