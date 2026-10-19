import 'dart:async';
import 'dart:io';

import 'package:multicast_dns/multicast_dns.dart';

/// Une box repérée sur le réseau local.
class FoundBox {
  final String name;
  final String ip;
  final int port;

  const FoundBox({required this.name, required this.ip, required this.port});

  String get url => port == 80 ? 'http://$ip' : 'http://$ip:$port';
}

/// Cherche les LiXee-Box du réseau local.
///
/// Les box s'annoncent en `_http._tcp` sous leur nom (`LIXEEBOX-8BF0`) ; on
/// ne garde que les noms qui commencent par « lixee », pour écarter les
/// imprimantes et autres appareils du même service.
class TvDiscovery {
  TvDiscovery._();

  static const _service = '_http._tcp.local';

  static Future<List<FoundBox>> scan({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final client = MDnsClient(
      rawDatagramSocketFactory: (
        host,
        int port, {
        bool reuseAddress = true,
        bool reusePort = false,
        int ttl = 255,
      }) {
        // reusePort n'existe pas sur Android : le passer lève une erreur.
        return RawDatagramSocket.bind(host, port, reuseAddress: reuseAddress);
      },
    );
    final found = <String, FoundBox>{};
    try {
      await client.start();
      final pointers =
          await client
              .lookup<PtrResourceRecord>(
                ResourceRecordQuery.serverPointer(_service),
                timeout: timeout,
              )
              .toList();
      for (final ptr in pointers) {
        final name = ptr.domainName.split('.$_service').first;
        if (!name.toLowerCase().startsWith('lixee') ||
            found.containsKey(name)) {
          continue;
        }
        await for (final srv in client.lookup<SrvResourceRecord>(
          ResourceRecordQuery.service(ptr.domainName),
          timeout: const Duration(seconds: 2),
        )) {
          await for (final ip in client.lookup<IPAddressResourceRecord>(
            ResourceRecordQuery.addressIPv4(srv.target),
            timeout: const Duration(seconds: 2),
          )) {
            found[name] = FoundBox(
              name: name,
              ip: ip.address.address,
              port: srv.port,
            );
            break;
          }
          break;
        }
      }
    } catch (e) {
      print('[TV] Recherche mDNS impossible: $e');
    } finally {
      client.stop();
    }
    final list =
        found.values.toList()..sort((a, b) => a.name.compareTo(b.name));
    return list;
  }

  /// Adresse IPv4 de la TV sur le réseau local, pour le QR code.
  static Future<String?> localAddress() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    String? fallback;
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (address.isLoopback) continue;
        final ip = address.address;
        final private =
            ip.startsWith('192.168.') ||
            ip.startsWith('10.') ||
            RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(ip);
        if (private) return ip;
        fallback ??= ip;
      }
    }
    return fallback;
  }
}
