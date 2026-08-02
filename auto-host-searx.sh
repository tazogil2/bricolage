#!/bin/bash
set -euo pipefail

# =============================================================================
# Script d'installation : Docker + SearXNG + Nginx (HTTPS) sur Raspberry Pi
# Description :
#   - Met à jour le système
#   - Installe Docker via le script officiel
#   - Configure un DNS dynamique avec FreeDNS
#   - Déploie SearXNG via Docker Compose sous /searx/
#   - Configure Nginx en proxy inverse avec SSL (Let's Encrypt)
#   - Pages statiques à la racine (/)
# =============================================================================

# -----------------------------------------------------------------------------
# Couleurs et fonctions de logging
# -----------------------------------------------------------------------------
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_CYAN='\033[0;36m'
C_BOLD='\033[1m'
C_RESET='\033[0m'

log_info()  { echo -e "${C_GREEN}[INFO]${C_RESET} $1"; }
log_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET} $1"; }
log_step()  { echo -e "\n${C_CYAN}${C_BOLD}=== $1 ===${C_RESET}\n"; }
log_error() { echo -e "${C_RED}[ERROR]${C_RESET} $1"; exit 1; }

# -----------------------------------------------------------------------------
# Variables globales
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/searxng"
CONF_FILE="${INSTALL_DIR}/install.conf"
NGINX_CONF="/etc/nginx/sites-available/searxng"
SEARX_PORT=8080
SEARX_PREFIX="/searx"
STATIC_ROOT="/var/www/html"

# -----------------------------------------------------------------------------
# Vérifications pré-requis
# -----------------------------------------------------------------------------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Ce script doit être exécuté en tant que root (utilisez sudo)."
    fi
}

check_raspberry_pi() {
    local ARCH
    ARCH=$(uname -m)
    
    # Tentative de détection du modèle
    local BOARD_MODEL=""
    if [[ -f /proc/device-tree/model ]]; then
        BOARD_MODEL=$(tr -d '\0' < /proc/device-tree/model)
    elif grep -qi "^Model" /proc/cpuinfo 2>/dev/null; then
        BOARD_MODEL=$(grep -i "^Model" /proc/cpuinfo | cut -d':' -f2 | xargs)
    fi

    if echo "$BOARD_MODEL" | grep -qi "raspberry"; then
        log_info "Raspberry Pi détecté : ${BOARD_MODEL} (${ARCH})"
    else
        log_warn "Carte non identifiée (« ${BOARD_MODEL:-inconnue} ») mais architecture ${ARCH}. Le script continue."
    fi
}

get_codename() {
    . /etc/os-release
    echo "${VERSION_CODENAME:-bookworm}"
}

