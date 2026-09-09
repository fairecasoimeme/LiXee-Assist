import 'package:flutter_test/flutter_test.dart';
import 'package:zigpower_connect/services/action_group_service.dart';

/// Réponse réelle de `GET /api/actiongroups/list`, réduite à deux actions par
/// groupe. Le second groupe n'a pas d'icône : la box l'accepte.
const _listing = '''
{
  "groups": [
    {"index": 0, "name": "Fermeture des volets", "icon": "\\ud83c\\udfe0",
     "color": "#ff8080", "enabled": true,
     "actions": [
       {"type": "device", "IEEE": "6ce4a4fffea2eced", "actionName": "DOWN"},
       {"type": "device", "IEEE": "f044d3fffe70769d", "actionName": "DOWN"}
     ]},
    {"index": 1, "name": "Ouverture des volets", "icon": "",
     "color": "#00b000", "enabled": true,
     "actions": [
       {"type": "device", "IEEE": "6ce4a4fffea2eced", "actionName": "UP"}
     ]},
    {"index": 2, "name": "", "icon": "", "color": "", "actions": []}
  ],
  "max": 8
}
''';

void main() {
  group('parseGroups', () {
    test('retient les groupes nommés', () {
      final groups = ActionGroupService.parseGroups('LIXEEBOX-8BF0', _listing);
      // Le troisième est un emplacement libre : la box en renvoie huit, dont
      // ceux qui n'ont jamais été configurés.
      expect(groups.map((g) => g.name),
          ['Fermeture des volets', 'Ouverture des volets']);
    });

    test('icône, couleur et nombre d\'actions viennent de la box', () {
      final fermeture =
          ActionGroupService.parseGroups('b', _listing).first;
      expect(fermeture.icon, '🏠');
      expect(fermeture.color, '#ff8080');
      expect(fermeture.actionCount, 2);
      expect(fermeture.index, 0);
    });

    test('la clé est bâtie sur le nom, jamais sur le rang', () {
      // Supprimer un groupe décale tous les suivants : un widget lié au rang
      // se retrouverait pointé sur son voisin.
      final groups = ActionGroupService.parseGroups('maison', _listing);
      expect(groups.first.key, 'maison#Fermeture des volets');
      expect(groups.last.key, 'maison#Ouverture des volets');
    });

    test('rend une liste vide sur un firmware sans groupes', () {
      expect(ActionGroupService.parseGroups('b', '{}'), isEmpty);
      expect(ActionGroupService.parseGroups('b', 'pas du json'), isEmpty);
      expect(ActionGroupService.parseGroups('b', '{"groups": 3}'), isEmpty);
    });
  });

  group('parseResult', () {
    test('lit un déclenchement abouti', () {
      final result = ActionGroupService.parseResult('{"ok":true,"sent":6}');
      expect(result.ok, isTrue);
      expect(result.sent, 6);
    });

    test('lit un échec et son motif', () {
      final result =
          ActionGroupService.parseResult('{"ok":false,"error":"groupe vide"}');
      expect(result.ok, isFalse);
      expect(result.error, 'groupe vide');
    });

    test('une réponse illisible n\'est jamais un succès', () {
      expect(ActionGroupService.parseResult('<html>').ok, isFalse);
      expect(ActionGroupService.parseResult('[]').ok, isFalse);
    });
  });
}
