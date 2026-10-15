import 'box_energy_api.dart';
import 'energy_detail_service.dart';
import 'widget_data_service.dart';

/// Ce que coûte l'électricité en ce moment, du point de vue de celui qui
/// passe devant l'écran : de « profites-en » à « évite ».
enum PriceLevel {
  /// Les panneaux produisent plus que la maison ne consomme.
  surplus,

  /// Heures creuses : le bon moment.
  cheap,

  /// Tarif unique : l'heure ne change rien au prix.
  flat,

  /// Heures pleines d'un jour ordinaire.
  normal,

  /// Jour blanc en heures pleines.
  expensive,

  /// Jour rouge ou pointe mobile, en heures pleines.
  peak,
}

/// La « météo de l'électricité » : le tarif en cours, son prix s'il est
/// connu, et ce qu'on peut en faire.
class ElectricityWeather {
  final PriceLevel level;

  /// Nom du tarif en cours, en clair : « Heures creuses · jour bleu ».
  final String title;

  /// Prix du kWh en cours, en euros ; `null` si aucun prix n'est saisi.
  final double? pricePerKWh;

  /// Le conseil du moment, en une phrase.
  final String advice;

  /// Couleur Tempo de demain, quand elle est connue.
  final TempoColor? tomorrow;

  const ElectricityWeather({
    required this.level,
    required this.title,
    required this.advice,
    this.pricePerKWh,
    this.tomorrow,
  });
}

/// Gravité d'une alerte du kiosque.
enum AdviceLevel { info, warning, danger }

/// Une alerte à montrer en grand : ce qui se passe, et quoi faire.
class EnergyAlert {
  final AdviceLevel level;
  final String title;
  final String message;

  const EnergyAlert(this.level, this.title, this.message);
}

/// La consommation qui ne s'arrête jamais : frigo, box internet, veilles…
class BaseLoad {
  /// Puissance moyenne de l'heure la plus calme, en watts.
  final int watts;

  /// Heure de début de cette heure la plus calme, de 0 à 23.
  final int? hour;

  /// Ce que cette puissance représente sur un an, en kWh.
  double get yearlyKWh => watts * 8760 / 1000;

  /// Son coût sur un an, si un prix est connu.
  final double? yearlyEur;

  const BaseLoad(this.watts, this.yearlyEur, {this.hour});
}

/// Le mois en cours : ce qui est consommé, et ce que ça donnera au rythme
/// actuel. En euros si les prix sont saisis, sinon en kWh.
class MonthOutlook {
  /// Depuis le 1er du mois, aujourd'hui compris.
  final double soFar;

  /// Projection sur le mois entier, au rythme des jours passés.
  final double projected;

  /// Vrai si les montants sont en euros, faux s'ils sont en kWh.
  final bool euros;

  const MonthOutlook(this.soFar, this.projected, {required this.euros});
}

/// L'abonnement comparé aux pics de puissance réellement atteints.
class SubscriptionCheck {
  /// Puissance souscrite, en kVA.
  final int subscribedKVA;

  /// Plus fort pic observé, en VA.
  final int peakVA;

  /// Nombre de jours observés.
  final int days;

  /// Puissance qui suffirait, en kVA, si elle est plus basse que l'actuelle ;
  /// `null` si l'abonnement est bien taillé ou si l'observation est trop
  /// courte.
  final int? suggestedKVA;

  /// La consommation frôle-t-elle souvent le maximum ? L'abonnement est
  /// alors juste, et le risque de coupure réel.
  final bool tight;

  /// Le compteur publie-t-il son pic du jour ? Sinon, le pic n'est vu que
  /// lors des relevés du kiosque et peut être sous-estimé : aucun palier
  /// plus bas n'est alors conseillé, un disjoncteur qui saute coûtant
  /// plus cher que l'économie.
  final bool measured;

  /// Triphasé : le plus fort appel de la phase la plus chargée, et la
  /// limite de chaque phase, en VA.
  final int? phasePeakVA;
  final int? phaseLimitVA;

  /// Jours des 30 derniers passés au-dessus de 80 % de la limite.
  final int? days30Over80;

  const SubscriptionCheck({
    this.phasePeakVA,
    this.phaseLimitVA,
    this.days30Over80,
    required this.subscribedKVA,
    required this.peakVA,
    required this.days,
    this.suggestedKVA,
    this.measured = true,
    this.tight = false,
  });

  /// Jours d'observation avant de conseiller quoi que ce soit.
  static const minDays = 14;
}