# -----------------------------------------------------------------------------
# Fichier de configuration
# -----------------------------------------------------------------------------
generate_config_file() {
    if [[ -f "$CONF_FILE" ]]; then
        log_info "Fichier de configuration existant trouvé : $CONF_FILE"
        . "$CONF_FILE"
        return
    fi

    log_step "Création du fichier de configuration"

    mkdir -p "$INSTALL_DIR"

    cat > "$CONF_FILE" << 'EOF'
# =============================================================
# Fichier de configuration pour l'installation SearXNG
# =============================================================

# --- Domaine ---
# Votre nom de domaine FreeDNS (ex : monsite.mooo.com)
DOMAIN=""

# --- FreeDNS Dynamic DNS ---
# Token récupéré sur https://freedns.afraid.org/dynamic/
# Copiez UNIQUEMENT la partie après ? dans l'URL de mise à jour
FREEDNS_TOKEN=""

# Intervalles de mise à jour DNS (en minutes, 5 minimum recommandé)
FREEDNS_UPDATE_INTERVAL=5

# --- SearXNG ---
# Nom de l'instance affiché dans l'interface
SEARX_INSTANCE_NAME="SearXNG"
# Langue par défaut
SEARX_LANG="fr"
# Port interne du conteneur Docker
SEARX_PORT=8080
# Préfixe du sous-dossier (ex: /searx, /search, etc.)
SEARX_PREFIX="/searx"

# --- Let's Encrypt ---
# Adresse e-mail pour les notifications Let's Encrypt
LE_EMAIL=""

# --- Pages statiques ---
# Titre de la page d'accueil statique
STATIC_TITLE="Bienvenue"

# --- Nginx ---
# Rediriger tout le trafic HTTP vers HTTPS
FORCE_HTTPS=true
EOF

    chmod 600 "$CONF_FILE"

    echo ""
    echo -e "${C_YELLOW}${C_BOLD}Le fichier de configuration a été créé : ${CONF_FILE}${C_RESET}"
    echo -e "${C_YELLOW}Veuillez l'éditer avec vos informations avant de relancer le script.${C_RESET}"
    echo ""
    echo "  sudo nano ${CONF_FILE}"
    echo ""
    echo "Champs obligatoires :"
    echo "  - DOMAIN           : votre domaine FreeDNS"
    echo "  - FREEDNS_TOKEN    : votre token FreeDNS"
    echo "  - LE_EMAIL         : votre e-mail pour Let's Encrypt"
    echo ""

    # Édition interactive
    read -rp "Voulez-vous éditer le fichier maintenant ? [O/n] " choice
    case "${choice:-O}" in
        [OoYy]*)
            ${EDITOR:-nano} "$CONF_FILE"
            ;;
        *)
            log_error "Veuillez éditer $CONF_FILE puis relancer le script."
            ;;
    esac

    . "$CONF_FILE"

    # Validation des champs obligatoires
    validate_config
}

validate_config() {
    local errors=0

    if [[ -z "${DOMAIN:-}" ]]; then
        echo -e "${C_RED}  ✗ DOMAIN est vide${C_RESET}"
        errors=$((errors + 1))
    fi

    if [[ -z "${FREEDNS_TOKEN:-}" ]]; then
        echo -e "${C_RED}  ✗ FREEDNS_TOKEN est vide${C_RESET}"
        errors=$((errors + 1))
    fi

    if [[ -z "${LE_EMAIL:-}" ]]; then
        echo -e "${C_RED}  ✗ LE_EMAIL est vide${C_RESET}"
        errors=$((errors + 1))
    fi

    if [[ $errors -gt 0 ]]; then
        log_error "Configuration incomplète. Éditez $CONF_FILE et relancez le script."
    fi

    log_info "Configuration validée : domaine=$DOMAIN | prefixe=${SEARX_PREFIX}"
}

# -----------------------------------------------------------------------------
# Étape 1 : Mise à jour du système
# -----------------------------------------------------------------------------
system_update() {
    log_step "Mise à jour du système"

    apt-get update -y
    apt-get full-upgrade -y
    apt-get autoremove -y
    apt-get autoclean -y

    log_info "Système mis à jour"
}

# -----------------------------------------------------------------------------
# Étape 2 : Installation de Docker (via script officiel)
# -----------------------------------------------------------------------------
install_docker() {
    log_step "Installation de Docker (via script officiel)"

    # Dépendances
    apt-get install -y -qq \
        ca-certificates curl gnupg lsb-release apt-transport-https \
        software-properties-common openssl >/dev/null 2>&1

    # Exécuter le script officiel Docker (maintenu, auto-détecte l'OS)
    curl -fsSL https://get.docker.com | sh

    # Démarrer et activer
    systemctl enable docker.service
    systemctl start docker

    # Ajouter l'utilisateur au groupe docker
    if [[ -n "$SUDO_USER" ]]; then
        usermod -aG docker "$SUDO_USER"
        log_info "Utilisateur '$SUDO_USER' ajouté au groupe docker"
    fi

    # Vérification
    if docker info >/dev/null 2>&1; then
        log_info "Docker installé avec succès (version : $(docker --version | awk '{print $3}' | tr -d ','))"
    else
        log_error "Docker ne démarre pas. Vérifiez les logs : journalctl -u docker"
    fi
}

