# LiXee-Box : historique de consommation heure par heure

Demande de l'application **LiXee-Assist** (kiosque, TV, NSPanel) au firmware
de la LiXee-Box, pour la **comparaison des offres d'électricité**. Ce document
s'adresse à la session Claude Code du firmware : il dit ce qu'il faut
collecter et exposer, et comment l'application s'en servira.

## Contexte

LiXee-Assist compare les trois options du tarif réglementé (Tarif Bleu d'EDF :
Base, Heures creuses, Tempo) sur la **consommation réelle de la maison**, et
dit à l'utilisateur laquelle lui coûterait le moins.

Aujourd'hui, l'application ne dispose que de :

| Source | Contenu | Limite |
|---|---|---|
| `/exportEnergyChart?time=hour` | 24 dernières heures, heure par heure, par index | 24 h seulement |
| `/exportEnergyChart?time=day` | ~30 jours, total par jour et par index (HC / HP) | aucun horaire |

Conséquences :

- **Contrat HC ou Tempo** : les totaux HC et HP de chaque jour suffisent à
  recalculer les autres options. L'application le fait sans changement côté
  box.
- **Contrat Base** : on ne connaît que le total de chaque jour. Impossible de
  savoir quelle part aurait été consommée en heures creuses, donc de dire si
  Heures creuses ou Tempo seraient rentables. C'est pourtant le cas le plus
  fréquent, et celui où le conseil est le plus utile.
- **Sur un an** : 30 jours d'octobre ne disent rien de l'hiver. Les jours
  rouges Tempo (22 par an, de novembre à mars) tombent quand le chauffage
  électrique tourne : il faut l'historique d'une saison entière.

Seule la box voit tourner les index en continu ; l'application ne voit que
des instantanés. **La collecte doit donc se faire dans la box.**

## 1. Collecte et stockage (le cœur de la demande)

Chaque heure, enregistrer :

| Donnée | Calcul | Taille |
|---|---|---|
| Consommation | Différence de l'index total de soutirage sur l'heure (somme des index tarifaires, ou EAST en mode standard), en Wh | 2 octets (`0xFFFF` = inconnu) |
| Injection | Différence de EAIT, ou de l'index du ZLinky de production, en Wh ; seulement si la maison produit | 2 octets |
| Index tarifaire | Rang de l'index actif pendant l'heure (0 = attribut 256, 1 = 258…), `0xFE` s'il a changé en cours d'heure, `0xFF` si inconnu | 1 octet |

- **Par différence d'index**, pas en intégrant la puissance : c'est exact et
  robuste aux relevés manqués.
- **Durée** : au moins **400 jours**, en tampon tournant. De quoi couvrir une
  saison Tempo complète (1er septembre → 31 août) et comparer un mois au même
  mois de l'année précédente.
- **Taille** : 5 octets × 24 × 400 ≈ **48 Ko**. Un fichier binaire à taille
  fixe sur LittleFS, avec l'heure de départ en en-tête, convient ; écriture une
  fois par heure, l'usure de la flash reste négligeable.
- **Heures en UTC** : pas de journées de 23 ou 25 heures au changement
  d'heure. L'application convertit en heure de Paris.
- **Après un redémarrage ou une perte du Linky** : les heures sans relevé
  valent « inconnu ». L'énergie accumulée pendant le trou (écart d'index) est
  posée sur la **première heure suivante**, et le trou est signalé (`gaps`,
  ci-dessous) : l'application saura que cette heure regroupe plusieurs heures.
- **Reprise de l'existant** : si la box conserve déjà des données horaires
  au-delà de 24 h (fichiers des graphes, courbe de charge), les exposer par la
  même route permettrait une comparaison tout de suite, sans attendre des mois
  de collecte.

## 2. `GET /api/energy/hourly`

Paramètres, lus par nom : `days=N` (1 à 400, défaut 30), ou `from=AAAA-MM-JJ`
et `to=AAAA-MM-JJ` (UTC, `to` inclus).

```json
{
  "startUtc": "2026-09-15T22:00:00Z",
  "stepS": 3600,
  "unit": "Wh",
  "cons":   [412, 388, null, 520],
  "prod":   [0, 0, 0, 0],
  "tariff": [0, 0, null, 1],
  "gaps":   [{"at": "2026-09-16T00:00:00Z", "hours": 1}]
}
```

- Tableaux **plats et alignés** : la valeur `i` porte sur l'heure qui commence
  à `startUtc + i × stepS`.
- `null` pour une heure inconnue (dans `tariff` aussi pour un changement en
  cours d'heure : l'application répartira au prorata).
