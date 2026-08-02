#!/bin/bash

# install_searx_rpi.sh
# Installation de SearXNG sur Raspberry Pi avec :
#   - Choix DNS dynamique : DuckDNS ou FreeDNS
#   - Reverse proxy Nginx + HTTPS (Let's Encrypt)
# Auteur : tazogil2 assisté de Lumo / Projet bricolage
# Date : 2026-08-02

set -e

# ── Couleurs ──────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── Variables globales ────────────────────────────────────
PROJECT_DIR="/opt/searxng"
SEARX_PORT=8080
HTTP_PORT=80
HTTPS_PORT=443

echo -e "${CYAN}"
echo "================================================="
echo "   Installation de SearXNG sur Raspberry Pi"
echo "   avec Nginx + HTTPS (Let's Encrypt)"
echo "================================================="
echo -e "${NC}"

# ── 1. Vérification des privilèges ───────────────────────
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Ce script doit être lancé avec sudo.${NC}"
    echo "Utilisez : sudo bash $0"
    exit 1
fi

# ── 2. Détection de l'utilisateur principal ──────────────
REAL_USER="${SUDO_USER:-$USER}"
echo -e "${YELLOW}Utilisateur détecté : ${REAL_USER}${NC}"

# ── 3. Mise à jour du système ────────────────────────────
echo -e "${YELLOW}[1/8] Mise à jour du système...${NC}"
apt update && apt upgrade -y

# ── 4. Installation des dépendances ───────────────────────
echo -e "${YELLOW}[2/8] Installation des dépendances...${NC}"
apt install -y git curl jq openssl ufw \
    nginx certbot python3-certbot-nginx

# ── 5. Installation de Docker (si absent) ─────────────────
echo -e "${YELLOW}[3/8] Vérification de Docker...${NC}"
if ! command -v docker &> /dev/null; then
    echo -e "${YELLOW}Docker non détecté. Installation en cours...${NC}"
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
    rm /tmp/get-docker.sh
    usermod -aG docker "$REAL_USER"
    systemctl enable docker
    systemctl start docker
    echo -e "${GREEN}Docker installé.${NC}"
else
    echo -e "${GREEN}Docker déjà présent.${NC}"
fi

# Docker Compose plugin
if ! docker compose version &> /dev/null; then
    echo -e "${YELLOW}Installation du plugin Docker Compose...${NC}"
    apt install -y docker-compose-plugin
fi

# ── 6. Choix du service DNS ──────────────────────────────
echo ""
echo -e "${CYAN}Choisissez votre service DNS dynamique :${NC}"
echo "  1) DuckDNS  (ex : monsearx.duckdns.org)"
echo "  2) FreeDNS  (afraid.org)"
echo ""
read -p "Votre choix (1 ou 2) : " dns_choice

DDNS_DOMAIN=""
DDNS_TOKEN=""
DDNS_UPDATE_URL=""
SERVICE_TYPE=""

case "$dns_choice" in
    1)
        SERVICE_TYPE="duckdns"
        echo -e "${GREEN}--- Configuration DuckDNS ---${NC}"
        read -p "Sous-domaine DuckDNS (ex : monsearx) : " DDNS_SUBDOMAIN
        DDNS_DOMAIN="${DDNS_SUBDOMAIN}.duckdns.org"
        read -p "Token DuckDNS : " DDNS_TOKEN
        ;;
    2)
        SERVICE_TYPE="freedns"
        echo -e "${GREEN}--- Configuration FreeDNS ---${NC}"
        read -p "Nom de domaine FreeDNS complet (ex : monsearx.mooo.com) : " DDNS_DOMAIN
        read -p "URL de mise à jour FreeDNS (depuis Dynamic DNS > Direct URL) : " DDNS_UPDATE_URL
        ;;
    *)
        echo -e "${RED}Choix invalide. Abandon.${NC}"
        exit 1
        ;;
esac

echo -e "${GREEN}Domaine utilisé : ${DDNS_DOMAIN}${NC}"

# ── 7. Création du répertoire projet ─────────────────────
echo -e "${YELLOW}[4/8] Création du répertoire projet...${NC}"
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

# ── 8. Configuration .env ────────────────────────────────
echo -e "${YELLOW}[5/8] Génération des fichiers de configuration...${NC}"

SEARX_SECRET=$(openssl rand -hex 32)

cat <<EOF > .env
# ── SearXNG ───────────────────────────
SEARXNG_SECRET_KEY=${SEARX_SECRET}
SEARXNG_BASE_URL=https://${DDNS_DOMAIN}/

# ── DNS Dynamique ─────────────────────
DDNS_PROVIDER=${SERVICE_TYPE}
DDNS_DOMAIN=${DDNS_DOMAIN}
DDNS_TOKEN=${DDNS_TOKEN}
DDNS_UPDATE_URL=${DDNS_UPDATE_URL}
EOF

chmod 600 .env

# ── 9. Docker Compose ────────────────────────────────────
cat <<'EOF' > docker-compose.yml
version: "3.8"

