# Installer LiXee-Assist sur un Sonoff NSPanel Pro

Ce guide installe LiXee-Assist sur un panneau mural Sonoff NSPanel Pro, où
l'application s'ouvre en kiosque tactile : énergie, appareils, groupes
d'actions et thermostats de votre LiXee-Box, sans navigateur.

Tout se fait au doigt, sur le panneau. Comptez cinq minutes.

## Ce qu'il vous faut

- Un NSPanel Pro connecté à votre WiFi, avec **F-Droid** : sa tuile se
  trouve dans le menu du panneau.
- Une **LiXee-Box déjà installée** et joignable sur ce même réseau. Une box
  neuve se configure d'abord avec LiXee-Assist sur un téléphone.
- Pour ajouter vos box d'un geste : un téléphone avec LiXee-Assist
  (version 1.1.0 (42) ou suivante), sur le même WiFi que le panneau.
  À défaut, l'adresse de la box et ses identifiants suffisent.

## 1. Ajouter le dépôt LiXee à F-Droid

1. Sur le panneau, ouvrez le menu et touchez **F-Droid**.
2. Ouvrez l'onglet **Paramètres**, puis **Dépôts**.
3. Touchez **+**, puis saisissez l'adresse du dépôt :

       https://fairecasoimeme.github.io/LiXee-Assist/fdroid/repo

4. Validez. F-Droid télécharge la liste des applications du dépôt.

## 2. Installer LiXee-Assist

1. Dans F-Droid, cherchez **LiXee-Assist** (loupe, en bas à droite).
2. Touchez **Installer**, puis confirmez l'installation.
3. Touchez **Ouvrir**.

Au premier lancement, autorisez la position : Android l'exige pour
rechercher les box sur le réseau.

## 3. Ajouter votre box

Le kiosque s'ouvre sur l'écran **Ajouter une box**, avec un QR code.

**Depuis le téléphone (le plus simple)**

1. Sur le téléphone, ouvrez LiXee-Assist, puis le menu **⋮** et
   **Envoyer vers une TV**.
2. Scannez le QR code affiché par le panneau.
3. Vérifiez que le code à six chiffres est le même sur les deux écrans,
   cochez les box à envoyer, validez.

Vos box arrivent sur le panneau avec leurs adresses et leurs identifiants.

**Sans téléphone**

1. Touchez **Saisie manuelle**.
2. Les box trouvées sur le réseau sont proposées : touchez la vôtre pour
   remplir l'adresse. Sinon, saisissez-la (par exemple `192.168.1.50`).
3. Si la box est protégée, saisissez son identifiant et son mot de passe.
4. Touchez **Ajouter** : le panneau vérifie la connexion avant d'enregistrer.

## 4. Utiliser le kiosque

La barre du bas donne accès aux vues que votre box peut remplir :

- **Énergie** : puissance en direct, consommation et coût sur 24 h, graphe
  heure par heure.
- **Appareils** : vos volets, prises et capteurs. Un appui ouvre les
  commandes.
- **Groupes** : vos groupes d'actions, lancés d'un appui.
- **Thermostats** : une zone par page ; **−** et **+** règlent la consigne.

En haut : le nom de la box (touchez-le pour en changer si vous en avez
plusieurs), l'heure, et la roue des **Réglages**.

## 5. Régler la veille de l'écran

Le kiosque éteint lui-même l'écran après un délai sans appui, et le premier
toucher le rallume sans rien déclencher.

Dans **Réglages**, touchez **Veille de l'écran** pour changer le délai :
1, 2, 5, 10, 30 minutes, ou jamais.

## Revenir au kiosque

Après un redémarrage du panneau, ou si vous êtes revenu à son écran
d'accueil : ouvrez **F-Droid**, puis LiXee-Assist, et touchez **Ouvrir**.

## Mettre à jour

F-Droid signale les nouvelles versions dans son onglet **Mises à jour**.

## En cas de souci

- **Le QR code n'aboutit pas** : le téléphone doit être en WiFi, sur le même
  réseau que le panneau, pas en 4G.
- **« Identifiant ou mot de passe refusé »** : ce sont ceux de la box
  (menu Config → Sécurité), pas ceux de votre WiFi.
- **Une vue manque dans la barre du bas** : elle n'apparaît que si la box a
  de quoi la remplir, par exemple au moins un thermostat.
- **La box est « Hors ligne »** : vérifiez qu'elle est allumée et sur le
  même réseau ; le panneau réessaie toutes les 30 secondes.
