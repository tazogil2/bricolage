Voici le script complet corrigé avec vos 4 points résolus :#!/bin/bash

# installer-rpi.sh
# Installation de SearXNG + Linkding + Page statique sur Raspberry Pi
#   - DuckDNS uniquement
#   - Docker + Nginx + HTTPS (Let's Encrypt)
#   - Configurations séparées par service
#   - Montage automatique /var/www sur clé USB (persistant via fstab)
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
print_step "1/14" "Vérification du stockage USB..."

# Détecte la clé USB (recherche un disque ext4 monté ou disponible)
USB_PARTITION=""

# Essayer de trouver un partition ext4 montée automatiquement
MOUNTED_USB=$(mount | grep -E "/dev/sd[a-z][0-9]" | grep "ext4" | awk '{print $1}' | head -n1)
if [ -n "$MOUNTED_USB" ]; then
    USB_PARTITION="$MOUNTED_USB"
else
    # Essayer de monter ce qui ressemble à une clé USB non montée
    for dev in /dev/sd[a-z][0-9]; do
        if [ -b "$dev" ]; then
            FS_TYPE=$(blkid -s TYPE -o value "$dev" 2>/dev/null)
            if [ "$FS_TYPE" = "ext4" ]; then
                USB_PARTITION="$dev"
                break
            fi
        fi
    done
fi

if [ -z "$USB_PARTITION" ]; then
    print_error "Aucune clé USB formatée ext4 détectée."
    print_warning "Veuillez brancher une clé USB formatée en ext4 et relancer le script."
    print_warning "Formatage possible avec : sudo mkfs.ext4 /dev/sdX"
    exit 1
fi

print_success "Clé USB détectée : ${USB_PARTITION}"

# ── 4. Création des points de montage ────────────────────
print_step "2/14" "Configuration du montage USB..."

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

# Créer le dossier var-www sur la clé
mkdir -p "${USB_MOUNT_POINT}/var-www"

# Monter /var/www sur la clé USB
if mountpoint -q "$WWW_ROOT"; then
    umount "$WWW_ROOT"
fi

mount --bind "${USB_MOUNT_POINT}/var-www" "${WWW_ROOT}"
print_success "/var/www lié à la clé USB"

# ── PERSISTANCE : Ajouter fstab pour survie aux redémarrages ─────────────
UUID=$(blkid -s UUID -o value "${USB_PARTITION}")
if [ -z "$UUID" ]; then
    print_error "Impossible de récupérer l'UUID de la clé USB."
    exit 1
fi

# Supprimer ancienne entrée fstab si elle existe
sed -i '/var-www/d' /etc/fstab 2>/dev/null || true

# Ajouter nouvelle entrée (persistante)
echo "# Mount for /var/www on external USB drive - Autoconfigured by install script" >> /etc/fstab
echo "UUID=${UUID}  /var/www  ext4  defaults,noatime  0  2" >> /etc/fstab
print_success "Montage configuré comme persistant (survivre aux redémarrages)"

# ── 5. Configuration locale ──────────────────────────────
print_step "3/14" "Configuration régionale..."

locale-gen fr_FR.UTF-8
update-locale LANG=fr_FR.UTF-8 LC_ALL=fr_FR.UTF-8
print_success "Locale configurée en fr_FR.UTF-8"

# ── 6. Mise à jour du système ────────────────────────────
print_step "4/14" "Mise à jour du système..."
apt update && apt upgrade -y
print_success "Système mis à jour"

# ── 7. Installation des dépendances ───────────────────────
print_step "5/14" "Installation des dépendances..."

apt install -y git curl jq openssl ufw fail2ban \
    nginx certbot python3-certbot-nginx \
    rsync vim

# ── 8. Installation de Docker ────────────────────────────
print_step "6/14" "Installation de Docker..."

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
        COMPOSE_VERSION="1.29.2"
        curl -L "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" \
            -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
    }
fi
print_success "Docker Compose installé"

# ── 9. Configuration SSH ⚠ SECURITÉ CRITIQUE ─────────────
print_step "7/14" "Sécurisation SSH..."

print_warning "═══════════════════════════════════════════════════════"
print_warning "⚠ IMPORTANT - LIRE ATTENTIVEMENT :"
print_warning ""
print_warning "Le script va désactiver la connexion SSH par mot de passe."
print_warning "Si votre clé SSH ne fonctionne pas, vous serez BLOQUÉ dehors !"
print_warning ""
print_warning "RECOMMANDATION : Ouvrez DEUX sessions SSH avant de continuer :"
print_warning "  Terminal 1 : ssh ${REAL_USER}@$(hostname -I | awk '{print $1}')  ← celui-ci"
print_warning "  Terminal 2 : ssh ${REAL_USER}@$(hostname -I | awk '{print $1}')  ← garde ouvert !"
print_warning ""
print_warning "En cas de problème dans Terminal 1, vous pourrez reconnectez-vous via Terminal 2"
print_warning "et annuler les modifications dans /etc/ssh/sshd_config"
print_warning "═══════════════════════════════════════════════════════"
print_warning ""

