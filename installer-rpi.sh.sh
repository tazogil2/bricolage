#!/bin/bash

# installer-rpi.sh
# Installation de SearXNG + Linkding + Page statique sur Raspberry Pi
#   - DuckDNS uniquement
#   - Docker + Nginx + HTTPS (Let's Encrypt)
#   - Configurations séparées par service
#   - Montage automatique /var/www sur clé USB
#   - Sécurité: SSH par clé, UFW, fail2ban
#
# Auteur : tazogil2 assisté de Lumo / Projet bricolage
# Date : 2026-08-09

set -e

# ── Couleurs ──────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'

# ── Variables globales ────────────────────────────────────
USB_MOUNT_POINT="/mnt/searx-storage"
WWW_ROOT="/var/www"
PROJECT_DIR="/opt/selfhost"
SEARX_PORT=8080
LINKDING_PORT=9090
HTTP_PORT=80
HTTPS_PORT=443
SSH_PORT=22

# ── Fonctions d'affichage ─────────────────────────────────
print_banner() {
    echo -e "${CYAN}"
    echo "============================================================"
    echo "  Auto-hébergement sur Raspberry Pi"
    echo "  Searx + Linkding + Pages statiques"
    echo "============================================================"
    echo -e "${NC}"
}

print_step() {
    echo -e "${YELLOW}[${1}] ${2}${NC}"
}

print_success() {
    echo -e "${GREEN}✓ ${1}${NC}"
}

print_error() {
    echo -e "${RED}✗ ${1}${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ ${1}${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ ${1}${NC}"
}

# ── 1. Vérification des privilèges ───────────────────────
if [ "$EUID" -ne 0 ]; then
    print_error "Ce script doit être lancé avec sudo."
    echo "Utilisez : sudo bash $0"
    exit 1
fi

print_banner

# ── 2. Détection de l'utilisateur principal ──────────────
REAL_USER="${SUDO_USER:-$USER}"
print_info "Utilisateur détecté : ${REAL_USER}"

# ── 3. Vérification de la clé USB ────────────────────────
print_step "1/12" "Vérification du stockage USB..."

# Détecte la clé USB (suppose qu'elle est montée automatiquement ou à monter)
USB_DEVICE=$(find /dev -name "sd*" -type b 2>/dev/null | grep -v "sd[a-z]1$" | head -n1)

if [ -z "$USB_DEVICE" ]; then
    # Essayer de trouver un disque USB connecté
    USB_DEVICE=$(lsblk -ndo NAME,FSTYPE,MOUNTPOINT | awk '$2=="ext4" {print $1}' | head -n1)
fi

if [ -z "$USB_DEVICE" ]; then
    print_error "Aucune clé USB formatée ext4 détectée."
    print_warning "Veuillez brancher une clé USB formatée en ext4 et relancer le script."
    print_warning "Formatage possible avec : sudo mkfs.ext4 /dev/sdX"
    exit 1
fi

USB_PARTITION="/dev/${USB_DEVICE}"
print_success "Clé USB détectée : ${USB_PARTITION}"

# ── 4. Création des points de montage ────────────────────
print_step "2/12" "Configuration du montage USB..."

mkdir -p "$USB_MOUNT_POINT"
mkdir -p "$WWW_ROOT"

# Vérifier si déjà monté
if mountpoint -q "$USB_MOUNT_POINT"; then
    print_warning "Point de montage déjà actif, démonter..."
    umount "$USB_MOUNT_POINT"
fi

# Monter la clé USB
mount "${USB_PARTITION}" "${USB_MOUNT_POINT}"
print_success "Clé USB montée sur ${USB_MOUNT_POINT}"

# Monter /var/www sur la clé USB
if mountpoint -q "$WWW_ROOT"; then
    umount "$WWW_ROOT"
fi

# Créer un lien symbolique ou monter directement
mount --bind "${USB_MOUNT_POINT}/var-www" "${WWW_ROOT}" 2>/dev/null || {
    mkdir -p "${USB_MOUNT_POINT}/var-www"
    mount --bind "${USB_MOUNT_POINT}/var-www" "${WWW_ROOT}"
}
print_success "/var/www lié à la clé USB"

# ── 5. Configuration locale ──────────────────────────────
print_step "3/12" "Configuration régionale..."

locale-gen fr_FR.UTF-8
update-locale LANG=fr_FR.UTF-8 LC_ALL=fr_FR.UTF-8
print_success "Locale configurée en fr_FR.UTF-8"

# ── 6. Mise à jour du système ────────────────────────────
print_step "4/12" "Mise à jour du système..."
apt update && apt upgrade -y
print_success "Système mis à jour"

# ── 7. Installation des dépendances ───────────────────────
print_step "5/12" "Installation des dépendances..."

