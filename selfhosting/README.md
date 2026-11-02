# Auto-hébergement SearXNG + Linkding + RSS-Bridge sur Raspberry Pi

## ⚠️ Avant toute installation

Vérifiez si votre FAI vous attribue une vraie adresse IP publique ou s'il utilise le CGNAT (Carrier-Grade NAT).

Test rapide : sur le Pi, exécutez `curl api.ipify.org` et comparez avec l'IP affichée sur whatismyip.com depuis votre ordinateur.

- **Identiques** : vous avez une IP publique, le port forwarding fonctionnera.
- **Différentes** (ou commençant par `100.64.x.x`) : CGNAT — les redirections de ports sont inopérantes depuis l'extérieur. Solutions possibles : IPv6 native, ou tunnel (Cloudflare).

Ce script déploie un serveur personnel hébergeant **SearXNG** (moteur de recherche privé), **Linkding** (gestionnaire de signets), **RSS-Bridge** (générateur de flux RSS) et un espace pour des pages statiques (blog MkDocs). Tout le trafic passe par Nginx en HTTPS avec des certificats Let's Encrypt.

## 🏗️ Architecture

```
Internet ──► Box (redirection 80/443) ──► Raspberry Pi
                                            │
                              UFW (22/80/443 uniquement)
                                            │
                                       Nginx (reverse proxy)
                   ┌──────────────┬───────────────┬──────────────┐
                   │              │               │              │
            jolicoco.duckdns.org  sx.       ld.           rb.
              (site statique)   (SearXNG)  (Linkding)  (RSS-Bridge)
                   │              │            │              │
                   └──── /var/www/html ── 127.0.0.1:8080 :9090 :8081
                                    (conteneurs Docker, jamais exposés directement)
```

Points clés du design :

- **Un seul certificat SAN** couvrant les 4 noms de domaine (renouvellement unique).
- **Ports Docker liés à 127.0.0.1** : les services ne sont joignables que via Nginx — double barrière avec UFW.
- **Système sur SSD** : le script refuse de s'exécuter si le Pi démarre sur la carte SD.
- **Configurations Nginx séparées** : un fichier par service (`apex`, `searx`, `linkding`, `rssbridge`) + snippets réutilisables.

## 📋 1. Prérequis matériels

| Composant | Spécifications recommandées | Notes |
|-----|-----|-----|
| Raspberry Pi | Modèle 4B ou supérieur (4 Go RAM) | Les modèles Zero 2 W fonctionnent mais seront plus lents |
| SSD + boîtier USB 3.0 | 128 Go minimum, boîtier **UASP** (ASM1153E, JMS578/583) | Système ET données sur le SSD |
| Alimentation | Alimentation officielle USB-C (5,1 V / 3 A) | Icône éclair jaune = sous-tension → hub USB alimenté |
| Réseau | Câble Ethernet (recommandé) | Évite les coupures pendant l'installation |
| Budget | ~150 € (si départ de zéro) | Pi, SSD, boîtier, alimentation |

## 🛠️ 2. Préparation de l'environnement (AVANT le script)

### A. Migration vers le SSD

Le système doit démarrer sur le SSD, pas sur la carte SD :

1. Mettre à jour le firmware : `sudo rpi-eeprom-update -a` puis redémarrer.
2. `sudo raspi-config` → *Advanced Options* → *Boot Order* → **USB Boot**.
3. Cloner la SD vers le SSD : outil **SD Card Copier** (graphique) ou `dd`.
4. Étendre le système de fichiers : *Advanced Options* → *Expand Filesystem*.
5. Retirer la SD et redémarrer. Vérification : `findmnt -n -o SOURCE /` doit afficher `/dev/sda*`, pas `/dev/mmcblk*`.

La carte SD conservée devient une roue de secours bootable.

### B. Clé SSH

```bash
ssh-keygen -t ed25519 -C "votre_email@exemple.com"
```

L'authentification par clé est obligatoire : le script désactive l'authentification SSH par mot de passe.

### C. DuckDNS

