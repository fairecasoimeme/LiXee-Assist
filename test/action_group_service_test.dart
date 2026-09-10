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

/// Extrait réel de `/agicons.js` (firmware 2.23) : du JavaScript, pas du JSON.
/// Le libellé de la seconde icône porte une apostrophe échappée, pour vérifier
/// qu'elle ne coupe pas la lecture du tracé qui la suit.
const _iconSet = r"""
var AG_THEMES=['Éclairage','Volets / ouvrants'];var AG_ICONS={'window-shutter':[1,'Volet fermé','M3,4H21V8H19V20H17V8H7V20H5V8H3V4M8,9H16V11H8V9M8,12H16V14H8V12M8,15H16V17H8V15M8,18H16V20H8V18Z'],'window-shutter-open':[1,'Volet d\'entrée','M3,4H21V8H19V20H17V8H7V20H5V8H3V4M8,9H16V11H8V9Z'],'vide':[8,'Sans tracé','']};
""";

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

  group('parseIconSet', () {
    test('associe chaque nom à son tracé', () {
      final icons = ActionGroupService.parseIconSet(_iconSet);
      expect(icons.keys, ['window-shutter', 'window-shutter-open']);
      expect(icons['window-shutter'], startsWith('M3,4H21V8'));
    });

    test('une apostrophe échappée dans le libellé ne coupe pas la lecture', () {
      expect(ActionGroupService.parseIconSet(_iconSet)['window-shutter-open'],
          'M3,4H21V8H19V20H17V8H7V20H5V8H3V4M8,9H16V11H8V9Z');
    });

    test('une icône sans tracé est écartée', () {
      expect(ActionGroupService.parseIconSet(_iconSet), isNot(contains('vide')));
    });

    test('le nom du groupe mène à son tracé', () {
      final groups = ActionGroupService.parseGroups(
        'b',
        '{"groups":[{"index":0,"name":"Fermeture","icon":"window-shutter"},'
            '{"index":1,"name":"Ancien","icon":"\ud83c\udfe0"}]}',
        icons: ActionGroupService.parseIconSet(_iconSet),
      );
      expect(groups.first.iconPath, startsWith('M3,4H21V8'));
      // Un émoji d'avant la 2.23 n'a pas de tracé : le widget l'écrira tel quel.
      expect(groups.last.iconPath, isNull);
      expect(groups.last.icon, '🏠');
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
