import SwiftUI
import UIKit

/// Accès aux relevés que l'app publie pour les widgets.
///
/// L'extension de widgets vit dans un processus à part, qui ne voit pas les
/// préférences de l'app : les relevés transitent par un UserDefaults commun,
/// celui de l'App Group. Les clés et leur format sont ceux qu'écrit
/// HomeWidgetBridge côté Dart — les mêmes que lit le widget Android.
enum Shared {

    /// Doit être identique à `HomeWidgetBridge.appGroupId` côté Dart, et
    /// déclaré dans « Signing & Capabilities » sur les deux cibles.
    static let appGroup = "group.com.lixee.assist"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    /// Tout est stocké en chaîne, y compris les nombres : une chaîne vide veut
    /// dire « pas de valeur », pas zéro.
    static func string(_ key: String) -> String? {
        guard let value = defaults?.string(forKey: key), !value.isEmpty else { return nil }
        return value
    }

    static func int(_ key: String) -> Int? { string(key).flatMap { Int($0) } }

    static func double(_ key: String) -> Double? { string(key).flatMap { Double($0) } }

    /// Horodatage publié en millisecondes depuis 1970.
    static func date(_ key: String) -> Date? {
        double(key).map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    /// Box connues de l'app, dans l'ordre de ses réglages.
    ///
    /// La liste peut contenir un doublon quand une box a été enregistrée deux
    /// fois : on ne la propose qu'une fois au choix.
    static func boxNames() -> [String] {
        guard let raw = string("widget_device_list"),
              let data = raw.data(using: .utf8),
              let names = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }
}

/// Teintes du widget Android, clair et sombre — mêmes valeurs que colors.xml.
enum Palette {
    static let background = Color(light: 0xFFFFFF, dark: 0x1E1E1E)
    static let textPrimary = Color(light: 0x1A1A1A, dark: 0xF2F2F2)
    static let textSecondary = Color(light: 0x6B6B6B, dark: 0xA0A0A0)
    static let accent = Color(light: 0x1B75BC, dark: 0x5EA9E4)
    static let production = Color(light: 0x2E9E5B, dark: 0x5FC98A)
    static let track = Color(light: 0xE4E8EC, dark: 0x33383D)
    static let warn = Color(light: 0xE8912D, dark: 0xF0A85A)
    static let alert = Color(light: 0xD3452F, dark: 0xE86B57)
    static let positive = Color(light: 0x2E9E5B, dark: 0x5FC98A)
    static let negative = Color(light: 0xD3452F, dark: 0xE86B57)
}

extension Color {
    /// Couleur qui suit le thème clair ou sombre du système.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
