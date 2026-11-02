#!/bin/bash
# auto-host-searx-raspberry.sh — v2.0
# SearXNG + Linkding + RSS-Bridge sur Raspberry Pi (système sur SSD)
#   - Vérifie le démarrage sur SSD (refuse la carte SD)
#   - DuckDNS wildcard : sx./ld./rb.<domaine> + SAN unique 4 noms
#   - Ports Docker liés à 127.0.0.1 uniquement
#   - Nginx : 4 vhosts séparés + snippets réutilisables
#   - fail2ban (sshd + nginx-botsearch), UFW, SSH par clé
#
# Auteur : tazogil2 assisté de Lumo — consolidé après installation réelle
# Leçons intégrées : python3-systemd, logpath unique, http2 on,
#   fail2ban-client -t, reconnexion groupe docker, test ACME externe.

set -euo pipefail

# ── Couleurs / helpers ────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
step()    { echo -e "${YELLOW}[$(date +%H:%M:%S)] ${1}${NC}"; }
ok()      { echo -e "${GREEN}✓ ${1}${NC}"; }
err()     { echo -e "${RED}✗ ${1}${NC}"; }
warn()    { echo -e "${YELLOW}⚠ ${1}${NC}"; }

# ── Variables ─────────────────────────────────────────────
PROJECT_DIR="/opt/selfhost"
WWW_ROOT="/var/www"
PORT_SEARXNG=8080
PORT_LINKDING=9090
PORT_RSSBRIDGE=8081
DUCKDNS_SUBDOMAIN=""      # demandé interactivement

# ═══ PRÉREQUIS MANUELS (non scriptables) ═══
# 1. Box : redirection TCP 80 et 443 vers l'IP locale du Pi + bail DHCP fixe
# 2. DuckDNS : domaine créé (le wildcard *.<domaine> est automatique)
# 3. Test préalable anti-CGNAT : curl api.ipify.org (sur le Pi) doit
#    correspondre à l'IP vue sur whatismyip.com

# ── 1. Privilèges ──────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then err "Lancez avec : sudo bash $0"; exit 1; fi
REAL_USER="${SUDO_USER:-$USER}"
echo -e "${CYAN}════ Auto-hébergement SearXNG + Linkding + RSS-Bridge ════${NC}"
ok "Utilisateur : ${REAL_USER}"

# ── 2. Vérification démarrage SSD (leçon clé : pas de SD) ─
step "Vérification du disque de démarrage..."
ROOT_SOURCE=$(findmnt -n -o SOURCE /)
case "$ROOT_SOURCE" in
  /dev/mmcblk*)
    err "Le système démarre sur la CARTE SD (${ROOT_SOURCE})."
    err "Migrez d'abord vers le SSD (raspi-config → Boot Order → USB),"
    err "clonez avec SD Card Copier, puis relancez ce script."
    exit 1 ;;
esac
ok "Système sur ${ROOT_SOURCE} (SSD confirmé)"

# ── 3. Système + dépendances ──────────────────────────────
step "Mise à jour et dépendances..."
apt update && apt upgrade -y
apt install -y git curl openssl ufw nginx certbot \
    python3-certbot-nginx fail2ban python3-systemd jq
# NOTE v2 : python3-systemd explicite (backend systemd de fail2ban)

# ── 4. Docker ─────────────────────────────────────────────
step "Docker..."
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sh /tmp/get-docker.sh && rm /tmp/get-docker.sh
  usermod -aG docker "$REAL_USER"
  systemctl enable --now docker
  ok "Docker installé"
  warn "IMPORTANT : ${REAL_USER} doit SE DÉCONNECTER / RECONNECTER"
  warn "pour que le groupe docker s'applique (sinon 'docker' exige sudo)."
else
  systemctl is-active --quiet docker || systemctl start docker
  ok "Docker déjà présent"
fi
command -v docker compose &>/dev/null || apt install -y docker-compose-plugin

# ── 5. Collecte des informations ───────────────────────────
while [ -z "$DUCKDNS_SUBDOMAIN" ]; do read -rp "Sous-domaine DuckDNS (ex: jolicoco) : " DUCKDNS_SUBDOMAIN; done
DUCKDNS_DOMAIN="${DUCKDNS_SUBDOMAIN}.duckdns.org"
SEARX_HOST="sx.${DUCKDNS_DOMAIN}"
LINKDING_HOST="ld.${DUCKDNS_DOMAIN}"
RSSBRIDGE_HOST="rb.${DUCKDNS_DOMAIN}"

