import AppIntents
import WidgetKit

/// Une entrée choisie dans un catalogue publié par l'app.
///
/// Appareils, groupes d'actions et zones de thermostat se choisissent tous de
/// la même manière : l'app publie une liste, le widget en retient une clé.
/// Seuls changent le catalogue lu et le champ qui sert de libellé. Sur Android
/// c'est un écran de configuration ; ici c'est un paramètre d'intention, réglé
/// en maintenant le widget appuyé puis « Modifier le widget ».
protocol CatalogEntity: AppEntity where ID == String {
    /// Clé de l'App Group où l'app publie le catalogue.
    static var catalogKey: String { get }

    /// Champ du catalogue qui nomme l'entrée à l'écran.
    static var labelField: String { get }

    init(id: String, label: String, box: String)

    var label: String { get }

    /// La box dont l'entrée provient, montrée en sous-titre : deux pièces
    /// peuvent porter le même nom sur deux box différentes.
    var box: String { get }
}

extension CatalogEntity {
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(label)", subtitle: "\(box)")
    }

    /// Les entrées publiées, dans l'ordre du catalogue.
    ///
    /// Une entrée sans clé est ignorée : c'est la clé qui relie le widget à ses
    /// relevés, et sans elle il n'aurait rien à afficher.
    static func published() -> [Self] {
        Shared.catalog(catalogKey).compactMap { entry in
            guard let key = entry["key"], !key.isEmpty else { return nil }
            return Self(
                id: key,
                label: entry[labelField] ?? key,
                box: entry["box"] ?? ""
            )
        }
    }
}

/// Les entrées désignées par leurs clés, dans l'ordre demandé.
///
/// Le catalogue survit à une box muette : l'app y garde les entrées de la
/// fois précédente, pour qu'un hoquet du Wi-Fi n'empêche pas de poser un
/// widget.
private func published<Entity: CatalogEntity>(matching identifiers: [String]) -> [Entity] {
    let entries = Entity.published()
    return identifiers.compactMap { id in entries.first { $0.id == id } }
}

// Les trois requêtes ci-dessous ne diffèrent que par leur type. Une seule,
// générique, se compilerait mais ne s'installerait pas : le compilateur de
// métadonnées AppIntents n'accepte qu'une requête de type concret.
//
// `defaultResult` renvoie la première entrée, faute de choix explicite : un
// widget fraîchement posé montre ainsi quelque chose plutôt qu'un cadre vide.

struct DeviceQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [DeviceEntity] {
        published(matching: identifiers)
    }
    func suggestedEntities() async throws -> [DeviceEntity] { DeviceEntity.published() }
    func defaultResult() async -> DeviceEntity? { DeviceEntity.published().first }
}

struct GroupQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [GroupEntity] {
        published(matching: identifiers)
    }
    func suggestedEntities() async throws -> [GroupEntity] { GroupEntity.published() }
    func defaultResult() async -> GroupEntity? { GroupEntity.published().first }
}

struct ThermostatQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ThermostatEntity] {
        published(matching: identifiers)
    }
    func suggestedEntities() async throws -> [ThermostatEntity] { ThermostatEntity.published() }
    func defaultResult() async -> ThermostatEntity? { ThermostatEntity.published().first }
}

// --- Appareil Zigbee ---------------------------------------------------------

struct DeviceEntity: CatalogEntity {
    let id: String
    let label: String
    let box: String

    static var catalogKey = "widget_device_catalog"
    static var labelField = "label"
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Appareil"
    static var defaultQuery = DeviceQuery()
}

struct SelectDeviceIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Appareil"
    static var description = IntentDescription("Choisissez l'appareil à afficher.")

    @Parameter(title: "Appareil")
    var device: DeviceEntity?
}

// --- Groupe d'actions --------------------------------------------------------

struct GroupEntity: CatalogEntity {
    let id: String
    let label: String
    let box: String

    static var catalogKey = "widget_group_catalog"
    static var labelField = "name"
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Groupe d'actions"
    static var defaultQuery = GroupQuery()
}

struct SelectGroupIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Groupe d'actions"
    static var description = IntentDescription("Choisissez le groupe à déclencher.")

    @Parameter(title: "Groupe")
    var group: GroupEntity?
}

// --- Zone de thermostat ------------------------------------------------------

struct ThermostatEntity: CatalogEntity {
    let id: String
    let label: String
    let box: String

    static var catalogKey = "widget_thermostat_catalog"
    static var labelField = "name"
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Thermostat"
    static var defaultQuery = ThermostatQuery()
}

struct SelectThermostatIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Thermostat"
    static var description = IntentDescription("Choisissez la zone à afficher.")

    @Parameter(title: "Zone")
    var zone: ThermostatEntity?
}