read -p "[ATTENTION] Confirmez avoir ouvert une session de secours ? (oui/non) : " CONFIRM_SECURE

if [ "$CONFIRM_SECURE" != "oui" ]; then
    print_warning "Annulation... Revenez quand vous avez une session de secours ouverte !"
    exit 1
fi

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

# Recharger SSH
echo -e "${YELLOW}Redémarrage du service SSH...${NC}"
sleep 3
systemctl reload sshd 2>/dev/null || true
print_success "SSH sécurisé (authentification par clé uniquement)"

print_info "Testez rapidement : si vous pouvez toujours vous connecter, tout est OK."

# ── 10. Configuration du pare-feu ────────────────────────
print_step "8/14" "Configuration du pare-feu (UFW)..."

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

# ── 11. Collecte des informations DNS ⚠ SOUS-DOMAINES ────
print_step "9/14" "Configuration DuckDNS..."

echo ""
print_warning "═══════════════════════════════════════════════════════"
print_warning "⚠ AVANT DE CONTINUER :"
print_warning ""
print_warning "Sur https://www.duckdns.org, vous devez avoir créé TROIS domaines :"
print_warning "  1. Votre domaine principal : exemple"
print_warning "     → donne : exemple.duckdns.org"
print_warning ""
print_warning "  2. Sous-domaine searx : searx"
print_warning "     → donne : searx.example.duckdns.org"
print_warning ""
print_warning "  3. Sous-domaine linkding : ld"
print_WARNING "     → donne : ld.example.duckdns.org"
print_warning ""
print_warning "Sans ces trois entrées, les certificats SSL échoueront !"
print_warning "═══════════════════════════════════════════════════════"
echo ""

read -p "Votre sous-domaine DuckDNS (ex: mon-projet) : " DUCKDNS_SUBDOMAIN
DUCKDNS_DOMAIN="${DUCKDNS_SUBDOMAIN}.duckdns.org"

read -rp "Votre token DuckDNS (visible sur la page principale) : " DUCKDNS_TOKEN
print_success "Domaine configuré : ${DUCKDNS_DOMAIN}"
print_info "Les services seront accessibles sur :"
print_info "  - https://searx.${DUCKDNS_DOMAIN}"
print_info "  - https://ld.${DUCKDNS_DOMAIN}"

# Email pour certificats Let's Encrypt
read -rp "Adresse email pour certificats SSL : " SSL_EMAIL
print_success "Email SSL configuré : ${SSL_EMAIL}"

# ── 12. Création de la structure de projet ───────────────
print_step "10/14" "Création de la structure du projet..."

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
print_step "11/14" "Configuration du miseur DNS..."

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
LINKDING_PASSWORD=$(openssl rand -base64 24)
ADMIN_PASSWORD_LINKDING="CHANGE_ME_NOW_${LINKDING_PASSWORD}"

# ── 15. Création des Docker Composes ─────────────────────
print_step "12/14" "Déploiement des services..."

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

# Configuration initiale SearXNG (avec le VRAI secret interpolé)
cat > "${PROJECT_DIR}/searxng/searxng/settings.yml" << EOF
use_default_settings: true
general:
  debug: false
  instance_name: "Searx Privé"
search:
  safe_search: 0
  autocomplete: "google"
server:
  secret_key: "${SEARX_SECRET}"
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

print_success "Searx configuré avec secret généré"

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
      - LD_SUPERUSER_PASSWORD=${ADMIN_PASSWORD_LINKDING}
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
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';
    access_log /var/log/nginx/access.log main;
    error_log /var/log/nginx/error.log warn;

    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/xml text/javascript application/x-javascript application/xml+rss application/json;

    client_body_buffer_size 128k;
    client_max_body_size 10m;

    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header Referrer-Policy no-referrer always;

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

# Config Searx
SEARX_HOST="searx.${DUCKDNS_DOMAIN}"
cat > "/etc/nginx/sites-available/${DUCKDNS_DOMAIN}-searx" << EOF
server {
    server_name ${SEARX_HOST};

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_redirect off;
        proxy_buffering off;
        proxy_request_buffering off;
        
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        
        client_max_body_size 10m;
    }
}
EOF