/// Niveau du risque de coupure.
enum RiskLevel { low, medium, high }

/// Le risque que le disjoncteur saute : la puissance comparée à
/// l'abonnement.
class CutRisk {
  /// Part de la puissance souscrite, de 0 à 1 (et au-delà en dépassement).
  final double ratio;
  final RiskLevel level;

  /// Vrai si le ratio vient de la moyenne sur une minute de la box, faux
  /// s'il vient de la puissance de l'instant.
  final bool averaged;

  /// Phase la plus chargée, en triphasé.
  final int? phase;

  const CutRisk(this.ratio, this.level, {this.averaged = false, this.phase});

  String get label => switch (level) {
    RiskLevel.low => 'Faible',
    RiskLevel.medium => 'À surveiller',
    RiskLevel.high => 'Élevé',
  };

  String get advice => switch (level) {
    RiskLevel.low => 'Tu as de la marge avant que le disjoncteur saute.',
    RiskLevel.medium =>
      'Évite d\'allumer un autre gros appareil en même temps.',
    RiskLevel.high =>
      'Éteins un appareil maintenant : le disjoncteur risque de sauter.',
  };
}

/// Les conseils du kiosque, calculés à partir de ce que la box mesure.
///
/// Rien ici ne parle au réseau : tout vient du relevé et des réglages déjà
/// récupérés, pour que les règles se testent sans box.
class EnergyAdvice {
  EnergyAdvice._();

  static String _day(TempoColor color) => switch (color) {
    TempoColor.blue => 'jour bleu',
    TempoColor.white => 'jour blanc',
    TempoColor.red => 'jour rouge',
  };

  /// La météo de l'électricité ; `null` sans tarif connu.
  static ElectricityWeather? weather(
    LinkySnapshot snapshot,
    EnergyExtras? extras,
  ) {
    final tariff = extras?.tariff;
    if (tariff == null) return null;
    final price = tariff.price ?? extras?.prices[tariff.attribute];
    // « 22:00 » donné par la box ; en Tempo, les heures sont fixes.
    final next = _clock(tariff.nextChange);
    // Un surplus, c'est injecter plus qu'on ne tire du réseau. Les deux
    // valeurs ne sont pas relevées au même instant, et une production
    // vendue en totalité passe par son propre compteur : de l'injection
    // pendant que la maison soutire n'est pas un surplus à consommer.
    final produced = snapshot.productionPowerVA ?? 0;
    final injecting =
        produced > 0 && produced > (snapshot.apparentPowerVA ?? 0);
    final peakHours = tariff.isPeakHours;
    final today = tariff.isTempo ? tariff.today : null;

    final String title;
    if (tariff.isBase) {
      title = 'Tarif Base';
    } else if (tariff.isEjpPeak) {
      title = 'Pointe mobile';
    } else if (today != null) {
      title =
          '${peakHours ? 'Heures pleines' : 'Heures creuses'} · ${_day(today)}';
    } else if (tariff.label.toUpperCase().contains('NORMALE')) {
      title = 'Heures normales';
    } else {
      title = peakHours ? 'Heures pleines' : 'Heures creuses';
    }

    PriceLevel level;
    String advice;
    if (tariff.isEjpPeak || (today == TempoColor.red && peakHours)) {
      level = PriceLevel.peak;
      advice =
          tariff.isEjpPeak
              ? "L'électricité est très chère aujourd'hui : réduis au maximum, "
                  'surtout le chauffage et le four.'
              : "Jour rouge : l'électricité est très chère jusqu'à "
                  '${next ?? '22 h'}. Évite le four, le sèche-linge et le '
                  'chauffage d\'appoint.';
    } else if (today == TempoColor.white && peakHours) {
      level = PriceLevel.expensive;
      advice =
          "Jour blanc : l'électricité est plus chère. Décale ce qui peut "
          'attendre les heures creuses, à partir de ${next ?? '22 h'}.';
    } else if (tariff.isBase) {
      level = PriceLevel.flat;
      advice =
          'Le prix est le même à toute heure : ce qui compte, c\'est ce que '
          'tu consommes au total.';
    } else if (peakHours) {
      level = PriceLevel.normal;
      advice =
          'Si tu peux, garde les gros appareils (lave-linge, lave-vaisselle, '
          'sèche-linge) pour les heures creuses${next == null ? '' : ', dès $next'}.';
    } else if (today == TempoColor.red) {
      level = PriceLevel.cheap;
      advice =
          'Jour rouge, mais heures creuses : profites-en pour ce qui ne peut '
          'pas attendre, car dès 6 h le prix grimpe fortement.';
    } else {
      level = PriceLevel.cheap;
      advice =
          "C'est le bon moment : lance la machine, le lave-vaisselle ou la "
          'recharge de la voiture.';
    }

    // Du soleil en trop vaut mieux que n'importe quel tarif, sauf en jour
    // rouge où le conseil d'éviter reste le plus utile.
    if (injecting && level != PriceLevel.peak) {
      level = PriceLevel.surplus;
      advice =
          'Tes panneaux produisent plus que tu ne consommes : c\'est le '
          'moment de lancer un appareil.';
    }

    return ElectricityWeather(
      level: level,
      title: title,
      advice: advice,
      pricePerKWh: price,
      tomorrow: tariff.isTempo ? tariff.tomorrow : null,
    );
  }