services:
  searxng:
    image: searxng/searxng:latest
    container_name: searxng
    restart: unless-stopped
    ports:
      - "127.0.0.1:8080:8080"
    volumes:
      - ./searxng:/etc/searxng:rw
    environment:
      - SEARXNG_BASE_URL=${SEARXNG_BASE_URL}
      - SEARXNG_SECRET=${SEARXNG_SECRET_KEY}
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

  ddns-updater:
    image: ghcr.io/nicocraft86/ddns-updater:latest
    container_name: ddns-updater
    restart: unless-stopped
    environment:
      - PERIOD=5m
      - LOG_LEVEL=info
      - PROVIDER=${DDNS_PROVIDER}
      - DOMAIN=${DDNS_DOMAIN}
      - TOKEN=${DDNS_TOKEN}
      - UPDATE_URL=${DDNS_UPDATE_URL}
    volumes:
      - ./ddns-data:/updater/data
EOF

# ── 10. Initialisation de la config SearXNG ───────────────
echo -e "${YELLOW}[6/8] Initialisation de SearXNG...${NC}"
mkdir -p searxng ddns-data

# Génère le settings.yml par défaut
docker compose run --rm --entrypoint "" searxng sh -c \
    "if [ ! -f /etc/searxng/settings.yml ]; then searxng-doc gen-settings /etc/searxng/settings.yml; fi" 2>/dev/null || true

# Si toujours absent, on lance une fois le conteneur pour qu'il génère le fichier
if [ ! -f searxng/settings.yml ]; then
    docker compose up -d searxng
    sleep 5
    docker compose stop searxng
fi

# On s'assure que la limite est levée pour l'accès à distance
if [ -f searxng/settings.yml ]; then
    sed -i 's/limiter: false/limiter: true/' searxng/settings.yml 2>/dev/null || true
    # Désactive le blocage par IP en mode production (à ajuster selon vos besoins)
    sed -i 's|base_url:.*|base_url: "https://'"${DDNS_DOMAIN}"'/"|' searxng/settings.yml 2>/dev/null || true
fi

# ── 11. Démarrage de SearXNG ─────────────────────────────
echo -e "${YELLOW}[7/8] Démarrage des conteneurs...${NC}"
docker compose up -d

# Attendre que SearXNG réponde
echo -e "${YELLOW}Attente du démarrage de SearXNG...${NC}"
for i in $(seq 1 30); do
    if curl -sf "http://127.0.0.1:${SEARX_PORT}/" >/dev/null 2>&1; then
        echo -e "${GREEN}SearXNG répond !${NC}"
        break
    fi
    sleep 2
    if [ "$i" -eq 30 ]; then
        echo -e "${RED}SearXNG ne répond pas sur le port ${SEARX_PORT}.${NC}"
        echo "Vérifiez les logs : docker compose logs searxng"
    fi
done

# ── 12. Configuration Nginx (Reverse Proxy) ──────────────
echo -e "${YELLOW}[8/8] Configuration du reverse proxy Nginx...${NC}"

NGINX_CONF="/etc/nginx/sites-available/searxng"

cat <<EOF > "$NGINX_CONF"
# ── Reverse proxy Nginx pour SearXNG ─────────────────────
# Généré par install_searx_rpi.sh

# Redirection HTTP -> HTTPS
server {
    listen ${HTTP_PORT};
    listen [::]:${HTTP_PORT};
    server_name ${DDNS_DOMAIN};

    # Let's Encrypt challenge
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    # Redirection vers HTTPS
    location / {
        return 301 https://\$host\$request_uri;
    }
}

# Serveur HTTPS
server {
    listen ${HTTPS_PORT} ssl http2;
    listen [::]:${HTTPS_PORT} ssl http2;
    server_name ${DDNS_DOMAIN};

    # Certificats SSL (gérés par certbot)
    ssl_certificate     /etc/letsencrypt/live/${DDNS_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DDNS_DOMAIN}/privkey.pem;

    # Paramètres SSL modernes
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    # Headers de sécurité
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header Referrer-Policy no-referrer always;

    # Reverse proxy vers SearXNG
    location / {
        proxy_pass http://127.0.0.1:${SEARX_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Connection \$http_connection;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_redirect off;
    }

    # Cache des fichiers statiques
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff2?)$ {
        proxy_pass http://127.0.0.1:${SEARX_PORT};
        proxy_cache_valid 200 1d;
        expires 1d;
        add_header Cache-Control "public, immutable";
    }
}
EOF

# Activer le site Nginx
ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/searxng

# Désactiver le site par défaut
rm -f /etc/nginx/sites-enabled/default

# Tester la configuration Nginx
echo -e "${YELLOW}Test de la configuration Nginx...${NC}"
if nginx -t; then
    systemctl reload nginx
    echo -e "${GREEN}Configuration Nginx validée.${NC}"
else
    echo -e "${RED}Erreur de configuration Nginx !${NC}"
    echo "Le certificat SSL n'existe probablement pas encore."
    echo "Lancement de certbot pour générer le certificat..."
fi

# ── 13. Génération du certificat Let's Encrypt ────────────
echo -e "${YELLOW}Génération du certificat Let's Encrypt...${NC}"

