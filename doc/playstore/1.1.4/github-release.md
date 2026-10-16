## LiXee-Assist 1.1.4

### Nouveautés depuis la 1.1.2
- **Énergie détaillée** : le graphe heure par heure distingue les tarifs et les sous-compteurs. Il montre la production sous l'axe, et le gaz et l'eau s'affichent à côté de l'électricité.
- **Économies** : un nouvel onglet du kiosque, calculé sur les vraies données de la maison. On y trouve :
  - le mois face au budget réglé dans la box ;
  - la consommation plancher ;
  - l'abonnement comparé aux pics de puissance ;
  - le délestage, avec un bouton « Rallumer ».
- **Comparaison des tarifs réglementés** : Base, Heures creuses et Tempo, grille du 1er août 2026, appliqués à la consommation relevée.
  - Exacte pour les contrats HC et Tempo, grâce aux totaux de chaque jour.
  - Estimée en Base, faute d'historique heure par heure dans la box.
- **Graphes en plein écran** : un toucher (ou OK sur la TV) ouvre l'électricité, le gaz ou l'eau en grand, chaque heure détaillée.
- **Risque de coupure** :
  - il s'appuie sur la charge à la minute fournie par la box (v2.26) ;
  - en triphasé, une jauge par phase ;
  - avec des panneaux solaires, la jauge d'injection.
- **Météo de l'électricité** : le tarif en cours, son prix, la couleur Tempo du lendemain, et des alertes discrètes.
- **Kiosque** :
  - disponible sur téléphone et tablette ;
  - navigation par glissement ;
  - mise en page paysage.
- **Vieux Android** : l'accès à distance par le tunnel fonctionne de nouveau sur Android 7, grâce aux racines Let's Encrypt embarquées.

### Changements
- Android 7.0 minimum (SDK 24), comme l'exige la protection automatique du Play Store.

### Fichiers
- `lixee-assist-libre-1.1.4.apk` : la version libre (sans Firebase ni services Google), signée avec la clé habituelle. Le dépôt F-Droid LiXee la reprend automatiquement à la publication de cette version.