  /// « 22:00 » → « 22 h », « 06:30 » → « 6 h 30 ».
  static String? _clock(String? hhmm) {
    final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(hhmm ?? '');
    if (m == null) return null;
    final h = int.parse(m.group(1)!);
    final min = m.group(2)!;
    return min == '00' ? '$h h' : '$h h $min';
  }

  /// Ce que coûte la consommation de l'instant, en euros par heure ; `null`
  /// si le prix du tarif en cours n'est pas saisi.
  ///
  /// Le compteur donne une puissance apparente, en VA : elle sert ici de
  /// puissance active, ce qui surestime un peu. C'est un ordre de grandeur,
  /// présenté comme tel.
  static double? costPerHour(LinkySnapshot snapshot, EnergyExtras? extras) {
    final weather = EnergyAdvice.weather(snapshot, extras);
    final price = weather?.pricePerKWh;
    final power = snapshot.apparentPowerVA;
    if (price == null || power == null) return null;
    return power / 1000 * price;
  }

  /// Le risque de coupure : à 70 % de l'abonnement il faut surveiller, à
  /// 90 % agir. En triphasé, c'est la phase la plus chargée qui compte, sur
  /// son tiers de l'abonnement.
  static CutRisk? cutRisk(LinkySnapshot snapshot, EnergyExtras? extras) {
    RiskLevel level(double ratio) =>
        ratio >= 0.9
            ? RiskLevel.high
            : (ratio >= 0.7 ? RiskLevel.medium : RiskLevel.low);

    // La box v2.26 donne la charge de la dernière minute, celle qui fait
    // couper, déjà rapportée à la limite de la phase la plus chargée.
    final load = extras?.freshMinuteLoad;

    if (snapshot.threePhase) {
      final limit = snapshot.phaseLimitVA;
      if (limit == null || limit <= 0) {
        if (load == null) return null;
        return CutRisk(load / 100, level(load / 100), averaged: true);
      }
      var worst = 0;
      for (var i = 1; i < 3; i++) {
        if (snapshot.phasePowersVA[i] > snapshot.phasePowersVA[worst])
          worst = i;
      }
      final ratio =
          load != null ? load / 100 : snapshot.phasePowersVA[worst] / limit;
      return CutRisk(
        ratio,
        level(ratio),
        averaged: load != null,
        // La box ne dit pas quelle phase porte sa charge à la minute.
        phase: load == null ? worst + 1 : null,
      );
    }

    if (load != null) {
      return CutRisk(load / 100, level(load / 100), averaged: true);
    }

    final subscribed = snapshot.subscribedPowerVA;
    if (subscribed == null || subscribed <= 0) return null;
    final minute = extras?.freshMinuteVA;
    final power = minute ?? snapshot.apparentPowerVA;
    if (power == null) return null;
    final ratio = power / subscribed;
    return CutRisk(ratio, level(ratio), averaged: minute != null);
  }

