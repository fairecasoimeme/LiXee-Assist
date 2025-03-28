import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';

class DashboardScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Tableau de Bord")),
      body: Padding(
        padding: EdgeInsets.all(20),
        child: Column(
          children: [
            Text("Consommation en temps réel", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            SizedBox(height: 10),
            Expanded(child: LineChart(_buildChartData())),
            SizedBox(height: 20),
            ElevatedButton(
              onPressed: () {
                // TODO: Ajouter action de rafraîchissement des données
              },
              child: Text("Rafraîchir les données"),
            ),
          ],
        ),
      ),
    );
  }

  /// 📊 Données factices pour le graphique
  LineChartData _buildChartData() {
    return LineChartData(
      titlesData: FlTitlesData(show: true),
      borderData: FlBorderData(show: false),
      lineBarsData: [
        LineChartBarData(
          spots: [
            FlSpot(0, 10),
            FlSpot(1, 20),
            FlSpot(2, 30),
            FlSpot(3, 25),
            FlSpot(4, 40),
            FlSpot(5, 50),
          ],
          isCurved: true,
          color: Colors.green,
          barWidth: 3,
          isStrokeCapRound: true,
        ),
      ],
    );
  }
}
