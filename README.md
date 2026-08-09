# Auto-heberger Searx et LinkDing sur un Raspberry

## ⚠️ Avant toute installation

Vérifiez si votre FAI vous attribue une vraie adresse IP publique ou s'il utilise le CGNAT (Carrier-Grade NAT).

Test rapide : Allez sur [whatismyip.com](https://whatismyip.com) depuis votre ordinateur connecté au même réseau. Comparez cette IP avec celle affichée dans l'interface de votre box internet.

Si elles sont identiques : Vous avez une IP publique. Vous pourrez utiliser le Port Forwarding (méthode standard).

Si elles sont différentes (ou commençant par 100.x.x.x) : Vous êtes derrière le CGNAT. Le port forwarding classique ne fonctionnera pas, votre FAI interdit cette solution d'Auto-hébergement.

Ce guide permet d'installer un serveur personnel abritant Searx (moteur de recherche privé), Linkding (gestionnaire de signets) et un espace pour des pages statiques (blog). Tout est automatisé via un script bash pour les utilisateurs débutants.

## 📋 1. Prérequis Matériels et Logiciels

Avant de commencer, assurez-vous d'avoir le matériel suivant :

  | Composant |  Spécifications  recommandées | Notes | 
 |-----  |-----  |-----  | 
  | Raspberry Pi  | Modèle 4B ou supérieur (4 Go RAM recommandé)  |  Les modèles Zéro 2 W peuvent fonctionner mais seront plus lents. |
  | Carte SD  | Minimum 16 Go, Classe 10 / UHS-I  | Qualité indispensable pour la durée de vie du système.  |
  | Alimentation | Alimentation officielle Raspberry Pi USB-C | Évitez les chargeurs de téléphone instables. |
  | Stockage externe | Clé USB ou SSD avec format ext4 | Servira à stocker les données (/var/www) pour faciliter les sauvegardes. | 
  | Réseau | Câble Ethernet (recommandé) ou Wi-Fi stable | Le câble évite les coupures pendant l'installation. |   
| Budget | ~150 € (si vous n'avez pas le matériel) | Inclut le Pi, la carte, l'alim et le stockage USB. | 


## 🛠️ 2. Préparation Environnementale (AVANT l'installation)

Ces étapes doivent être réalisées sur votre ordinateur principal (Mac, Windows ou Linux) avant de toucher au Raspberry Pi.

### A. Création des clés SSH

Nous utilisons l'authentification par clé pour plus de sécurité.ssh-keygen -t ed25519 -C "votre_email@exemple.com"Conseil : Pour ce projet, nous partirons sur une clé sans phrase de passe (empty passphrase) pour faciliter l'usage par des débutants.

### B. Configuration DuckDNS

Vous aurez besoin d'un nom de domaine pour accéder à vos services.

Inscrivez-vous sur [DuckDNS.org](https://duckdns.org) (connexion possible avec Google, Github, Twitter, etc.). DuckDNS a été choisi parmi d'autres services similaires (freeDNS, No-IP).

1. Créez un domaine (ex: mon-projet.duckdns.org).
2. Notez le token affiché sur la page — il sera demandé plus tard.
3. Créez les sous-domaines suivants dans votre tableau de bord DuckDNS :

      *    searx.mon-projet (Recherche → searx.mon-projet.duckdns.org)
      *    ld.mon-projet (Signets → ld.mon-projet.duckdns.org)
      *    blog.mon-projet (Blog → blog.mon-projet.duckdns.org)


### C. Installation de l'OS sur la Carte SD

1. Téléchargez et lancez Raspberry Pi Imager.
2. Choisissez le système : Raspberry Pi OS (64-bit) LITE.
3. Cliquez sur "Configurer les options" (la roue dentée) :

      *   Nom d'hôte : rpi-services
      *   Compte utilisateur : Choisissez un nom court (ex: admin) et définissez un mot de passe fort.
      *   SSH : Activez-le. Sélectionnez "Utiliser la clé SSH" et collez la clé publique générée à l'étape A.
      *   Paramètres régionaux : Fuseau horaire sur Europe/Paris, clavier Français.

4. Écrivez l'image sur la carte SD.

## 🚀 3. Installation Physique et Réseau

1. Insérez la carte SD dans le Raspberry Pi.
1. Branchez la clé USB (stockage externe) sur un port USB libre.
1. Connectez le Pi au routeur via Ethernet.
1. Branchez l'alimentation.
1. Attendez 2 minutes que le système démarre.

Configuration du Routeur (Box Internet)

Connectez-vous à l'interface d'administration de votre box (généralement 192.168.1.1 ou 192.168.0.1).

Trouvez l'adresse IP du Pi : Dans la liste des appareils connectés, repérez rpi-services et notez son adresse IP locale (ex: 192.168.1.45).

Réservation DHCP (IP Statique) : Associez l'adresse MAC du Pi à cette IP pour qu'elle ne change jamais.

Redirection de Ports (Port Forwarding) : Créez des règles pour rediriger le trafic entrant vers l'IP du Pi :

- Port 22 (SSH) → Vers le Pi (Port 22)
- Port 80 (HTTP) → Vers le Pi (Port 80)
- Port 443 (HTTPS) → Vers le Pi (Port 443)

## 💻 4. Déploiement du Script

Ouvrez un terminal sur votre ordinateur principal et exécutez les commandes suivantes. Remplacez <UTIL> par votre nom d'utilisateur et <IP> par l'IP locale du Pi.

1. Transférer le script:

        scp installer-rpi.sh <UTIL>@<IP>:~

2. Se connecter au Pi

        ssh <UTIL>@<IP>

3. Rendre le script exécutable et lancer l'installation

        chmod 700 installer-rpi.sh
        ./installer-rpi.sh

Suivez les instructions à l'écran. Le script va :

1. Vérifier et monter la clé USB sur /var/www.
2. Installer Docker, Nginx, Fail2Ban et UFW.
3. Demander votre token DuckDNS et configurer les certificats SSL.
4. Déployer Searx, Linkding et la page "Work in Progress".
5. Sécuriser l'accès SSH et activer le pare-feu.

## ✅ 5. Vérifications Finales

Une fois le script terminé :

|  Service | URL |
|  -----|  -----|  
| Recherche|  https://searx.<votre-domaine>.duckdns.org| 
|  Signets|  https://ld.<votre-domaine>.duckdns.org| 
|  Blog|  https://blog.<votre-domaine>.duckdns.org| 
|  Connexion SSH | ssh <UTIL>@<votre-domaine>.duckdns.org| 

## 🔒 6. Sécurité et Maintenance

Mises à jour automatiques : Le script configure unattended-upgrades pour le système et des tâches cron pour Docker.

Sauvegarde : Comme /var/www est sur la clé USB, vous pouvez simplement débrancher la clé et la brancher sur un autre PC Linux pour récupérer vos données.

Phrase de passe SSH : Bien que l'installation ait utilisé une clé sans passe, il est fortement recommandé de protéger votre clé privée par une phrase de passe dès que possible.

Pour changer la phrsa de passe : 

    ssh-keygen -p -f ~/.ssh/id_ed25519

Pour gérer la saisie automatique : Configurez ssh-agent (voir annexe).



## 🆘 Annexe : Dépannage
| Problème| Solution|
|----|----|   
| Impossible de se connecter en SSH| Vérifiez que la clé publique a bien été copiée dans Imager et que le port 22 est redirigé.|
| Les sites web sont inaccessible| Vérifiez que les ports 80 et 443 sont redirigés et que DuckDNS pointe vers votre IP publique.|
| Le certificat SSL échoue| Vérifiez que le port 80 est accessible depuis Internet (test avec un outil en ligne).|
| Searx ne répond pas| Consultez les logs : docker compose logs searxng| 
