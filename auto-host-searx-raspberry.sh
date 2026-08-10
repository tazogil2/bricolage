#!/bin/bash

# auto-host-searx-raspberry.sh
# Installation de SearXNG + Page statique sur Raspberry Pi
#   - DuckDNS uniquement (1 domaine, pas de sous-domaine)
#   - Searx sur /searx/
#   - Page statique à la racine
#   - Formatage automatique de la clé USB en ext4
#   - Sécurité: SSH par clé, UFW
#
# Auteur : tazogil2 assisté de Lumo / Projet bricolage
# Date : 2026-08-10

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
HTTP_PORT=80
HTTPS_PORT=443

# ── Fonctions d'affichage ─────────────────────────────────
print_banner() {
  echo -e "${CYAN}"
  echo "=================================================="
  echo "  Auto-hébergement Searx"
  echo "=================================================="
  echo -e "${NC}"
}

print_step() { echo -e "${YELLOW}[${1}] ${2}${NC}"; }
print_success() { echo -e "${GREEN}✓ ${1}${NC}"; }
print_error() { echo -e "${RED}✗ ${1}${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ ${1}${NC}"; }
print_info() { echo -e "${BLUE}ℹ ${1}${NC}"; }

# ── 1. Vérification des privilèges ───────────────────────
if [ "$EUID" -ne 0 ]; then
  print_error "Ce script doit être lancé avec sudo."
  echo "Utilisez : sudo bash $0"
  exit 1
fi

print_banner

REAL_USER="${SUDO_USER:-$USER}"
print_info "Utilisateur détecté : ${REAL_USER}"

# ── 2. Détection et formatage automatique de la clé USB ──
print_step "1/10" "Vérification du stockage USB..."

USB_DEVICE=""
USB_PARTITION=""

# Détecter les disques USB (exclure mmcblk qui est la carte SD du Pi)
for dev in /dev/sd[a-z]; do
  if [ -b "$dev" ]; then
    USB_DEVICE="$dev"
    # Chercher la première partition
    if [ -b "${dev}1" ]; then
      USB_PARTITION="${dev}1"
    else
      USB_PARTITION="$dev"
    fi
    break
  fi
done

if [ -z "$USB_DEVICE" ]; then
  print_error "Aucune clé USB détectée."
  print_warning "Veuillez brancher une clé USB et relancer le script."
  exit 1
fi

print_warning "═══════════════════════════════════════════════════════"
print_warning "⚠ ATTENTION :"
print_warning "La clé USB détectée (${USB_DEVICE}) va être FORMATÉE en ext4."
print_warning "TOUTES LES DONNÉES PRÉSENTES SUR CETTE CLÉ SERONT EFFACÉES !"
print_warning "═══════════════════════════════════════════════════════"
print_warning ""

read -p "Confirmer le formatage de ${USB_DEVICE} ? (oui/non) : " CONFIRM_FORMAT

if [ "$CONFIRM_FORMAT" != "oui" ]; then
  print_error "Formatage annulé. Impossible de continuer sans clé USB."
  exit 1
fi

# Démonter la clé si elle est montée
umount "${USB_DEVICE}" 2>/dev/null || true
umount "${USB_DEVICE}1" 2>/dev/null || true
umount "${USB_DEVICE}"* 2>/dev/null || true

# Effacer toutes les signatures existantes
print_info "Effacement des données existantes..."
wipefs -a "${USB_DEVICE}" 2>/dev/null || true

# Créer une nouvelle table de partitions et une partition unique
print_info "Création de la partition..."
parted -s "${USB_DEVICE}" mklabel msdos
parted -s "${USB_DEVICE}" mkpart primary ext4 0% 100%

# Petite pause pour laisser le kernel détecter la nouvelle partition
sleep 2

USB_PARTITION="${USB_DEVICE}1"

# Formater en ext4
print_info "Formatage en ext4..."
mkfs.ext4 -F "${USB_PARTITION}"

print_success "Clé USB formatée : ${USB_PARTITION}"

