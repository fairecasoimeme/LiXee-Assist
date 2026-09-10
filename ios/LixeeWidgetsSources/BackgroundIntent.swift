import AppIntents
import Foundation
import home_widget

/// L'appui sur un bouton de widget, remis au code Dart.
///
/// L'extension ne sait ni joindre la box ni s'y authentifier : elle réveille un
/// moteur Flutter qui exécute le rappel enregistré par
/// `HomeWidget.registerInteractivityCallback`, lequel traite déjà les mêmes URI
/// que le widget Android. Rien de l'authentification n'est donc à réécrire en
/// Swift — et rien à en exposer dans un processus de plus.
@available(iOS 17, *)
struct LixeeActionIntent: AppIntent {
    static var title: LocalizedStringResource = "Action LiXee"

    /// Ces intentions n'ont de sens que déclenchées par un widget : les
    /// proposer dans Raccourcis n'offrirait qu'un champ d'URI libre.
    static var isDiscoverable = false

    @Parameter(title: "URI")
    var url: URL?

    init() {}

    init(url: URL?) { self.url = url }

    func perform() async throws -> some IntentResult {
        await HomeWidgetBackgroundWorker.run(url: url, appGroup: Shared.appGroup)
        return .result()
    }
}
