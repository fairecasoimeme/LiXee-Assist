import 'package:flutter_test/flutter_test.dart';
import 'package:zigpower_connect/services/energy_detail_service.dart';
import 'package:zigpower_connect/services/tariff_compare.dart';
import 'package:zigpower_connect/services/widget_data_service.dart';

LinkySnapshot _snapshot({
  String contract = 'BASE',
  int subscribedA = 30,
  List<HourlySample> hourly = const [],
}) => LinkySnapshot(
  deviceName: 'maison',
  timestamp: DateTime(2026, 10, 15, 12),
  source: LinkySource.local,
  subscribedCurrentA: subscribedA,
  contract: contract,
  hourly: hourly,
);

/// Trente jours à 10 kWh, puis aujourd'hui, incomplet.
final _daily = [
  for (var i = 0; i < 30; i++) const DailySample(1, 10, 10000),
  const DailySample(15, 10, 4000),
];

void main() {
  final now = DateTime(2026, 10, 15, 12);

  test('option du contrat d\'après le compteur', () {
    expect(TariffCompare.optionOf('BASE'), TariffOption.base);
    expect(TariffCompare.optionOf('HC..'), TariffOption.offPeak);
    expect(TariffCompare.optionOf('BBR(T'), TariffOption.tempo);
    expect(TariffCompare.optionOf('TEMPO'), TariffOption.tempo);
    expect(TariffCompare.optionOf('EJP.'), isNull);
  });

  test('heures creuses supposées de 22 h à 6 h sans contrat HC', () {
    final split = TariffCompare.offPeakShare([
      for (var h = 0; h < 24; h++) HourlySample(h, 1000),
      const HourlySample(12, 100),
    ], TariffOption.base);
    expect(split.measured, isFalse);
    expect(split.share, closeTo(8 / 24, 1e-9));
  });

  test('heures creuses mesurées par les index d\'un contrat HC', () {
    final split = TariffCompare.offPeakShare([
      for (var h = 0; h < 24; h++)
        HourlySample(h, 1000, 0, 0, 0, {h < 12 ? 256 : 258: 1000}),
      const HourlySample(12, 100),
    ], TariffOption.offPeak);
    expect(split.measured, isTrue);
    expect(split.share, closeTo(0.5, 1e-9));
  });

  test('base 6 kVA sur trente jours, abonnement au prorata', () {
    final r =
        TariffCompare.compare(
          snapshot: _snapshot(),
          daily: _daily,
          colors: const {},
          now: now,
        )!;
    expect(r.days, 30);
    expect(r.current, TariffOption.base);
    final base = r.costOf(TariffOption.base)!;
    expect(base.kva, 6);
    expect(base.energyEur, closeTo(300 * 0.2001, 1e-6));
    expect(base.subscriptionEur, closeTo(190.81 * 30 / 365, 1e-6));
  });

  test('un jour rouge pèse sur Tempo', () {
    final redDay = DateTime(2026, 10, 14);
    final blue =
        TariffCompare.compare(
          snapshot: _snapshot(),
          daily: _daily,
          colors: const {},
          now: now,
        )!;
    final red =
        TariffCompare.compare(
          snapshot: _snapshot(),
          daily: _daily,
          colors: {redDay: TempoColor.red},
          now: now,
        )!;
    expect(red.redDays, 1);
    expect(
      red.costOf(TariffOption.tempo)!.energyEur,
      greaterThan(blue.costOf(TariffOption.tempo)!.energyEur),
    );
  });

  test('en HC, la part de chaque jour vient de ses totaux', () {
    final r =
        TariffCompare.compare(
          snapshot: _snapshot(contract: 'HC..'),
          daily: [
            for (var i = 0; i < 30; i++)
              const DailySample(1, 10, 10000, 0, {256: 6000, 258: 4000}),
            const DailySample(15, 10, 4000),
          ],
          colors: const {},
          now: now,
        )!;
    expect(r.offPeakSource, OffPeakSource.daily);
    expect(r.offPeakShare, closeTo(0.6, 1e-9));
    expect(
      r.costOf(TariffOption.offPeak)!.energyEur,
      closeTo(300 * (0.6 * 0.1589 + 0.4 * 0.2142), 1e-6),
    );
  });

  test('en Base, la part des heures creuses est estimée', () {
    final r =
        TariffCompare.compare(
          snapshot: _snapshot(),
          daily: _daily,
          colors: const {},
          now: now,
        )!;
    expect(r.offPeakSource, OffPeakSource.assumed);
  });

  test('au-delà de 15 kVA, pas d\'option Base', () {
    final r =
        TariffCompare.compare(
          // 90 A en historique : 18 kVA.
          snapshot: _snapshot(subscribedA: 90, contract: 'HC..'),
          daily: _daily,
          colors: const {},
          now: now,
        )!;
    expect(r.costOf(TariffOption.base), isNull);
    expect(r.costOf(TariffOption.offPeak)!.kva, 18);
  });

  test('pas de comparaison sans une semaine de relevés', () {
    expect(
      TariffCompare.compare(
        snapshot: _snapshot(),
        daily: _daily.sublist(0, 5),
        colors: const {},
        now: now,
      ),
      isNull,
    );
  });

  test('couleurs Tempo de l\'API', () {
    final days = TempoCalendar.parse(
      '[{"dateJour":"2026-01-12","codeJour":3,"periode":"2025-2026"},'
      '{"dateJour":"2026-01-13","codeJour":2,"periode":"2025-2026"},'
      '{"dateJour":"2026-01-14","codeJour":0,"periode":"2025-2026"}]',
    );
    expect(days[DateTime(2026, 1, 12)], TempoColor.red);
    expect(days[DateTime(2026, 1, 13)], TempoColor.white);
    expect(days.length, 2);
    expect(TempoCalendar.seasonOf(DateTime(2026, 10, 15)), '2026-2027');
    expect(TempoCalendar.seasonOf(DateTime(2026, 3, 1)), '2025-2026');
  });
}