# ── 3. Montage USB persistant ────────────────────────────
print_step "2/10" "Configuration du montage USB..."

mkdir -p "$USB_MOUNT_POINT"
mkdir -p "$WWW_ROOT"

mount "${USB_PARTITION}" "${USB_MOUNT_POINT}"
print_success "Clé USB montée sur ${USB_MOUNT_POINT}"

mkdir -p "${USB_MOUNT_POINT}/var-www"

if mountpoint -q "$WWW_ROOT"; then
  umount "$WWW_ROOT"
fi

mount --bind "${USB_MOUNT_POINT}/var-www" "${WWW_ROOT}"
print_success "/var/www lié à la clé USB"

# Persistance fstab
UUID=$(blkid -s UUID -o value "${USB_PARTITION}")
if [ -z "$UUID" ]; then
  print_error "Impossible de récupérer l'UUID de la clé USB."
  exit 1
fi

sed -i '/var-www/d' /etc/fstab 2>/dev/null || true
echo "# Mount for /var/www on external USB drive" >>/etc/fstab
echo "UUID=${UUID}  /var/www  ext4  defaults,noatime  0  2" >>/etc/fstab
print_success "Montage configuré comme persistant"

# ── 4. Mise à jour système ────────────────────────────────
print_step "3/10" "Mise à jour du système..."
apt update && apt upgrade -y
print_success "Système mis à jour"

# ── 5. Installation des dépendances ───────────────────────
print_step "4/10" "Installation des dépendances..."
apt install -y git curl openssl ufw nginx certbot python3-certbot-nginx parted
print_success "Dépendances installées"

# ── 6. Installation de Docker ────────────────────────────
print_step "5/10" "Installation de Docker..."

if ! command -v docker &>/dev/null; then
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

if ! docker compose version &>/dev/null; then
  print_info "Installation du plugin Docker Compose..."
  apt install -y docker-compose-plugin 2>/dev/null || true
fi
print_success "Docker Compose installé"

# ── 7. Configuration SSH ⚠ ──────────────────────────────
print_step "6/10" "Sécurisation SSH..."

print_warning "═══════════════════════════════════════════════════════"
print_warning "⚠ IMPORTANT :"
print_warning "Le script va désactiver la connexion SSH par mot de passe."
print_warning "Ouvrez DEUX sessions SSH avant de continuer !"
print_warning "═══════════════════════════════════════════════════════"
print_warning ""

read -p "[ATTENTION] Confirmez avoir ouvert une session de secours ? (oui/non) : " CONFIRM_SECURE

if [ "$CONFIRM_SECURE" != "oui" ]; then
  print_warning "Annulation... Revenez quand vous avez une session de secours ouverte !"
  exit 1
fi

sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config 2>/dev/null || true
sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config 2>/dev/null || true
systemctl reload sshd 2>/dev/null || true

print_success "SSH sécurisé (authentification par clé uniquement)"

# ── 8. Pare-feu UFW ───────────────────────────────────────
print_step "7/10" "Configuration du pare-feu..."

ufw --force reset 2>/dev/null || true
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw default deny incoming
ufw default allow outgoing
ufw --force enable

print_success "Pare-feu configuré"

# ── 9. Collecte des informations DuckDNS ──────────────────
print_step "8/10" "Configuration DuckDNS..."

print_warning "═══════════════════════════════════════════════════════"
print_warning "Sur https://www.duckdns.org, vous devez avoir créé :"
print_warning "  1. Votre domaine principal (ex: mon-projet)"
print_warning "     → donne : mon-projet.duckdns.org"
print_warning ""
print_warning "C'est tout ! Un seul domaine suffit."
print_warning "Searx sera accessible sur : https://mon-projet.duckdns.org/searx/"
print_warning "═══════════════════════════════════════════════════════"
echo ""

read -p "Votre sous-domaine DuckDNS (ex: mon-projet) : " DUCKDNS_SUBDOMAIN
DUCKDNS_DOMAIN="${DUCKDNS_SUBDOMAIN}.duckdns.org"

