import 'package:flutter/material.dart';

class AutomationScreen extends StatefulWidget {
  @override
  _AutomationScreenState createState() => _AutomationScreenState();
}

class _AutomationScreenState extends State<AutomationScreen> {
  List<String> rules = [
    "Éteindre la prise si > 200W",
    "Allumer la lampe à 18h",
  ];

  void addNewRule() {
    setState(() {
      rules.add("Nouvelle règle...");
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Automatisations")),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              itemCount: rules.length,
              itemBuilder: (context, index) {
                return Card(
                  child: ListTile(
                    title: Text(rules[index]),
                    trailing: IconButton(
                      icon: Icon(Icons.delete, color: Colors.red),
                      onPressed: () {
                        setState(() {
                          rules.removeAt(index);
                        });
                      },
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: EdgeInsets.all(10),
            child: ElevatedButton(
              onPressed: addNewRule,
              child: Text("Ajouter une automatisation"),
            ),
          ),
        ],
      ),
    );
  }
}