apt install -y git curl jq openssl ufw fail2ban \
    nginx certbot python3-certbot-nginx \
    rsync vim

# ── 8. Installation de Docker ────────────────────────────
print_step "6/12" "Installation de Docker..."

if ! command -v docker &> /dev/null; then
    print_info "Docker non détecté. Installation en cours..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
    rm /tmp/get-docker.sh
    usermod -aG docker "$REAL_USER"
    systemctl enable docker
    systemctl start docker
    print_success "Docker installé"
else
    print_success "Docker déjà présent"
fi

# Plugin Docker Compose
if ! docker compose version &> /dev/null; then
    print_info "Installation du plugin Docker Compose..."
    apt install -y docker-compose-plugin 2>/dev/null || {
        # Fallback: installation manuelle
        COMPOSE_VERSION="1.29.2"
        curl -L "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" \
            -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
    }
fi
print_success "Docker Compose installé"

# ── 9. Configuration SSH ─────────────────────────────────
print_step "7/12" "Sécurisation SSH..."

# Désactiver la connexion par mot de passe
sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config 2>/dev/null || true
sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config 2>/dev/null || true

# Désactiver root login
sed -i 's/^PermitRootLogin yes/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config 2>/dev/null || true
sed -i 's/^#PermitRootLogin prohibit-password/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config 2>/dev/null || true

# Forcer la demande de mot de passe pour sudo
cat > /etc/sudoers.d/90-require-passwd << EOF
Defaults    passwd_timestamp
EOF

# Recharger SSH (attention: ne pas faire pendant la session actuelle !)
echo -e "${YELLOW}Note: Redémarrage SSH dans 5 secondes...${NC}"
sleep 5
systemctl reload sshd 2>/dev/null || true
print_success "SSH sécurisé (authentification par clé uniquement)"

print_warning "⚠ IMPORTANT: Conservez une session ouverte avant de fermer ce terminal !"
print_warning "En cas de problème, vous pourrez reconnectez-vous avec votre clé SSH."

# ── 10. Configuration du pare-feu ────────────────────────
print_step "8/12" "Configuration du pare-feu (UFW)..."

# Sauvegarder les règles existantes
ufw --force reset 2>/dev/null || true

ufw allow "${SSH_PORT}/tcp" comment 'SSH'
ufw allow "${HTTP_PORT}/tcp" comment 'HTTP'
ufw allow "${HTTPS_PORT}/tcp" comment 'HTTPS'
ufw default deny incoming
ufw default allow outgoing
ufw --force enable

# Fail2ban
systemctl enable fail2ban
systemctl start fail2ban

# Configuration fail2ban pour SSH
cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 3600
EOF

systemctl restart fail2ban
print_success "Pare-feu et Fail2ban configurés"

# ── 11. Collecte des informations DNS ────────────────────
print_step "9/12" "Configuration DuckDNS..."

echo ""
print_info "Vous devez avoir créé votre domaine sur https://www.duckdns.org"
echo ""

read -p "Votre sous-domaine DuckDNS (ex: mon-projet) : " DUCKDNS_SUBDOMAIN
DUCKDNS_DOMAIN="${DUCKDNS_SUBDOMAIN}.duckdns.org"

read -rp "Votre token DuckDNS (visible sur la page principale) : " DUCKDNS_TOKEN
print_success "Domaine configuré : ${DUCKDNS_DOMAIN}"

# Email pour certificats Let's Encrypt
read -rp "Adresse email pour certificats SSL : " SSL_EMAIL
print_success "Email SSL configuré : ${SSL_EMAIL}"

# ── 12. Création de la structure de projet ───────────────
print_step "10/12" "Création de la structure du projet..."

mkdir -p "${PROJECT_DIR}"
mkdir -p "${WWW_ROOT}/html"
mkdir -p "${WWW_ROOT}/static"
mkdir -p "${PROJECT_DIR}/searxng"
mkdir -p "${PROJECT_DIR}/linkding"
mkdir -p "${WWW_ROOT}/html/.well-known/acme-challenge"
mkdir -p "${PROJECT_DIR}/nginx/conf.d"

chown -R "${REAL_USER}:${REAL_USER}" "${PROJECT_DIR}"
chown -R "www-data:www-data" "${WWW_ROOT}"
print_success "Structure créée"

# ── 13. Configuration DuckDNS updater ────────────────────
print_step "11/12" "Configuration du更新ateur DNS..."

cat > "${PROJECT_DIR}/duckdns-update.sh" << 'EOF'
#!/bin/bash
DUCKDNS_DOMAIN="$1"
DUCKDNS_TOKEN="$2"
curl -k "https://www.duckdns.org/update?domains=${DUCKDNS_DOMAIN}&token=${DUCKDNS_TOKEN}&verbose=true"
EOF