# -----------------------------------------------------------------------------
# Étape 3 : Installation de Nginx
# -----------------------------------------------------------------------------
install_nginx() {
    log_step "Installation de Nginx"

    apt-get install -y -qq nginx >/dev/null 2>&1
    systemctl enable nginx.service

    log_info "Nginx installé (version : $(nginx -v 2>&1 | awk -F/ '{print $2}'))"
}

# -----------------------------------------------------------------------------
# Étape 4 : Configuration du DNS dynamique FreeDNS
# -----------------------------------------------------------------------------
setup_freedns() {
    log_step "Configuration du DNS dynamique FreeDNS"

    local SCRIPT_PATH="/usr/local/bin/freedns-update.sh"
    local CRON_LABEL="# FreeDNS dynamic DNS update"

    # Script de mise à jour
    cat > "$SCRIPT_PATH" << EOF
#!/bin/bash
# Mise à jour automatique de l'IP chez FreeDNS
# Généré par install.sh

FREEDNS_TOKEN="${FREEDNS_TOKEN}"
LOG_FILE="/var/log/freedns-update.log"

CURRENT_IP=\$(curl -s https://api.ipify.org 2>/dev/null)

if [[ -z "\$CURRENT_IP" ]]; then
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] ERREUR : Impossible de récupérer l'IP publique" >> "\$LOG_FILE"
    exit 1
fi

RESULT=\$(curl -s "https://freedns.afraid.org/dynamic/update.php?\${FREEDNS_TOKEN}" 2>/dev/null)

echo "[\$(date '+%Y-%m-%d %H:%M:%S')] IP=\$CURRENT_IP | Réponse: \$RESULT" >> "\$LOG_FILE"

case "\$RESULT" in
    *updated*|*has not changed*)
        # OK
        ;;
    *)
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] ATTENTION : Réponse inattendue de FreeDNS" >> "\$LOG_FILE"
        ;;
esac
EOF

    chmod +x "$SCRIPT_PATH"

    # Première exécution immédiate
    log_info "Première mise à jour DNS..."
    bash "$SCRIPT_PATH" || log_warn "La première mise à jour DNS a échoué (vérifiez le token)"

    # Tâche cron
    local INTERVAL="${FREEDNS_UPDATE_INTERVAL:-5}"
    ( crontab -l 2>/dev/null | grep -v "$CRON_LABEL" ; \
      echo "$CRON_LABEL" ; \
      echo "*/${INTERVAL} * * * * ${SCRIPT_PATH}" ) \
        | crontab -

    log_info "FreeDNS configuré (mise à jour toutes les ${INTERVAL} min)"
    log_info "Logs : /var/log/freedns-update.log"
}

