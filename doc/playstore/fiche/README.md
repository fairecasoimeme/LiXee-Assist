# Fiche Play Store de LiXee-Assist

Textes et images de la fiche principale du Play Store (version avec
Firebase). La fiche F-Droid, qui décrit la version libre, est dans
`fastlane/metadata/android/`.

## Textes

| Champ | Limite | Français | Anglais |
|---|---|---|---|
| Titre | 30 | `fr-FR/title.txt` | `en-US/title.txt` |
| Description courte | 80 | `fr-FR/short_description.txt` | `en-US/short_description.txt` |
| Description complète | 4 000 | `fr-FR/full_description.txt` | `en-US/full_description.txt` |

Les notes de version de la 1.1.4 sont dans `fastlane/metadata/android/*/changelogs/46.txt`.

## Images (`screenshots/`)

**Image de présentation** (1024 × 500, obligatoire) : `feature-graphic-fr.png`,
`feature-graphic-en.png`. Source : projet Remotion LiXee-Box,
`src/store/FeatureGraphic.tsx` (`npx remotion still FeatureGraphicFr`).

**Téléphone** (1080 × 1920, 8 au maximum : en choisir 8 sur 9) :

| Fichier | Légende |
|---|---|
| `phone/01-energie.png` | Puissance, risque de coupure, budget, gaz, eau et électricité |
| `phone/02-graphe-detail.png` | Chaque heure en détail, comparée à l'heure habituelle |
| `phone/03-economies.png` | Les économies calculées sur les vraies données de la maison |
| `phone/04-comparaison-tarifs.png` | Base, Heures creuses ou Tempo : quel tarif coûte le moins |
| `phone/05-appareils.png` | Volets, capteurs et prises Zigbee |
| `phone/06-thermostat.png` | Consigne et mode de chaque zone |
| `phone/07-mes-box.png` | Les box, en local ou par le tunnel |
| `phone/08-interface-box.png` | L'interface complète de la box |
| `phone/09-modes-affichage.png` | Mode normal ou kiosque, au choix |

**Android TV** (1280 × 720) : `tv/01-energie.png`, `tv/02-economies.png`,
`tv/03-graphe-detail.png`, `tv/04-accueil.png`.

Les captures montrent des box réelles (canohes, llupia…) : leurs adresses sont
tronquées à l'écran, et la barre d'état du téléphone est masquée.
