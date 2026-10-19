#!/usr/bin/env bash
# Prépare la variante libre de LiXee-Assist, celle que F-Droid compile.
#
# Elle retire ce qui n'est pas libre : Firebase (notifications push) et le
# lecteur de QR code, qui s'appuie sur ML Kit. Tout le reste est identique.
#
#   tool/foss.sh            transforme les sources en place
#   flutter build apk --release --dart-define=FOSS=true
#
# Le script modifie l'arbre de travail : à lancer sur une copie ou un clone
# jetable, jamais avant un commit. `git checkout -- . && git clean -fd foss`
# ne suffit pas à tout annuler (google-services.json est supprimé).
set -euo pipefail
cd "$(dirname "$0")/.."

# 1. Les deux seuls fichiers Dart qui dépendent de code non libre.
cp foss/lib/services/push_backend.dart lib/services/push_backend.dart
cp foss/lib/screens/qr_scan_screen.dart lib/screens/qr_scan_screen.dart

# 2. Leurs paquets.
sed -i -E '/^  (firebase_core|firebase_messaging|mobile_scanner):/d' pubspec.yaml

# 3. Gradle : toute ligne marquée « non-libre ».
sed -i '/non-libre/d' android/build.gradle.kts android/app/build.gradle.kts
rm -f android/app/google-services.json

# 4. Rien ne doit rester.
if grep -rnE 'firebase|mobile_scanner|google-services|com\.google\.gms' \
    pubspec.yaml lib android/build.gradle.kts android/app/build.gradle.kts \
    android/settings.gradle.kts; then
  echo "Des références non libres subsistent (voir ci-dessus)." >&2
  exit 1
fi
echo "Variante libre prête."