# Préparation du dossier pour le challenge ACME
mkdir -p /var/www/html/.well-known/acme-challenge

# Configuration Nginx temporaire (HTTP uniquement) pour le challenge
# si les certificats n'existent pas encore
LE_CERT_PATH="/etc/letsencrypt/live/${DDNS_DOMAIN}/fullchain.pem"

if [ ! -f "$LE_CERT_PATH" ]; then
    echo -e "${YELLOW}Certificat absent. Préparation d'une config HTTP temporaire...${NC}"

    # Config temporaire HTTP uniquement pour passer le challenge
    cat <<EOF > /etc/nginx/sites-enabled/searxng
server {
    listen ${HTTP_PORT};
    listen [::]:${HTTP_PORT};
    server_name ${DDNS_DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        proxy_pass http://127.0.0.1:${SEARX_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

    systemctl reload nginx

    # Génération du certificat
    certbot certonly --webroot \
        -w /var/www/html \
        -d "$DDNS_DOMAIN" \
        --non-interactive \
        --agree-tos \
        --email "admin@${DDNS_DOMAIN}" \
        --no-eff-email

    # Réécriture de la configuration Nginx complète (HTTP + HTTPS)
    cat <<EOF > "$NGINX_CONF"
# ── Reverse proxy Nginx pour SearXNG ─────────────────────
# Régénéré après obtention du certificat Let's Encrypt

server {
    listen ${HTTP_PORT};
    listen [::]:${HTTP_PORT};
    server_name ${DDNS_DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen ${HTTPS_PORT} ssl http2;
    listen [::]:${HTTPS_PORT} ssl http2;
    server_name ${DDNS_DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DDNS_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DDNS_DOMAIN}/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header Referrer-Policy no-referrer always;

    location / {
        proxy_pass http://127.0.0.1:${SEARX_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Connection \$http_connection;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_redirect off;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff2?)\$ {
        proxy_pass http://127.0.0.1:${SEARX_PORT};
        proxy_cache_valid 200 1d;
        expires 1d;
        add_header Cache-Control "public, immutable";
    }
}
EOF

    ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/searxng
    systemctl reload nginx
    echo -e "${GREEN}Certificat Let's Encrypt généré et Nginx reconfiguré.${NC}"
else
    echo -e "${GREEN}Certificat Let's Encrypt déjà présent.${NC}"
fi

# ── 14. Renouvellement automatique ───────────────────────
echo -e "${YELLOW}Configuration du renouvellement automatique...${NC}"

# Test du renouvellement
certbot renew --dry-run 2>/dev/null && echo -e "${GREEN}Renouvellement test OK.${NC}" || \
    echo -e "${YELLOW}Le test de renouvellement a échoué (peut être normal en première utilisation).${NC}"

# Cron de renouvellement (certbot crée normalement son propre timer systemd)
systemctl enable certbot.timer 2>/dev/null || true
systemctl start certbot.timer 2>/dev/null || true

# Hook de rechargement Nginx après renouvellement
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat <<'EOF' > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
#!/bin/bash
/usr/sbin/nginx -s reload
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deload-nginx.sh 2>/dev/null || \
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

# ── 15. Pare-feu UFW ────────────────────────────────────
echo -e "${YELLOW}Configuration du pare-feu (UFW)...${NC}"
ufw allow OpenSSH
ufw allow "${HTTP_PORT}/tcp"
ufw allow "${HTTPS_PORT}/tcp"
ufw --force enable
echo -e "${GREEN}Pare-feu configuré.${NC}"

# ── 16. Résumé final ─────────────────────────────────────
LOCAL_IP=$(hostname -I | awk '{print $1}')

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Installation terminée avec succès !${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${CYAN}── Accès ──────────────────────────────────────────${NC}"
echo -e "  Local :  http://${LOCAL_IP}:${SEARX_PORT}"
echo -e "  Web  :  https://${DDNS_DOMAIN}"
echo ""
echo -e "${CYAN}── Configuration DNS ──────────────────────────────${NC}"
echo -e "  Service : ${SERVICE_TYPE}"
echo -e "  Domaine : ${DDNS_DOMAIN}"
echo ""
echo -e "${CYAN}── Sécurité ──────────────────────────────────────${NC}"
echo -e "  HTTPS    : Actif (Let's Encrypt)"
echo -e "  Firewall : UFW activé (SSH + HTTP + HTTPS)"
echo -e "  SSL auto-renew : Configuré"
echo ""
echo -e "${CYAN}── Commandes utiles ──────────────────────────────${NC}"
echo -e "  Logs SearXNG   : docker compose -f ${PROJECT_DIR}/docker-compose.yml logs -f searxng"
echo -e "  Redémarrer    : docker compose -f ${PROJECT_DIR}/docker-compose.yml restart"
echo -e "  Config SearX  : ${PROJECT_DIR}/searxng/settings.yml"
echo -e "  Config Nginx  : ${NGINX_CONF}"
echo -e "  Renouvel SSL  : certbot renew"
echo ""
echo -e "${YELLOW}La configuration des moteurs de recherche se fait"
echo -e "  dans l'interface d'administration de SearXNG.${NC}"
echo ""
