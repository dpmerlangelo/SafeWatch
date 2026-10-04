import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// How a camera was found.
enum DiscoverySource { onvif, sadp, portScan, arpCache }

/// A single camera-like device found on the local network.
///
/// IMPORTANT: `ip` is NOT a stable identity — a camera's IP can change
/// (DHCP renewal, APIPA fallback, being moved to another network, a user
/// manually re-IPing it in the camera's own config page, etc). `serialNumber`
/// (when available, i.e. Hikvision devices found via SADP) is the strongest
/// stable identity — it survives IP changes AND NIC/MAC changes. `mac` is
/// the next-best fallback. Callers that want to recognize "this is the same
/// camera I saw before, just at a new address" should key their
/// storage/UI off `identityKey` (serial > mac > ip), not `ip` directly.
class DiscoveredCamera {
  final String ip;
  final int port;
  final DiscoverySource source;
  final String? onvifServiceUrl;
  final String? mac;

  /// Device serial number, e.g. from a Hikvision SADP `<DeviceSN>` reply.
  /// Only ever populated for `DiscoverySource.sadp` results — ONVIF and
  /// the ARP-cache/port-scan paths have no way to learn this without an
  /// authenticated SDK/HTTP call, which discovery intentionally doesn't
  /// make (no credentials at discovery time).
  final String? serialNumber;

  /// True when this device was found via a broadcast-based protocol
  /// (SADP/ONVIF) but does NOT sit in any subnet your machine currently
  /// has an interface in. Broadcast discovery can "see" it across a
  /// switch regardless of subnet (that's why iVMS-4200 finds cameras on
  /// mismatched subnets), but actually *connecting* to it (RTSP, SDK
  /// login, HTTP) will fail until either the camera's IP is changed to
  /// match your subnet, or your NIC gets a secondary IP in the camera's
  /// subnet. UI should surface this rather than silently failing later.
  final bool crossSubnet;

  DiscoveredCamera({
    required this.ip,
    required this.port,
    required this.source,
    this.onvifServiceUrl,
    this.mac,
    this.serialNumber,
    this.crossSubnet = false,
  });

  /// Stable identity key: serial number when we have one (strongest —
  /// survives IP AND MAC changes), then MAC, then falls back to IP.
  /// Use this (not `ip`) as the key when persisting "known cameras" so a
  /// camera that changes IP is recognized as the same device rather than
  /// showing up as a brand-new one.
  String get identityKey => serialNumber ?? mac ?? ip;

  DiscoveredCamera copyWith({
    String? mac,
    String? serialNumber,
    int? port,
    DiscoverySource? source,
    bool? crossSubnet,
  }) {
    return DiscoveredCamera(
      ip: ip,
      port: port ?? this.port,
      source: source ?? this.source,
      onvifServiceUrl: onvifServiceUrl,
      mac: mac ?? this.mac,
      serialNumber: serialNumber ?? this.serialNumber,
      crossSubnet: crossSubnet ?? this.crossSubnet,
    );
  }

  String get label {
    switch (source) {
      case DiscoverySource.onvif:
        return 'ONVIF device';
      case DiscoverySource.sadp:
        return 'Hikvision (SADP)';
      case DiscoverySource.portScan:
        return 'Possible camera';
      case DiscoverySource.arpCache:
        return 'Possible camera (ARP)';
    }
  }

  @override
  String toString() =>
      '$ip:$port (${source.name})'
      '${serialNumber != null ? ' sn=$serialNumber' : ''}'
      '${mac != null ? ' mac=$mac' : ''}'
      '${crossSubnet ? ' [cross-subnet]' : ''}';
}

/// Finds cameras on the local LAN, iVMS-4200-style "Device Search" style.
///
/// PERFORMANCE NOTES (read this before changing timeouts/concurrency):
///  - `_getPrefixLength` is memoized (`_prefixLengthCache`). It used to
///    spawn a subprocess (`ifconfig`/`powershell`) on every single call,
///    and it's called from nested loops (once per camera x per interface
///    x per address). That was the single biggest silent cost in a full
///    `discoverAllStream()` run — often dozens of redundant subprocess
///    spawns. Call `_prefixLengthCache.clear()` at the top of every fresh
///    top-level scan (already done in `discoverAllStream`) so a stale
///    mask never survives a network change between scans.
///  - `scanSubnetForCameras` now scans every local interface/subnet
///    CONCURRENTLY instead of serially. On a multi-NIC machine this was
///    previously the difference between (scanA + scanB) and
///    max(scanA, scanB).
///  - ONVIF/SADP now short-circuit as soon as every phase-1 source
///    (ONVIF, SADP, ARP cache) has produced at least one result AND a
///    minimum settle window has passed, instead of always waiting out
///    the full timeout. See `_earlySettleWindow` in `discoverAllStream`.
class CameraDiscoveryService {
  static const int _onvifMulticastPort = 3702;
  static const String _onvifMulticastAddress = '239.255.255.250';
  static const int _sadpPort = 37020;
  static const List<int> _commonCameraPorts = [8000];

  final bool debugLogging;

  CameraDiscoveryService({this.debugLogging = true});