  /// La consommation plancher : l'heure la plus calme des dernières 24 h,
  /// à n'importe quelle heure.
  ///
  /// Le plancher de nuit que calcule la box (de 1 h à 5 h) n'est pas
  /// retenu : la nuit, c'est souvent l'heure de la recharge de la voiture
  /// ou du ballon d'eau chaude, qui n'ont rien d'une consommation de fond.
  ///
  /// L'heure en cours, incomplète, n'est pas comptée, et il faut au moins
  /// douze heures complètes pour que le plancher veuille dire quelque chose.
  static BaseLoad? baseLoad(LinkySnapshot snapshot, EnergyExtras? extras) {
    final price = _averagePrice(extras?.prices ?? const {});
    final complete =
        snapshot.hourly.length > 1
            ? snapshot.hourly.sublist(0, snapshot.hourly.length - 1)
            : const <HourlySample>[];
    if (complete.length < 12) return null;
    // Un Linky en mode producteur (5 ou 7) mesure à la fois ce qui est tiré
    // et ce qui est injecté : en plein soleil, les panneaux couvrent une
    // part de la consommation, et ce qui est tiré du réseau ne dit plus ce
    // que la maison consomme. Seules les heures sans production comptent
    // alors. Avec un compteur de production à part (vente totale), le
    // Linky de consommation voit toute la maison : toutes les heures
    // comptent.
    final selfConsumes = snapshot.linkyMode == 5 || snapshot.linkyMode == 7;
    final measured = [
      for (final s in complete)
        if (!selfConsumes || s.productionWh == 0) s,
    ];
    if (measured.length < 4) return null;
    final calmest = measured.reduce((a, b) => b.wh < a.wh ? b : a);
    final watts = calmest.wh;
    if (watts <= 0) return null;
    return BaseLoad(
      watts,
      price == null ? null : watts * 8760 / 1000 * price,
      hour: calmest.hour,
    );
  }

  /// Le prix moyen du kWh saisi sur la box, faute de savoir à quelle heure
  /// tourne ce qui ne s'arrête jamais.
  static double? _averagePrice(Map<int, double> prices) {
    if (prices.isEmpty) return null;
    return prices.values.reduce((a, b) => a + b) / prices.length;
  }

  /// Paliers d'abonnement proposés par les fournisseurs, en kVA.
  static const subscriptionTiers = [3, 6, 9, 12, 15, 18, 24, 30, 36];

  /// L'abonnement est-il trop gros ? Le plus petit palier qui garde 15 %
  /// de marge au-dessus du plus fort pic observé suffirait.
  static SubscriptionCheck? subscription(
    LinkySnapshot snapshot,
    Map<String, int> peaks, {
    PowerSummary? summary,
  }) {
    if (summary != null) return _fromSummary(summary);
    final subscribed = snapshot.subscribedPowerVA;
    if (subscribed == null || subscribed <= 0 || peaks.isEmpty) return null;
    final subscribedKVA = (subscribed / 1000).round();
    final peak = peaks.values.reduce((a, b) => a > b ? a : b);
    int? suggested;
    final measured = snapshot.maxPowerTodayVA != null;
    if (measured && peaks.length >= SubscriptionCheck.minDays) {
      final enough = subscriptionTiers.firstWhere(
        (tier) => tier * 1000 >= peak * 1.15,
        orElse: () => subscribedKVA,
      );
      if (enough < subscribedKVA) suggested = enough;
    }
    return SubscriptionCheck(
      subscribedKVA: subscribedKVA,
      peakVA: peak,
      days: peaks.length,
      suggestedKVA: suggested,
      measured: measured,
    );
  }

  /// Le bilan d'après les mesures de la box (v2.26) : la moyenne sur une
  /// minute, celle qui fait couper le compteur, sur jusqu'à deux ans.
  static SubscriptionCheck _fromSummary(PowerSummary summary) {
    final subscribedKVA = (summary.subscribedVA / 1000).round();
    final peak = summary.worstVa1m ?? 0;
    // En triphasé, c'est la phase la plus chargée qui fait couper, à un
    // tiers de l'abonnement : son pic, ramené aux trois phases, dit quel
    // abonnement la porterait.
    final phasePeak = summary.threePhase ? summary.worstPhaseVa1m : null;
    final sizing = phasePeak != null ? phasePeak * 3 : peak;
    bool often(int band, Set<PeakRate> rates) =>
        rates.contains(summary.rates[band]);
    final tight =
        often(90, {PeakRate.daily, PeakRate.weekly}) ||
        often(100, {PeakRate.daily, PeakRate.weekly, PeakRate.monthly});
    int? suggested;
    final rarelyHigh =
        !often(80, {PeakRate.daily, PeakRate.weekly, PeakRate.monthly});
    if (!tight &&
        rarelyHigh &&
        sizing > 0 &&
        summary.observedDays >= SubscriptionCheck.minDays) {
      final enough = subscriptionTiers.firstWhere(
        (tier) => tier * 1000 >= sizing * 1.15,
        orElse: () => subscribedKVA,
      );
      if (enough < subscribedKVA) suggested = enough;
    }
    return SubscriptionCheck(
      subscribedKVA: subscribedKVA,
      peakVA: peak,
      days: summary.observedDays,
      suggestedKVA: suggested,
      tight: tight,
      phasePeakVA: phasePeak,
      phaseLimitVA: phasePeak == null ? null : summary.phaseLimitVA,
      days30Over80: summary.days30Over80,
    );
  }

