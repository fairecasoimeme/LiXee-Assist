import AppIntents
import WidgetKit

/// Une LiXee-Box, telle qu'on la choisit en configurant un widget.
///
/// L'app gère plusieurs box : chaque widget posé doit savoir laquelle
/// afficher. Sur Android c'est un écran de configuration ; sur iOS c'est ce
/// paramètre d'intention, qu'on règle en maintenant le widget appuyé puis
/// « Modifier le widget ».
struct BoxEntity: AppEntity {
    let id: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "LiXee-Box"
    static var defaultQuery = BoxQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(id)")
    }
}

/// Les box proposées au choix : celles que l'app a publiées.
struct BoxQuery: EntityQuery {
    func entities(for identifiers: [BoxEntity.ID]) async throws -> [BoxEntity] {
        identifiers.map { BoxEntity(id: $0) }
    }

    func suggestedEntities() async throws -> [BoxEntity] {
        Shared.boxNames().map { BoxEntity(id: $0) }
    }

    /// Sans choix explicite, la première box : un widget fraîchement posé
    /// montre ainsi quelque chose plutôt qu'un cadre vide.
    func defaultResult() async -> BoxEntity? {
        Shared.boxNames().first.map { BoxEntity(id: $0) }
    }
}

struct SelectBoxIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "LiXee-Box"
    static var description = IntentDescription("Choisissez la box à afficher.")

    @Parameter(title: "Box")
    var box: BoxEntity?
}
