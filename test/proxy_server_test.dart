import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zigpower_connect/services/proxy_server.dart';

void main() {
  final box = Uri.parse('https://be841cad.lixee-box.fr');

  test('l\'origine du proxy local devient celle de la box', () {
    expect(
      rewriteProxyOrigin('Origin', 'http://127.0.0.1:43127', box),
      'https://be841cad.lixee-box.fr',
    );
  });

  test('le Referer garde sa page, sur la box', () {
    expect(
      rewriteProxyOrigin(
        'Referer',
        'http://127.0.0.1:43127/config?tab=tunnel',
        box,
      ),
      'https://be841cad.lixee-box.fr/config?tab=tunnel',
    );
  });

  test('une origine étrangère au proxy est retirée', () {
    expect(rewriteProxyOrigin('Origin', 'https://exemple.com', box), isNull);
    expect(rewriteProxyOrigin('Origin', 'null', box), isNull);
  });

  test('les autres en-têtes passent tels quels', () {
    expect(rewriteProxyOrigin('Accept', 'text/html', box), 'text/html');
  });

  test('une box sur un port particulier', () {
    expect(
      rewriteProxyOrigin(
        'Origin',
        'http://localhost:5000',
        Uri.parse('http://192.168.1.149:8080'),
      ),
      'http://192.168.1.149:8080',
    );
  });

  test('un POST traverse le proxy avec l\x27origine de la box', () async {
    // Une fausse box qui renvoie les en-têtes reçus.
    final box = await HttpServer.bind('127.0.0.2', 0);
    box.listen((request) async {
      await request.drain<void>();
      request.response
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'origin': request.headers.value('origin'),
            'referer': request.headers.value('referer'),
          }),
        );
      await request.response.close();
    });
    final target = 'http://127.0.0.2:${box.port}';
    final proxy = await startProxy(targetBaseUrl: target);

    final client = HttpClient();
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:${proxy.port}/tunnel'),
    );
    request.headers.set('Origin', 'http://127.0.0.1:${proxy.port}');
    request.headers.set(
      'Referer',
      'http://127.0.0.1:${proxy.port}/config?tab=tunnel',
    );
    request.write('code=123456');
    final response = await request.close();
    final seen = jsonDecode(await response.transform(utf8.decoder).join());

    expect(seen['origin'], target);
    expect(seen['referer'], '$target/config?tab=tunnel');

    client.close(force: true);
    await proxy.close(force: true);
    await box.close(force: true);
  });
}