read -rp "Votre token DuckDNS : " DUCKDNS_TOKEN
print_success "Domaine configuré : ${DUCKDNS_DOMAIN}"

read -rp "Adresse email pour certificats SSL : " SSL_EMAIL
print_success "Email SSL configuré : ${SSL_EMAIL}"

# ── 10. Création de la structure ─────────────────────────
print_step "9/10" "Création de la structure..."

mkdir -p "${PROJECT_DIR}"
mkdir -p "${WWW_ROOT}/html"
mkdir -p "${PROJECT_DIR}/searxng"
mkdir -p "${WWW_ROOT}/html/.well-known/acme-challenge"

chown -R "${REAL_USER}:${REAL_USER}" "${PROJECT_DIR}"
chown -R "www-data:www-data" "${WWW_ROOT}"
print_success "Structure créée"

# ── 11. DuckDNS updater ──────────────────────────────────
cat >"${PROJECT_DIR}/duckdns-update.sh" <<'EOF'
#!/bin/bash
DUCKDNS_DOMAIN="$1"
DUCKDNS_TOKEN="$2"
curl -k "https://www.duckdns.org/update?domains=${DUCKDNS_DOMAIN}&token=${DUCKDNS_TOKEN}&verbose=true"
EOF

chmod +x "${PROJECT_DIR}/duckdns-update.sh"
"${PROJECT_DIR}/duckdns-update.sh" "${DUCKDNS_DOMAIN}" "${DUCKDNS_TOKEN}"

(
  crontab -l 2>/dev/null
  echo "*/5 * * * * ${PROJECT_DIR}/duckdns-update.sh ${DUCKDNS_DOMAIN} ${DUCKDNS_TOKEN} > /dev/null 2>&1"
) | crontab -
print_success "DuckDNS configuré (mise à jour auto)"

# ── 12. Génération des secrets ───────────────────────────
SEARX_SECRET=$(openssl rand -hex 32)

# ── 13. Docker Compose SearXNG ───────────────────────────
print_step "10/10" "Déploiement de Searx..."

cat >"${PROJECT_DIR}/searxng/docker-compose.yml" <<EOF
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
    logging:
      driver: "json-file"
      options:
        max-size: "1m"
        max-file: "1"
EOF

mkdir -p "${PROJECT_DIR}/searxng/searxng"

cat >"${PROJECT_DIR}/searxng/searxng/settings.yml" <<EOF
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

# ── 14. Configuration Nginx (HTTP temporaire pour SSL) ───
print_info "Configuration Nginx (HTTP temporaire)..."

