import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zigpower_connect/services/network_scope.dart';

/// La politique LAN accepte sans regarder le certificat : n'importe quel
/// exemplaire suffit à vérifier qu'elle répond bien `true`.
class _DummyCertificate implements X509Certificate {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  group('isLanUrl', () {
    test('reconnaît les plages privées', () {
      expect(isLanUrl('http://192.168.1.42'), isTrue);
      expect(isLanUrl('http://10.0.0.7'), isTrue);
      expect(isLanUrl('http://172.16.0.1'), isTrue);
      expect(isLanUrl('http://172.31.255.254'), isTrue);
      expect(isLanUrl('http://127.0.0.1:8080'), isTrue);
    });

    test('reconnaît les noms locaux', () {
      expect(isLanUrl('http://lixee-box.local'), isTrue);
      expect(isLanUrl('http://localhost:3000'), isTrue);
    });

    test('exclut les plages publiques voisines des privées', () {
      expect(isLanUrl('http://172.15.0.1'), isFalse);
      expect(isLanUrl('http://172.32.0.1'), isFalse);
      expect(isLanUrl('http://192.169.0.1'), isFalse);
      expect(isLanUrl('http://11.0.0.1'), isFalse);
    });

    test('exclut le tunnel et les URLs inexploitables', () {
      expect(isLanUrl('https://remote.lixee-box.fr'), isFalse);
      expect(isLanUrl('https://8.8.8.8'), isFalse);
      expect(isLanUrl(''), isFalse);
      expect(isLanUrl('pas une url'), isFalse);
    });

    // Un hôte qui commencerait par des chiffres sans être une IP ne doit pas
    // être pris pour une adresse privée : c'est par là qu'un nom de domaine
    // contrôlé par un tiers passerait pour du réseau local.
    test('exclut un nom de domaine déguisé en adresse privée', () {
      expect(isLanUrl('https://192.168.1.1.attaquant.fr'), isFalse);
      expect(isLanUrl('https://10.0.0.1.example.com'), isFalse);
    });
  });

  group('certificatePolicyFor', () {
    test('accepte le certificat auto-signé de la box en LAN', () {
      final policy = certificatePolicyFor('https://192.168.1.42');

      expect(policy, isNotNull);
      expect(policy!(_DummyCertificate(), '192.168.1.42', 443), isTrue);
    });

    test('impose la validation du certificat via le tunnel', () {
      expect(certificatePolicyFor('https://remote.lixee-box.fr'), isNull);
    });

    test('valide par défaut quand la portée est indéterminable', () {
      expect(certificatePolicyFor(''), isNull);
      expect(certificatePolicyFor('pas une url'), isNull);
    });
  });

  group('scopedHttpClient', () {
    test('reporte le délai de connexion', () {
      final client = scopedHttpClient(
        'http://192.168.1.42',
        connectionTimeout: const Duration(seconds: 3),
      );
      addTearDown(() => client.close(force: true));

      expect(client.connectionTimeout, const Duration(seconds: 3));
    });
  });
}
