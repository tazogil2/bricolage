#!/usr/bin/env bash
#
# partage-imprimante.sh — Configure le partage réseau CUPS
# Usage: sudo ./partage-imprimante.sh [sous-réseau, ex: 192.168.8.0/24]

set -euo pipefail

SUBNET="${1:-192.168.8.0/24}"
CONF="/etc/cups/cupsd.conf"

# --- Vérifications préalables ---
[[ $EUID -eq 0 ]] || { echo "Erreur: exécuter avec sudo"; exit 1; }
[[ -f "$CONF" ]] || { echo "Erreur: $CONF introuvable — CUPS installé ?"; exit 1; }

# --- Sauvegarde datée (jamais écrasée) ---
cp "$CONF" "$CONF.avant-partage.$(date +%Y%m%d-%H%M%S)"
echo "[OK] Sauvegarde créée"

# --- Port d'écoute : remplacer 'Listen localhost:631' par 'Port 631' ---
if grep -qE '^Listen localhost:631|^Listen 127\.0\.0\.1:631' "$CONF"; then
    sed -i -E 's/^Listen (localhost|127\.0\.0\.1):631/Port 631/' "$CONF"
    echo "[OK] CUPS écoutera sur toutes les interfaces"
else
    echo "[SKIP] 'Port 631' déjà configuré"
fi

# --- Autoriser le LAN dans les blocs Location ---
if ! grep -q '^Allow @LOCAL' "$CONF"; then
    # Insère 'Allow @LOCAL' après chaque directive 'Order allow,deny'
    sed -i '/^ *Order allow,deny/a\  Allow @LOCAL' "$CONF"
    echo "[OK] Accès LAN ajouté aux blocs Location"
else
    echo "[SKIP] 'Allow @LOCAL' déjà présent"
fi

# --- Publication des files d'impression ---
cupsctl --share-printers > /dev/null
echo "[OK] Partage des imprimantes activé"

# --- Pare-feu : port 631 ouvert uniquement au LAN ---
if ufw status 2>/dev/null | grep -q "631/tcp.*ALLOW.*$SUBNET"; then
    echo "[SKIP] Règle ufw déjà présente"
else
    ufw allow from "$SUBNET" to any port 631 proto tcp > /dev/null
    echo "[OK] ufw: port 631 ouvert pour $SUBNET"
fi

# --- Validation syntaxique avant redémarrage ---
cupsd -t && systemctl restart cups || { echo "ERREUR: config invalide — restaurez la sauvegarde"; exit 1; }
echo "[OK] CUPS redémarré"

# --- Contrôle final ---
ss -ltn | grep -q ':631' && echo "✓ CUPS écoute sur le réseau" || echo "⚠ Vérifier manuellement: ss -ltnp | grep 631"
