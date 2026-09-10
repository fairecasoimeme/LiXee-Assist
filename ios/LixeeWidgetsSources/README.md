# Widgets iOS — mise en place dans Xcode

Sources des six widgets iOS, calqués sur ceux d'Android :

| Widget | Rôle | Boutons |
|---|---|---|
| Consommation, Production, Bilan | relevés Linky | non |
| Appareil | état d'un appareil Zigbee | oui |
| Groupe d'actions | déclenche un groupe | oui |
| Thermostat | consigne, température, modes | oui |

Elles ne compilent qu'une fois rattachées à une cible *Widget Extension*, qui
ne peut être créée que dans Xcode. Procédure à faire une fois, sur un Mac.

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
2. Clic droit sur le groupe › *Add Files to "Runner"…* › sélectionner **tous**
   les `.swift` de `ios/LixeeWidgetsSources/`.
3. **Décocher** *Copy items if needed* : les fichiers restent où ils sont,
   versionnés. Cible : **LixeeWidgets uniquement**.

## 3. Régler la cible LixeeWidgets

- *General › Minimum Deployments* : **iOS 17.0**. La configuration par
  AppIntent et les boutons interactifs l'exigent ; l'app, elle, reste à
  iOS 15.
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

## 5. Donner `home_widget` à l'extension

L'appui sur un bouton n'est pas traité en Swift : `LixeeActionIntent` réveille
un moteur Flutter qui exécute le rappel enregistré par
`HomeWidget.registerInteractivityCallback`, lequel commande la box avec le même
code que l'app. Rien de l'authentification n'est donc réécrit ici — mais
l'extension a besoin du plugin, que la cible Runner ne lui prête pas.

Ajouter au `Podfile`, **après** avoir créé la cible dans Xcode : l'ajouter
avant ferait échouer `pod install`, qui ne trouverait pas la cible.

```ruby
target 'LixeeWidgets' do
  use_frameworks!
  pod 'home_widget', :path => '.symlinks/plugins/home_widget/ios'
end
```

Puis `pod install`, et versionner `Podfile` et `Podfile.lock`.

## 6. Si Xcode signale « Cycle inside Runner »

Cible Runner › *Build Phases* : faire glisser *Embed Foundation Extensions*
au-dessus de *Thin Binary*.

## 7. Essayer

1. Lancer l'app sur un iPhone sous iOS 17 ou plus, et la laisser relever
   les box une fois : c'est ce relevé qui remplit les catalogues, sans
   lesquels rien n'est proposé au choix.
2. Appui long sur l'écran d'accueil › *+* › LiXee-Assist › un des six
   widgets.
3. Appui long sur le widget › *Modifier le widget* › choisir la box,
   l'appareil, le groupe ou la zone.

Versionner ensuite `project.pbxproj` et le dossier `LixeeWidgets` créé par
Xcode, pour que Xcode Cloud construise l'extension.

## Vérifier les sources sans Xcode

Les sources se relisent hors projet, ce qui évite d'attendre la cible pour
savoir si elles compilent. Le module `home_widget` n'existant qu'après
`pod install`, un module factice suffit à ce contrôle :

```sh
mkdir -p /tmp/hwstub
cat > /tmp/hwstub/home_widget.swift <<'EOF'
import Foundation
public enum HomeWidgetBackgroundWorker {
    public static func run(url: URL?, appGroup: String) async {}
}
EOF
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun --sdk iphoneos swiftc -emit-module -module-name home_widget \
  -target arm64-apple-ios17.0 -sdk "$SDK" \
  -emit-module-path /tmp/hwstub/home_widget.swiftmodule /tmp/hwstub/home_widget.swift
xcrun --sdk iphoneos swiftc -typecheck -target arm64-apple-ios17.0 -sdk "$SDK" \
  -I /tmp/hwstub ios/LixeeWidgetsSources/*.swift
```

## Différences avec Android

- **Pas de confirmation avant d'agir** : Android interpose une boîte de
  dialogue avant d'émettre une commande ; iOS n'offre aucune étape
  intermédiaire depuis un widget, l'appui commande directement.
- **Pas de logo dans l'en-tête** : la marque LiXee est un *drawable* Android ;
  l'ajouter ici demanderait de la reverser dans les *Assets* de l'extension.
- **Rafraîchissement rationné** : iOS décide seul quand relire la
  chronologie, quelques dizaines de fois par jour au plus. L'app redemande un
  rendu à chaque relevé abouti, et chaque appui sur un bouton en provoque un.
