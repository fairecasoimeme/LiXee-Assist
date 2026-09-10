# Widgets iOS

Sources des six widgets iOS, calqués sur ceux d'Android :

| Widget | Rôle | Boutons |
|---|---|---|
| Consommation, Production, Bilan | relevés Linky | non |
| Appareil | état d'un appareil Zigbee | oui |
| Groupe d'actions | déclenche un groupe | oui |
| Thermostat | consigne, température, modes | oui |

La cible *Widget Extension* `LixeeWidgets` fait partie du projet : rien n'est
à créer dans Xcode. `flutter build ios` construit l'extension avec l'app et
l'embarque dans `Runner.app/PlugIns/`.

## Comment un bouton commande la box

L'appui n'est pas traité en Swift. `LixeeActionIntent` réveille un moteur
Flutter dans l'extension, qui exécute le rappel enregistré par
`HomeWidget.registerInteractivityCallback` et commande la box avec le même
code que l'app. Rien de l'authentification n'est donc réécrit ici — mais
l'extension a besoin du plugin `home_widget`, que la cible Runner ne lui
prête pas : le `Podfile` le lui donne dans son propre bloc `target`.

## App Group

Runner et LixeeWidgets partagent `group.com.lixee.assist`, par où l'app
transmet les relevés et les catalogues. Il doit rester identique à
`Shared.appGroup` (Swift) et à `HomeWidgetBridge.appGroupId` (Dart).

Les deux cibles le déclarent dans leurs entitlements. La capacité *App Groups*
doit être activée sur les deux App ID du portail développeur, faute de quoi la
signature échoue sur appareil :

| | Debug, Profile | Release |
|---|---|---|
| App | `com.lixee.assist` | `com.lixee.lixee-assist` |
| Extension | `com.lixee.assist.LixeeWidgets` | `com.lixee.lixee-assist.LixeeWidgets` |

L'identifiant de l'extension prolonge celui de l'app dans chaque
configuration : iOS l'exige, et l'app n'a pas le même identifiant partout.

## Vérifier

```sh
flutter build ios --simulator --debug
```

C'est le seul contrôle qui vaille. Un `swiftc -typecheck` sur ces sources
passe alors même que l'extension ne s'installerait pas : le compilateur de
métadonnées AppIntents impose des contraintes qu'il ignore — une `EntityQuery`
générique, par exemple, se compile mais est rejetée.

Pour essayer sur appareil, sous iOS 17 ou plus :

1. Lancer l'app et la laisser relever les box une fois : c'est ce relevé qui
   remplit les catalogues, sans lesquels rien n'est proposé au choix.
2. Appui long sur l'écran d'accueil › *+* › LiXee-Assist › un des six widgets.
3. Appui long sur le widget › *Modifier le widget* › choisir la box,
   l'appareil, le groupe ou la zone.

## Différences avec Android

- **Pas de confirmation avant d'agir** : Android interpose une boîte de
  dialogue avant d'émettre une commande ; iOS n'offre aucune étape
  intermédiaire depuis un widget, l'appui commande directement.
- **Pas de logo dans l'en-tête** : la marque LiXee est un *drawable* Android ;
  l'ajouter ici demanderait de la reverser dans les *Assets* de l'extension.
- **Rafraîchissement rationné** : iOS décide seul quand relire la
  chronologie, quelques dizaines de fois par jour au plus. L'app redemande un
  rendu à chaque relevé abouti, et chaque appui sur un bouton en provoque un.