  /// Le budget du mois rapporté à une heure, en Wh : la ligne à ne pas
  /// dépasser en moyenne sur le graphe heure par heure. `null` sans budget
  /// réglé sur la box, ou sans prix pour convertir les euros en Wh.
  ///
  /// La conversion suit le coût réel des dernières 24 h, abonnement et
  /// taxes compris : c'est ce coût que compte le budget.
  static double? hourlyBudgetWh(
    LinkySnapshot snapshot,
    EnergyExtras? extras, {
    DateTime? now,
  }) {
    final budget = extras?.thresholds.monthBudgetEur;
    if (budget == null || budget <= 0) return null;
    final day = now ?? DateTime.now();
    final days = DateTime(day.year, day.month + 1, 0).day;
    final eurosPerHour = budget / days / 24;

    final wh = snapshot.hourly.fold<int>(0, (sum, s) => sum + s.wh);
    final cost = snapshot.hourly.fold<double>(0, (sum, s) => sum + s.costEur);
    if (wh > 0 && cost > 0) return eurosPerHour * wh / cost;
    final price = _averagePrice(extras?.prices ?? const {});
    return price == null || price <= 0 ? null : eurosPerHour / price * 1000;
  }

  /// Le mois en cours, d'après l'historique jour par jour ; `null` s'il
  /// ne couvre pas encore le mois.
  static MonthOutlook? month(EnergyExtras? extras, DateTime now) {
    final days =
        (extras?.daily ?? const <DailySample>[])
            .where((d) => d.month == now.month && d.day <= now.day)
            .toList();
    if (days.isEmpty) return null;
    final euros = days.any((d) => d.costEur > 0);
    final soFar = days.fold<double>(
      0,
      (sum, d) => sum + (euros ? d.costEur : d.wh / 1000),
    );
    // Le jour en cours ne compte que pour la part écoulée.
    final elapsed = (now.day - 1) + (now.hour + now.minute / 60) / 24;
    final length = DateTime(now.year, now.month + 1, 0).day;
    final projected = elapsed < 1 ? soFar : soFar / elapsed * length;
    return MonthOutlook(soFar, projected, euros: euros);
  }

  /// Hier comparé à la semaine qui l'a précédé : de quoi féliciter ou
  /// alerter. `null` si l'écart est faible ou l'historique trop court.
  static EnergyAlert? yesterday(EnergyExtras? extras) {
    final daily = extras?.daily ?? const <DailySample>[];
    // Le dernier jour est aujourd'hui, incomplet.
    if (daily.length < 9) return null;
    final yesterday = daily[daily.length - 2];
    final week = daily.sublist(daily.length - 9, daily.length - 2);
    final usual = week.fold<int>(0, (sum, d) => sum + d.wh) / week.length;
    if (usual <= 0 || yesterday.wh <= 0) return null;
    final change = (yesterday.wh - usual) / usual * 100;
    if (change >= (extras?.thresholds.anomalyPercent ?? 30)) {
      return EnergyAlert(
        AdviceLevel.warning,
        'Hier, +${change.round()} % par rapport à d\'habitude',
        'Un appareil inhabituel, du chauffage en plus ? Regarde le graphe '
            'heure par heure pour trouver le moment.',
      );
    }
    if (change <= -15) {
      return EnergyAlert(
        AdviceLevel.info,
        'Bravo : hier, ${(-change).round()} % de moins que d\'habitude',
        'Continue comme ça : chaque jour comme celui-là allège la facture.',
      );
    }
    return null;
  }

