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
