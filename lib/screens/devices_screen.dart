import 'package:flutter/material.dart';

class DevicesScreen extends StatefulWidget {
  @override
  _DevicesScreenState createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  List<Map<String, dynamic>> devices = [
    {"name": "Lampe Salon", "status": true},
    {"name": "Prise Cuisine", "status": false},
    {"name": "Capteur Température", "status": true},
  ];

  void toggleDeviceStatus(int index) {
    setState(() {
      devices[index]["status"] = !devices[index]["status"];
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Appareils Zigbee")),
      body: ListView.builder(
        itemCount: devices.length,
        itemBuilder: (context, index) {
          return Card(
            child: ListTile(
              title: Text(devices[index]["name"]),
              trailing: Switch(
                value: devices[index]["status"],
                onChanged: (value) => toggleDeviceStatus(index),
              ),
            ),
          );
        },
      ),
    );
  }
}
