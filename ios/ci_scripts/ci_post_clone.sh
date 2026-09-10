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

# -x : chaque commande s'affiche dans le journal Xcode Cloud avant de
# s'exécuter. Sans lui, un échec ne dit que « exited with code 1 », sans
# indiquer laquelle des étapes a cédé.
set -ex

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

# CocoaPods n'est pas garanti sur l'image Xcode Cloud — mais il y est parfois,
# et l'installer par-dessus fait échouer « brew link ». On ne l'installe donc
# que s'il manque.
if ! command -v pod >/dev/null 2>&1; then
    HOMEBREW_NO_AUTO_UPDATE=1 brew install cocoapods
fi

cd ios
# --repo-update : le Podfile.lock versionné a pris du retard sur les plugins,
# et les versions qu'ils réclament peuvent manquer à l'index local.
pod install --repo-update

exit 0