chmod +x "${PROJECT_DIR}/duckdns-update.sh"

# Mettre à jour immédiatement
"${PROJECT_DIR}/duckdns-update.sh" "${DUCKDNS_DOMAIN}" "${DUCKDNS_TOKEN}"

# Cron job pour mise à jour toutes les 5 minutes
(crontab -l 2>/dev/null; echo "*/5 * * * * ${PROJECT_DIR}/duckdns-update.sh ${DUCKDNS_DOMAIN} ${DUCKDNS_TOKEN} > /dev/null 2>&1") | crontab -
print_success "DuckDNS configuré (mise à jour automatique)"

# ── 14. Génération des secrets ───────────────────────────
print_info "Génération des secrets..."

SEARX_SECRET=$(openssl rand -hex 32)
LINKDING_SECRET=$(openssl rand -hex 32)

# ── 15. Création des Docker Composes ─────────────────────
print_step "12/12" "Déploiement des services..."

# === SearXNG ===
cat > "${PROJECT_DIR}/searxng/docker-compose.yml" << EOF
version: "3.8"

services:
  searxng:
    image: searxng/searxng:latest
    container_name: searxng
    restart: unless-stopped
    ports:
      - "127.0.0.1:${SEARX_PORT}:8080"
    volumes:
      - ./searxng:/etc/searxng:rw
    environment:
      - SEARXNG_BASE_URL=https://${DUCKDNS_DOMAIN}/searx/
      - SEARXNG_SECRET=${SEARX_SECRET}
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETGID
      - SETUID
    mem_limit: 512m
    networks:
      - selfhost
    logging:
      driver: "json-file"
      options:
        max-size: "1m"
        max-file: "1"

networks:
  selfhost:
    driver: bridge
EOF

mkdir -p "${PROJECT_DIR}/searxng/searxng"

# Configuration initiale SearXNG
cat > "${PROJECT_DIR}/searxng/searxng/settings.yml" << 'EOF'
use_default_settings: true
general:
  debug: false
  instance_name: "Searx Privé"
search:
  safe_search: 0
  autocomplete: "google"
server:
  secret_key: "{{ SECRET }}"
  limiter: false
  image_proxy: true
ui:
  static_use_hash: true
  default_theme: simple
outgoing:
  request_timeout: 3.0
  max_request_timeout: 10.0
  pool_connections: 20
  pool_maxsize: 10
EOF

# === Linkding ===
cat > "${PROJECT_DIR}/linkding/docker-compose.yml" << EOF
version: "3.8"

services:
  linkding:
    image: sissbruecker/linkding:latest
    container_name: linkding
    restart: unless-stopped
    ports:
      - "127.0.0.1:${LINKDING_PORT}:9090"
    volumes:
      - ./linkding-data:/var/lib/linkding:rw
    environment:
      - LD_SUPERUSER_NAME=admin
      - LD_SUPERUSER_PASSWORD=CHANGE_ME_NOW
      - LD_TITLE=Linkding Privé
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETGID
      - SETUID
    mem_limit: 256m
    networks:
      - selfhost
    logging:
      driver: "json-file"
      options:
        max-size: "1m"
        max-file: "1"

networks:
  selfhost:
    driver: bridge
EOF

mkdir -p "${PROJECT_DIR}/linkding/linkding-data"

# ── 16. Configuration Nginx ──────────────────────────────
print_info "Configuration Nginx..."

# Configuration globale Nginx
cat > /etc/nginx/nginx.conf << 'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 768;
}