while [ -z "$DUCKDNS_TOKEN" ]; do read -rp "Token DuckDNS : " DUCKDNS_TOKEN; done
while [ -z "$SSL_EMAIL" ]; do read -rp "Email Let's Encrypt : " SSL_EMAIL; done

echo "Domaines : ${DUCKDNS_DOMAIN}, ${SEARX_HOST}, ${LINKDING_HOST}, ${RSSBRIDGE_HOST}"

# ── 6. DuckDNS (mise à jour + cron.d) ─────────────────────
step "DuckDNS..."
mkdir -p "$PROJECT_DIR"
umask 077
cat >"${PROJECT_DIR}/duckdns-update.sh" <<EOF
#!/bin/bash
curl -k -s "https://www.duckdns.org/update?domains=${DUCKDNS_SUBDOMAIN}&token=${DUCKDNS_TOKEN}"
EOF
chmod 700 "${PROJECT_DIR}/duckdns-update.sh"   # le token est dedans
"${PROJECT_DIR}/duckdns-update.sh" >/dev/null && ok "Mise à jour DNS effectuée" \
  || { err "Échec de la mise à jour DuckDNS (vérifiez le token)"; exit 1; }

tee /etc/cron.d/duckdns >/dev/null <<EOF
*/5 * * * * root ${PROJECT_DIR}/duckdns-update.sh > /dev/null 2>&1
EOF
ok "Cron /etc/cron.d/duckdns installé"
umask 022

# ── 7. Vérification du wildcard (arrêt net si KO) ─────────
step "Vérification du wildcard DNS..."
for h in "$SEARX_HOST" "$LINKDING_HOST" "$RSSBRIDGE_HOST"; do
  if ! getent hosts "$h" >/dev/null; then
    err "${h} ne résout pas — le wildcard DuckDNS ne semble pas actif."
    err "Vérifiez le domaine sur duckdns.org avant de continuer."
    exit 1
  fi
done
ok "Wildcard OK"

# ── 8. Sécurisation SSH ──────────────────────────────────
step "Sécurisation SSH..."
warn "Le script va désactiver l'authentification SSH par mot de passe."
read -rp "Session SSH de secours ouverte ? (oui/non) : " C
[ "$C" = "oui" ] || { warn "Annulé — revenez avec une session de secours."; exit 1; }
SSHD_CFG="/etc/ssh/sshd_config"
grep -q '^PasswordAuthentication no' "$SSHD_CFG" \
  || sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' "$SSHD_CFG"
sshd -t && systemctl reload sshd
ok "SSH par clé uniquement"

# ── 9. UFW ────────────────────────────────────────────────
step "Pare-feu..."
ufw --force reset >/dev/null
ufw allow 22/tcp comment 'SSH' >/dev/null
ufw allow 80/tcp comment 'HTTP' >/dev/null
ufw allow 443/tcp comment 'HTTPS' >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw --force enable >/dev/null
ok "UFW : 22/80/443 autorisés, entrées bloquées par défaut"

# ── 10. Conteneurs (ports 127.0.0.1 uniquement) ───────────
step "Génération des secrets et du compose..."
SEARX_SECRET=$(openssl rand -hex 32)
LINKDING_USER="admin"
LINKDING_PASS=$(openssl rand -base64 18 | tr -d '/+=')
umask 077
printf "Utilisateur : %s\nMot de passe : %s\n" "$LINKDING_USER" "$LINKDING_PASS" \
  > "${PROJECT_DIR}/linkding/ADMIN_CREDENTIALS.txt" 2>/dev/null \
  || { mkdir -p "${PROJECT_DIR}/linkding"; printf "Utilisateur : %s\nMot de passe : %s\n" \
    "$LINKDING_USER" "$LINKDING_PASS" > "${PROJECT_DIR}/linkding/ADMIN_CREDENTIALS.txt"; }
umask 022

mkdir -p "${PROJECT_DIR}/searxng/searxng" "${PROJECT_DIR}/linkding/data"

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

