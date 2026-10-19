import AppIntents
import Foundation
import home_widget

/// L'appui sur un bouton de widget, remis au code Dart.
///
/// L'extension ne sait ni joindre la box ni s'y authentifier : elle réveille un
/// moteur Flutter qui exécute le rappel enregistré par
/// `HomeWidget.registerInteractivityCallback`, lequel traite déjà les mêmes URI
/// que le widget Android.
///
/// Ce fichier appartient à Runner, et est compilé aussi dans l'extension qui a
/// besoin du type pour construire ses boutons. C'est le plugin qui impose ce
/// partage : il monte le moteur d'arrière-plan dans le processus de l'app, au
/// moment où Dart enregistre son rappel. Exécutée dans le processus du widget,
/// `HomeWidgetBackgroundWorker.run` attendrait sans fin une initialisation qui
/// n'y arrive jamais, et l'appui resterait sans effet.
@available(iOS 17, *)
public struct LixeeActionIntent: AppIntent {
    static public var title: LocalizedStringResource = "Action LiXee"

    /// Ces intentions n'ont de sens que déclenchées par un widget : les
    /// proposer dans Raccourcis n'offrirait qu'un champ d'URI libre.
    static public var isDiscoverable = false

    @Parameter(title: "URI")
    var url: URL?

    /// Fourni par le widget plutôt qu'écrit ici : Runner ne voit pas
    /// `Shared.appGroup`, qui reste la seule définition côté Swift.
    @Parameter(title: "App Group")
    var appGroup: String?

    public init() {}

    public init(url: URL?, appGroup: String?) {
        self.url = url
        self.appGroup = appGroup
    }

    public func perform() async throws -> some IntentResult {
        guard let appGroup else { return .result() }
        await HomeWidgetBackgroundWorker.run(url: url, appGroup: appGroup)
        return .result()
    }
}

/// Fait exécuter l'intention dans l'app, quitte à la réveiller, plutôt que dans
/// le processus attaché au widget. Sans cela un appui reste sans effet dès que
/// l'app n'est plus en mémoire. Le protocole n'existe pas pour une extension :
/// la conformité disparaît de la version compilée pour LixeeWidgets, qui n'en a
/// pas l'usage puisqu'elle ne fait que construire l'intention.
@available(iOS 17, *)
@available(iOSApplicationExtension, unavailable)
extension LixeeActionIntent: ForegroundContinuableIntent {}