# -----------------------------------------------------------------------------
# Étape 5 : Création des pages statiques
# -----------------------------------------------------------------------------
setup_static_pages() {
    log_step "Création des pages statiques à la racine"

    mkdir -p "$STATIC_ROOT"

    cat > "$STATIC_ROOT/index.html" << EOF
<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>${STATIC_TITLE:-Bienvenue}</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            max-width: 800px;
            margin: 100px auto;
            padding: 20px;
            line-height: 1.6;
        }
        h1 { color: #6d4aff; }
        a { color: #6d4aff; text-decoration: none; }
        a:hover { text-decoration: underline; }
        .footer { margin-top: 50px; border-top: 1px solid #ddd; padding-top: 20px; }
    </style>
</head>
<body>
    <h1>Bienvenue sur mon serveur</h1>
    <p>Ceci est votre page d'accueil statique.</p>
    <p>Pour accéder au moteur de recherche privé, rendez-vous sur : <strong><a href="${SEARX_PREFIX}/">${SEARX_PREFIX}</a></strong></p>
    <div class="footer">
        <p><small>Hébergé sur Raspberry Pi • SearXNG • Nginx</small></p>
    </div>
</body>
</html>
EOF

    cat > "$STATIC_ROOT/about.html" << EOF
<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <title>À propos</title>
    <style>
        body { font-family: Arial, sans-serif; max-width: 800px; margin: 100px auto; padding: 20px; }
        h1 { color: #6d4aff; }
        a { color: #6d4aff; text-decoration: none; }
    </style>
</head>
<body>
    <h1>À propos</h1>
    <p>Ce serveur héberge :</p>
    <ul>
        <li>Un moteur de recherche privé SearXNG (<a href="${SEARX_PREFIX}/">accès</a>)</li>
        <li>Dans un environnement sécurisé (HTTPS, rate limiting)</li>
    </ul>
    <p><a href="/">Retour à l'accueil</a></p>
</body>
</html>
EOF

    # Permissions
    chown -R www-data:www-data "$STATIC_ROOT"
    chmod -R 755 "$STATIC_ROOT"

    log_info "Pages statiques créées dans $STATIC_ROOT"
}

# -----------------------------------------------------------------------------
# Étape 6 : Configuration SearXNG (Docker Compose)
# -----------------------------------------------------------------------------
setup_searxng() {
    log_step "Configuration de SearXNG (sous-dossier ${SEARX_PREFIX})"

    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"

    # --- docker-compose.yml ---
    cat > docker-compose.yml << 'EOF'
version: "3.7"

services:
  searxng:
    image: searxng/searxng:latest
    container_name: searxng
    restart: unless-stopped
    ports:
      - "127.0.0.1:8080:8080"
    volumes:
      - ./settings.yml:/etc/searxng/settings.yml:ro
    environment:
      - TZ=Europe/Paris
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETGID
      - SETUID
    mem_limit: 256m

networks:
  default:
    driver: bridge
EOF

    # --- settings.yml ---
    local SECRET_KEY
    SECRET_KEY="$(openssl rand -hex 32)"

    cat > settings.yml << EOF
use_default_settings: true

general:
  debug: false
  instance_name: "${SEARX_INSTANCE_NAME}"
  contact_url: false

server:
  secret_key: "${SECRET_KEY}"
  limiter: false
  image_proxy: true
  base_url: "https://${DOMAIN}${SEARX_PREFIX}/"
  url_prefix: "${SEARX_PREFIX}"

ui:
  default_locale: "${SEARX_LANG}"
  default_theme: simple
  infinite_scroll: true
  center_alignment: true

search:
  safe_search: 0
  autocomplete: "google"
  formats:
    - html
    - json

redis:
  url: false

engines:
  - name: google
    engine: google
    shortcut: g
    disabled: false
  - name: duckduckgo
    engine: duckduckgo
    shortcut: ddg
    disabled: false
  - name: wikipedia
    engine: wikipedia
    shortcut: wp
    disabled: false
  - name: brave
    engine: brave
    shortcut: br
    disabled: false
  - name: qwant
    engine: qwant
    shortcut: qw
    disabled: false
EOF

    # --- .env ---
    cat > .env << EOF
SEARXNG_SECRET=${SECRET_KEY}
SEARXNG_HOST=127.0.0.1
SEARXNG_PORT=${SEARX_PORT}
SEARX_PREFIX=${SEARX_PREFIX}
TZ=Europe/Paris
EOF

    chown -R 1000:1000 "$INSTALL_DIR" || true

    log_info "SearXNG configuré dans $INSTALL_DIR"
    log_info "SearXNG sera accessible via : https://${DOMAIN}${SEARX_PREFIX}/"
}

# -----------------------------------------------------------------------------
# Étape 7 : Démarrage de SearXNG
# -----------------------------------------------------------------------------
start_searxng() {
    log_step "Démarrage de SearXNG"

    cd "$INSTALL_DIR"
    docker compose pull
    docker compose up -d

    sleep 5

    if docker compose ps | grep -q "Up"; then
        log_info "SearXNG est en cours d'exécution"
    else
        log_warn "SearXNG ne semble pas démarré. Vérifiez : docker compose logs"
    fi
}

# -----------------------------------------------------------------------------
# Étape 8 : Configuration Nginx (HTTP d'abord, pour Let's Encrypt)
# -----------------------------------------------------------------------------
configure_nginx_http() {
    log_step "Configuration Nginx (HTTP temporaire pour Let's Encrypt)"

    cat > "$NGINX_CONF" << EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location ${SEARX_PREFIX}/ {
        return 301 https://\$host${SEARX_PREFIX}/;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

    ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/searxng
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

    mkdir -p /var/www/html

    nginx -t 2>/dev/null && systemctl restart nginx
    log_info "Nginx configuré en HTTP (temporaire)"
}

# -----------------------------------------------------------------------------
# Étape 9 : Installation des certificats Let's Encrypt
# -----------------------------------------------------------------------------
install_certificates() {
    log_step "Installation des certificats Let's Encrypt"

    # Installation de Certbot
    apt-get install -y -qq certbot python3-certbot-nginx >/dev/null 2>&1

    # Petite pause pour que le DNS se propage
    log_info "Vérification de la résolution DNS..."
    local RESOLVED_IP
    RESOLVED_IP=$(dig +short "$DOMAIN" 2>/dev/null || host "$DOMAIN" 2>/dev/null | grep "has address" | awk '{print $NF}')

    if [[ -z "$RESOLVED_IP" ]]; then
        log_warn "Le domaine $DOMAIN ne résout pas encore. En attente (60s)..."
        sleep 60
        RESOLVED_IP=$(dig +short "$DOMAIN" 2>/dev/null || echo "")
    fi

    local PUBLIC_IP
    PUBLIC_IP=$(curl -s https://api.ipify.org 2>/dev/null || echo "")

    if [[ -n "$RESOLVED_IP" && -n "$PUBLIC_IP" && "$RESOLVED_IP" != "$PUBLIC_IP" ]]; then
        log_warn "Attention : $DOMAIN résout vers $RESOLVED_IP mais l'IP publique est $PUBLIC_IP"
        log_warn "Le certificat Let's Encrypt pourrait échouer. Le script continue..."
    fi

    # Demande du certificat
    certbot certonly \
        --webroot \
        --webroot-path=/var/www/html \
        --email "${LE_EMAIL}" \
        --agree-tos \
        --no-eff-email \
        -d "${DOMAIN}" \
        --non-interactive

    if [[ $? -eq 0 ]]; then
        log_info "Certificat Let's Encrypt obtenu pour ${DOMAIN}"
    else
        log_error "Échec de l'obtention du certificat. Vérifiez le DNS et relancez."
    fi

    # Renouvellement automatique (cron)
    systemctl enable certbot.timer 2>/dev/null || true
    systemctl start certbot.timer 2>/dev/null || true

    log_info "Renouvellement automatique activé"
}

# -----------------------------------------------------------------------------
# Étape 10 : Configuration Nginx finale (HTTPS + proxy + pages statiques)
# -----------------------------------------------------------------------------
configure_nginx_https() {
    log_step "Configuration Nginx finale (HTTPS + proxy + pages statiques)"

    cat > "$NGINX_CONF" << EOF
# Rate limiting zones
limit_req_zone \$binary_remote_addr zone=searx_search:10m rate=5r/s;
limit_req_zone \$binary_remote_addr zone=searx_static:10m rate=20r/s;
limit_req_zone \$binary_remote_addr zone=searx_login:10m rate=1r/s;
limit_req_zone \$binary_remote_addr zone=searx_api:10m rate=2r/s;
limit_conn_zone \$binary_remote_addr zone=searx_conn:10m;

limit_req_status 429;

# Redirection HTTP → HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location ${SEARX_PREFIX}/ {
        return 301 https://\$host${SEARX_PREFIX}/;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

# Serveur HTTPS principal
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};

    # Certificats Let's Encrypt
    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    # Paramètres SSL
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    # En-têtes de sécurité (globaux)
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer" always;

    # ===========================================
    # Pages statiques à la racine (/)
    # ===========================================
    location / {
        root ${STATIC_ROOT};
        index index.html index.htm;
        
        expires 30d;
        add_header Cache-Control "public, immutable";
    }

    # ===========================================
    # SearXNG sous ${SEARX_PREFIX}/
    # ===========================================

    # Recherche principale
    location ${SEARX_PREFIX}/search {
        limit_req zone=searx_search burst=10 nodelay;
        limit_conn zone=searx_conn 20;

        proxy_pass http://127.0.0.1:${SEARX_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;

        add_header Cache-Control "no-store, no-cache, must-revalidate" always;
    }

    # Pages statiques de SearXNG (CSS, JS, images)
    location ${SEARX_PREFIX}/static/ {
        limit_req zone=searx_static burst=50 nodelay;

        proxy_pass http://127.0.0.1:${SEARX_PORT};
        proxy_set_header Host \$host;

        expires 30d;
        add_header Cache-Control "public, immutable";
    }

    # Interface admin / stats (BLOQUÉE - 404)
    location ~ ^${SEARX_PREFIX}/(config|stats)/ {
        deny all;
        return 404;
    }

    # Route principale ${SEARX_PREFIX}/ (formulaire de recherche)
    location ${SEARX_PREFIX}/ {
        limit_req zone=searx_search burst=10 nodelay;
        limit_conn zone=searx_conn 20;

        proxy_pass http://127.0.0.1:${SEARX_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;

        add_header Cache-Control "no-store, no-cache, must-revalidate" always;
    }

    # API SearXNG
    location ${SEARX_PREFIX}/api/ {
        limit_req zone=searx_api burst=5 nodelay;

        proxy_pass http://127.0.0.1:${SEARX_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;

        add_header Cache-Control "no-store, no-cache, must-revalidate" always;
    }
}
EOF

    # Hook de renouvellement : reload nginx après obtention du nouveau certif
    local HOOK_DIR="/etc/letsencrypt/renewal-hooks/deploy"
    mkdir -p "$HOOK_DIR"
    cat > "$HOOK_DIR/reload-nginx.sh" << 'EOF'
#!/bin/bash
/usr/bin/systemctl reload nginx
EOF
    chmod +x "$HOOK_DIR/reload-nginx.sh"

    nginx -t 2>/dev/null && systemctl restart nginx

    log_info "Nginx configuré en HTTPS avec proxy inverse"
}

# -----------------------------------------------------------------------------
# Étape 11 : Vérification finale
# -----------------------------------------------------------------------------
final_checks() {
    log_step "Vérifications finales"

    local OK=0
    local FAIL=0

    check_service() {
        if systemctl is-active --quiet "$1" 2>/dev/null; then
            echo -e "  ${C_GREEN}✓${C_RESET} $1 : actif"
            OK=$((OK + 1))
        else
            echo -e "  ${C_RED}✗${C_RESET} $1 : inactif"
            FAIL=$((FAIL + 1))
        fi
    }

    check_service "docker"
    check_service "nginx"

    if docker compose -f "$INSTALL_DIR/docker-compose.yml" ps 2>/dev/null | grep -q "Up"; then
        echo -e "  ${C_GREEN}✓${C_RESET} SearXNG : en cours d'exécution"
        OK=$((OK + 1))
    else
        echo -e "  ${C_RED}✗${C_RESET} SearXNG : arrêté"
        FAIL=$((FAIL + 1))
    fi

    if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
        echo -e "  ${C_GREEN}✓${C_RESET} Certificat Let's Encrypt : présent"
        OK=$((OK + 1))
    else
        echo -e "  ${C_RED}✗${C_RESET} Certificat Let's Encrypt : absent"
        FAIL=$((FAIL + 1))
    fi

    if crontab -l 2>/dev/null | grep -q "freedns-update"; then
        echo -e "  ${C_GREEN}✓${C_RESET} FreeDNS DNS dynamique : cron actif"
        OK=$((OK + 1))
    else
        echo -e "  ${C_RED}✗${C_RESET} FreeDNS DNS dynamique : cron manquant"
        FAIL=$((FAIL + 1))
    fi

    echo ""
    echo -e "  Résultat : ${C_GREEN}$OK OK${C_RESET} / ${C_RED}$FAIL échec(s)${C_RESET}"
}

# -----------------------------------------------------------------------------
# Résumé final
# -----------------------------------------------------------------------------
show_summary() {
    local LOCAL_IP
    LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')

    cat << EOF

${C_GREEN}╔══════════════════════════════════════════════════════╗
║         INSTALLATION TERMINÉE AVEC SUCCÈS            ║
╚══════════════════════════════════════════════════════╝${C_RESET}

${C_BOLD}Accès :${C_RESET}
  • Page d'accueil   : https://${DOMAIN}/
  • SearXNG          : https://${DOMAIN}${SEARX_PREFIX}/
  • SearXNG (local)  : http://${LOCAL_IP}:${SEARX_PORT}

${C_BOLD}Services installés :${C_RESET}
  • Docker           $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')
  • Nginx            $(nginx -v 2>&1 | awk -F/ '{print $2}')
  • SearXNG          $(docker compose -f "$INSTALL_DIR/docker-compose.yml" images 2>/dev/null | grep searxng | awk '{print $2}')
  • Certbot          $(certbot --version 2>/dev/null | awk '{print $2}')
  • FreeDNS          Cron actif (toutes les ${FREEDNS_UPDATE_INTERVAL} min)

${C_BOLD}Fichiers importants :${C_RESET}
  • Config générale   : ${CONF_FILE}
  • Docker Compose    : ${INSTALL_DIR}/docker-compose.yml
  • SearXNG settings  : ${INSTALL_DIR}/settings.yml
  • Nginx             : ${NGINX_CONF}
  • Certificats SSL   : /etc/letsencrypt/live/${DOMAIN}/
  • Log FreeDNS       : /var/log/freedns-update.log
  • Pages statiques   : ${STATIC_ROOT}/

${C_BOLD}Commandes utiles :${C_RESET}
  • Logs SearXNG     : cd ${INSTALL_DIR} && docker compose logs -f
  • Redémarrer       : cd ${INSTALL_DIR} && docker compose restart
  • Logs Nginx       : journalctl -u nginx -f
  • Tester SSL       : curl -I https://${DOMAIN}/
  • Renouveler certif: sudo certbot renew --dry-run
  • Logs FreeDNS     : tail -f /var/log/freedns-update.log

${C_YELLOW}${C_BOLD}Pensez à ouvrir les ports 80 et 443 sur votre routeur/box${C_RESET}
${C_YELLOW}vers l'IP locale du Raspberry Pi : ${LOCAL_IP}${C_RESET}

${C_BOLD}Architecture :${C_RESET}
  ┌─────────────┐      ┌──────────────────┐      ┌─────────────┐
  │ Internet    │──────│ Nginx (443/HTTPS)│──────│ SearXNG     │
  │             │      │ + pages statiques│      │ (:8080 local)│
  └─────────────┘      └──────────────────┘      └─────────────┘

  /            → pages statiques (${STATIC_ROOT}/)
  ${SEARX_PREFIX}/         → SearXNG (proxy inverse)

EOF
}

# =============================================================================
# Point d'entrée
# =============================================================================
main() {
    echo -e "${C_CYAN}${C_BOLD}"
    echo "╔══════════════════════════════════════════════╗"
    echo "║  Installation Docker + SearXNG + Nginx (RPi) ║"
    echo "║  avec FreeDNS + Let's Encrypt                ║"
    echo "╚══════════════════════════════════════════════╝"
    echo -e "${C_RESET}"

    check_root
    check_raspberry_pi

    # Génère ou charge la configuration AVANT toute chose
    generate_config_file

    # Étapes d'installation
    system_update
    install_docker
    install_nginx
    setup_static_pages
    setup_freedns
    setup_searxng
    start_searxng
    configure_nginx_http
    install_certificates
    configure_nginx_https
    final_checks
    show_summary
}

main "$@"