cat >/etc/nginx/nginx.conf <<'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events { worker_connections 768; }

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" ';
    access_log /var/log/nginx/access.log main;
    error_log /var/log/nginx/error.log warn;

    gzip on;
    gzip_types text/plain text/css application/json application/javascript;

    include /etc/nginx/sites-enabled/*;
}
EOF

# Config HTTP temporaire (pour le challenge Let's Encrypt)
cat >"/etc/nginx/sites-available/${DUCKDNS_DOMAIN}" <<EOF
server {
    listen ${HTTP_PORT};
    listen [::]:${HTTP_PORT};
    server_name ${DUCKDNS_DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
        allow all;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

ln -sf "/etc/nginx/sites-available/${DUCKDNS_DOMAIN}" "/etc/nginx/sites-enabled/"
rm -f /etc/nginx/sites-enabled/default

nginx -t && systemctl reload nginx
print_success "Nginx configuré (HTTP temporaire)"

# ── 15. Certificats SSL ──────────────────────────────────
print_info "Génération des certificats SSL..."

certbot certonly --webroot \
  -w /var/www/html \
  -d "${DUCKDNS_DOMAIN}" \
  --non-interactive \
  --agree-tos \
  --email "${SSL_EMAIL}" \
  --no-eff-email

print_success "Certificats SSL générés"

systemctl enable certbot.timer 2>/dev/null || true
systemctl start certbot.timer 2>/dev/null || true

mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat >/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/bin/bash
/usr/sbin/nginx -s reload
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

# ── 16. Configuration Nginx finale (HTTP + HTTPS) ─────────
print_info "Configuration Nginx finale (HTTPS)..."

cat >"/etc/nginx/sites-available/${DUCKDNS_DOMAIN}" <<EOF
server {
    listen ${HTTP_PORT};
    listen [::]:${HTTP_PORT};
    server_name ${DUCKDNS_DOMAIN};

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
    server_name ${DUCKDNS_DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DUCKDNS_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DUCKDNS_DOMAIN}/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    root /var/www/html;
    index index.html;

    # Page statique à la racine
    location / {
        try_files \$uri \$uri/ =404;
    }

    # Searx sur /searx/
    location /searx/ {
        rewrite ^/searx/(.*)$ /$1 break;
        proxy_pass http://127.0.0.1:${SEARX_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_buffering off;
        proxy_request_buffering off;

        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }

    location = /searx {
        return 301 /searx/;
    }
}
EOF

ln -sf "/etc/nginx/sites-available/${DUCKDNS_DOMAIN}" "/etc/nginx/sites-enabled/"
nginx -t && systemctl reload nginx
print_success "Nginx configuré (HTTPS actif)"

# ── 17. Page d'accueil ───────────────────────────────────
cat >"${WWW_ROOT}/html/index.html" <<EOF
<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Bienvenue</title>
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
        .container { text-align: center; padding: 2rem; }
        h1 { font-size: 3rem; margin-bottom: 1rem; }
        p { font-size: 1.5rem; opacity: 0.9; }
        .emoji { font-size: 4rem; margin: 1rem 0; }
        a { color: #fff; text-decoration: underline; }
    </style>
</head>
<body>
    <div class="container">
        <div class="emoji">👋</div>
        <h1>Bienvenue sur votre serveur</h1>
        <p>Accédez à Searx via : <a href="https://${DUCKDNS_DOMAIN}/searx/">${DUCKDNS_DOMAIN}/searx/</a></p>
    </div>
</body>
</html>
EOF

chown www-data:www-data "${WWW_ROOT}/html/index.html"
print_success "Page d'accueil créée"

# ── 18. Démarrage Searx ──────────────────────────────────
cd "${PROJECT_DIR}/searxng"
docker compose up -d
print_success "Searx démarré"

# ── 19. Mises à jour automatiques ────────────────────────
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF

cat >/etc/cron.daily/docker-update <<'EOF'
#!/bin/bash
cd /opt/selfhost/searxng && docker compose pull && docker compose up -d
EOF
chmod +x /etc/cron.daily/docker-update

# ── 20. Résumé final ─────────────────────────────────────
LOCAL_IP=$(hostname -I | awk '{print $1}')

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✓ Installation terminée avec succès !${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${CYAN}── ACCÈS AUX SERVICES ───────────────────────────────────${NC}"
echo -e "  🏠 Page d'accueil :  https://${DUCKDNS_DOMAIN}"
echo -e "  🔍 Searx          :  https://${DUCKDNS_DOMAIN}/searx/"
echo ""
echo -e "${CYAN}── ACCÈS SSH ────────────────────────────────────────────${NC}"
echo -e "  Commande : ssh ${REAL_USER}@${DUCKDNS_DOMAIN}"
echo ""
echo -e "${CYAN}── COMMANDES UTILES ─────────────────────────────────────${NC}"
echo -e "  Logs Searx       : docker compose -f /opt/selfhost/searxng/docker-compose.yml logs -f"
echo -e "  Redémarrer Searx : docker compose -f /opt/selfhost/searxng/docker-compose.yml restart"
echo -e "  Renouveler SSL   : sudo certbot renew"
echo ""
print_success "Script terminé. Bonne utilisation !"rint_success "Script terminé. Bonne utilisation !"