cat >"${PROJECT_DIR}/docker-compose.yml" <<EOF
services:
  searxng:
    image: searxng/searxng:latest
    container_name: searxng
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT_SEARXNG}:8080"
    volumes:
      - ./searxng/searxng:/etc/searxng:rw
    environment:
      - SEARXNG_BASE_URL=https://${SEARX_HOST}/
    cap_drop: [ALL]
    cap_add: [CHOWN, SETGID, SETUID]
    mem_limit: 512m

  linkding:
    image: sissbruecker/linkding:latest
    container_name: linkding
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT_LINKDING}:9090"
    volumes:
      - ./linkding/data:/etc/linkding/data
    environment:
      - LD_SUPERUSER_NAME=${LINKDING_USER}
      - LD_SUPERUSER_PASSWORD=${LINKDING_PASS}
      - LD_CSRF_TRUSTED_ORIGINS=https://${LINKDING_HOST}
    mem_limit: 512m

  rssbridge:
    image: rssbridge/rss-bridge:latest
    container_name: rssbridge
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT_RSSBRIDGE}:80"
    mem_limit: 256m
EOF

chown -R "${REAL_USER}:${REAL_USER}" "${PROJECT_DIR}"
cd "${PROJECT_DIR}" && docker compose up -d
ok "Conteneurs démarrés (127.0.0.1 uniquement)"