  /// Les alertes du moment, de la plus urgente à la moins urgente.
  static List<EnergyAlert> alerts(
    LinkySnapshot snapshot,
    EnergyExtras? extras,
  ) {
    final alerts = <EnergyAlert>[];

    // Les alertes de la box (v2.26) des six dernières heures, telles
    // qu'elle les a envoyées au téléphone.
    final recent = [
      for (final a in extras?.boxAlerts ?? const <BoxAlert>[])
        if (a.at != null &&
            DateTime.now().difference(a.at!) < const Duration(hours: 6) &&
            a.title.isNotEmpty)
          a,
    ]..sort((a, b) => b.id.compareTo(a.id));
    final boxTypes = {for (final a in recent) a.type};
    for (final a in recent) {
      alerts.add(EnergyAlert(_boxLevel(a.type), a.title, a.message));
    }

    final power = snapshot.apparentPowerVA;
    final max = snapshot.subscribedPowerVA;
    final limit =
        extras?.thresholds.overPowerW ?? (max == null ? null : max * 0.9);
    final powerKnown = boxTypes.any(
      (t) => t == 'subscribed_power' || t == 'over_power',
    );
    if (!powerKnown &&
        power != null &&
        limit != null &&
        limit > 0 &&
        power >= limit) {
      alerts.add(
        EnergyAlert(
          AdviceLevel.danger,
          'Tu approches de ta puissance maximale',
          'Le disjoncteur risque de sauter : éteins un gros appareil (four, '
              'radiateur, plaque) avant d\'en allumer un autre.',
        ),
      );
    }

    final water =
        extras?.utilities.where((u) => u.kind == UtilityKind.water).firstOrNull;
    final nightLimit = extras?.thresholds.nightWaterLitres;
    if (boxTypes.any((t) => t.contains('water'))) {
      // La box l'a déjà signalée.
    } else if (water != null && nightLimit != null) {
      final night = _nightLitres(water.hourly);
      if (night != null && night >= nightLimit) {
        alerts.add(
          EnergyAlert(
            AdviceLevel.danger,
            "Fuite d'eau possible",
            'Cette nuit, entre minuit et 5 h, ${night.round()} litres ont coulé '
                'alors que personne ne devrait en utiliser. Vérifie les '
                'robinets, la chasse d\'eau et le chauffe-eau.',
          ),
        );
      }
    } else if (water != null) {
      final hours = _runningNightHours(water.hourly);
      if (hours >= 3) {
        alerts.add(
          EnergyAlert(
            AdviceLevel.danger,
            "Fuite d'eau possible",
            "L'eau coule sans s'arrêter depuis $hours heures, même la nuit. "
                'Vérifie les robinets, la chasse d\'eau et le chauffe-eau.',
          ),
        );
      }
    }

    if (extras?.tariff case final tariff? when tariff.isTempo) {
      if (tariff.tomorrow == TempoColor.red) {
        alerts.add(
          const EnergyAlert(
            AdviceLevel.warning,
            'Demain, jour rouge',
            "L'électricité sera très chère de 6 h à 22 h. Ce soir, programme "
                'le chauffe-eau et les machines en heures creuses.',
          ),
        );
      } else if (tariff.tomorrow == TempoColor.white) {
        alerts.add(
          const EnergyAlert(
            AdviceLevel.info,
            'Demain, jour blanc',
            "L'électricité sera un peu plus chère de 6 h à 22 h : garde les "
                'machines pour les heures creuses.',
          ),
        );
      }
    }

    if (yesterday(extras) case final alert?) alerts.add(alert);

    return alerts;
  }

  /// Litres écoulés entre minuit et 5 h la dernière nuit, si les 24
  /// dernières heures la couvrent entièrement.
  static double? _nightLitres(List<UtilitySample> hourly) {
    final night = hourly.where((s) => s.hour < 5).toList();
    if (night.length < 5) return null;
    return night.fold<double>(0, (sum, s) => sum + s.value);
  }

  /// Gravité d'une alerte de la box, d'après son type.
  static AdviceLevel _boxLevel(String type) => switch (type) {
    'subscribed_power' ||
    'over_power' ||
    'water_leak' ||
    'night_water_leak' ||
    'freeze' ||
    'power_outage' => AdviceLevel.danger,
    'over_budget' ||
    'red_day' ||
    'price_change' ||
    'daily_anomaly' => AdviceLevel.warning,
    _ => AdviceLevel.info,
  };

  /// Nombre d'heures complètes, jusqu'à la dernière, où l'eau a coulé sans
  /// interruption — à condition que la série couvre une heure de nuit (1 h
  /// à 5 h), où rien ne devrait couler. 0 sinon.
  static int _runningNightHours(List<UtilitySample> hourly) {
    if (hourly.length < 2) return 0;
    final complete = hourly.sublist(0, hourly.length - 1);
    var count = 0;
    var night = false;
    for (final sample in complete.reversed) {
      if (sample.value <= 0) break;
      count++;
      if (sample.hour >= 1 && sample.hour <= 5) night = true;
    }
    return night ? count : 0;
  }
}
