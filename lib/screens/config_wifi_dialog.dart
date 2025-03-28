import 'package:flutter/material.dart';

class ConfigWifiDialog extends StatefulWidget {
  final Function(String, String) onSubmit;

  ConfigWifiDialog({required this.onSubmit});

  @override
  _ConfigWifiDialogState createState() => _ConfigWifiDialogState();
}

class _ConfigWifiDialogState extends State<ConfigWifiDialog> {
  final TextEditingController ssidController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text("Configurer WiFi"),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: ssidController,
            decoration: InputDecoration(labelText: "SSID"),
          ),
          TextField(
            controller: passwordController,
            decoration: InputDecoration(labelText: "Mot de passe"),
            obscureText: true,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text("Annuler"),
        ),
        ElevatedButton(
          onPressed: () {
            widget.onSubmit(ssidController.text, passwordController.text);
            Navigator.pop(context);
          },
          child: Text("Envoyer"),
        ),
      ],
    );
  }
}
