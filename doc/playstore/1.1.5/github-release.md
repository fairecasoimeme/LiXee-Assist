## LiXee-Assist 1.1.5

### Corrections
- **Activation du tunnel** : la validation du code d'activation échouait avec « Forbidden : CSRF check failed » sur les box récentes. L'application présente désormais à la box sa propre adresse comme origine des requêtes, au lieu de celle du proxy local.

### Nouveautés
- **Conseils calculés par la box** : avec une LiXee-Box en v3.3, l'application affiche les conseils que la box calcule (`/api/energy/advice`), sans rien recalculer. La page web de la box, MQTT et l'application disent donc la même chose. Cela couvre :
  - la météo de l'électricité ;
  - le risque de coupure ;
  - la consommation plancher ;
  - l'abonnement ;
  - le mois face au budget ;
  - les alertes ;
  - la comparaison des tarifs réglementés, avec la grille et les couleurs Tempo relevées par la box.
- **Box plus anciennes** (v2.26, v3.0 à v3.2) : rien ne change, l'application garde ses propres calculs.
- **Économies** : le plus fort appel de puissance, mois par mois, comparé à l'abonnement (box v3.3).

### Fichiers
- `lixee-assist-libre-1.1.5.apk` : la version libre (sans Firebase ni services Google), signée avec la clé habituelle. Le dépôt F-Droid LiXee la reprend automatiquement à la publication de cette version.