- `prod` absent sans production ; `tariff` absent en contrat Base.
- `gaps` : chaque trou, avec l'heure qui porte le rattrapage (`at`) et le
  nombre d'heures qu'il couvre.
- **Taille** : 30 jours = 720 valeurs ≈ 4 Ko ; 400 jours ≈ 60 Ko, sous la
  limite d'environ 300 Ko du tunnel. L'application découpera avec `from`/`to`
  si besoin ; une réponse en flux (chunked) est bienvenue pour ne pas tout
  tenir en RAM.

## 3. `GET /api/energy/monthly?months=24`

Totaux par mois, par index, sur 24 mois, pour l'estimation sur un an et la
saisonnalité.

```json
{
  "months": [
    {"month": "2026-01", "days": 31, "measuredDays": 31,
     "wh": {"256": 612000, "258": 801000},
     "prodWh": 0, "costEur": 245.30}
  ]
}
```

- `measuredDays` : jours effectivement relevés (un mois incomplet se voit).
- `costEur` : coût calculé par la box avec les prix saisis, abonnement compris,
  comme `Cout total` de l'export ; `null` sans prix.
- Cette route peut être alimentée par l'historique horaire, ou par des
  compteurs mensuels séparés, plus légers (12 × 24 valeurs).

## 4. Plages d'heures creuses dans `/api/energy/config`

L'application doit savoir à quelles heures tombent les heures creuses de la
maison (elles dépendent du PDL : Enedis les fixe, souvent 22 h – 6 h, parfois
en deux plages).

```json
"offPeak": {"source": "observed", "ranges": [["22:00", "06:00"]]}
```

- `source: "observed"` : contrat HC, plages relevées par la box sur les
  bascules d'index (elle les connaît déjà pour `nextChange` de `/api/tariff`).
- `source: "user"` : contrat Base, plages saisies dans la configuration de la
  box (l'utilisateur les trouve sur sa facture) — un champ à ajouter, avec
  22:00 – 06:00 par défaut.
- `source: "default"` : rien d'observé ni de saisi ; l'application le dira.

## 5. Facultatif : couleurs Tempo passées

Aujourd'hui, l'application lit les couleurs sur `api-couleur-tempo.fr`
(données RTE). Si la box les récupère déjà (contrat Tempo par le compteur, ou
par RTE), une route les rendrait disponibles sans service tiers — utile pour
la variante F-Droid de l'application :

```
GET /api/tempo?season=2025-2026
{"season":"2025-2026","days":{"2025-09-01":1,"2025-09-02":1,"2026-01-12":3}}
```

(1 = bleu, 2 = blanc, 3 = rouge.)

## Règles communes (comme les routes v2.26)

- Une box antérieure répond **404** : l'application garde son estimation
  actuelle et l'affiche comme telle.
- Authentification par `checkAuth` (session par le tunnel, session ou Basic en
  direct).
- Aucun secret dans les réponses.
- Routes existantes inchangées.

## Ce que fera l'application

- **Contrat Base** : chaque heure de l'historique reçoit le prix qu'elle
  aurait eu en Heures creuses (selon `offPeak`) et en Tempo (selon la couleur
  du jour, jour Tempo de 6 h à 6 h) : comparaison exacte sur les jours relevés.
- **Sur un an** : les mois de `monthly` pondèrent l'estimation (l'hiver pèse
  ce qu'il pèse).
- **Affichage** : « Avec Tempo, tu aurais payé X € de moins sur les 30 derniers
  jours, ≈ Y € sur un an. »

## Critères de recette

1. Après 48 h de fonctionnement, `/api/energy/hourly?days=2` renvoie 48
   valeurs dont la somme égale l'écart de l'index total sur la période (à
   1 Wh près par heure).
2. Un redémarrage de 2 h produit un `gap` de 2 heures et aucune énergie
   perdue : la somme reste égale à l'écart d'index.
3. Au passage à l'heure d'hiver, aucune heure dupliquée ni manquante (UTC).
4. En contrat HC, `tariff` bascule aux heures de `offPeak.ranges`.
5. `days=400` sur une box pleine répond en moins de 5 s et sous 300 Ko.

## Rappel : correctif encore attendu en v2.26

Dans `/api/energy/config`, la clé `"water"` apparaît deux fois : l'adresse IEEE
du compteur d'eau, puis l'objet de ses réglages, qui l'écrase. Renommer
l'adresse en `waterIeee` (l'application lit déjà `waterIeee` ou `water.ieee`).
