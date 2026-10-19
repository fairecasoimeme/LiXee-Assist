import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../screens/home_screen.dart' show resolveMdnsIP;
import '../services/box_client.dart';
import '../services/session_manager.dart' show AuthMode;
import '../services/session_pool.dart';
import 'tv_data.dart';
import 'tv_discovery.dart';

/// Résultat d'une tentative d'ajout, pour l'écran TV et pour le téléphone.
class PairingOutcome {
  final bool ok;
  final String message;
  final String? entry;

  const PairingOutcome.success(this.entry, this.message) : ok = true;
  const PairingOutcome.failure(this.message) : ok = false, entry = null;
}

/// Serveur d'appairage : reçoit du téléphone une box à ajouter.
///
/// Il n'écoute que le temps de l'écran d'ajout, et seulement à une adresse
/// secrète (`/p/<jeton>`) que seul le QR code donne. Deux façons d'arriver :
///
/// - LiXee-Assist, qui envoie l'entrée complète d'une box qu'il connaît
///   déjà : nom, adresses locale et tunnel, identifiants ;
/// - le navigateur du téléphone, qui affiche un formulaire : adresse (les box
///   trouvées sur le réseau y sont proposées), identifiant, mot de passe.
///
/// Dans les deux cas, la TV vérifie les identifiants auprès de la box avant
/// d'enregistrer quoi que ce soit. Les échanges restent sur le réseau local,
/// en HTTP : c'est aussi ainsi que l'app parle à la box en local.
class TvPairingServer {
  /// Box trouvées sur le réseau, proposées dans le formulaire du navigateur.
  final List<FoundBox> Function() suggestions;
  final void Function(PairingOutcome outcome) onOutcome;

  TvPairingServer({required this.suggestions, required this.onOutcome});

  HttpServer? _server;
  late final String token = _randomHex(16);

  /// Code affiché sur la TV et sur le téléphone, pour vérifier qu'on parle
  /// bien au même écran quand plusieurs TV sont allumées.
  late final String code = (int.parse(token.substring(0, 8), radix: 16) %
          1000000)
      .toString()
      .padLeft(6, '0');

  String? _host;
  int _failures = 0;
  bool _done = false;

  /// Au-delà, le jeton est grillé : il faut rouvrir l'écran d'ajout.
  static const _maxFailures = 5;

  Uri? get pairingUrl =>
      _server == null || _host == null
          ? null
          : Uri.parse('http://$_host:${_server!.port}/p/$token');

  /// Essais sur l'émulateur, isolé derrière le PC : `PAIRING_HOST` met
  /// l'adresse du PC dans le QR code, `PAIRING_PORT` fixe le port à relayer
  /// (`adb forward`, puis un relais Windows vers le réseau local).
  static const _hostOverride = String.fromEnvironment('PAIRING_HOST');
  static const _portOverride = int.fromEnvironment('PAIRING_PORT');

