# Publier LiXee-Assist par F-Droid

Deux canaux, qui partagent la même variante « libre » de l'application
(sans Firebase ni lecteur de QR code, voir `tool/foss.sh`) :

- **le dépôt F-Droid LiXee**, hébergé par GitHub Pages et mis à jour par le
  workflow `.github/workflows/fdroid-repo.yml` ;
- **le dépôt officiel F-Droid**, sur demande auprès de fdroiddata, dont
  `com.lixee.assist.yml` est le brouillon de recette.

## Dépôt F-Droid LiXee

Adresse à donner aux utilisateurs :

    https://fairecasoimeme.github.io/LiXee-Assist/fdroid/repo

### Mise en place, une seule fois

1. **Créer la clé du dépôt.** Elle signe l'index, pas les APK ; elle est
   distincte de la clé de publication de l'application. Choisissez un mot de
   passe et gardez le fichier en lieu sûr : le perdre oblige tous les
   utilisateurs à retirer puis rajouter le dépôt.

       keytool -genkeypair -v -keystore lixee-fdroid.p12 -storetype PKCS12 \
         -alias lixee-fdroid -keyalg RSA -keysize 4096 -validity 10000 \
         -dname "CN=LiXee F-Droid, O=LIXEE SAS, C=FR"

2. **Ajouter deux secrets** au dépôt GitHub (Settings → Secrets and
   variables → Actions) :
   - `FDROID_KEYSTORE_B64` : le fichier `lixee-fdroid.p12` encodé en base64.
     Sous Linux ou macOS : `base64 -w0 lixee-fdroid.p12`. Sous Windows, dans
     PowerShell, cette commande met le texte dans le presse-papiers, prêt à
     coller dans GitHub :

         [Convert]::ToBase64String([IO.File]::ReadAllBytes("lixee-fdroid.p12")) | Set-Clipboard

   - `FDROID_KEYSTORE_PASS` : son mot de passe.

3. **Activer GitHub Pages** (Settings → Pages), source « GitHub Actions ».

### À chaque version

1. Compiler la variante libre, sur une copie du dépôt :

       bash tool/foss.sh
       flutter build apk --release

2. Créer une version GitHub (étiquette `v1.2.0`, par exemple) et y joindre
   l'APK sous le nom `lixee-assist-libre-1.2.0.apk`. Le préfixe compte : le
   workflow ne prend que les fichiers `lixee-assist-libre-*.apk`.

3. Publier la version : le workflow se lance, reconstruit l'index et met le
   site en ligne. Il se relance aussi à la main (Actions → Dépôt F-Droid →
   Run workflow).

Le dépôt garde les trois dernières versions ; les plus anciennes passent en
archive.

### Limites connues

- L'APK est signé avec la clé de publication LiXee. La version du dépôt
  officiel F-Droid, elle, sera signée par F-Droid : on ne passe pas de l'une
  à l'autre sans désinstaller.
- La version du Play Store porte encore une autre signature (celle de
  Google) : même contrainte.

## Dépôt officiel F-Droid

La demande se fait par une « merge request » sur
<https://gitlab.com/fdroid/fdroiddata>, avec `com.lixee.assist.yml` adapté à
la version visée. Avant de la déposer :

- `versionName`, `versionCode` et `commit` doivent désigner une étiquette
  git publiée ;
- `bundletool-all-1.18.1.jar` est suivi dans le dépôt : la recette le
  supprime, mais le retirer du dépôt évite une remarque à la relecture.