1. Créez un domaine sur [duckdns.org](https://duckdns.org) (ex: `mon-projet`).
2. Notez le **token** affiché sur la page.
3. Le wildcard `*.mon-projet.duckdns.org` est automatique : les sous-domaines `sx.`, `ld.`, `rb.` résolvent sans configuration supplémentaire. Testez : `ping sx.mon-projet.duckdns.org`.

### D. Configuration de la box

1. **Bail DHCP fixe** : associez l'adresse MAC du Pi à une IP locale permanente.
2. **Redirection de ports** : TCP 80 et TCP 443 vers l'IP locale du Pi.
3. ⚠️ Constatez que le Pi apparaît sous son ancien nom dans la box ? C'est un cache DHCP, sans importance — forcez un renouvellement de bail si cela vous chiffonne.

## 🚀 3. Installation

Depuis votre ordinateur :

```bash
scp auto-host-searx-raspberry.sh <UTIL>@<IP-du-Pi>:~
ssh <UTIL>@<IP-du-Pi>
chmod 700 auto-host-searx-raspberry.sh
sudo bash auto-host-searx-raspberry.sh
```

Le script effectue dans l'ordre :

1. Vérifie le démarrage sur SSD (refuse la carte SD).
2. Met à jour le système et installe les dépendances (dont `python3-systemd`, requis par fail2ban).
3. Installe Docker.
4. Configure la mise à jour DuckDNS (cron toutes les 5 minutes).
5. Vérifie que le wildcard DNS résout.
6. Sécurise SSH (clé uniquement — gardez une session de secours ouverte !).
7. Configure UFW (22/80/443 uniquement).
8. Démarre les 3 conteneurs (liés à 127.0.0.1).
9. Configure Nginx + obtient le certificat SAN Let's Encrypt (4 domaines).
10. Active fail2ban (sshd + nginx-botsearch).
11. Configure les mises à jour automatiques.

**Point de vigilance** : le script s'interrompt pour un test manuel — depuis l'extérieur (4G/5G), `http://sx.<domaine>.duckdns.org/.well-known/acme-challenge/test` doit retourner un **404 nginx** avant que le certificat ne soit demandé. Sinon, corrigez les redirections de la box d'abord.

## ✅ 4. Vérifications finales

| Service | URL |
|-----|-----|
| Site statique | https://\<domaine\>.duckdns.org |
| SearXNG | https://sx.\<domaine\>.duckdns.org |
| Linkding | https://ld.\<domaine\>.duckdns.org |
| RSS-Bridge | https://rb.\<domaine\>.duckdns.org |

Tests de santé :

```bash
sudo certbot renew --dry-run     # renouvellement SSL
sudo fail2ban-client status      # jails actives
docker compose -f /opt/selfhost/docker-compose.yml ps
```

Les identifiants Linkding sont générés aléatoirement et stockés dans `/opt/selfhost/linkding/ADMIN_CREDENTIALS.txt` (permissions 600).

## 🔒 5. Sécurité

- **SSH par clé uniquement**, mot de passe désactivé (fail2ban surveille les tentatives).
- **UFW** : seuls les ports 22 (SSH), 80 et 443 (Nginx) sont ouverts.
- **fail2ban** : jails `sshd` (backend systemd) et `nginx-botsearch` (bantime 1 h).
- **Conteneurs cloisonnés** : ports Docker sur 127.0.0.1, cap_drop ALL, limites mémoire.
- **HTTPS partout** : redirection 301, HSTS, TLS 1.2/1.3 uniquement.
- **Mises à jour automatiques** : unattended-upgrades (système) + cron quotidien (images Docker).

## 👥 6. Collaboration sur le site statique

Plusieurs utilisateurs peuvent déployer dans `/var/www/html` via un groupe partagé :

```bash
sudo groupadd web
sudo usermod -aG web stef
sudo adduser --ingroup web camille    # nouveau collaborateur
sudo chown -R stef:web /var/www/html
sudo find /var/www/html -type d -exec chmod 2775 {} \;
sudo find /var/www/html -type f -exec chmod 664 {} \;
```

- Le bit **setgid** (2775) fait hériter le groupe `web` à tout nouveau fichier.
- Les scripts de déploiement rsync doivent utiliser `--chmod=D2775,F664` pour garantir les droits indépendamment de l'umask (rsync `-a` écrase sinon les permissions).
- Nginx (`www-data`) n'a besoin que de la lecture : il reste satisfait avec ces permissions.
- Dépôt de clé SSH pour un nouvel utilisateur : `ssh-copy-id -i id_ed25519.pub camille@<domaine>` (ou copie manuelle en root, puis `chown -R camille: /home/camille/.ssh`, `chmod 700` sur le dossier et `600` sur `authorized_keys`).

## 🆘 7. Dépannage

| Problème | Solution |
|----|----|
| Impossible de se connecter en SSH | Clé publique bien copiée ? Session de secours disponible ? Vérifier fail2ban : `sudo fail2ban-client status sshd` |
| Sites inaccessibles depuis l'extérieur | Redirections box (80/443) actives ? CGNAT ? Test : `curl api.ipify.org` vs whatismyip.com |
| `ERR_CONNECTION_RESET` en mobile | Souvent le navigateur qui tente HTTPS alors que le 443 n'est pas encore configuré ; tester en `http://` explicite |
| Le certificat SSL échoue | Le test 404 ACME externe passe-t-il ? `http://<domaine>/.well-known/acme-challenge/test` doit donner un 404 nginx |
| fail2ban ne démarre pas | `sudo fail2ban-client -t` pour la ligne fautive ; un seul `logpath` par jail ; vérifier `python3-systemd` |
| `docker` exige sudo | Se déconnecter/reconnecter après l'ajout au groupe docker |
| Searx ne répond pas | `docker compose -f /opt/selfhost/docker-compose.yml logs -f searxng` |
| `nginx -t` : Permission denied sur les certificats | Lancer avec `sudo` (les clés live/ sont en 700 root) |
| Hook deploy-hook certbot affiché en rouge | Sortie normale de `nginx -s reload` coloriée par certbot — ignorable si « Successfully received certificate » suit |
| Écriture impossible dans /var/www/html | Vérifier groupe `web` + setgid + permissions (voir section 6) |

## 📝 Historique des versions

- **v2.0** (2026-10-17) : refonte complète — système sur SSD obligatoire, 3 services (SearXNG, Linkding, RSS-Bridge), sous-domaines wildcard, certificat SAN unique, vhosts séparés, fail2ban. Correctifs issus d'une installation réelle pas-à-pas : `python3-systemd` explicite, jail `nginx-badbots` supprimée (absente de fail2ban 1.1.0), `logpath` unique par jail, validation `fail2ban-client -t` préalable, syntaxe `http2 on;`, test ACME externe avant certbot, message de reconnexion groupe docker.
- **v1.0** (2026-08-10) : SearXNG seul sur chemin `/searx/`, formatage automatique de la clé USB.

---

*Auteur : tazogil2 assisté de Lumo — Projet bricolage*