  Future<Uri?> start() async {
    _host =
        _hostOverride.isNotEmpty
            ? _hostOverride
            : await TvDiscovery.localAddress();
    if (_host == null) return null;
    _server = await HttpServer.bind(
      InternetAddress.anyIPv4,
      _portOverride,
      shared: true,
    );
    _server!.listen(_handle, onError: (_) {});
    return pairingUrl;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handle(HttpRequest request) async {
    final segments = request.uri.pathSegments;
    if (_done ||
        segments.length < 2 ||
        segments[0] != 'p' ||
        segments[1] != token) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final sub = segments.length > 2 ? segments[2] : '';
    try {
      if (request.method == 'GET' && sub.isEmpty) {
        await _html(request, _formPage());
      } else if (request.method == 'GET' && sub == 'info') {
        await _json(request, {'code': code});
      } else if (request.method == 'POST' && sub.isEmpty) {
        final form = Uri.splitQueryString(
          await utf8.decoder.bind(request).join(),
        );
        // Une adresse tapée l'emporte sur la box choisie dans la liste.
        final typed = (form['address'] ?? '').trim();
        final outcome = await addWithCredentials(
          address: typed.isNotEmpty ? typed : (form['box'] ?? ''),
          login: form['login'] ?? '',
          password: form['password'] ?? '',
          name: form['name'],
          known: suggestions(),
        );
        await _html(request, _resultPage(outcome));
        _report(outcome);
      } else if (request.method == 'POST' && sub == 'entry') {
        final body = jsonDecode(await utf8.decoder.bind(request).join());
        final outcome = await _fromEntry(body is Map ? '${body['entry']}' : '');
        await _json(request, {'ok': outcome.ok, 'message': outcome.message});
        _report(outcome);
      } else if (request.method == 'POST' && sub == 'entries') {
        // Synchronisation : toutes les box choisies sur le téléphone.
        final body = jsonDecode(await utf8.decoder.bind(request).join());
        final list =
            body is Map && body['entries'] is List
                ? (body['entries'] as List).map((e) => '$e').toList()
                : const <String>[];
        final outcome = await _fromEntries(list);
        await _json(request, {'ok': outcome.ok, 'message': outcome.message});
        _report(outcome);
      } else {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      }
    } catch (e) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
    }
  }

  void _report(PairingOutcome outcome) {
    if (outcome.ok) {
      _done = true;
    } else if (++_failures >= _maxFailures) {
      _done = true;
    }
    onOutcome(outcome);
  }

  /// Ajoute une box d'après son adresse et ses identifiants : formulaire du
  /// navigateur, ou saisie à la télécommande.
  ///
  /// [known] sert à retrouver le nom d'une box trouvée sur le réseau ; à
  /// défaut, [name], puis l'adresse elle-même.
  static Future<PairingOutcome> addWithCredentials({
    required String address,
    required String login,
    required String password,
    String? name,
    List<FoundBox> known = const [],
  }) async {
    final url = normalizeAddress(address);
    if (url == null) {
      return const PairingOutcome.failure('Indiquez l\'adresse de la box.');
    }
    final host = Uri.parse(url).host;
    final found = known.where((b) => b.ip == host).firstOrNull;
    final label =
        (name ?? '').trim().isNotEmpty
            ? name!.trim().replaceAll('|', ' ')
            : found?.name ?? host;

    final hasAuth = login.isNotEmpty || password.isNotEmpty;
    if (login.contains('|') || password.contains('|')) {
      return const PairingOutcome.failure(
        'Le caractère | n\'est pas accepté dans l\'identifiant ou le mot de passe.',
      );
    }
    final device = BoxDevice(
      name: label,
      primaryUrl: url,
      login: hasAuth ? login : null,
      password: hasAuth ? password : null,
    );
    final check = await verify(device);
    if (check != null) return PairingOutcome.failure(check);

    // Tunnel configuré sur la box : il devient l'adresse principale, le
    // réseau local l'adresse de secours, comme sur le téléphone.
    final tunnel = hasAuth ? await _tunnelUrl(device) : null;
    final entry =
        !hasAuth
            ? '$label|$url'
            : tunnel != null
            ? '$label|$tunnel|auth|$login|$password|$url'
            : '$label|$url|auth|$login|$password';
    await TvData.upsert(entry);
    return PairingOutcome.success(entry, '$label est ajoutée à la TV.');
  }

  /// `192.168.1.20`, `lixeebox-8bf0.local`, `http://…/` → `http://hôte[:port]`.
  static String? normalizeAddress(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return null;
    if (!text.startsWith('http://') && !text.startsWith('https://')) {
      text = 'http://$text';
    }
    final uri = Uri.tryParse(text);
    if (uri == null || uri.host.isEmpty) return null;
    return uri.hasPort
        ? '${uri.scheme}://${uri.host}:${uri.port}'
        : '${uri.scheme}://${uri.host}';
  }

