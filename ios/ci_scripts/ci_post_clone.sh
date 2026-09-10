#!/bin/sh
#
# Préparation du clone pour Xcode Cloud.
#
# Xcode Cloud part d'un clone nu du dépôt : ni Flutter, ni les pods. Or le
# projet iOS dépend de fichiers qu'ils génèrent et qui ne sont pas versionnés —
# ios/Flutter/Generated.xcconfig (flutter pub get) et les .xcfilelist de
# Pods/Target Support Files (pod install). Sans ce script, le build échoue sur
# « could not find included file 'Generated.xcconfig' » et « Unable to load
# contents of file list ».
#
# Xcode Cloud exécute ce fichier de lui-même, parce qu'il se trouve dans un
# dossier ci_scripts voisin du .xcworkspace. Il doit rester exécutable.

set -e

# Même version que celle qui construit l'app ailleurs : une version « stable »
# flottante ferait changer le build sans que le code ait bougé.
FLUTTER_VERSION="3.29.3"

cd "$CI_PRIMARY_REPOSITORY_PATH"

git clone https://github.com/flutter/flutter.git --depth 1 \
    --branch "$FLUTTER_VERSION" "$HOME/flutter"
export PATH="$PATH:$HOME/flutter/bin"

# Artefacts iOS du moteur, que le build attend déjà présents.
flutter precache --ios

# Crée ios/Flutter/Generated.xcconfig et résout les paquets Dart.
flutter pub get

# CocoaPods n'est pas garanti sur l'image Xcode Cloud.
HOMEBREW_NO_AUTO_UPDATE=1 brew install cocoapods

cd ios
pod install

exit 0
