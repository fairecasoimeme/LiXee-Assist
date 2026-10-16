import 'package:flutter/material.dart';

import '../panel/app_mode.dart';

/// Réglage des deux modes d'affichage, depuis l'interface normale : lequel
/// s'ouvre au lancement, et les options de chacun.
class DisplayModeScreen extends StatefulWidget {
  const DisplayModeScreen({super.key});

  @override
  State<DisplayModeScreen> createState() => _DisplayModeScreenState();
}

class _DisplayModeScreenState extends State<DisplayModeScreen> {
  static const _blue = Color(0xFF1B75BC);

  /// Applique un réglage, puis redessine l'écran avec sa nouvelle valeur.
  Future<void> _set(Future<void> Function() change) async {
    await change();
    if (mounted) setState(() {});
  }

  /// Le kiosque remplace toute l'interface : cet écran disparaît avec elle.
  Future<void> _openKiosk() => AppMode.enterKiosk();

  Widget _title(IconData icon, String title, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, color: _blue),
            const SizedBox(width: 10),
            Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(text, style: TextStyle(color: Colors.grey.shade700)),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Modes d'affichage")),
      body: ListView(
        children: [
          _title(
            Icons.rocket_launch_outlined,
            'Au lancement',
            "Le mode dans lequel l'application s'ouvre.",
          ),
          RadioListTile<bool>(
            value: false,
            groupValue: AppMode.startInKiosk,
            activeColor: _blue,
            title: const Text('Mode normal'),
            subtitle: const Text(
              "La liste de vos box et leur interface complète : pour le "
              'téléphone de tous les jours.',
            ),
            onChanged: (_) => _set(() => AppMode.setStartInKiosk(false)),
          ),
          RadioListTile<bool>(
            value: true,
            groupValue: AppMode.startInKiosk,
            activeColor: _blue,
            title: const Text('Mode kiosque'),
            subtitle: const Text(
              'Un tableau de bord à gros boutons : pour une tablette ou un '
              'ancien téléphone posé au mur.',
            ),
            onChanged: (_) => _set(() => AppMode.setStartInKiosk(true)),
          ),
          const Divider(height: 32),

          _title(
            Icons.dashboard_outlined,
            'Mode kiosque',
            'Énergie, appareils, groupes et thermostats, une box à la fois. '
                'Les réglages se retrouvent aussi dans le kiosque, sous la '
                'roue dentée.',
          ),
          SwitchListTile(
            value: AppMode.kioskKeepAwake,
            activeColor: _blue,
            title: const Text('Écran toujours allumé'),
            subtitle: const Text(
              "L'écran ne se met pas en veille tant que le kiosque est "
              'affiché. À réserver à un appareil branché.',
            ),
            onChanged: (v) => _set(() => AppMode.setKioskKeepAwake(v)),
          ),
          SwitchListTile(
            value: AppMode.kioskFullscreen,
            activeColor: _blue,
            title: const Text('Plein écran'),
            subtitle: const Text(
              "Masque la barre d'état et les boutons du système.",
            ),
            onChanged: (v) => _set(() => AppMode.setKioskFullscreen(v)),
          ),
          ListTile(
            title: const Text("Vue à l'ouverture"),
            trailing: DropdownButton<KioskTab>(
              value: AppMode.kioskStartTab,
              underline: const SizedBox(),
              items: [
                for (final tab in KioskTab.values)
                  DropdownMenuItem(value: tab, child: Text(tab.label)),
              ],
              onChanged:
                  (tab) =>
                      tab == null
                          ? null
                          : _set(() => AppMode.setKioskStartTab(tab)),
            ),
          ),
          ListTile(
            title: const Text('Actualisation'),
            subtitle: const Text(
              'Un relevé plus espacé ménage la batterie et le réseau.',
            ),
            trailing: DropdownButton<int>(
              value: AppMode.kioskRefreshSeconds,
              underline: const SizedBox(),
              items: [
                for (final seconds in AppMode.refreshChoices)
                  DropdownMenuItem(
                    value: seconds,
                    child: Text(refreshLabel(seconds)),
                  ),
              ],
              onChanged:
                  (seconds) =>
                      seconds == null
                          ? null
                          : _set(() => AppMode.setKioskRefreshSeconds(seconds)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: _blue,
                minimumSize: const Size.fromHeight(48),
              ),
              icon: const Icon(Icons.dashboard_outlined),
              label: const Text('Passer en mode kiosque'),
              onPressed: _openKiosk,
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'Pour en revenir : la roue dentée du kiosque, puis « Revenir au '
              'mode normal ».',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ),
          const Divider(height: 32),

          _title(
            Icons.phone_android,
            'Mode normal',
            "L'interface habituelle de LiXee-Assist.",
          ),
          SwitchListTile(
            value: AppMode.normalKeepAwake,
            activeColor: _blue,
            title: const Text('Écran toujours allumé'),
            subtitle: const Text(
              "L'écran ne se met pas en veille tant que l'application est "
              'affichée.',
            ),
            onChanged: (v) => _set(() => AppMode.setNormalKeepAwake(v)),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