  /// Box envoyées ensemble par LiXee-Assist.
  ///
  /// Toutes sont vérifiées en parallèle. Seule une box qui refuse ses
  /// identifiants est écartée : une box muette sur le moment (éteinte, ou
  /// joignable seulement par un tunnel coupé) est gardée, puisque le
  /// téléphone la connaît déjà et qu'elle répondra plus tard.
  Future<PairingOutcome> _fromEntries(List<String> entries) async {
    final devices = <String, BoxDevice>{};
    for (final entry in entries) {
      final device = BoxDevice.tryParse(entry);
      if (device != null && !entry.contains('\n')) devices[entry] = device;
    }
    if (devices.isEmpty) {
      return const PairingOutcome.failure('Aucune box à ajouter.');
    }
    final checks = await Future.wait(devices.values.map(verify));
    final added = <String>[];
    final refused = <String>[];
    for (final (i, entry) in devices.keys.indexed) {
      final name = devices[entry]!.name;
      if (checks[i]?.startsWith('Identifiant') ?? false) {
        refused.add(name);
      } else {
        await TvData.upsert(entry);
        added.add(name);
      }
    }
    if (added.isEmpty) {
      return PairingOutcome.failure(
        'Identifiants refusés par ${refused.join(', ')}.',
      );
    }
    final message = StringBuffer(
      added.length == 1
          ? '${added.first} est ajoutée à la TV.'
          : '${added.length} box ajoutées à la TV : ${added.join(', ')}.',
    );
    if (refused.isNotEmpty) {
      message.write(' Identifiants refusés par ${refused.join(', ')}.');
    }
    return PairingOutcome.success(null, message.toString());
  }

  /// Entrée envoyée par LiXee-Assist.
  Future<PairingOutcome> _fromEntry(String entry) async {
    final device = BoxDevice.tryParse(entry);
    if (device == null || entry.contains('\n')) {
      return const PairingOutcome.failure('Configuration illisible.');
    }
    final check = await verify(device);
    if (check != null) return PairingOutcome.failure(check);
    await TvData.upsert(entry);
    return PairingOutcome.success(entry, '${device.name} est ajoutée à la TV.');
  }

  /// `null` si la box répond et accepte les identifiants, sinon la raison.
  ///
  /// On interroge d'abord la box sans identifiants : si elle répond, elle
  /// n'en demande pas, et n'importe quel mot de passe « passerait ».
  static Future<String?> verify(BoxDevice device) async {
    var refused = false;
    await for (final (_, route) in BoxClient.routes(
      device,
      mdnsResolver: resolveMdnsIP,
    )) {
      final open = await BoxClient.rawGet(
        '${route.baseUrl}/getDevices',
        route.timeout,
      ).catchError((_) => null);
      if (open != null) return null;
      if (!device.hasAuth) {
        return 'Cette box demande un identifiant et un mot de passe.';
      }
      try {
        final body = await BoxClient.get(route, '/getDevices');
        if (body != null) return null;

        // Dernier recours, sans ambiguïté : le formulaire de connexion. Le
        // mode d'accès mémorisé pour cette adresse peut être faux (une box
        // qui n'accepte que le formulaire, même en local), et la requête
        // précédente l'a suivi.
        BoxClient.dropSession(route);
        final session = SessionPool.session(
          route.baseUrl,
          device.login!,
          device.password!,
        );
        if (await session.login().timeout(route.timeout * 2)) {
          SessionPool.setAuthMode(route.baseUrl, AuthMode.form);
          return null;
        }
        refused = true;
      } catch (_) {
        // Voie suivante.
      }
    }
    if (refused) return 'Identifiant ou mot de passe refusé par la box.';
    return 'La box ne répond pas.';
  }

