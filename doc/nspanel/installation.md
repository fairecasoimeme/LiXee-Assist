# Installer LiXee-Assist sur un Sonoff NSPanel Pro

Ce guide installe LiXee-Assist sur un panneau mural Sonoff NSPanel Pro, où
l'application s'ouvre en kiosque tactile : énergie, appareils, groupes
d'actions et thermostats de votre LiXee-Box, sans navigateur.

Tout se fait au doigt, sur le panneau. Comptez cinq minutes.

F-Droid s'affiche en anglais sur le panneau : ses libellés sont donnés ici
tels qu'ils apparaissent à l'écran.

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
2. En bas de l'écran, touchez **Settings**, puis **Repositories**.
3. Touchez le bouton **+** en bas à droite, puis saisissez l'adresse du
   dépôt :

       https://fairecasoimeme.github.io/LiXee-Assist/fdroid/repo

4. Validez. Le dépôt **LiXee** s'ajoute à la liste, sous celui de F-Droid.

## 2. Installer LiXee-Assist

1. Revenez à l'écran principal de F-Droid et cherchez **LiXee-Assist**.
2. Ouvrez sa fiche, touchez **Install**, puis confirmez l'installation
   quand le panneau le demande.
3. Touchez **Open**.

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

## 5. Les réglages du kiosque

Touchez la roue, en haut à droite. Chaque appui sur une ligne passe à la
valeur suivante.

- **Veille de l'écran** : le kiosque éteint l'écran après ce délai sans
  appui (1, 2, 5, 10, 30 minutes, ou jamais). Le premier toucher le rallume
  sans rien déclencher.
- **Lancer au démarrage** : le kiosque s'ouvre tout seul quand le panneau
  redémarre.
- **Retour automatique** : après un passage par l'écran du panneau, le
  kiosque revient de lui-même au premier plan une fois l'écran éteint
  (1, 2, 5, 10 minutes, ou jamais).
- **Quitter le kiosque** : rend la main à l'écran d'accueil du panneau.

Pour quitter durablement le kiosque, réglez **Retour automatique** sur
« Jamais » avant de toucher **Quitter le kiosque**.

## Rouvrir le kiosque à la main

Avec les réglages d'origine, vous n'avez rien à faire : le kiosque se lance
au démarrage et revient seul.

Si vous avez désactivé ces réglages : ouvrez **F-Droid**, puis
**Settings → Manage installed apps**, touchez LiXee-Assist, puis **Open**.

## Mettre à jour

Dans F-Droid, ouvrez l'onglet **Updates** et tirez la liste vers le bas pour
l'actualiser. Quand une nouvelle version existe, touchez **Update**.

## En cas de souci

- **Le QR code n'aboutit pas** : le téléphone doit être en WiFi, sur le même
  réseau que le panneau, pas en 4G.
- **« Identifiant ou mot de passe refusé »** : ce sont ceux de la box
  (menu Config → Sécurité), pas ceux de votre WiFi.
- **Une vue manque dans la barre du bas** : elle n'apparaît que si la box a
  de quoi la remplir, par exemple au moins un thermostat.
- **La box est « Hors ligne »** : vérifiez qu'elle est allumée et sur le
  même réseau ; le panneau réessaie toutes les 30 secondes.
- **F-Droid ne propose pas la dernière version** : sa liste date de sa
  dernière actualisation. Tirez l'onglet **Updates** vers le bas, puis
  réessayez après quelques minutes.
