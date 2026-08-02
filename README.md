# Script d'installation : Docker + SearXNG + Nginx (HTTPS) sur Raspberry Pi

Auteur : Généré par *Lumo*

## Description :

- Met à jour le système
- Installe Docker, Nginx
- Configure un DNS dynamique avec FreeDNS
- Déploie SearXNG via Docker Compose
- Configure Nginx en proxy inverse avec SSL (Let's Encrypt)

## Instructions :

Se connecter au *RASP* et télécharger ce script avec cette commande :

    wget https://github.com/tazogil2/bricolage/archive/refs/heads/main.zip && unzip main.zip && rm main.zip

Aller dans le dossier téléchargé : 

    cd bricolage-main


Rendre le script exécutable : 

    chmod 700 auto-host-searx.sh


Trouver le token FreeDNS : 

1. Connectez-vous sur freedns.afraid.org
2. Allez dans Subdomains → Dynamic DNS
3. Cliquez sur votre sous-domaine pour voir l'URL de mise à jour, qui ressemble
à :https://freedns.afraid.org/dynamic/update.php?a1b2c3d4e5f6g7h8i9j0…
4. Copiez **tout ce qui est après `?`** → c'est votre `FREEDNS_TOKEN`


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

Points d'attention :

|Élément | Vérification |
|---|---|
|url_prefix	| Vérifié dans settings.yml |
|proxy_pass	| Pas de ${SEARX_PREFIX} inclus |
|Routes bloquées |	/config et /stats renvoie 404 |
|Statiques	| / sert depuis ${STATIC_ROOT} |
|SearXNG	| ${SEARX_PREFIX}/ sert via proxy |
