# Script d'installation : Docker + SearXNG + Nginx (HTTPS) sur Raspberry Pi

Auteur : Généré par *Lumo*

## Description :

- Met à jour le système
- Installe Docker, Nginx
- Configure un DNS dynamique avec FreeDNS ou DuckDNS
- Déploie SearXNG via Docker Compose
- Configure Nginx en proxy inverse avec SSL (Let's Encrypt)

## Instructions :

Se connecter au *RASP* et télécharger ce script avec cette commande :

    wget https://github.com/tazogil2/bricolage/archive/refs/heads/main.zip && unzip main.zip && rm main.zip

Aller dans le dossier téléchargé : 

    cd bricolage-main


Rendre le script exécutable : 

    chmod 700 auto-host-searx.sh

Exécuter le script : 

    sudo ./auto-host-searx.sh

Le script va créer le fichier de configuration /opt/searxng/install.conf et vous
proposer de l'éditer immédiatement. 3 champs sont obligatoires :

- DOMAIN="moninstance.mooo.com"
- FREEDNS_TOKEN="a1b2c3d4e5f6g7h8i9j0..." 
- LE_EMAIL="moi@example.com"

Autres champs optionnels : 

- SEARX_INSTANCE_NAME="SearXNG"
- SEARX_LANG="fr" 
- SEARX_PORT=8080 
- FREEDNS_UPDATE_INTERVAL=5
- FORCE_HTTPS=true

Relancer le script après l'édition de la configuration : 

    sudo ./auto-host-searx.sh

Ouvertures réseau :

|---Port---|---Destination---|
|------|------|
|80	| Routeur → IP RPi |
| 443	| Routeur → IP RPi |

Les étapes de ce script :

|Étape |	Commentaire|
|------|------|
|Nginx| 	Installation et configuration complète du reverse proxy| 
|HTTPS	| Génération automatique du certificat Let's Encrypt via certbot| 
|Stratégie SSL| 	Config temporaire HTTP-only pour le challenge ACME, puis reconfiguration HTTPS complète| 
|Renouvellement| 	Timer systemd + hook de rechargement Nginx après renouvellement| 
|Pare-feu| 	UFW activé (SSH + 80 + 443 uniquement)| 
|Sécurité| 	Headers HSTS, X-Frame-Options, X-Content-Type-Options, Referrer-Policy| 
|Cache	| Mise en cache des fichiers statiques via Nginx| 
| Port binding	| SearXNG bindé sur 127.0.0.1:8080 uniquement (non exposé publiquement)| 