http {
    # Paramètres de base
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # Logging
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';
    access_log /var/log/nginx/access.log main;
    error_log /var/log/nginx/error.log warn;

    # Gzip
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/xml text/javascript application/x-javascript application/xml+rss application/json;

    # Limites
    client_body_buffer_size 128k;
    client_max_body_size 10m;

    # Security headers (globaux)
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header Referrer-Policy no-referrer always;

    # Rate limiting
    limit_req_zone $binary_remote_addr zone=global:10m rate=10r/s;

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF

# Redirection HTTP → HTTPS + Let's Encrypt challenge
cat > "/etc/nginx/sites-available/${DUCKDNS_DOMAIN}" << EOF
server {
    listen ${HTTP_PORT};
    listen [::]:${HTTP_PORT};
    server_name ${DUCKDNS_DOMAIN} *.${DUCKDNS_DOMAIN};

    # Let's Encrypt challenge
    location /.well-known/acme-challenge/ {
        root /var/www/html;
        allow all;
    }

    # Redirection HTTPS
    location / {
        return 301 https://\$host\$request_uri;
    }
}

# Serveur HTTPS principal
server {
    listen ${HTTPS_PORT} ssl http2;
    listen [::]:${HTTPS_PORT} ssl http2;
    server_name ${DUCKDNS_DOMAIN} *.${DUCKDNS_DOMAIN};

    # Certificats SSL
    ssl_certificate     /etc/letsencrypt/live/${DUCKDNS_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DUCKDNS_DOMAIN}/privkey.pem;

    # Paramètres SSL modernes
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    # HSTS
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    # Root pour page statique
    root /var/www/html;
    index index.html;

    # Page "Work in Progress"
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

# Config Searx
cat > "/etc/nginx/sites-available/${DUCKDNS_DOMAIN}-searx" << 'EOF'
server {
    server_name searx.<domain>;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_redirect off;
        proxy_buffering off;
        proxy_request_buffering off;
        
        # Timeout anti-saturation
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        
        # Limitation taille requête
        client_max_body_size 10m;
    }
}
EOF

# Remplacer <domain> par le vrai domaine
sed -i "s/<domain>/<\/domain>/g; s/<\/domain>/$(echo ${DUCKDNS_DOMAIN} | sed 's/\./\\\./g')/g" "/etc/nginx/sites-available/${DUCKDNS_DOMAIN}-searx"
sed -i "s/searx\.</searx./g" "/etc/nginx/sites-available/${DUCKDNS_DOMAIN}-searx"

# Config Linkding
cat > "/etc/nginx/sites-available/${DUCKDNS_DOMAIN}-linkding" << 'EOF'
server {
    server_name ld.<domain>;

    location / {
        proxy_pass http://127.0.0.1:9090;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_redirect off;
        
        # Timeout
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}
EOF

# Remplacer <domain> par le vrai domaine
sed -i "s/<domain>/<\/domain>/g; s/<\/domain>/$(echo ${DUCKDNS_DOMAIN} | sed 's/\./\\\./g')/g" "/etc/nginx/sites-available/${DUCKDNS_DOMAIN}-linkding"
sed -i "s/ld\.</ld./g" "/etc/nginx/sites-available/${DUCKDNS_DOMAIN}-linkding"

# Activer les sites
ln -sf "/etc/nginx/sites-available/${DUCKDNS_DOMAIN}" "/etc/nginx/sites-enabled/"
ln -sf "/etc/nginx/sites-available/${DUCKDNS_DOMAIN}-searx" "/etc/nginx/sites-enabled/"
ln -sf "/etc/nginx/sites-available/${DUCKDNS_DOMAIN}-linkding" "/etc/nginx/sites-enabled/"

# Désactiver le site par défaut
rm -f /etc/nginx/sites-enabled/default

# Test configuration Nginx
nginx -t
if [ $? -eq 0 ]; then
    systemctl reload nginx
    print_success "Configuration Nginx validée"
else
    print_error "Erreur de configuration Nginx!"
    exit 1
fi

# ── 17. Certificats Let's Encrypt ────────────────────────
print_info "Génération des certificats SSL..."

# Config temporaire HTTP uniquement pour le challenge ACME
cat > "/etc/nginx/sites-enabled/${DUCKDNS_DOMAIN}" << EOF
server {
    listen ${HTTP_PORT};
    listen [::]:${HTTP_PORT};
    server_name ${DUCKDNS_DOMAIN} *.${DUCKDNS_DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
        allow all;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

systemctl reload nginx

# Génération certificat
certbot certonly --webroot \
    -w /var/www/html \
    -d "${DUCKDNS_DOMAIN}" \
    -d "*.${DUCKDNS_DOMAIN}" \
    --non-interactive \
    --agree-tos \
    --email "${SSL_EMAIL}" \
    --no-eff-email \
    --force-renewal

# Restauration config Nginx complète
cat > "/etc/nginx/sites-available/${DUCKDNS_DOMAIN}" << EOF
server {
    listen ${HTTP_PORT};
    listen [::]:${HTTP_PORT};
    server_name ${DUCKDNS_DOMAIN} *.${DUCKDNS_DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
        allow all;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen ${HTTPS_PORT} ssl http2;
    listen [::]:${HTTPS_PORT} ssl http2;
    server_name ${DUCKDNS_DOMAIN} *.${DUCKDNS_DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DUCKDNS_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DUCKDNS_DOMAIN}/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    root /var/www/html;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

ln -sf "/etc/nginx/sites-available/${DUCKDNS_DOMAIN}" "/etc/nginx/sites-enabled/"
systemctl reload nginx

print_success "Certificats SSL générés"

# Renouvellement automatique
systemctl enable certbot.timer 2>/dev/null || true
systemctl start certbot.timer 2>/dev/null || true

# Hook de rechargement Nginx
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh << 'EOF'
#!/bin/bash
/usr/sbin/nginx -s reload
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

# ── 18. Page "Work in Progress" ──────────────────────────
cat > "${WWW_ROOT}/html/index.html" << 'EOF'
<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>En construction</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, s
