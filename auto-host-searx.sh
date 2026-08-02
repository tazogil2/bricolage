#!/bin/bash
set -euo pipefail

# =============================================================================
# Script d'installation : Docker + SearXNG + Nginx (HTTPS) sur Raspberry Pi
# Auteur : Généré par Lumo
# Description :
#   - Met à jour le système
#   - Installe Docker, Nginx
#   - Configure un DNS dynamique avec FreeDNS
#   - Déploie SearXNG via Docker Compose
#   - Configure Nginx en proxy inverse avec SSL (Let's Encrypt)
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

log_info() { echo -e "${C_GREEN}[INFO]${C_RESET} $1"; }
log_warn() { echo -e "${C_YELLOW}[WARN]${C_RESET} $1"; }
log_step() { echo -e "\n${C_CYAN}${C_BOLD}=== $1 ===${C_RESET}\n"; }
log_error() {
  echo -e "${C_RED}[ERROR]${C_RESET} $1"
  exit 1
}

# -----------------------------------------------------------------------------
# Variables globales
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/searxng"
CONF_FILE="${INSTALL_DIR}/install.conf"
NGINX_CONF="/etc/nginx/sites-available/searxng"
SEARX_PORT=8080

# -----------------------------------------------------------------------------
# Vérifications pré-requis
# -----------------------------------------------------------------------------
check_root() {
  if [[ $EUID -ne 0 ]]; then
    log_error "Ce script doit être exécuté en tant que root (utilisez sudo)."
  fi
}

