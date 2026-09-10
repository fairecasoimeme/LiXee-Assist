import 'dart:io';

/// Détermine si une URL désigne une box joignable directement sur le réseau
/// local, par opposition à un accès relayé par le tunnel.
///
/// La distinction commande la stratégie d'authentification : en LAN le
/// firmware accepte le Basic — une requête unique, sans état ni cookie —
/// alors que le tunnel impose le login par formulaire. Tenter le formulaire
/// sur une box locale coûte une détection, un POST voué à échouer, et
/// plusieurs secondes d'attente.
bool isLanUrl(String baseUrl) {
  final host = Uri.tryParse(baseUrl)?.host ?? '';
  if (host.isEmpty) return false;
  if (host.endsWith('.local') || host == 'localhost') return true;

  final ipv4 =
      RegExp(r'^(\d{1,3})\.(\d{1,3})\.\d{1,3}\.\d{1,3}$').firstMatch(host);
  if (ipv4 == null) return false;

  final a = int.parse(ipv4.group(1)!);
  final b = int.parse(ipv4.group(2)!);
  return a == 10 ||
      a == 127 ||
      (a == 172 && b >= 16 && b <= 31) ||
      (a == 192 && b == 168);
}

/// L'exigence sur le certificat qui convient à [baseUrl] : `null` impose la
/// validation normale, une fonction acceptante l'assouplit.
///
/// Sur le réseau local, la box présente un certificat auto-signé qu'aucune
/// autorité ne contresignera jamais : le refuser rendrait l'accès direct
/// impossible, et un intercepteur devrait de toute façon déjà être sur le
/// réseau. Le tunnel, lui, traverse Internet sous un vrai nom de domaine ;
/// y accepter n'importe quel certificat livrerait identifiants et cookie de
/// session au premier relais qui se ferait passer pour la box.
///
/// Une URL dont la portée est indéterminable est traitée comme distante :
/// se tromper dans ce sens coûte une connexion refusée, dans l'autre une
/// interception silencieuse.
bool Function(X509Certificate, String, int)? certificatePolicyFor(
  String baseUrl,
) =>
    isLanUrl(baseUrl) ? (_, __, ___) => true : null;

/// Un client HTTP dont l'exigence sur le certificat correspond à la portée de
/// [baseUrl].
HttpClient scopedHttpClient(String baseUrl, {Duration? connectionTimeout}) {
  final client = HttpClient();
  if (connectionTimeout != null) client.connectionTimeout = connectionTimeout;
  client.badCertificateCallback = certificatePolicyFor(baseUrl);
  return client;
}
