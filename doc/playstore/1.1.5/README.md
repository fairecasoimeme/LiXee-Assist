# LiXee-Assist 1.1.5 (48) : notes de version Play Store

## Notes de version (fr-FR, 500 caractères max)

Depuis la dernière version publiée sur le Play Store, la 1.1.4 (46).

```
• Accès à distance : l'activation du tunnel avec le code d'activation ne bloque plus sur « Forbidden : CSRF check failed ».
• Avec une LiXee-Box en v3.3, les conseils et la comparaison des tarifs sont calculés par la box : l'application, la page web de la box et MQTT affichent les mêmes chiffres.
• Onglet Économies : le plus fort appel de puissance, mois par mois.
• Kiosque : l'heure la plus calme ne tombe plus sur une heure non relevée par la box (v3.2), à 0 Wh.
```

## Release notes (en-US)

```
• Remote access: activating the tunnel with the activation code no longer stops on "Forbidden: CSRF check failed".
• With a LiXee-Box on v3.3, the advice and the tariff comparison are computed by the box: the app, the box's web page and MQTT show the same figures.
• Savings tab: the highest power draw, month by month.
• Kiosk: the calmest hour no longer lands on an hour the box did not record (v3.2), at 0 Wh.
```

## Captures d'écran

Inchangées depuis la 1.1.4 (voir `doc/playstore/1.1.4/`).

## Remarques

- **Wi-Fi facultatif** : le paquet `wifi_iot` déclarait le Wi-Fi obligatoire, ce que la console Play signalait. Il est maintenant marqué facultatif dans le manifeste, et la version passe au build 48.

- **Box v3.3** : la partie conseils n'a pas encore été essayée sur une box réelle en v3.3. Les box plus anciennes gardent les calculs de l'application, comme en 1.1.4.