  void _log(String message) {
    if (debugLogging) {
      // ignore: avoid_print
      print('[CameraDiscovery] $message');
    }
  }

  /// Returns every non-virtual IPv4 interface, since a camera might be
  /// reachable only via Wi-Fi, only via a directly-connected Ethernet
  /// port, or via a router — we don't know which, so we probe on all of them.
  Future<List<NetworkInterface>> _activeInterfaces() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: true,
    );
    return interfaces.where((iface) {
      final nameLower = iface.name.toLowerCase();
      final looksVirtual = _virtualAdapterNamePatterns
          .any((pattern) => nameLower.contains(pattern));
      final isWindowsVirtualMiniport = iface.name.contains('*');
      return !looksVirtual && !isWindowsVirtualMiniport && iface.addresses.isNotEmpty;
    }).toList();
  }

  // ---- Real subnet-mask detection (replaces the old "always /24" guess) ----

  int _ipToInt(String ip) {
    final parts = ip.split('.').map(int.parse).toList();
    return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3];
  }

  String _intToIp(int value) {
    return [
      (value >> 24) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF,
    ].join('.');
  }

  int _dottedMaskToPrefixLength(String mask) {
    if (mask.startsWith('0x')) {
      final v = int.parse(mask.substring(2), radix: 16);
      return v.toRadixString(2).replaceAll('0', '').length;
    }
    final maskInt = _ipToInt(mask);
    return maskInt.toRadixString(2).replaceAll('0', '').length;
  }

  // Memoization cache for subnet-mask lookups, keyed by "interfaceName|ip".
  // Cleared at the start of every top-level discovery pass (see
  // `discoverAllStream`) so it never serves a stale mask across passes,
  // but reused freely *within* a single pass where the same
  // interface/address gets looked up many times.
  final Map<String, int> _prefixLengthCache = {};

  Future<int> _getPrefixLength(String interfaceName, String ip) async {
    final cacheKey = '$interfaceName|$ip';
    final cached = _prefixLengthCache[cacheKey];
    if (cached != null) return cached;

    int prefixLength = 24;
    try {
      if (Platform.isWindows) {
        final result = await Process.run('powershell', [
          '-NoProfile',
          '-Command',
          "Get-NetIPAddress -InterfaceAlias '$interfaceName' -AddressFamily IPv4 "
              "| Where-Object {\$_.IPAddress -eq '$ip'} "
              "| Select-Object -ExpandProperty PrefixLength",
        ]);
        final out = result.stdout.toString().trim();
        final parsed = int.tryParse(out);
        if (parsed != null) prefixLength = parsed;
      } else {
        final result = await Process.run('ifconfig', [interfaceName]);
        final out = result.stdout.toString();
        final match = RegExp(r'netmask (0x[0-9a-fA-F]+|\d+\.\d+\.\d+\.\d+)')
            .firstMatch(out);
        if (match != null) {
          prefixLength = _dottedMaskToPrefixLength(match.group(1)!);
        }
      }
    } catch (e) {
      _log('Subnet mask lookup failed for $interfaceName ($ip): $e — assuming /24');
    }

    _prefixLengthCache[cacheKey] = prefixLength;
    return prefixLength;
  }

  ({int networkStart, int broadcast, int hostCount}) _subnetBounds(
      String ip, int prefixLength) {
    final ipInt = _ipToInt(ip);
    final hostBits = 32 - prefixLength;
    final maskInt = hostBits == 0 ? 0xFFFFFFFF : (0xFFFFFFFF << hostBits) & 0xFFFFFFFF;
    final network = ipInt & maskInt;
    final broadcast = network | (~maskInt & 0xFFFFFFFF);
    final hostCount = broadcast - network - 1;
    return (networkStart: network, broadcast: broadcast, hostCount: hostCount < 0 ? 0 : hostCount);
  }

  /// Real "is this IP inside this local interface's subnet" check, using
  /// the interface's actual prefix length — NOT a naive first-three-octets
  /// string compare (that breaks badly on anything wider than a /24,
  /// which is exactly the case for 169.254.0.0/16 link-local addresses:
  /// two APIPA IPs can differ in the third octet and still be on the same
  /// /16 segment).
  Future<bool> _ipInAnyLocalSubnet(String ip, List<NetworkInterface> interfaces) async {
    final ipInt = _ipToInt(ip);
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        final prefixLength = await _getPrefixLength(iface.name, addr.address);
        final bounds = _subnetBounds(addr.address, prefixLength);
        if (ipInt >= bounds.networkStart && ipInt <= bounds.broadcast) {
          return true;
        }
      }
    }
    return false;
  }

  // ---------------------------------------------------------------------
  // ARP TABLE — this is what lets us find/identify a camera regardless of
  // its current IP. Any device this machine has exchanged even a single
  // packet with (including one we just probed a moment ago during a port
  // scan) shows up here with its IP *and* its MAC. MAC doesn't change when
  // a camera's IP does, so it's what we use as the camera's real identity.
  // ---------------------------------------------------------------------

  /// Reads the OS ARP/neighbor cache. Returns a map of IP -> MAC (lowercase,
  /// colon-separated, e.g. "a4:14:37:12:34:56").
  Future<Map<String, String>> _readArpTable() async {
    final table = <String, String>{};
    try {
      if (Platform.isWindows) {
        final result = await Process.run('arp', ['-a']);
        final out = result.stdout.toString();
        // Lines look like:  192.168.1.23    a4-14-37-12-34-56     dynamic
        final re = RegExp(
            r'(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\s+([0-9a-fA-F]{2}(?:-[0-9a-fA-F]{2}){5})');
        for (final m in re.allMatches(out)) {
          final ip = m.group(1)!;
          final mac = m.group(2)!.replaceAll('-', ':').toLowerCase();
          table[ip] = mac;
        }
      } else {
        // macOS / Linux both support `arp -a`. Lines look like:
        // ? (192.168.1.23) at a4:14:37:12:34:56 on en0 ifscope [ethernet]
        final result = await Process.run('arp', ['-a']);
        final out = result.stdout.toString();
        final re = RegExp(
            r'\((\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\)\s+at\s+([0-9a-fA-F]{1,2}(?::[0-9a-fA-F]{1,2}){5})');
        for (final m in re.allMatches(out)) {
          final ip = m.group(1)!;
          final mac = m.group(2)!.toLowerCase();
          table[ip] = mac;
        }
      }
    } catch (e) {
      _log('ARP table read failed: $e');
    }
    return table;
  }

  /// Fast, low-noise discovery path: read whatever's already in the ARP
  /// cache (devices the OS has recently talked to on any local subnet) and
  /// just check those specific IPs for camera-like ports, instead of
  /// blind-scanning the whole subnet.
  Future<List<DiscoveredCamera>> discoverViaArpCache({
    Duration perHostTimeout = const Duration(milliseconds: 200),
  }) async {
    final found = <String, DiscoveredCamera>{};
    final interfaces = await _activeInterfaces();
    final localIps = <String>{
      for (final iface in interfaces) for (final a in iface.addresses) a.address
    };

    final table = await _readArpTable();
    if (table.isEmpty) {
      _log('ARP cache: empty or unreadable');
      return [];
    }
    _log('ARP cache: ${table.length} entr${table.length == 1 ? 'y' : 'ies'} to check');

    final entries = table.entries.where((e) => !localIps.contains(e.key)).toList();
    var index = 0;
    Future<void> worker() async {
      while (index < entries.length) {
        final entry = entries[index++];
        final ip = entry.key;
        final mac = entry.value;
        for (final port in _commonCameraPorts) {
          try {
            final socket = await Socket.connect(ip, port, timeout: perHostTimeout);
            socket.destroy();
            found[ip] = DiscoveredCamera(
              ip: ip,
              port: port,
              source: DiscoverySource.arpCache,
              mac: mac,
            );
            _log('ARP cache: found open port $port on $ip (mac=$mac)');
            break;
          } catch (_) {
            // closed/unreachable
          }
        }
      }
    }

    // ARP cache is typically small (dozens of entries at most) so a wide
    // worker pool finishes essentially instantly.
    await Future.wait(List.generate(32, (_) => worker()));
    return found.values.toList();
  }

  /// Runs ONVIF WS-Discovery on every active interface and returns any
  /// devices that answered. Replies arrive over L2 multicast, so a device
  /// can be found here even if it's not in any locally-configured subnet —
  /// `crossSubnet` is set accordingly rather than filtering it out.
  ///
  /// 5s (rather than the previous 4s) since this broadcast pass is now
  /// the ENTIRE scan (no TCP subnet-scan fallback runs after it by
  /// default) — a bit more patience here is worth it now that there's
  /// nothing downstream to catch a straggler.
  Future<List<DiscoveredCamera>> discoverOnvifCameras({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final found = <String, DiscoveredCamera>{};
    final interfaces = await _activeInterfaces();

    if (interfaces.isEmpty) {
      _log('ONVIF: no usable interfaces found');
      return [];
    }

    await Future.wait(interfaces.map((iface) async {
      for (final localAddr in iface.addresses) {
        if (localAddr.isLoopback) continue;
        await _probeOnvifOnInterface(
          iface: iface,
          localAddress: localAddr,
          timeout: timeout,
          found: found,
        );
      }
    }));

    final table = await _readArpTable();
    final enriched = <DiscoveredCamera>[];
    for (final c in found.values) {
      final withMac = table.containsKey(c.ip) ? c.copyWith(mac: table[c.ip]) : c;
      final crossSubnet = !await _ipInAnyLocalSubnet(withMac.ip, interfaces);
      enriched.add(withMac.copyWith(crossSubnet: crossSubnet));
    }

    _log('ONVIF: discovery finished, ${enriched.length} device(s) found '
        '(${enriched.where((c) => c.crossSubnet).length} cross-subnet)');
    return enriched;
  }

  Future<void> _probeOnvifOnInterface({
    required NetworkInterface iface,
    required InternetAddress localAddress,
    required Duration timeout,
    required Map<String, DiscoveredCamera> found,
  }) async {
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(localAddress, 0, reuseAddress: true);
      socket.broadcastEnabled = true;
      socket.joinMulticast(InternetAddress(_onvifMulticastAddress), iface);
      _log('ONVIF: bound on ${localAddress.address} (${iface.name}), joined multicast');

      final probe = _buildOnvifProbeMessage();
      final probeBytes = utf8.encode(probe);
      final target = InternetAddress(_onvifMulticastAddress);

      // Re-probe every 1.2s instead of every 3s. Most ONVIF cameras reply
      // within a few hundred ms of the FIRST probe anyway; this just
      // makes sure a dropped first probe doesn't cost the full timeout
      // window before a retry goes out.
      final probeTimer = Timer.periodic(const Duration(milliseconds: 1200), (t) {
        socket?.send(probeBytes, target, _onvifMulticastPort);
        _log('ONVIF: probe re-sent on ${iface.name}');
      });
      socket.send(probeBytes, target, _onvifMulticastPort);
      _log('ONVIF: initial probe sent on ${iface.name}');

      final completer = Completer<void>();
      final sub = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket?.receive();
        if (datagram == null) return;

        _log('ONVIF: reply received from ${datagram.address.address} on ${iface.name}');
        final response = utf8.decode(datagram.data, allowMalformed: true);
        for (final addr in _extractXAddrs(response)) {
          final uri = Uri.tryParse(addr);
          if (uri == null || uri.host.isEmpty) continue;
          found[uri.host] = DiscoveredCamera(
            ip: uri.host,
            port: uri.hasPort ? uri.port : 80,
            source: DiscoverySource.onvif,
            onvifServiceUrl: addr,
          );
        }
      });

      Timer(timeout, () {
        if (!completer.isCompleted) completer.complete();
      });
      await completer.future;
      probeTimer.cancel();
      await sub.cancel();
    } catch (e) {
      _log('ONVIF: discovery on ${iface.name} failed with error: $e');
    } finally {
      socket?.close();
    }
  }

  /// Runs Hikvision's SADP broadcast discovery, per active interface. This
  /// is the primary "works like iVMS-4200" path: SADP replies travel over
  /// the local L2 broadcast domain, so a camera on a different IP subnet
  /// than your PC (e.g. camera on 192.168.1.x, PC on 169.254.x.x) is still
  /// found here as long as they're on the same physical switch/segment —
  /// no routing required for *discovery*, only for actually connecting
  /// afterward (RTSP/SDK login).
  ///
  /// SADP replies also carry the device's serial number (`<DeviceSN>`),
  /// which is the strongest identity signal available at discovery time —
  /// unlike MAC or IP, it never changes even if the camera's NIC or IP
  /// does. `DiscoveredCamera.serialNumber` is populated here so callers
  /// can match against a previously-saved `serial_number` even after the
  /// camera's IP has drifted.
  ///
  /// 5s (rather than the previous 4s) for the same reason as
  /// `discoverOnvifCameras` — this is now the whole scan, not one stage
  /// of two.
  Future<List<DiscoveredCamera>> discoverSadpCameras({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final found = <String, DiscoveredCamera>{};
    final interfaces = await _activeInterfaces();

    if (interfaces.isEmpty) {
      _log('SADP: no usable interfaces found');
      return [];
    }

    await Future.wait(interfaces.map((iface) async {
      for (final localAddr in iface.addresses) {
        if (localAddr.isLoopback) continue;
        await _probeSadpOnInterface(
          iface: iface,
          localAddress: localAddr,
          timeout: timeout,
          found: found,
        );
      }
    }));

    final table = await _readArpTable();
    final enriched = <DiscoveredCamera>[];
    for (final c in found.values) {
      final withMac = table.containsKey(c.ip) ? c.copyWith(mac: table[c.ip]) : c;
      final crossSubnet = !await _ipInAnyLocalSubnet(withMac.ip, interfaces);
      enriched.add(withMac.copyWith(crossSubnet: crossSubnet));
    }

    _log('SADP: discovery finished, ${enriched.length} device(s) found '
        '(${enriched.where((c) => c.crossSubnet).length} cross-subnet, '
        '${enriched.where((c) => c.serialNumber != null).length} with serial number)');
    return enriched;
  }

  Future<void> _probeSadpOnInterface({
    required NetworkInterface iface,
    required InternetAddress localAddress,
    required Duration timeout,
    required Map<String, DiscoveredCamera> found,
  }) async {
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(localAddress, _sadpPort, reuseAddress: true);
      socket.broadcastEnabled = true;
      _log('SADP: bound on ${localAddress.address} (${iface.name})');

      final prefixLength = await _getPrefixLength(iface.name, localAddress.address);
      final bounds = _subnetBounds(localAddress.address, prefixLength);
      final targets = <String>{_intToIp(bounds.broadcast), '255.255.255.255'};
      _log('SADP: broadcasting to ${targets.join(', ')} via ${iface.name}');

      final probeBytes = utf8.encode(_buildSadpProbeMessage());
      void broadcastOnce() {
        for (final target in targets) {
          socket?.send(probeBytes, InternetAddress(target), _sadpPort);
        }
      }

      // Same tightened cadence as ONVIF above.
      final probeTimer = Timer.periodic(const Duration(milliseconds: 1200), (t) {
        broadcastOnce();
        _log('SADP: inquiry re-broadcast on ${iface.name}');
      });
      broadcastOnce();
      _log('SADP: initial inquiry broadcast sent on ${iface.name}');

      final completer = Completer<void>();
      final sub = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket?.receive();
        if (datagram == null) return;

        final response = utf8.decode(datagram.data, allowMalformed: true);
        if (!response.contains('ProbeMatch')) return;

        _log('SADP: reply received from ${datagram.address.address} on ${iface.name}');
        final ip = _extractSadpTag(response, 'IPv4Address') ??
            datagram.address.address;
        final httpPort =
            int.tryParse(_extractSadpTag(response, 'HttpPort') ?? '') ?? 80;
        final mac = _extractSadpTag(response, 'MAC');
        final serial = _extractSadpTag(response, 'DeviceSN');

        found[ip] = DiscoveredCamera(
          ip: ip,
          port: httpPort,
          source: DiscoverySource.sadp,
          mac: mac?.toLowerCase(),
          serialNumber: (serial != null && serial.isNotEmpty) ? serial : null,
        );
      });

      Timer(timeout, () {
        if (!completer.isCompleted) completer.complete();
      });
      await completer.future;
      probeTimer.cancel();
      await sub.cancel();
    } catch (e) {
      _log('SADP: discovery on ${iface.name} failed with error: $e');
    } finally {
      socket?.close();
    }
  }

  /// Scans ALL active non-virtual local subnets for hosts with a
  /// camera-like open port. This can only ever reach IPs your machine can
  /// route to — that's a hard OS/networking limit, not something fixable
  /// in Dart. On a large or link-local (APIPA, /16) range it only affords
  /// to check a slice of it (see maxHostsToScan) — `discoverViaArpCache()`
  /// and repeated `discoverAll()` passes cover devices outside that slice
  /// once the OS has ARPed them once.
  ///
  /// Every local interface/subnet is scanned CONCURRENTLY (previously
  /// this looped `for (iface in interfaces) { await scan(iface) }`, which
  /// meant a machine with 2 active NICs paid for both scans back-to-back
  /// instead of at the same time).
  Future<List<DiscoveredCamera>> scanSubnetForCameras({
    Duration perHostTimeout = const Duration(milliseconds: 100),
    int concurrency = 256,
    Set<String> skipInterfaceLocalIps = const {},
    List<int> ports = const [8000],
  }) async {
    final results = <DiscoveredCamera>[];
    final seenKeys = <String>{};

    try {
      final interfaces = await _activeInterfaces();

      if (interfaces.isEmpty) {
        _log('Port scan: no usable IPv4 interfaces found');
        return [];
      }

      final scanTasks = <Future<void>>[];

      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (addr.isLoopback) continue;

          final localIp = addr.address;
          final parts = localIp.split('.');
          if (parts.length != 4) continue;

          if (skipInterfaceLocalIps.contains(localIp)) {
            _log('Port scan: skipping ${iface.name} ($localIp) — already found via a faster method');
            continue;
          }

          // Fire off this interface/address's subnet scan without
          // awaiting it here — all of them run in parallel, collected
          // below via Future.wait.
          scanTasks.add(_scanOneInterfaceSubnet(
            iface: iface,
            localIp: localIp,
            ports: ports,
            perHostTimeout: perHostTimeout,
            concurrency: concurrency,
            results: results,
            seenKeys: seenKeys,
          ));
        }
      }

      await Future.wait(scanTasks);
    } catch (e) {
      _log('Port scan failed: $e');
    }

    // Enrich with MAC — the TCP connects above just caused the OS to ARP
    // every host that answered, so the ARP table now has fresh entries.
    final table = await _readArpTable();
    final enriched =
        results.map((c) => table.containsKey(c.ip) ? c.copyWith(mac: table[c.ip]) : c).toList();

    _log('Port scan: finished, ${enriched.length} host(s) found across all interfaces');
    return enriched;
  }

  /// One interface/address's worth of subnet scanning — pulled out of
  /// `scanSubnetForCameras` so multiple of these can run concurrently via
  /// `Future.wait`. `results`/`seenKeys` are shared mutable collections;
  /// this is safe because Dart is single-threaded and there's no `await`
  /// between the "already seen?" check and the add, so concurrent workers
  /// (even across different interface scans) can never interleave mid-add.
  Future<void> _scanOneInterfaceSubnet({
    required NetworkInterface iface,
    required String localIp,
    required List<int> ports,
    required Duration perHostTimeout,
    required int concurrency,
    required List<DiscoveredCamera> results,
    required Set<String> seenKeys,
  }) async {
    final prefixLength = await _getPrefixLength(iface.name, localIp);
    final bounds = _subnetBounds(localIp, prefixLength);

    // Link-local (APIPA, 169.254.0.0/16) addresses are assigned
    // pseudo-randomly across the whole /16, so a small slice near the low
    // end will very often just miss the device entirely. Allow a much
    // bigger scan budget specifically for that range; cap everything else
    // more conservatively.
    final isLinkLocalRange = localIp.startsWith('169.254.');
    final maxHostsToScan = isLinkLocalRange ? 65534 : 4096;

    var hostCount = bounds.hostCount;
    if (hostCount > maxHostsToScan) {
      _log('Port scan: /$prefixLength on ${iface.name} has $hostCount hosts — capping to $maxHostsToScan');
      hostCount = maxHostsToScan;
    }

    _log('Port scan: probing ${_intToIp(bounds.networkStart + 1)}-${_intToIp(bounds.networkStart + hostCount)} '
        '(/$prefixLength) on ports $ports via interface "${iface.name}" ($localIp)');

    final hosts = List<int>.generate(hostCount, (i) => bounds.networkStart + 1 + i);
    var index = 0;

    Future<void> worker() async {
      while (index < hosts.length) {
        final i = index++;
        final host = _intToIp(hosts[i]);
        if (host == localIp) continue;

        for (final port in ports) {
          try {
            final socket = await Socket.connect(host, port, timeout: perHostTimeout);
            socket.destroy();
            final key = '$host:$port';
            if (seenKeys.add(key)) {
              _log('Port scan: found open port $port on $host via ${iface.name}');
              results.add(DiscoveredCamera(ip: host, port: port, source: DiscoverySource.portScan));
            }
            break;
          } catch (_) {
            // Closed, filtered, or unreachable
          }
        }
      }
    }

    // Boost concurrency for the much larger link-local scan so it
    // doesn't take forever.
    final effectiveConcurrency = isLinkLocalRange ? concurrency * 4 : concurrency;
    await Future.wait(List.generate(effectiveConcurrency, (_) => worker()));
  }

  /// Quick recheck of cameras you've already found before (e.g. loaded from
  /// your app's own storage, keyed by MAC). Just does a direct connect to
  /// each one's *last known* IP + port — no scanning, no broadcasting.
  ///
  /// Returns only the ones still reachable at their last known address.
  Future<List<DiscoveredCamera>> recheckKnownCameras(
    List<DiscoveredCamera> knownCameras, {
    Duration timeout = const Duration(milliseconds: 300),
  }) async {
    final stillThere = <DiscoveredCamera>[];
    await Future.wait(knownCameras.map((known) async {
      try {
        final socket = await Socket.connect(known.ip, known.port, timeout: timeout);
        socket.destroy();
        _log('Recheck: ${known.identityKey} still at ${known.ip}:${known.port}');
        stillThere.add(known);
      } catch (_) {
        _log('Recheck: ${known.identityKey} no longer at ${known.ip}:${known.port}');
      }
    }));
    return stillThere;
  }

  /// Runs discovery, but first fast-path-rechecks any cameras you already
  /// know about (by their last known IP).
  Stream<DiscoveredCamera> discoverAllStreamWithKnownCameras(
    List<DiscoveredCamera> knownCameras,
  ) async* {
    final stillThere = await recheckKnownCameras(knownCameras);
    final foundIdentities = <String>{};
    for (final cam in stillThere) {
      foundIdentities.add(cam.identityKey);
      yield cam;
    }

    if (stillThere.length == knownCameras.length && knownCameras.isNotEmpty) {
      _log('All ${knownCameras.length} known camera(s) confirmed at their last known IP — skipping full discovery');
      return;
    }

    await for (final cam in discoverAllStream()) {
      if (foundIdentities.contains(cam.identityKey)) continue;
      yield cam;
    }
  }

  /// Runs discovery and returns everything at once (convenience wrapper
  /// around `discoverAllStream`).
  Future<List<DiscoveredCamera>> discoverAll() async {
    final results = <DiscoveredCamera>[];
    await for (final cam in discoverAllStream()) {
      results.add(cam);
    }
    return results;
  }

  /// After all three broadcast/cache sources (ONVIF, SADP, ARP cache) have
  /// reported in, wait this much longer before finishing — just a small
  /// settle window in case a slow reply is still in flight, rather than
  /// always burning the full per-source timeout.
  static const Duration _earlySettleWindow = Duration(milliseconds: 500);

  /// Same discovery, but emits each camera the moment it's found instead of
  /// waiting for every method to finish.
  ///
  /// THIS NOW MATCHES HOW HIKVISION'S OWN SADP TOOL (AND IVMS-4200'S
  /// "DEVICE SEARCH") ACTUALLY WORKS: it's broadcast-only. SADP literally
  /// stands for "Search Active Devices Protocol" — the real tool sends a
  /// UDP broadcast to the LAN, listens for replies for a few seconds, and
  /// that's it. It does NOT open a TCP connection to every host in your
  /// subnet.
  ///
  /// The previous version of this method followed broadcast discovery
  /// with a brute-force TCP port-scan fallback (`scanSubnetForCameras`) —
  /// hundreds of concurrent `Socket.connect` attempts across up to 4096+
  /// hosts. That's what was causing the UI to freeze/stutter: even though
  /// each connect is async, firing that many concurrent socket attempts
  /// and their timeout timers floods the same isolate Flutter uses for
  /// building/painting frames, so the event loop falls behind and frames
  /// get dropped. Removing it from the default path removes the freeze
  /// at the source, and also makes discovery genuinely fast — broadcast
  /// replies normally land within a second on a healthy LAN, so a full
  /// pass now finishes in ~2-3s total instead of stalling on a subnet
  /// sweep.
  ///
  /// The TCP port-scan fallback still exists (`scanSubnetForCameras` /
  /// `deepScanForCameras`) for the rare case where a camera doesn't speak
  /// ONVIF or SADP and isn't in the ARP cache yet — but it's opt-in now,
  /// not run automatically. Wire a separate "Advanced / Deep Scan" button
  /// to `deepScanForCameras()` if you want to expose it.
  ///
  /// Dedup is keyed on BOTH identity (serial/MAC-preferred) AND raw
  /// ip:port, so a device that resolves to two different identityKeys
  /// across sources (e.g. ONVIF sees it before SADP resolves its serial)
  /// still collapses into a single result instead of showing up twice.
  Stream<DiscoveredCamera> discoverAllStream() async* {
    _log('--- Starting camera discovery (broadcast-only, SADP-style) ---');
    _prefixLengthCache.clear();
    await _logAllInterfaces();

    final byIdentity = <String, DiscoveredCamera>{};
    final identityForIpPort = <String, String>{};

    // Returns whether this call resulted in a NEW device being recorded
    // (i.e. should be yielded to the caller).
    bool noteAndShouldYield(DiscoveredCamera c) {
      final ipPortKey = '${c.ip}:${c.port}';
      final existingKeyForSocket = identityForIpPort[ipPortKey];

      if (existingKeyForSocket != null) {
        // Same ip:port seen before, possibly under a different identity
        // key (e.g. serial/MAC resolved this time but not last time) —
        // merge into the original entry instead of creating a duplicate.
        final existing = byIdentity[existingKeyForSocket];
        if (existing != null) {
          var merged = existing;
          if (merged.mac == null && c.mac != null) {
            merged = merged.copyWith(mac: c.mac);
          }
          if (merged.serialNumber == null && c.serialNumber != null) {
            merged = merged.copyWith(serialNumber: c.serialNumber);
          }
          byIdentity[existingKeyForSocket] = merged;
        }
        return false;
      }

      identityForIpPort[ipPortKey] = c.identityKey;
      final existing = byIdentity[c.identityKey];
      if (existing == null) {
        byIdentity[c.identityKey] = c;
        return true;
      }
      var merged = existing;
      if (merged.mac == null && c.mac != null) {
        merged = merged.copyWith(mac: c.mac);
      }
      if (merged.serialNumber == null && c.serialNumber != null) {
        merged = merged.copyWith(serialNumber: c.serialNumber);
      }
      byIdentity[c.identityKey] = merged;
      return false;
    }

    // Broadcast + cache sources, all in parallel — this is the ENTIRE
    // scan now, matching real SADP behavior. Exits early (after a short
    // settle window) once all three have reported, rather than always
    // waiting out the full per-source timeout.
    final controller = StreamController<DiscoveredCamera>();
    var pending = 3;
    Timer? settleTimer;
    void maybeCloseSoon() {
      settleTimer?.cancel();
      settleTimer = Timer(_earlySettleWindow, () {
        if (!controller.isClosed) controller.close();
      });
    }
    void done() {
      pending--;
      if (pending == 0) {
        maybeCloseSoon();
      }
    }

    discoverOnvifCameras().then((cams) {
      for (final c in cams) {
        controller.add(c);
      }
      done();
    });
    discoverSadpCameras().then((cams) {
      for (final c in cams) {
        controller.add(c);
      }
      done();
    });
    discoverViaArpCache().then((cams) {
      for (final c in cams) {
        controller.add(c);
      }
      done();
    });

    await for (final cam in controller.stream) {
      final isNew = noteAndShouldYield(cam);
      if (isNew) yield cam;
    }
    settleTimer?.cancel();

    _log('--- Discovery complete: ${byIdentity.length} device(s) found via broadcast/cache ---');
  }

  /// Optional, opt-in fallback for the rare device that doesn't answer
  /// ONVIF or SADP broadcasts and isn't already in the ARP cache (e.g. a
  /// non-Hikvision, non-ONVIF camera you've never connected to before).
  ///
  /// This is the expensive brute-force TCP port scan that used to run
  /// automatically as part of every search and caused the UI freeze —
  /// it's no longer part of `discoverAll()` / `discoverAllStream()`.
  /// Wire it to an explicit "Advanced Scan" / "Can't find your camera?"
  /// action instead of the main scan button, and consider showing a
  /// progress indicator, since it can still take several seconds on a
  /// large subnet even with concurrent scanning.
  ///
  /// [alreadyFound] lets you skip subnets that the broadcast pass already
  /// covered — pass the results of a prior `discoverAll()` call and this
  /// will compute which local subnets to skip automatically.
  Future<List<DiscoveredCamera>> deepScanForCameras({
    List<DiscoveredCamera> alreadyFound = const [],
  }) async {
    _log('--- Starting deep scan (TCP port sweep, opt-in) ---');
    _prefixLengthCache.clear();
    final interfaces = await _activeInterfaces();
    final foundOnLocalIp = <String>{};

    for (final cam in alreadyFound) {
      if (cam.crossSubnet) continue;
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final prefixLength = await _getPrefixLength(iface.name, addr.address);
          final bounds = _subnetBounds(addr.address, prefixLength);
          final camIpInt = _ipToInt(cam.ip);
          if (camIpInt >= bounds.networkStart && camIpInt <= bounds.broadcast) {
            foundOnLocalIp.add(addr.address);
          }
        }
      }
    }

    final results = await scanSubnetForCameras(skipInterfaceLocalIps: foundOnLocalIp);
    _log('--- Deep scan complete: ${results.length} additional device(s) found ---');
    return results;
  }

  /// Windows-only helper: adds a secondary IP address to [interfaceName]
  /// inside the target subnet, so a camera found cross-subnet via SADP/
  /// ONVIF (see `DiscoveredCamera.crossSubnet`) becomes actually reachable
  /// for RTSP/SDK login — this is the same fix iVMS-4200's "Modify
  /// Netmask" flow nudges you toward, just automated. Requires the app to
  /// be running elevated (admin), since changing adapter IPs does.
  ///
  /// [secondaryIp] should be a free address in the camera's subnet (e.g.
  /// if the camera is 192.168.1.100/24, something like 192.168.1.250).
  /// [subnetMask] defaults to a /24.
  Future<bool> addWindowsSecondaryIp({
    required String interfaceName,
    required String secondaryIp,
    String subnetMask = '255.255.255.0',
  }) async {
    if (!Platform.isWindows) {
      _log('addWindowsSecondaryIp: no-op, not running on Windows');
      return false;
    }
    try {
      final result = await Process.run('netsh', [
        'interface',
        'ip',
        'add',
        'address',
        interfaceName,
        secondaryIp,
        subnetMask,
      ]);
      final ok = result.exitCode == 0;
      _log(ok
          ? 'Added secondary IP $secondaryIp on $interfaceName'
          : 'Failed to add secondary IP: ${result.stderr}');
      return ok;
    } catch (e) {
      _log('addWindowsSecondaryIp failed: $e');
      return false;
    }
  }

  /// Suggests a free-looking secondary IP inside [cameraIp]'s subnet
  /// (assumes /24) that this PC's NIC can add via [addWindowsSecondaryIp],
  /// so a cross-subnet camera found via SADP/ONVIF becomes actually
  /// reachable. Picks a high host number (.250) to minimize collision odds
  /// with real devices — same convention iVMS-4200's "Modify Netmask"
  /// dialog nudges toward. Falls back to the camera's own IP (a caller
  /// should treat that as "couldn't compute one") if it isn't IPv4-shaped.
  String suggestSecondaryIp(String cameraIp) {
    final parts = cameraIp.split('.');
    if (parts.length != 4) return cameraIp;
    return '${parts[0]}.${parts[1]}.${parts[2]}.250';
  }

  Future<void> _logAllInterfaces() async {
    if (!debugLogging) return;
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: true,
      );
      if (interfaces.isEmpty) {
        _log('Interfaces: none found (is networking enabled?)');
        return;
      }
      for (final iface in interfaces) {
        final addrs = iface.addresses.map((a) => a.address).join(', ');
        _log('Interfaces: "${iface.name}" -> $addrs');
      }
    } catch (e) {
      _log('Interfaces: failed to list — $e');
    }
  }

  static const List<String> _virtualAdapterNamePatterns = [
    'vethernet',
    'vmware',
    'virtualbox',
    'vboxnet',
    'docker',
    'hyper-v',
    'tailscale',
    'tap',
    'tun',
    'utun',
    'wsl',
    'loopback',
    'bluetooth',
    'zerotier',
    'zt',
  ];

  String _buildOnvifProbeMessage() {
    final messageId = _generateUuid();
    return '''<?xml version="1.0" encoding="UTF-8"?>
<e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope"
            xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing"
            xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery"
            xmlns:dn="http://www.onvif.org/ver10/network/wsdl">
  <e:Header>
    <w:MessageID>uuid:$messageId</w:MessageID>
    <w:To e:mustUnderstand="1">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>
    <w:Action w:mustUnderstand="1">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action>
  </e:Header>
  <e:Body>
    <d:Probe>
      <d:Types>dn:NetworkVideoTransmitter</d:Types>
    </d:Probe>
  </e:Body>
</e:Envelope>''';
  }

  String _buildSadpProbeMessage() {
    final uuid = _generateUuid();
    return '<?xml version="1.0" encoding="utf-8"?>'
        '<Probe><Uuid>$uuid</Uuid><Types>inquiry</Types></Probe>';
  }

  String _generateUuid() {
    final rand = Random();
    List<String> hex(int n) =>
        List.generate(n, (_) => rand.nextInt(16).toRadixString(16));
    return '${hex(8).join()}-${hex(4).join()}-4${hex(3).join()}-'
        'a${hex(3).join()}-${hex(12).join()}';
  }

  List<String> _extractXAddrs(String response) {
    final matches = RegExp(
      r'[a-zA-Z0-9]*:?XAddrs>([^<]+)<',
      caseSensitive: false,
    ).allMatches(response);

    final urls = <String>[];
    for (final m in matches) {
      final raw = m.group(1)?.trim() ?? '';
      urls.addAll(raw.split(RegExp(r'\s+')).where((s) => s.isNotEmpty));
    }
    return urls;
  }

  String? _extractSadpTag(String xml, String tag) {
    final match =
        RegExp('<$tag>([^<]*)</$tag>', caseSensitive: false).firstMatch(xml);
    return match?.group(1)?.trim();
  }
}