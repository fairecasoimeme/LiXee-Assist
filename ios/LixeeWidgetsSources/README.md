# Widgets iOS — mise en place dans Xcode

Sources des widgets énergie iOS (Consommation, Production, Bilan), en
affichage seul. Elles ne compilent qu'une fois rattachées à une cible
*Widget Extension*, qui ne peut être créée que dans Xcode. Procédure à faire
une fois, sur un Mac.

## 0. Remettre les pods à jour

Le `Podfile.lock` versionné a pris quinze mois de retard sur les plugins.

```sh
flutter pub get
cd ios
pod install --repo-update
```

Versionner le `Podfile.lock` régénéré.

## 1. Créer la cible

1. Ouvrir `ios/Runner.xcworkspace` (le *workspace*, pas le `.xcodeproj`).
2. *File › New › Target… › Widget Extension*.
3. *Product Name* : `LixeeWidgets`. Décocher *Include Live Activity*,
   *Include Control* et *Include Configuration App Intent* : ces sources
   apportent leur propre configuration.
4. À la question *Activate scheme?*, répondre au choix.

## 2. Remplacer les sources générées

1. Dans le groupe `LixeeWidgets`, supprimer les fichiers `.swift` que Xcode
   vient de générer (*Move to Trash*). Garder `Info.plist` et `Assets`.
2. Clic droit sur le groupe › *Add Files to "Runner"…* › sélectionner les
   cinq `.swift` de `ios/LixeeWidgetsSources/`.
3. **Décocher** *Copy items if needed* : les fichiers restent où ils sont,
   versionnés. Cible : **LixeeWidgets uniquement**.

## 3. Régler la cible LixeeWidgets

- *General › Minimum Deployments* : **iOS 17.0**. La configuration par
  AppIntent l'exige ; l'app, elle, reste à iOS 14.
- *Build Settings › Product Bundle Identifier* : il doit **prolonger celui de
  l'app, dans chaque configuration**. Or Runner n'a pas le même identifiant
  partout :

  | Configuration | Runner | LixeeWidgets |
  |---|---|---|
  | Debug, Profile | `com.lixee.assist` | `com.lixee.assist.LixeeWidgets` |
  | Release | `com.lixee.lixee-assist` | `com.lixee.lixee-assist.LixeeWidgets` |

## 4. App Group — sur les deux cibles

*Signing & Capabilities › + Capability › App Groups*, sur **Runner** et sur
**LixeeWidgets**, avec le même identifiant :

```
group.com.lixee.assist
```

C'est par lui que l'app transmet les relevés au widget. Il doit rester
identique à `Shared.appGroup` (Swift) et à `HomeWidgetBridge.appGroupId`
(Dart).

## 5. Si Xcode signale « Cycle inside Runner »

Cible Runner › *Build Phases* : faire glisser *Embed Foundation Extensions*
au-dessus de *Thin Binary*.

## 6. Essayer

1. Lancer l'app sur un iPhone sous iOS 17 ou plus, et la laisser relever
   les box une fois.
2. Appui long sur l'écran d'accueil › *+* › LiXee-Assist › un des trois
   widgets, en taille moyenne ou grande.
3. Appui long sur le widget › *Modifier le widget* › choisir la box.

Versionner ensuite `project.pbxproj` et le dossier `LixeeWidgets` créé par
Xcode, pour que Xcode Cloud construise l'extension.

## Différences avec Android

- **Pas de confirmation avant d'ouvrir l'app** : iOS ouvre l'app dès l'appui,
  sans étape intermédiaire possible.
- **Pas de rafraîchissement par appui** : un appui ouvre l'app sur la box,
  qui relève et redessine le widget au passage.
- **Rafraîchissement rationné** : iOS décide seul quand relire la
  chronologie, quelques dizaines de fois par jour au plus.