check_raspberry_pi() {
  if ! grep -qi "raspberry\|rpi\|aarch64\|arm" /proc/cpuinfo 2>/dev/null &&
    [[ "$(uname -m)" != "aarch64" ]] &&
    [[ "$(uname -m)" != "armv7l" ]]; then
    log_warn "Architecture non-RPi détectée ($(uname -m)). Le script continue mais n'est pas optimisé pour cette plateforme."
  fi
  log_info "Architecture détectée : $(uname -m)"
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

  cat >"$CONF_FILE" <<'EOF'
# =============================================================
# Fichier de configuration pour l'installation SearXNG
# =============================================================

# --- Domaine ---
# Votre nom de domaine FreeDNS (ex : monsite.mooo.com)
DOMAIN=""

# --- FreeDNS Dynamic DNS ---
# Token récupéré sur https://freedns.afraid.org/dynamic/
# Dans la section "Dynamic DNS", cliquez sur "Quick Cron Example"
# ou récupérez l'URL complète qui ressemble à :
# https://freedns.afraid.org/dynamic/update.php?XXXXXXXXXXXXXXXX
# Mettez UNIQUEMENT le token (la partie après ? )
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

# --- Let's Encrypt ---
# Adresse e-mail pour les notifications Let's Encrypt
LE_EMAIL=""

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

  log_info "Configuration validée : domaine=$DOMAIN"
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
# Étape 2 : Installation de Docker (adapté Raspberry Pi / ARM)
# -----------------------------------------------------------------------------
install_docker() {
    log_step "Installation de Docker"
    
    # 1. Pré-requis
    apt-get update -y
    apt-get install -y -qq \
        ca-certificates curl gnupg lsb-release \
        software-properties-common >/dev/null 2>&1
    
    # 2. Exécuter le script officiel (plus robuste et maintenu)
    curl -fsSL https://get.docker.com | sh
    
    # 3. Ajouter l'utilisateur au groupe docker
    if [[ -n "$SUDO_USER" ]]; then
        usermod -aG docker "$SUDO_USER"
        log_info "Utilisateur '$SUDO_USER' ajouté au groupe docker"
    fi
    
    # 4. Démarrer et activer
    systemctl enable docker.service
    systemctl start docker
    
    # 5. Vérification
    if docker info >/dev/null 2>&1; then
        log_info "Docker installé avec succès via le script officiel"
    else
        log_error "Docker ne démarre pas : journalctl -u docker"
    fi
}

# -----------------------------------------------------------------------------
# Étape 3 : Installation de Nginx
# -----------------------------------------------------------------------------
install_nginx() {
  log_step "Installation de Nginx"

  apt-get install -y -qq nginx >/dev/null 2>&1
  systemctl enable nginx.service

  log_info "Nginx installé"
}

# -----------------------------------------------------------------------------
# Étape 4 : Configuration du DNS dynamique FreeDNS
# -----------------------------------------------------------------------------
setup_freedns() {
  log_step "Configuration du DNS dynamique FreeDNS"

  local SCRIPT_PATH="/usr/local/bin/freedns-update.sh"
  local CRON_LABEL="# FreeDNS dynamic DNS update"

  # Script de mise à jour
  cat >"$SCRIPT_PATH" <<EOF
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
  (
    crontab -l 2>/dev/null | grep -v "$CRON_LABEL"
    echo "$CRON_LABEL"
    echo "*/${INTERVAL} * * * * ${SCRIPT_PATH}"
  ) |
    crontab -

  log_info "FreeDNS configuré (mise à jour toutes les ${INTERVAL} min)"
  log_info "Logs : /var/log/freedns-update.log"
}

# -----------------------------------------------------------------------------
# Étape 5 : Configuration SearXNG (Docker Compose)
# -----------------------------------------------------------------------------
setup_searxng() {
  log_step "Configuration de SearXNG"

  mkdir -p "$INSTALL_DIR"
  cd "$INSTALL_DIR"

  # --- docker-compose.yml ---
  cat >docker-compose.yml <<'EOF'
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
      - SEARXNG_BASE_URL=https://${DOMAIN}/
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

  # Remplacer la variable ${DOMAIN} dans le docker-compose
  sed -i "s|\${DOMAIN}|${DOMAIN}|g" docker-compose.yml

  # --- settings.yml ---
  local SECRET_KEY
  SECRET_KEY="$(openssl rand -hex 32)"

  cat >settings.yml <<EOF
use_default_settings: true

general:
  debug: false
  instance_name: "${SEARX_INSTANCE_NAME}"
  contact_url: false

server:
  secret_key: "${SECRET_KEY}"
  limiter: false
  image_proxy: true
  base_url: "https://${DOMAIN}/"

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
EOF

  # --- .env ---
  cat >.env <<EOF
SEARXNG_SECRET=${SECRET_KEY}
SEARXNG_HOST=127.0.0.1
SEARXNG_PORT=${SEARX_PORT}
TZ=Europe/Paris
EOF

  chown -R 1000:1000 "$INSTALL_DIR" || true

  log_info "SearXNG configuré dans $INSTALL_DIR"
}

# -----------------------------------------------------------------------------
# Étape 6 : Démarrage de SearXNG
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
# Étape 7 : Configuration Nginx (HTTP d'abord, pour Let's Encrypt)
# -----------------------------------------------------------------------------
configure_nginx_http() {
  log_step "Configuration Nginx (HTTP temporaire pour Let's Encrypt)"

  cat >"$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
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
# Étape 8 : Installation des certificats Let's Encrypt
# -----------------------------------------------------------------------------
install_certificates() {
  log_step "Installation des certificats Let's Encrypt"

  # Installation de Certbot
  apt-get install -y -qq certbot python3-certbot-nginx >/dev/null 2>&1

  # Petite pause pour que le DNS se propague
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
# Étape 9 : Configuration Nginx finale (HTTPS + proxy)
# -----------------------------------------------------------------------------
configure_nginx_https() {
  log_step "Configuration Nginx finale (HTTPS + proxy inverse)"

  cat >"$NGINX_CONF" <<EOF
# Redirection HTTP -> HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
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
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    # En-têtes de sécurité
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer" always;

    # Proxy inverse vers SearXNG
    location / {
        proxy_pass http://127.0.0.1:${SEARX_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # WebSocket
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        # Timeouts
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;

        # Taille max des requêtes
        client_max_body_size 10m;
    }

    # Cache des ressources statiques
    location /static/ {
        proxy_pass http://127.0.0.1:${SEARX_PORT}/static/;
        proxy_set_header Host \$host;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }

    # Bloquer l'accès au panneau admin depuis l'extérieur
    location ~ ^/(config|stats)/ {
        allow 127.0.0.1;
        allow ::1;
        allow 192.168.0.0/16;
        allow 10.0.0.0/8;
        deny all;
        proxy_pass http://127.0.0.1:${SEARX_PORT};
        proxy_set_header Host \$host;
    }
}
EOF

  # Hook de renouvellement : reload nginx après obtention du nouveau certif
  local HOOK_DIR="/etc/letsencrypt/renewal-hooks/deploy"
  mkdir -p "$HOOK_DIR"
  cat >"$HOOK_DIR/reload-nginx.sh" <<'EOF'
#!/bin/bash
/usr/bin/systemctl reload nginx
EOF
  chmod +x "$HOOK_DIR/reload-nginx.sh"

  nginx -t 2>/dev/null && systemctl restart nginx

  log_info "Nginx configuré en HTTPS avec proxy inverse"
}

# -----------------------------------------------------------------------------
# Étape 10 : Vérification finale
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

  cat <<EOF

${C_GREEN}╔══════════════════════════════════════════════════════╗
║         INSTALLATION TERMINÉE AVEC SUCCÈS            ║
╚══════════════════════════════════════════════════════╝${C_RESET}

${C_BOLD}Accès :${C_RESET}
  • SearXNG (HTTPS) : https://${DOMAIN}/
  • SearXNG (local) : http://${LOCAL_IP}:${SEARX_PORT}

${C_BOLD}Services installés :${C_RESET}
  • Docker          $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')
  • Nginx           $(nginx -v 2>&1 | awk -F/ '{print $2}')
  • SearXNG         $(docker compose -f "$INSTALL_DIR/docker-compose.yml" images 2>/dev/null | grep searxng | awk '{print $2}')
  • Certbot         $(certbot --version 2>/dev/null | awk '{print $2}')
  • FreeDNS         Cron actif (toutes les ${FREEDNS_UPDATE_INTERVAL} min)

${C_BOLD}Fichiers importants :${C_RESET}
  • Config générale   : ${CONF_FILE}
  • Docker Compose    : ${INSTALL_DIR}/docker-compose.yml
  • SearXNG settings  : ${INSTALL_DIR}/settings.yml
  • Nginx             : ${NGINX_CONF}
  • Certificats SSL   : /etc/letsencrypt/live/${DOMAIN}/
  • Log FreeDNS       : /var/log/freedns-update.log

${C_BOLD}Commandes utiles :${C_RESET}
  • Logs SearXNG     : cd ${INSTALL_DIR} && docker compose logs -f
  • Redémarrer       : cd ${INSTALL_DIR} && docker compose restart
  • Logs Nginx       : journalctl -u nginx -f
  • Tester SSL       : curl -I https://${DOMAIN}/
  • Renouveler certif: sudo certbot renew --dry-run

${C_YELLOW}${C_BOLD}Pensez à ouvrir les ports 80 et 443 sur votre routeur/box${C_RESET}
${C_YELLOW}vers l'IP locale du Raspberry Pi : ${LOCAL_IP}${C_RESET}

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
