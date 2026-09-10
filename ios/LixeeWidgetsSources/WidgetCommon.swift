import SwiftUI
import WidgetKit

/// Ce que le widget dit de l'âge de ses chiffres, et s'il faut s'en méfier.
struct Freshness {
    let text: String

    /// Vrai quand le relevé mérite d'être signalé — box muette, ou chiffres
    /// d'il y a plus d'une heure. Le widget le montre alors en orangé.
    let stale: Bool
}

/// Âge d'un relevé, dans les mots du widget Android.
///
/// Une box qui a cessé de répondre garde ses chiffres à l'écran : les effacer
/// ne dirait pas mieux ce qui se passe, alors qu'un dernier relevé daté le dit.
func freshness(timestamp: Date?, failedAt: Date?, now: Date = .now) -> Freshness {
    let unreachable: Bool = {
        guard let failedAt else { return false }
        guard let timestamp else { return true }
        return failedAt > timestamp
    }()

    guard let timestamp else {
        return Freshness(
            text: unreachable ? "Injoignable" : "Jamais relevé",
            stale: unreachable
        )
    }

    let age = now.timeIntervalSince(timestamp)
    let label = relativeAge(age)
    if unreachable { return Freshness(text: "Injoignable · \(label)", stale: true) }
    return Freshness(text: label, stale: age > 3600)
}

func relativeAge(_ seconds: TimeInterval) -> String {
    if seconds < 60 { return "à l'instant" }
    if seconds < 3600 {
        let minutes = Int(seconds / 60)
        return "\(minutes) minute\(minutes > 1 ? "s" : "")"
    }
    let hours = Int(seconds / 3600)
    return "\(hours) heure\(hours > 1 ? "s" : "")"
}

/// Un nombre tel que l'affiche le widget : entier quand il l'est, une décimale
/// sinon. « 21 °C » se lit mieux que « 21,0 °C », mais « 21,5 » doit rester
/// distinct de « 21 ».
func formatted(_ value: Double, decimals: Int? = nil) -> String {
    let places = decimals ?? (value == value.rounded() ? 0 : 1)
    return String(format: "%.\(places)f", value)
        .replacingOccurrences(of: ".", with: ",")
}

/// En-tête commun aux widgets : ce qu'on regarde, et depuis quand.
struct WidgetHeader: View {
    let title: String
    let freshness: Freshness

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(freshness.text)
                .font(.system(size: 10))
                .foregroundStyle(freshness.stale ? Palette.warn : Palette.textSecondary)
                .lineLimit(1)
        }
    }
}

/// Ce qu'affiche un widget qu'on a posé sans lui désigner sa cible.
struct UnboundView: View {
    let subject: String

    var body: some View {
        VStack(spacing: 4) {
            Text("\(subject) non choisi")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
            Text("Appui long sur le widget, puis « Modifier le widget »")
                .font(.system(size: 11))
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Les URI d'action, du même dialecte que celles du widget Android.
///
/// Le natif ne fait qu'émettre l'intention : c'est le rappel Dart enregistré
/// par `HomeWidget.registerInteractivityCallback` qui la traite, avec le même
/// code d'authentification et d'envoi que l'app. Aucune identification n'est
/// donc à reproduire ici.
enum WidgetAction {

    /// Les clés d'appareil et de zone contiennent `/`, `#` ou `~` : chacune
    /// doit tenir dans un seul segment, sinon `uri.pathSegments` la coupe en
    /// morceaux et le rappel Dart cherche une box qui n'existe pas.
    private static let segmentAllowed = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "-._~"))

    static func url(
        _ host: String,
        _ segments: [String] = [],
        query: [String: String] = [:]
    ) -> URL? {
        var text = "lixee://\(host)"
        for segment in segments {
            text += "/\(escape(segment))"
        }
        if !query.isEmpty {
            let pairs = query.sorted { $0.key < $1.key }
                .map { "\($0.key)=\(escape($0.value))" }
            text += "?\(pairs.joined(separator: "&"))"
        }
        return URL(string: text)
    }

    private static func escape(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? raw
    }
}

/// Un bouton du widget, dans le style des boutons Android.
///
/// Contrairement à Android, aucune confirmation ne s'interpose : iOS n'offre
/// pas d'étape intermédiaire depuis un widget. L'appui commande directement.
@available(iOS 17.0, *)
struct WidgetButton: View {
    let title: String
    let url: URL?
    var background: Color = Palette.actionBackground
    var foreground: Color = Palette.textPrimary
    var height: CGFloat = 34
    var size: CGFloat = 12

    var body: some View {
        Button(intent: LixeeActionIntent(url: url)) {
            Text(title)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(foreground)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: height)
        }
        .buttonStyle(.plain)
        .background(background, in: RoundedRectangle(cornerRadius: 10))
    }
}
