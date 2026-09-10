import Charts
import SwiftUI
import WidgetKit

/// Rendu d'un widget énergie : jauge, chiffres du jour, graphe horaire.
///
/// Même composition que le widget Android. Deux tailles : moyenne (4×2) et
/// grande (4×4) ; seule la hauteur du graphe change de l'une à l'autre.
struct EnergyWidgetView: View {
    let entry: EnergyEntry
    let theme: EnergyTheme

    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let snapshot = entry.snapshot, snapshot.timestamp != nil {
                content(snapshot)
            } else {
                // Box choisie mais jamais relevée : ne rien inventer.
                Spacer()
                Text("Ouvrez LiXee-Assist une fois pour relever la box.")
                    .font(.caption)
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
            }
        }
        .containerBackground(Palette.background, for: .widget)
        .widgetURL(openURL)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(entry.box ?? "LiXee-Box")
                .font(.caption.bold())
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("24 h")
                .font(.caption2)
                .foregroundStyle(Palette.textSecondary)
        }
    }

    @ViewBuilder
    private func content(_ s: EnergySnapshot) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if let label = theme.gaugeLabel {
                VStack(spacing: 2) {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(Palette.textSecondary)
                    ArcGauge(
                        value: theme.power(s),
                        max: s.maxPower,
                        accent: theme.accent
                    )
                    .frame(width: 70, height: 70)
                }
            }
            figures(s)
            Spacer(minLength: 0)
        }

        HourlyChart(points: s.hourly, theme: theme)
            .frame(height: family == .systemLarge ? 110 : 34)

        footer(s)
    }

    private func figures(_ s: EnergySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(theme.columnLabel)
                .font(.caption2)
                .foregroundStyle(Palette.textSecondary)
            Text("⚡ \(kWh(theme.energy(s))) kWh")
                .font(.subheadline.bold())
                .foregroundStyle(Palette.textPrimary)
            if let amount = theme.amount(s) {
                Text("🪙 \(amount.formatted(.number.precision(.fractionLength(2)))) €")
                    .font(.subheadline)
                    .foregroundStyle(Palette.textPrimary)
            }
            if let trend = s.trend {
                trendText(trend)
            }
        }
    }

    /// Sous 2 %, l'écart relève du bruit de mesure.
    private func trendText(_ pct: Int) -> some View {
        let good = Palette.positive
        let bad = Palette.negative
        let text: String
        let color: Color
        if pct > 2 {
            text = "↑ \(pct) % vs h-1"
            color = theme.risingIsGood ? good : bad
        } else if pct < -2 {
            text = "↓ \(-pct) % vs h-1"
            color = theme.risingIsGood ? bad : good
        } else {
            text = "→ stable"
            color = Palette.textSecondary
        }
        return Text(text).font(.caption2).foregroundStyle(color)
    }

    private func footer(_ s: EnergySnapshot) -> some View {
        HStack(spacing: 4) {
            if s.unreachable {
                Text("Injoignable ·")
            }
            if let timestamp = s.timestamp {
                // Style .relative : iOS tient l'âge à jour lui-même, sans
                // attendre la prochaine chronologie.
                Text("il y a \(timestamp, style: .relative)")
            }
        }
        .font(.caption2)
        .foregroundStyle(s.unreachable ? Palette.warn : Palette.textSecondary)
        .lineLimit(1)
    }

    private func kWh(_ wh: Int?) -> String {
        guard let wh else { return "—" }
        return (Double(wh) / 1000).formatted(.number.precision(.fractionLength(2)))
    }

    /// Ouvre l'app sur la box du widget. Le paramètre homeWidget est celui que
    /// le plugin guette pour transmettre l'URL à Flutter.
    private var openURL: URL? {
        guard let box = entry.box,
              let encoded = box.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: "lixee://open/\(encoded)?homeWidget")
    }
}

/// Jauge en arc de 270°, ouverte en bas — la géométrie du widget Android.
struct ArcGauge: View {
    let value: Int?
    let max: Int?
    let accent: Color

    private var ratio: Double {
        guard let value, let max, max > 0 else { return 0 }
        return min(Double(value) / Double(max), 1)
    }

    /// Teinte du thème loin du contrat, orange puis rouge en approchant.
    private var fill: Color {
        if ratio < 0.6 { return accent }
        if ratio < 0.85 { return Palette.warn }
        return Palette.alert
    }

    var body: some View {
        ZStack {
            // trim part de 3 h dans le sens horaire ; tourner de 135° amène
            // le départ en bas à gauche et l'arrivée en bas à droite.
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(Palette.track, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle()
                .trim(from: 0, to: 0.75 * ratio)
                .stroke(fill, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(135))
            VStack(spacing: 0) {
                Text(value.map { "\($0)" } ?? "—")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(accent)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("VA")
                    .font(.caption2)
                    .foregroundStyle(Palette.textSecondary)
            }
            .padding(.horizontal, 10)
        }
    }
}

/// Graphe des 24 dernières heures.
///
/// Le bilan est signé : soutiré au-dessus de zéro, injecté en dessous, en
/// vert — passer sous zéro est la bonne nouvelle. L'heure en cours, partielle,
/// est la dernière barre.
struct HourlyChart: View {
    let points: [HourPoint]
    let theme: EnergyTheme

    var body: some View {
        if points.isEmpty {
            Color.clear
        } else {
            VStack(spacing: 2) {
                Chart(points) { point in
                    BarMark(
                        x: .value("Heure", point.id),
                        y: .value("Wh", theme.value(of: point))
                    )
                    .foregroundStyle(color(for: point))
                    .cornerRadius(2)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)

                hourLabels
            }
        }
    }

    private func color(for point: HourPoint) -> Color {
        let isCurrent = point.id == points.count - 1
        if theme == .balance && point.net < 0 {
            return Palette.production
        }
        return theme.accent.opacity(isCurrent ? 1 : 0.55)
    }

    /// Quatre repères, comme sur Android ; le dernier est l'heure en cours.
    private var hourLabels: some View {
        let marks = [0, points.count / 3, 2 * points.count / 3, points.count - 1]
        return HStack {
            ForEach(Array(marks.enumerated()), id: \.offset) { position, index in
                if position > 0 { Spacer(minLength: 0) }
                Text("\(points[index].hour)h")
                    .font(.system(size: 9))
                    .foregroundStyle(position == marks.count - 1 ? theme.accent : Palette.textSecondary)
            }
        }
    }
}