# ── 11. Nginx : global + snippets ─────────────────────────
step "Nginx..."
cat >/etc/nginx/nginx.conf <<'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;
events { worker_connections 768; }
http {
    sendfile on; tcp_nopush on; tcp_nodelay on;
    keepalive_timeout 65; types_hash_max_size 2048;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" "$http_user_agent"';
    access_log /var/log/nginx/access.log main;
    error_log /var/log/nginx/error.log warn;
    gzip on;
    gzip_types text/plain text/css application/json application/javascript;
    include /etc/nginx/sites-enabled/*;
}
EOF

mkdir -p /etc/nginx/snippets /var/www/html/.well-known/acme-challenge
# Logs présents avant fail2ban (leçon phase 2)
touch /var/log/nginx/access.log /var/log/nginx/error.log

cat >/etc/nginx/snippets/acme.conf <<'EOF'
location ^~ /.well-known/acme-challenge/ {
    root /var/www/html;
    allow all;
}
EOF
cat >/etc/nginx/snippets/ssl-params.conf <<'EOF'
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
ssl_prefer_server_ciphers off;
ssl_session_cache shared:SSL:10m;
ssl_session_timeout 1d;
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
EOF
cat >/etc/nginx/snippets/proxy-headers.conf <<'EOF'
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_http_version 1.1;
proxy_set_header Connection "";
proxy_connect_timeout 60s;
proxy_send_timeout 60s;
proxy_read_timeout 60s;
EOF

# Bloc HTTP temporaire (ACME uniquement)
cat >/etc/nginx/sites-available/000-acme-temp <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DUCKDNS_DOMAIN} ${SEARX_HOST} ${LINKDING_HOST} ${RSSBRIDGE_HOST};
    include snippets/acme.conf;
    location / { return 301 https://\$host\$request_uri; }
}
EOF
ln -sf /etc/nginx/sites-available/000-acme-temp /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx
ok "Nginx prêt pour ACME"
warn "TESTEZ MAINTENANT depuis l'EXTÉRIEUR (4G/5G) :"
warn "  http://${SEARX_HOST}/.well-known/acme-challenge/test"
warn "Vous DEVEZ obtenir un 404 nginx. Sinon : vérifiez les redirections"
warn "de la box (TCP 80/443 → IP du Pi) avant de continuer."
read -rp "Le test 404 est OK ? (oui/non) : " C
[ "$C" = "oui" ] || { err "Corrigez la box avant de continuer (certbot échouerait)."; exit 1; }

# ── 12. Certificat SAN (4 noms) ────────────────────────────
step "Certificat Let's Encrypt..."
certbot certonly --webroot -w /var/www/html \
  -d "${DUCKDNS_DOMAIN}" -d "${SEARX_HOST}" -d "${LINKDING_HOST}" -d "${RSSBRIDGE_HOST}" \
  --non-interactive --agree-tos --email "${SSL_EMAIL}" --no-eff-email
systemctl enable --now certbot.timer
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat >/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/bin/bash
/usr/sbin/nginx -s reload
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
ok "Certificat SAN + renouvellement auto configurés"

# ── 13. Vhosts finaux (un fichier par service, http2 on) ──
cat >/etc/nginx/snippets/ssl-certs.conf <<EOF
ssl_certificate     /etc/letsencrypt/live/${DUCKDNS_DOMAIN}/fullchain.pem;
ssl_certificate_key /etc/letsencrypt/live/${DUCKDNS_DOMAIN}/privkey.pem;
EOF

write_vhost() {  # $1=fichier $2=server_name $3=bloc location
cat >"/etc/nginx/sites-available/$1" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $2;
    include snippets/acme.conf;
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name $2;
    include snippets/ssl-certs.conf;
    include snippets/ssl-params.conf;
$3
}
EOF
}

write_vhost apex "${DUCKDNS_DOMAIN}" "    root /var/www/html;
    index index.html;
    location / { try_files \$uri \$uri/ =404; }"

write_vhost searx "${SEARX_HOST}" "    location / {
        proxy_pass http://127.0.0.1:${PORT_SEARXNG};
        include snippets/proxy-headers.conf;
        proxy_buffering off;
        proxy_request_buffering off;
    }"

write_vhost linkding "${LINKDING_HOST}" "    client_max_body_size 10M;
    location / {
        proxy_pass http://127.0.0.1:${PORT_LINKDING};
        include snippets/proxy-headers.conf;
    }"

write_vhost rssbridge "${RSSBRIDGE_HOST}" "    location / {
        proxy_pass http://127.0.0.1:${PORT_RSSBRIDGE};
        include snippets/proxy-headers.conf;
    }"

rm -f /etc/nginx/sites-enabled/000-acme-temp
for s in apex searx linkding rssbridge; do
  ln -sf "/etc/nginx/sites-available/${s}" "/etc/nginx/sites-enabled/${s}"
done
nginx -t && systemctl reload nginx
ok "4 vhosts HTTPS actifs"

# ── 14. Page d'accueil ────────────────────────────────────
cat >${WWW_ROOT}/html/index.html <<EOF
<!DOCTYPE html>
<html lang="fr"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Bienvenue</title></head>
<body style="font-family:sans-serif;background:linear-gradient(135deg,#667eea,#764ba2);
display:flex;justify-content:center;align-items:center;min-height:100vh;margin:0;color:#fff">
<div style="text-align:center;padding:2rem">
<h1>Bienvenue sur votre serveur</h1>
<p>🔍 <a style="color:#fff" href="https://${SEARX_HOST}">${SEARX_HOST}</a></p>
<p>🔖 <a style="color:#fff" href="https://${LINKDING_HOST}">${LINKDING_HOST}</a></p>
<p>📡 <a style="color:#fff" href="https://${RSSBRIDGE_HOST}">${RSSBRIDGE_HOST}</a></p>
</div></body></html>
EOF
chown -R www-data:www-data ${WWW_ROOT}/html

# ── 15. fail2ban (leçons phase 2 appliquées) ─────────────
step "fail2ban..."
cat >/etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
backend = systemd

[nginx-botsearch]
enabled = true
logpath = /var/log/nginx/access.log
maxretry = 2
EOF
# Validation AVANT démarrage (leçon phase 2)
fail2ban-client -t
systemctl restart fail2ban
systemctl enable fail2ban
ok "fail2ban : sshd + nginx-botsearch"

# ── 16. Mises à jour auto ─────────────────────────────────
step "Mises à jour automatiques..."
tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF
tee /etc/cron.daily/docker-update >/dev/null <<EOF
#!/bin/bash
cd ${PROJECT_DIR} && docker compose pull && docker compose up -d
EOF
chmod +x /etc/cron.daily/docker-update

# ── 17. Résumé ────────────────────────────────────────────
echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✓ Installation terminée !${NC}"
echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo "🏠 Accueil     : https://${DUCKDNS_DOMAIN}"
echo "🔍 Searx      : https://${SEARX_HOST}"
echo "🔖 Linkding   : https://${LINKDING_HOST}  (identifiants : ${PROJECT_DIR}/linkding/ADMIN_CREDENTIALS.txt)"
echo "📡 RSS-Bridge : https://${RSSBRIDGE_HOST}"
echo "Tests : sudo certbot renew --dry-run | fail2ban-client status"