  static Future<String?> _tunnelUrl(BoxDevice device) async {
    await for (final (_, route) in BoxClient.routes(
      device,
      mdnsResolver: resolveMdnsIP,
    )) {
      try {
        final body = await BoxClient.get(route, '/api/tunnel/credentials');
        if (body == null) continue;
        final id = (jsonDecode(body) as Map)['tunnelClientId'];
        return id == null || '$id'.isEmpty ? null : 'https://$id.lixee-box.fr';
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  Future<void> _html(HttpRequest request, String page) async {
    request.response.headers.contentType = ContentType.html;
    request.response.headers.set('Cache-Control', 'no-store');
    request.response.write(page);
    await request.response.close();
  }

  Future<void> _json(HttpRequest request, Map<String, Object?> body) async {
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }

  String _formPage() {
    const escape = HtmlEscape();
    final app = Uri(
      scheme: 'lixee',
      host: 'pair',
      queryParameters: {'u': pairingUrl.toString()},
    );
    final boxes = suggestions();
    final options =
        boxes
            .map(
              (b) =>
                  '<option value="${escape.convert(b.url)}">${escape.convert(b.name)} · ${escape.convert(b.ip)}</option>',
            )
            .join();
    final choice =
        boxes.isEmpty
            ? ''
            : '<label>Box trouvée sur le réseau<select name="box">$options</select></label>'
                '<p class="note">Ou tapez son adresse ci-dessous, si elle n\'est pas dans la liste.</p>';
    return '''<!doctype html><html lang="fr"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Ajouter une box à la TV</title><style>$_css</style></head><body><main>
<h1>Ajouter une box à la TV</h1>
<p class="code">Code affiché sur la TV : <b>${_spaced(code)}</b></p>
<a class="app" href="$app">Envoyer depuis LiXee-Assist</a>
<p class="or">ou remplissez ce formulaire</p>
<form method="post">
$choice
<label>Adresse de la box<input name="address" inputmode="url" autocapitalize="off" placeholder="192.168.1.20"></label>
<label>Identifiant<input name="login" autocomplete="username" autocapitalize="off"></label>
<label>Mot de passe<input name="password" type="password" autocomplete="current-password"></label>
<label>Nom affiché sur la TV (facultatif)<input name="name" placeholder="Maison"></label>
<button type="submit">Ajouter à la TV</button>
</form>
<p class="note">Laissez identifiant et mot de passe vides si la box n'en a pas.</p>
</main></body></html>''';
  }

  String _resultPage(PairingOutcome outcome) {
    final message = const HtmlEscape().convert(outcome.message);
    final retry =
        outcome.ok || _failures + 1 >= _maxFailures
            ? ''
            : '<a class="app" href="${pairingUrl?.path}">Réessayer</a>';
    return '''<!doctype html><html lang="fr"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>LiXee-Assist</title><style>$_css</style></head><body><main>
<h1>${outcome.ok ? 'C\'est fait' : 'Pas encore'}</h1><p>$message</p>$retry
</main></body></html>''';
  }

  static String _spaced(String code) =>
      '${code.substring(0, 3)} ${code.substring(3)}';

  static const _css = '''
body{margin:0;font-family:system-ui,sans-serif;background:#f3f5f8;color:#17202b}
main{max-width:420px;margin:0 auto;padding:28px 20px}
h1{font-size:1.5rem;margin:0 0 12px}
.code{color:#5b6878}.code b{font-family:ui-monospace,monospace;color:#17202b;letter-spacing:.15em}
.app{display:block;text-align:center;background:#1b75bc;color:#fff;text-decoration:none;font-weight:700;padding:14px;border-radius:12px;margin:18px 0}
.or{text-align:center;color:#5b6878;margin:8px 0 14px}
form{display:grid;gap:14px}
label{display:grid;gap:6px;font-weight:600}
input,select{font-size:1rem;padding:12px;border:1px solid #c9d2dc;border-radius:10px;background:#fff}
button{font-size:1rem;font-weight:700;padding:14px;border:0;border-radius:12px;background:#17202b;color:#fff}
.note{color:#5b6878;font-size:.9rem}''';

  static String _randomHex(int bytes) {
    final random = Random.secure();
    return List.generate(
      bytes,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
}
