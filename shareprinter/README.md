# Partage d'imprimante CUPS sur le réseau local

Script d'automatisation pour partager une imprimante USB connectée à un PC fixe
sous Linux (testé sur LinuxMint) avec les autres machines du réseau local
(portables, smartphones) via le Wi-Fi du routeur.

## Contexte

L'imprimante (Brother laser) est reliée en USB au PC fixe, qui joue le rôle de
serveur d'impression CUPS. Le routeur GL.iNet ne sert qu'à interconnecter les
machines — il n'héberge aucun service d'impression.

```
[Portable] ----\
[Smartphone] ---+--[Routeur GL.iNet]---[PC fixe LinuxMint]
                              |                |
                              |                +---> [Imprimante Brother USB]
[Clé USB Samba]-/
```

## Prérequis

- Linux avec CUPS installé (toute distro le proposant par défaut :
  LinuxMint, Ubuntu, Debian...)
- L'imprimante fonctionne **localement** sur le PC serveur
  (test de la page d'impression réussi)
- `ufw` présent sur le serveur (paquet `ufw`)
- Droits root (`sudo`) sur la machine exécutant le script

## Usage

```bash
sudo ./setup-partage.sh                    # utilise le sous-réseau par défaut
sudo ./setup-partage.sh 192.168.8.0/24     # sous-réseau explicite
```

Le sous-réseau correspond à votre LAN. Pour le connaître :

```bash
ip route | grep default
# ex: default via 192.168.8.1 → le LAN est probablement 192.168.8.0/24
```

## Ce que fait le script

Le partage CUPS nécessite l'empilement de **quatre conditions
indépendantes** — c'est ce qui rend le problème difficile à diagnostiquer
manuellement, car cocher « Partager cette imprimante » dans l'interface
graphique ne remplit que la dernière.

| # | Action du script | Sans cela |
|---|------------------|-----------|
| 1 | Remplace `Listen localhost:631` par `Port 631` dans `/etc/cups/cupsd.conf` | CUPS refuse toute connexion réseau : les clients ne voient rien, pare-feu ouvert ou non |
| 2 | Ajoute `Allow @LOCAL` dans les blocs `<Location>` de `cupsd.conf` | CUPS rejette les requêtes des machines distantes |
| 3 | Active la publication (`cupsctl --share-printers`) | Pas d'annonce des files sur le réseau (découverte automatique défaillante) |
| 4 | Ouvre le port 631/tcp dans ufw, **uniquement pour le sous-réseau local** | ufw (s'il est actif) bloque les connexions entrantes vers CUPS |

Le script est **idempotent** : il peut être relancé sans risque. Chaque étape
vérifie l'état existant et affiche `[OK]` ou `[SKIP]` selon qu'elle modifie ou
non la configuration. Une sauvegarde horodatée de `cupsd.conf` est créée avant
toute modification, et la syntaxe est validée (`cupsd -t`) **avant** le
redémarrage du service : si la configuration est invalide, CUPS n'est pas
arrêté.

## Vérification après exécution

Sur le serveur :

```bash
cupsctl | grep -i share      # _share_printers=1 attendu
ss -ltnp | grep 631          # la 4e colonne doit être *:631, PAS 127.0.0.1:631
sudo ufw status              # 631/tcp ALLOW depuis le sous-réseau
```

Depuis un client, dans un navigateur :

```
http://IP_DU_SERVEUR:631/printers/
```

L'imprimante doit apparaître. L'URI à utiliser pour l'ajout manuel côté
client est :

```
ipp://IP_DU_SERVEUR:631/printers/NomExactDeLimprimante
```

(le nom exact figure sur la page ci-dessus, espaces inclus)

## Restauration

En cas de problème, restaurer la sauvegarde créée par le script :

```bash
sudo cp /etc/cups/cupsd.conf.avant-partage.AAAA-MM-JJ-HHMMSS /etc/cups/cupsd.conf
sudo systemctl restart cups
```

Ou, pour désactiver uniquement la règle pare-feu :

```bash
sudo ufw delete allow from 192.168.8.0/24 to any port 631 proto tcp
```

## Dépannage

| Symptôme | Cause probable | Vérification |
|---|---|---|
| Le client ne voit aucune imprimante | CUPS écoute sur localhost | `ss -ltnp \| grep 631` → colonne locale = `127.0.0.1:631` |
| Page `:631/printers/` inaccessible | Règle ufw absente ou mauvais sous-réseau | `sudo ufw status`, `ip route` |
| Page accessible mais ajout impossible | `Allow @LOCAL` manquant | Restaurer puis relancer le script |
| Découverte auto absente, URI IPP fonctionnelle | mDNS bloqué | Autoriser UDP 5353 : `sudo ufw allow from 192.168.8.0/24 to any port 5353 proto udp` |
| Ping impossible entre machines | Isolement client Wi-Fi sur le routeur | Désactiver « AP isolation » dans l'admin GL.iNet |

## Fichiers touchés

- `/etc/cups/cupsd.conf` — modifié (sauvegarde horodatée créée)
- `/etc/cups/printers.conf` — non modifié (le flag `Shared Yes` reste sous
  le contrôle de l'interface graphique)
- ufw — une règle ajoutée

## Historique

- Première version : config manuelle (correction de `cupsd.conf` par éditeur
  de texte, cf.Conversation de diagnostic, puis automatisation). Ce script
  condense l'ensemble.