# Config Linkding
LINKDING_HOST="ld.${DUCKDNS_DOMAIN}"
cat > "/etc/nginx/sites-available/${DUCKDNS_DOMAIN}-linkding" << EOF
server {
    server_name ${LINKDING_HOST};

    location / {
        proxy_pass http://127.0.0.1:9090;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_redirect off;
        
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}
EOF

# Activer les sites
ln -sf "/etc/nginx/sites-available/${DUCKDNS_DOMAIN}" "/etc/nginx/sites-enabled/"
ln -sf "/etc/nginx/sites-available/${DUCKDNS_DOMAIN}-searx" "/etc/nginx/sites-enabled/"
ln -sf "/etc/nginx/sites-available/${DUCKDNS_DOMAIN}-linkding" "/etc/nginx/sites-enabled/"

rm -f /etc/nginx/sites-enabled/default

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

certbot certonly --webroot \
    -w /var/www/html \
    -d "${DUCKDNS_DOMAIN}" \
    -d "*.${DUCKDNS_DOMAIN}" \
    --non-interactive \
    --agree-tos \
    --email "${SSL_EMAIL}" \
    --no-eff-email \
    --force-renewal

# Restauration config complète
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

systemctl enable certbot.timer 2>/dev/null || true
systemctl start certbot.timer 2>/dev/null || true

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
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            display: flex;
            justify-content: center;
            align-items: center;
            min-height: 100vh;
            margin: 0;
            color: white;
        }
        .container {
            text-align: center;
            padding: 2rem;
        }
        h1 { font-size: 3rem; margin-bottom: 1rem; }
        p { font-size: 1.5rem; opacity: 0.9; }
        .emoji { font-size: 4rem; margin: 1rem 0; }
    </style>
</head>
<body>
    <div class="container">
        <div class="emoji">🚧</div>
        <h1>En construction</h1>
        <p>Ce serveur est en cours de configuration.</p>
        <p>Veuillez revenir plus tard.</p>
    </div>
</body>
</html>
EOF

chown www-data:www-data "${WWW_ROOT}/html/index.html"
print_success "Page d'accueil créée"

# ── 19. Démarrage des conteneurs ─────────────────────────
print_info "Démarrage des services..."

cd "${PROJECT_DIR}/searxng"
docker compose up -d
print_success "Searx démarré"

cd "${PROJECT_DIR}/linkding"
docker compose up -d
print_success "Linkding démarré"

# ── 20. Mises à jour automatiques ────────────────────────
print_info "Configuration des mises à jour automatiques..."

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF

cat > /etc/cron.daily/docker-update << 'EOF'
#!/bin/bash
cd /opt/selfhost/searxng && docker compose pull && docker compose up -d
cd /opt/selfhost/linkding && docker compose pull && docker compose up -d
EOF
chmod +x /etc/cron.daily/docker-update

print_success "Mises à jour automatiques configurées"

# ── 21. Résumé final ─────────────────────────────────────
LOCAL_IP=$(hostname -I | awk '{print $1}')

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✓ Installation terminée avec succès !${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${CYAN}── ACCÈS AUX SERVICES ───────────────────────────────────${NC}"
echo -e "  🏠 Page d'accueil :  https://${DUCKDNS_DOMAIN}"
echo -e "  🔍 Searx          :  https://searx.${DUCKDNS_DOMAIN}"
echo -e "  🔖 Linkding       :  https://ld.${DUCKDNS_DOMAIN}"
echo ""
echo -e "${CYAN}── ACCÈS SSH ────────────────────────────────────────────${NC}"
echo -e "  Commande : ssh ${REAL_USER}@${DUCKDNS_DOMAIN}"
echo -e "  Port     : ${SSH_PORT} (par défaut)"
echo ""
echo -e "${CYAN}── IDENTIFIANTS LINKDING ────────────────────────────────${NC}"
echo -e "  Login    : admin"
echo -e "  Mot de passe : ${ADMIN_PASSWORD_LINKDING}"
echo -e ""
echo -e "${YELLOW}⚠ CHANGEZ CE MOT DE PASSE IMMÉDIATEMENT APRès LA PREMIERE CONNEXION !${NC}"
echo ""
echo -e "${CYAN}── COMMANDES UTILES ─────────────────────────────────────${NC}"
echo -e "  Voir les logs Searx    : docker compose -f /opt/selfhost/searxng/docker-compose.yml logs -f"
echo -e "  Voir les logs Linkding : docker compose -f /opt/selfhost/linkding/docker-compose.yml logs -f"
echo -e "  Redémarrer Searx       : docker compose -f /opt/selfhost/searxng/docker-compose.yml restart"
echo -e "  Redémarrer Linkding    : docker compose -f /opt/selfhost/linkding/docker-compose.yml restart"
echo -e "  Mettre à jour tout     : sudo apt update && sudo apt upgrade -y"
echo -e "  Voir les certificats   : sudo certbot certificates"
echo -e "  Renouveler SSL         : sudo certbot renew"
echo ""
echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}ACTION REQUISE IMMÉDIATEMENT :${NC}"
echo -e "${YELLOW}  CHANGEZ LE MOT DE PASSE LINKDING APRES LA CONNEXION !${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
echo ""
print_success "Script terminé. Merci d'avoir utilisé ce projet !"
