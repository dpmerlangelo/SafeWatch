import 'dart:async';
import 'dart:convert' show LineSplitter, Utf8Decoder, jsonEncode;
import 'dart:io' show Directory, File, Platform, Process, ProcessException;

import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:window_manager/window_manager.dart';
import 'package:screen_retriever/screen_retriever.dart';
import '../../constants/app_theme.dart';
import '../../controllers/theme_controller.dart';

import '../../services/alert_notifications.dart';
import '../../constants/app_colors.dart';
import '../../constants/supabase_constants.dart';

// NOTE on local recording (see `_newRecordingFilePath` / `_resolveBundled
// Ffmpeg` / `_CameraFeed.startRecording`):
//
//  - `path_provider` is used to find writable folders on the machine
//    running the app. Add to pubspec.yaml if missing:
//      path_provider: ^2.1.0
//
//  - Recording is done by spawning `ffmpeg` as a subprocess to stream-copy
//    the RTSP feed into a file, independent of playback. To avoid needing
//    ffmpeg installed system-wide on every device, a copy is bundled with
//    the app as a Flutter asset and extracted to local storage on first
//    use. One-time setup per platform you ship:
//
//      1. Download a static ffmpeg build (no separate install, just the
//         executable) for each OS you target:
//           Windows: https://www.gyan.dev/ffmpeg/builds/ ("release full"
//                     or "release essentials" zip — grab bin/ffmpeg.exe)
//           macOS:   https://evermeet.cx/ffmpeg/
//           Linux:   https://johnvansickle.com/ffmpeg/
//
//      2. Put the binary in your project at:
//           assets/ffmpeg/ffmpeg.exe   (Windows)
//           assets/ffmpeg/ffmpeg       (macOS/Linux — same filename, only
//                                        include the one(s) for the OS(es)
//                                        you're shipping)
//
//      3. Register the folder in pubspec.yaml:
//           flutter:
//             assets:
//               - assets/ffmpeg/
//
//      4. `flutter pub get` and rebuild. On first recording attempt the
//         app copies the bundled binary out to local app-support storage
//         and reuses it after that — no PATH setup needed on the target
//         machine.
//
//    ffmpeg is LGPL/GPL-licensed depending on the build — check
//    https://ffmpeg.org/legal.html for what redistributing a copy with
//    your app requires (typically: keep the binary as-is/unmodified and
//    make the corresponding source available on request for GPL builds,
//    or use an LGPL build if you'd rather avoid that).
//
//    If no asset is bundled, recording silently falls back to whatever
//    `ffmpeg` resolves to on the system PATH (the previous behavior).

/// True on Windows/macOS/Linux desktop builds (not web, not mobile).

bool get _isDesktopPlatform =>
    !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

/// True only inside the auxiliary window process (set in
/// `_AuxiliaryDisplayPageState`), so it can hide "Open Aux Window".
bool _isAuxWindow = false;

/// Guards against media_kit's native backend never having been set up.
bool _mediaKitReady = false;
void _ensureMediaKitReady() {
  if (_mediaKitReady) return;
  MediaKit.ensureInitialized();
  _mediaKitReady = true;
}

/// Resolves a working ffmpeg executable for local recording.
///
/// Looks for a copy bundled as a Flutter asset (`assets/ffmpeg/ffmpeg.exe`
/// on Windows, `assets/ffmpeg/ffmpeg` on macOS/Linux) and — the first time
/// it's needed — copies it out to a writable folder on disk, since asset
/// bundle contents can't be executed in place. After that first copy it
/// just reuses the extracted file, so this is cheap on subsequent calls.
///
/// Returns null if no bundled binary was found, in which case the caller
/// should fall back to whatever `ffmpeg` resolves to on PATH.
Future<String?> _resolveBundledFfmpeg() async {
  final binaryName = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
  final assetPath = 'assets/ffmpeg/$binaryName';

  try {
    final supportDir = await getApplicationSupportDirectory();
    final binDir = Directory('${supportDir.path}${Platform.pathSeparator}bin');
    if (!await binDir.exists()) {
      await binDir.create(recursive: true);
    }
    final localFile = File('${binDir.path}${Platform.pathSeparator}$binaryName');

    if (!await localFile.exists()) {
      final data = await rootBundle.load(assetPath);
      await localFile.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
      if (!Platform.isWindows) {
        // Extracted files aren't executable by default on macOS/Linux.
        await Process.run('chmod', ['+x', localFile.path]);
      }
    }
    return localFile.path;
  } catch (e) {
    // No bundled binary present (asset missing) — caller falls back to
    // whatever "ffmpeg" resolves to on the system PATH, if anything.
    debugPrint('No bundled ffmpeg asset found ($e); will try PATH instead.');
    return null;
  }
}

/// Builds a fresh, unique file path under a "CCTV Recordings" folder on the
/// local machine (laptop/PC/server running the app) for a new recording of
/// [camera]. Falls back to the current working directory if the platform's
/// documents folder can't be resolved.
Future<String> _newRecordingFilePath(CctvCamera camera) async {
  Directory baseDir;
  try {
    final docs = await getApplicationDocumentsDirectory();
    baseDir = Directory('${docs.path}${Platform.pathSeparator}CCTV Recordings');
  } catch (_) {
    baseDir =
        Directory('${Directory.current.path}${Platform.pathSeparator}CCTV Recordings');
  }
  if (!await baseDir.exists()) {
    await baseDir.create(recursive: true);
  }

  final safeName = camera.name
      .replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '')
      .trim()
      .replaceAll(' ', '_');
  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final stamp =
      '${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}${two(now.second)}';

  return '${baseDir.path}${Platform.pathSeparator}'
      '${safeName.isEmpty ? 'Camera' : safeName}_$stamp.mkv';
}

PageRoute<T> _instantRoute<T>(WidgetBuilder builder) {
  return PageRouteBuilder<T>(
    pageBuilder: (context, animation, secondaryAnimation) => builder(context),
    transitionDuration: Duration.zero,
    reverseTransitionDuration: Duration.zero,
    opaque: true,
  );
}

/// A single camera's connection info needed to build its RTSP URL.
class CctvCamera {
  final String id;
  final String name;
  final String ip;
  final int rtspPort;
  final String? username;
  final String? password;
  final String? location;
  final String? serialNumber;
  final String? status;
  final String? streamUrlOverride;
  final String channelPath;
  final double? latitude;
  final double? longitude;

  const CctvCamera({
    required this.id,
    required this.name,
    required this.ip,
    this.rtspPort = 554,
    this.username,
    this.password,
    this.location,
    this.serialNumber,
    this.status,
    this.streamUrlOverride,
    this.channelPath = 'Streaming/Channels/101',
    this.latitude,
    this.longitude,
  });

  factory CctvCamera.fromMap(Map<String, dynamic> data) {
    final portStr = (data['port'] ?? '554').toString().trim();
    final port = int.tryParse(portStr) ?? 554;
    return CctvCamera(
      id: data['id'].toString(),
      name: (data['name'] ?? 'Unnamed Camera').toString(),
      ip: (data['ip_address'] ?? '').toString().trim(),
      rtspPort: port,
      username: (data['username'] as String?)?.trim(),
      password: (data['password'] as String?)?.trim(),
      location: (data['location'] as String?)?.trim(),
      serialNumber: (data['serial_number'] as String?)?.trim(),
      status: (data['status'] as String?)?.trim(),
      streamUrlOverride: (data['stream_url'] as String?)?.trim(),
      latitude: (data['latitude'] as num?)?.toDouble(),
      longitude: (data['longitude'] as num?)?.toDouble(),
    );
  }

  static List<CctvCamera> listFromMaps(List<Map<String, dynamic>> list) {
    return list
        .map((data) => CctvCamera.fromMap(data))
        .where((camera) => camera.ip.isNotEmpty)
        .toList();
  }

  String get rtspUrl {
    if (streamUrlOverride != null && streamUrlOverride!.isNotEmpty) {
      return streamUrlOverride!;
    }
    final auth = (username != null &&
            username!.isNotEmpty &&
            password != null &&
            password!.isNotEmpty)
        ? '$username:$password@'
        : '';
    return 'rtsp://$auth$ip:$rtspPort/$channelPath';
  }
  String get gridRtspUrl => rtspUrl.contains('/Channels/101')
      ? rtspUrl.replaceFirst('/Channels/101', '/Channels/102')
      : rtspUrl;
}

enum AlertLevel {
  advisory,
  priority,
  critical;

  static AlertLevel? fromString(String? raw) {
    switch (raw) {
      case 'advisory':
        return AlertLevel.advisory;
      case 'priority':
        return AlertLevel.priority;
      case 'critical':
        return AlertLevel.critical;
      default:
        return null;
    }
  }

  /// Fallback when a row has no explicit level set yet.
  ///
  /// 'Violence' and 'Accident' (capitalized) are the class names that come
  /// straight out of the SafeWatch .pt model — see SAFEWATCH_CLASSES in
  /// yolo_detection_service.py. 'fire' also comes from SafeWatch. 'curfew'
  /// and 'traffic' are the two heuristic alert types the plain YOLO
  /// detection service is still responsible for.
  static AlertLevel forAlertType(String alertType) {
    switch (alertType) {
      case 'fire':
      case 'Violence':
        return AlertLevel.critical;
      case 'Accident':
      case 'traffic':
        return AlertLevel.priority;
      case 'curfew':
        return AlertLevel.advisory;
      default:
        return AlertLevel.priority;
    }
  }

  Color get color => switch (this) {
        AlertLevel.advisory => const Color(0xFFFFC107), // yellow
        AlertLevel.priority => const Color(0xFFFF9800), // orange
        AlertLevel.critical => const Color(0xFFFF3B30), // red
      };

  String get label => switch (this) {
        AlertLevel.advisory => 'LEVEL 1 · ADVISORY',
        AlertLevel.priority => 'LEVEL 2 · PRIORITY',
        AlertLevel.critical => 'LEVEL 3 · CRITICAL',
      };
}

// ---------------------------------------------------------------------------
// Feed status — drives the little status dot in the navigator tree.
// ---------------------------------------------------------------------------

enum _FeedStatus { live, buffering, error, empty }

_FeedStatus _statusOf(_CameraFeed? feed) {
  if (feed == null) return _FeedStatus.empty;
  if (feed.hasError) return _FeedStatus.error;
  if (feed.isBuffering) return _FeedStatus.buffering;
  return _FeedStatus.live;
}

extension on _FeedStatus {
  Color get dotColor => switch (this) {
        _FeedStatus.live => const Color(0xFF2ECC71),
        _FeedStatus.buffering => const Color(0xFFFFC107),
        _FeedStatus.error => const Color(0xFFFF3B30),
        _FeedStatus.empty => const Color(0xFF6B7280),
      };

  String get label => switch (this) {
        _FeedStatus.live => 'Online',
        _FeedStatus.buffering => 'Connecting',
        _FeedStatus.error => 'Offline',
        _FeedStatus.empty => 'Not shown',
      };
}

// ---------------------------------------------------------------------------
// Layout scheme model
// ---------------------------------------------------------------------------

class CameraLayoutScheme {
  final String id;
  String name;
  final int columns;
  final int rows;
  final bool isPreset;

  /// length == columns * rows. Each entry is a camera id, or null if empty.
  List<String?> slotCameraIds;

  CameraLayoutScheme({
    required this.id,
    required this.name,
    required this.columns,
    required this.rows,
    required this.slotCameraIds,
    this.isPreset = false,
  }) {
    _resizeSlotsIfNeeded();
  }

  int get slotCount => columns * rows;

  void _resizeSlotsIfNeeded() {
    if (slotCameraIds.length == slotCount) return;
    final resized = List<String?>.filled(slotCount, null);
    for (var i = 0; i < slotCameraIds.length && i < slotCount; i++) {
      resized[i] = slotCameraIds[i];
    }
    slotCameraIds = resized;
  }

  factory CameraLayoutScheme.autoFill({
    required int columns,
    required int rows,
    required List<CctvCamera> cameras,
    required String label,
  }) {
    final slotCount = columns * rows;
    final slots = List<String?>.filled(slotCount, null);
    for (var i = 0; i < cameras.length && i < slotCount; i++) {
      slots[i] = cameras[i].id;
    }
    return CameraLayoutScheme(
      id: 'preset_${columns}x$rows',
      name: label,
      columns: columns,
      rows: rows,
      slotCameraIds: slots,
      isPreset: true,
    );
  }

  CameraLayoutScheme copyWith({
    String? id,
    String? name,
    int? columns,
    int? rows,
    List<String?>? slotCameraIds,
    bool? isPreset,
  }) {
    return CameraLayoutScheme(
      id: id ?? this.id,
      name: name ?? this.name,
      columns: columns ?? this.columns,
      rows: rows ?? this.rows,
      slotCameraIds: slotCameraIds ?? List<String?>.from(this.slotCameraIds),
      isPreset: isPreset ?? this.isPreset,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'columns': columns,
      'rows': rows,
      'slotCameraIds': slotCameraIds,
    };
  }

  factory CameraLayoutScheme.fromMap(Map<String, dynamic> map) {
    final rawSlots = (map['slotCameraIds'] as List?) ?? const [];
    return CameraLayoutScheme(
      id: (map['id'] ?? DateTime.now().millisecondsSinceEpoch.toString())
          .toString(),
      name: (map['name'] ?? 'Layout').toString(),
      columns: (map['columns'] as num?)?.toInt() ?? 2,
      rows: (map['rows'] as num?)?.toInt() ?? 2,
      slotCameraIds:
          rawSlots.map((e) => e == null ? null : e.toString()).toList(),
      isPreset: false,
    );
  }

  /// Builds a scheme from a `camera_layouts` table row.
  factory CameraLayoutScheme.fromSupabaseRow(Map<String, dynamic> row) {
    final rawSlots = (row['slot_camera_ids'] as List?) ?? const [];
    return CameraLayoutScheme(
      id: row['id'].toString(),
      name: (row['name'] ?? 'Layout').toString(),
      columns: (row['columns'] as num?)?.toInt() ?? 2,
      rows: (row['rows'] as num?)?.toInt() ?? 2,
      slotCameraIds:
          rawSlots.map((e) => e == null ? null : e.toString()).toList(),
      isPreset: false,
    );
  }

  /// Row payload for insert/upsert into `camera_layouts`.
  /// Omits `id` for a fresh, not-yet-saved layout (client-generated
  /// millisecond ids aren't valid uuids) so Postgres can generate one.
  Map<String, dynamic> toSupabaseRow(String userId) {
    final looksLikeUuid = RegExp(
            r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
        .hasMatch(id);
    return {
      if (looksLikeUuid) 'id': id,
      'user_id': userId,
      'name': name,
      'columns': columns,
      'rows': rows,
      'slot_camera_ids': slotCameraIds,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
  }

  static const List<_PresetSize> presetSizes = [
    _PresetSize(2, 2, '2x2'),
    _PresetSize(3, 3, '3x3'),
    _PresetSize(4, 4, '4x4'),
  ];
}

class _PresetSize {
  final int columns;
  final int rows;
  final String label;
  const _PresetSize(this.columns, this.rows, this.label);
}

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

class CctvLiveScreen extends StatefulWidget {
  final bool isActive;
  final List<CctvCamera> cameras;
  final CameraLayoutScheme? initialLayout;

  const CctvLiveScreen({
    super.key,
    required this.isActive,
    required this.cameras,
    this.initialLayout,
  });

  static Widget fromSupabase({
    required bool isActive,
    CameraLayoutScheme? initialLayout,
  }) {
    return _CctvLiveScreenSupabaseBridge(
      isActive: isActive,
      initialLayout: initialLayout,
    );
  }

  @override
  State<CctvLiveScreen> createState() => _CctvLiveScreenState();
}

class _CctvLiveScreenSupabaseBridge extends StatelessWidget {
  final bool isActive;
  final CameraLayoutScheme? initialLayout;
  const _CctvLiveScreenSupabaseBridge({
    required this.isActive,
    this.initialLayout,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: Supabase.instance.client
          .from('cameras')
          .stream(primaryKey: ['id'])
          .order('created_at', ascending: false),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: Colors.white70),
          );
        }
        if (snapshot.hasError) {
          return Center(
            child: Text(
              'Error loading cameras: ${snapshot.error}',
              style: const TextStyle(color: Colors.white70),
            ),
          );
        }
        final cameras = snapshot.hasData
            ? CctvCamera.listFromMaps(snapshot.data!)
            : const <CctvCamera>[];
        return CctvLiveScreen(
          isActive: isActive,
          cameras: cameras,
          initialLayout: initialLayout,
        );
      },
    );
  }
}

class _CameraFeed {
  final CctvCamera camera;
  final Player player;
  final VideoController controller;
  bool hasError = false;
  String? errorMessage;
  bool isBuffering = true;
  bool isSubStream = false;

  /// Cameras start muted (matches the IVMS4200 convention of a silent
  /// grid) — tap a tile once to reveal the speaker toggle and unmute it.
  bool isMuted = true;

  /// Whether this feed is currently being saved to a local file.
  bool isRecording = false;
  String? recordingPath;
  Process? _recordingProcess;

  DateTime lastActivityAt = DateTime.now();
  bool isAutoRecoverable = false;
  DateTime? disconnectedAt;
  DateTime? recoveryCandidateSince;

  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<String>? _errorSub;
  StreamSubscription<bool>? _bufferingSub;

  _CameraFeed._(this.camera, this.player, this.controller);

  factory _CameraFeed(CctvCamera camera) {
    final player = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 2 * 1024 * 1024,
      ),
    );

    if (player.platform is libmpvPlayer) {
      final mpv = player.platform as libmpvPlayer;

    // Removed: profile=low-latency and video-sync=display-resample.
    mpv.setProperty('cache', 'yes');
    mpv.setProperty('demuxer-max-bytes', '16777216');        // 16 MB
    mpv.setProperty('demuxer-readahead-secs', '1');
    mpv.setProperty('demuxer-lavf-o', 'rtsp_transport=tcp'); // force TCP
    mpv.setProperty('demuxer-lavf-analyzeduration', '1');
    mpv.setProperty('demuxer-lavf-probesize', '2000000');
    mpv.setProperty('framedrop', 'no');
    mpv.setProperty('hwdec', 'auto-safe');  // if still smeared, test with 'no'
    mpv.setProperty('network-timeout', '8');
    }

    // Start silent so opening several tiles at once doesn't blast audio
    // from every camera simultaneously.
    player.setVolume(0);

    final controller = VideoController(player);
    return _CameraFeed._(camera, player, controller);
  }

  Future<void> toggleMute() async {
    isMuted = !isMuted;
    await player.setVolume(isMuted ? 0 : 100);
  }

  /// Starts saving the live stream to [filePath] on local disk.
  ///
  /// This spawns a separate `ffmpeg` process that pulls the RTSP feed
  /// independently of playback and does a clean stream-copy (no
  /// re-encoding, so it's cheap on CPU) into a proper container. This is
  /// deliberately NOT done via mpv's `stream-record` property — that dumps
  /// the raw, undemuxed byte stream, which for RTSP/RTP sources frequently
  /// produces a file that "exists" but isn't actually playable.
  ///
  /// Uses a copy of ffmpeg bundled with the app if one was packaged in
  /// (see `_resolveBundledFfmpeg`), so recording works on a fresh machine
  /// without a separate install. Falls back to `ffmpeg` on PATH if no
  /// bundled copy is found.
  Future<bool> startRecording(String filePath) async {
    try {
      final ffmpegPath = await _resolveBundledFfmpeg() ?? 'ffmpeg';
      final process = await Process.start(
        ffmpegPath,
        [
          '-y',
          '-rtsp_transport', 'tcp',
          '-i', camera.rtspUrl,
          '-c', 'copy',
          filePath,
        ],
        runInShell: true,
      );
      _recordingProcess = process;
      isRecording = true;
      recordingPath = filePath;

      // Surface ffmpeg's own diagnostics in the debug console — useful if
      // the source codec can't be stream-copied into this container, the
      // camera drops the connection, etc.
      process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((line) => debugPrint('[ffmpeg:${camera.name}] $line'));

      unawaited(process.exitCode.then((code) {
        if (code != 0) {
          debugPrint(
              'ffmpeg recording for ${camera.name} exited with code $code');
        }
        if (identical(_recordingProcess, process)) {
          _recordingProcess = null;
          isRecording = false;
        }
      }));

      return true;
    } on ProcessException catch (e) {
      debugPrint(
          'Failed to start recording for ${camera.name}: ffmpeg not found ($e)');
      return false;
    } catch (e) {
      debugPrint('Failed to start recording for ${camera.name}: $e');
      return false;
    }
  }

  Future<void> stopRecording() async {
    isRecording = false;
    final process = _recordingProcess;
    _recordingProcess = null;
    if (process == null) return;
    try {
      // Ask ffmpeg to shut down cleanly (flushes the container's index/
      // trailer) instead of killing it outright, which can leave a
      // corrupt, unplayable file.
      process.stdin.writeln('q');
      await process.stdin.flush();
      await process.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          process.kill();
          return -1;
        },
      );
    } catch (e) {
      debugPrint('Failed to stop recording for ${camera.name}: $e');
      process.kill();
    }
  }

  Future<void> dispose() async {
    if (isRecording) {
      try {
        await stopRecording();
      } catch (_) {}
    }
    await _positionSub?.cancel();
    await _errorSub?.cancel();
    await _bufferingSub?.cancel();
    await player.dispose();
  }
}

class _CctvLiveScreenState extends State<CctvLiveScreen> {
  final Map<String, _CameraFeed> _feeds = {};
  final List<CameraLayoutScheme> _customLayouts = [];
  late CameraLayoutScheme _currentLayout;

  String? _zoomedCameraId;
  bool _sidePanelOpen = false;
  bool _layoutsLoaded = false;

  // --- Sidebar layout editor state (replaces the old bottom sheet) ---
  CameraLayoutScheme? _draft; // non-null = sidebar editor is active
  int? _selectedSlot;
  final TextEditingController _draftNameController = TextEditingController();

  bool get _isEditing => _draft != null;

  /// What the video wall should be showing right now: the draft while
  /// editing, otherwise the applied layout.
  CameraLayoutScheme get _visibleLayout => _draft ?? _currentLayout;

  final ValueNotifier<int> _feedsVersion = ValueNotifier(0);
  Timer? _watchdogTimer;

  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  static const double _sidePanelWidth = 240;
  static const Duration _stallThreshold = Duration(seconds: 10);
  static const Duration _watchdogInterval = Duration(seconds: 3);
  static const Duration _reconnectCooldown = Duration(seconds: 8);
  static const Duration _recoverySustainDuration = Duration(milliseconds: 1200);

  Map<String, CctvCamera> get _camerasById =>
      {for (final c in widget.cameras) c.id: c};

  List<CctvCamera> get _filteredCameras {
    if (_searchQuery.trim().isEmpty) return widget.cameras;
    final q = _searchQuery.trim().toLowerCase();
    return widget.cameras.where((c) {
      return c.name.toLowerCase().contains(q) ||
          c.ip.toLowerCase().contains(q) ||
          (c.location ?? '').toLowerCase().contains(q);
    }).toList();
  }

  int get _onlineCount =>
      widget.cameras.where((c) => _statusOf(_feeds[c.id]) == _FeedStatus.live).length;

  @override
  void initState() {
    super.initState();
    _currentLayout = widget.initialLayout ??
        CameraLayoutScheme.autoFill(
          columns: 2,
          rows: 2,
          cameras: widget.cameras,
          label: '2x2',
        );
    _loadLayoutsFromSupabase();
    _syncFeedsToLayout();

    _watchdogTimer = Timer.periodic(_watchdogInterval, (_) => _checkStalledFeeds());
    _searchController.addListener(() {
      setState(() => _searchQuery = _searchController.text);
    });

    // Keep the app-wide alert watcher (sound + notification bell) fed with
    // up-to-date camera names, and make sure it's running. This is a
    // singleton so it keeps listening even if this screen is later
    // unmounted (e.g. user switches tabs) — alerts still make sound/appear
    // in the top-bar notification tab.
    AlertWatcher.instance
      ..updateCameraNames({for (final c in widget.cameras) c.id: c.name})
      ..start();
  }

  @override
  void didUpdateWidget(covariant CctvLiveScreen oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (!_sameCameraList(oldWidget.cameras, widget.cameras)) {
      _syncFeedsToLayout();
      AlertWatcher.instance
          .updateCameraNames({for (final c in widget.cameras) c.id: c.name});
    }
  }

  bool _sameCameraList(List<CctvCamera> a, List<CctvCamera> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id || a[i].rtspUrl != b[i].rtspUrl) return false;
    }
    return true;
  }

  void _checkStalledFeeds() {
    if (!mounted) return;
    final now = DateTime.now();
    for (final feed in _feeds.values.toList()) {
      if (feed.hasError) {
        if (feed.isAutoRecoverable &&
            feed.disconnectedAt != null &&
            now.difference(feed.disconnectedAt!) > _reconnectCooldown) {
          _retryFeed(feed.camera);
        }
        continue;
      }
      final stalled = now.difference(feed.lastActivityAt) > _stallThreshold;
      if (stalled) {
        setState(() {
          feed.hasError = true;
          feed.isAutoRecoverable = true;
          feed.disconnectedAt = now;
          feed.isBuffering = false;
          feed.errorMessage = 'Camera disconnected';
          feed.recoveryCandidateSince = null;
        });
        _feedsVersion.value++;
      }
    }
  }

  // --- LAYOUT PERSISTENCE (dedicated `camera_layouts` table) ---

  Future<void> _loadLayoutsFromSupabase() async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) {
      _layoutsLoaded = true;
      return;
    }
    try {
      final response = await Supabase.instance.client
          .from('camera_layouts')
          .select()
          .eq('user_id', uid)
          .order('created_at', ascending: true);

      final loaded = (response as List)
          .map((row) => CameraLayoutScheme.fromSupabaseRow(
              Map<String, dynamic>.from(row)))
          .toList();

      if (!mounted) return;
      setState(() {
        _customLayouts
          ..clear()
          ..addAll(loaded);
      });
    } catch (e) {
      debugPrint('Failed to load camera layouts: $e');
    } finally {
      _layoutsLoaded = true;
    }
  }

  /// Inserts a new layout or updates an existing one, returning the
  /// server-resolved row (with a real uuid if this was a new layout).
  Future<CameraLayoutScheme?> _upsertLayoutRemote(
      CameraLayoutScheme layout) async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return null;
    try {
      final row = layout.toSupabaseRow(uid);
      final response = await Supabase.instance.client
          .from('camera_layouts')
          .upsert(row)
          .select()
          .single();
      return CameraLayoutScheme.fromSupabaseRow(
          Map<String, dynamic>.from(response));
    } catch (e) {
      debugPrint('Failed to save camera layout: $e');
      return null;
    }
  }

  Future<void> _deleteLayoutRemote(CameraLayoutScheme layout) async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return;
    try {
      await Supabase.instance.client
          .from('camera_layouts')
          .delete()
          .eq('id', layout.id)
          .eq('user_id', uid);
    } catch (e) {
      debugPrint('Failed to delete camera layout: $e');
    }
  }

  void _syncFeedsToLayout() {
    final layout = _visibleLayout;
    final neededIds = layout.slotCameraIds.whereType<String>().toSet();
    final wantSub = layout.slotCount > 1;

    for (final id in _feeds.keys.toList()) {
      final feed = _feeds[id]!;
      if (!neededIds.contains(id) || feed.isSubStream != wantSub) {
        _feeds.remove(id)?.dispose();
      }
    }

    for (final id in neededIds) {
      if (_feeds.containsKey(id)) continue;
      final camera = _camerasById[id];
      if (camera != null) _openFeed(camera);
    }

    if (mounted) setState(() {});
    _feedsVersion.value++;
  }

  void _openFeed(CctvCamera camera, {bool startDisconnected = false}) {
    _ensureMediaKitReady();
    final useSub = _visibleLayout.slotCount > 1;

    if (camera.rtspUrl.isEmpty || camera.ip.isEmpty) {
      final feed = _CameraFeed(camera)
        ..isSubStream = useSub   
        ..hasError = true
        ..isBuffering = false
        ..errorMessage = 'No stream URL saved for this camera yet.';
      _feeds[camera.id] = feed;
      return;
    }

    final feed = _CameraFeed(camera)..isSubStream = useSub;
    if (startDisconnected) {
      feed.hasError = true;
      feed.isAutoRecoverable = true;
      feed.disconnectedAt = DateTime.now();
      feed.isBuffering = false;
      feed.errorMessage = 'Camera disconnected';
    }
    _feeds[camera.id] = feed;

    feed._errorSub = feed.player.stream.error.listen((error) {
      if (!mounted) return;
      setState(() {
        feed.hasError = true;
        feed.isAutoRecoverable = true;
        feed.disconnectedAt = DateTime.now();
        feed.isBuffering = false;
        feed.errorMessage = error;
        feed.recoveryCandidateSince = null;
      });
      _feedsVersion.value++;
    });

    feed._bufferingSub = feed.player.stream.buffering.listen((buffering) {
      if (!mounted) return;
      if (feed.hasError) return;
      if (feed.isBuffering == buffering) return;
      setState(() => feed.isBuffering = buffering);
      _feedsVersion.value++;
    });

    feed._positionSub = feed.player.stream.position.listen((_) {
      final now = DateTime.now();
      feed.lastActivityAt = now;

      if (!feed.hasError) {
        feed.recoveryCandidateSince = null;
        return;
      }

      feed.recoveryCandidateSince ??= now;
      final sustained = now.difference(feed.recoveryCandidateSince!) >=
          _recoverySustainDuration;

      if (sustained && mounted) {
        setState(() {
          feed.hasError = false;
          feed.isAutoRecoverable = false;
          feed.disconnectedAt = null;
          feed.errorMessage = null;
          feed.recoveryCandidateSince = null;
        });
        _feedsVersion.value++;
      }
    });

    try {
      feed.player.open(Media(useSub ? camera.gridRtspUrl : camera.rtspUrl));
    } catch (e) {
      feed.hasError = true;
      feed.errorMessage = e.toString();
    }
  }

  void _retryFeed(CctvCamera camera) {
    _feeds.remove(camera.id)?.dispose();
    setState(() {
      _openFeed(camera, startDisconnected: true);
    });
    _feedsVersion.value++;
  }

  /// Retries every feed currently in an error state — surfaced in the
  /// navigator header as a single reconnect action.
  void _retryAllErrored() {
    final errored = _feeds.values.where((f) => f.hasError).map((f) => f.camera).toList();
    for (final camera in errored) {
      _retryFeed(camera);
    }
  }

  void _applyLayout(CameraLayoutScheme layout) {
    setState(() {
      _zoomedCameraId = null;
      _currentLayout = layout;
    });
    _syncFeedsToLayout();
  }

  /// Opens a single camera by itself, without needing a saved layout.
  /// This builds a throwaway 1x1 scheme (isPreset: true) so it's never
  /// written to `camera_layouts` — it just becomes the current view.
  void _viewSingleCamera(CctvCamera camera) {
    _applyLayout(
      CameraLayoutScheme(
        id: 'single_${camera.id}',
        name: camera.name,
        columns: 1,
        rows: 1,
        slotCameraIds: [camera.id],
        isPreset: true,
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Sidebar layout editor (iVMS-style: edit in the tree, no bottom sheet)
  // ---------------------------------------------------------------------

  int? _firstEmptySlot(CameraLayoutScheme l) {
    final i = l.slotCameraIds.indexWhere((e) => e == null);
    return i < 0 ? null : i;
  }

  void _beginEdit(CameraLayoutScheme draft) {
    setState(() {
      _zoomedCameraId = null;
      _draft = draft;
      _selectedSlot = _firstEmptySlot(draft);
      _draftNameController.text = draft.name;
      _sidePanelOpen = true;
    });
    _syncFeedsToLayout();
  }

  void _startNewLayout() => _beginEdit(CameraLayoutScheme(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: '',
        columns: 2,
        rows: 2,
        slotCameraIds: List<String?>.filled(4, null),
      ));

  void _startEditLayout(CameraLayoutScheme layout) =>
      _beginEdit(layout.copyWith());

  void _cancelEdit() {
    setState(() {
      _draft = null;
      _selectedSlot = null;
    });
    _syncFeedsToLayout();
  }

  void _setDraftSize(int columns, int rows) {
    final d = _draft;
    if (d == null) return;
    final resized = List<String?>.filled(columns * rows, null);
    for (var i = 0; i < d.slotCameraIds.length && i < resized.length; i++) {
      resized[i] = d.slotCameraIds[i];
    }
    setState(() {
      _draft = d.copyWith(columns: columns, rows: rows, slotCameraIds: resized);
      if (_selectedSlot != null && _selectedSlot! >= resized.length) {
        _selectedSlot = null;
      }
    });
    _syncFeedsToLayout();
  }

  void _assignToSlot(int index, String cameraId) {
    final d = _draft;
    if (d == null) return;
    setState(() {
      final slots = d.slotCameraIds;
      for (var i = 0; i < slots.length; i++) {
        if (slots[i] == cameraId) slots[i] = null; // a camera lives in one slot
      }
      slots[index] = cameraId;
      _selectedSlot = _firstEmptySlot(d);
    });
    _syncFeedsToLayout();
  }

  /// Tap a camera in the tree: fills the selected slot, else the first empty one.
  void _assignFromTree(String cameraId) {
    final d = _draft;
    if (d == null) return;
    final target = _selectedSlot ?? _firstEmptySlot(d);
    if (target == null) return; // grid is full
    _assignToSlot(target, cameraId);
  }

  void _clearSlot(int index) {
    final d = _draft;
    if (d == null) return;
    setState(() {
      d.slotCameraIds[index] = null;
      _selectedSlot = index;
    });
    _syncFeedsToLayout();
  }

  Future<void> _saveDraft() async {
    final d = _draft;
    if (d == null) return;
    final name = _draftNameController.text.trim();
    final result =
        d.copyWith(name: name.isEmpty ? '${d.columns} x ${d.rows}' : name);

    final saved = await _upsertLayoutRemote(result);
    final finalLayout = saved ?? result;
    if (!mounted) return;

    setState(() {
      final idx = _customLayouts.indexWhere((l) => l.id == result.id);
      if (idx >= 0) {
        _customLayouts[idx] = finalLayout;
      } else {
        _customLayouts.add(finalLayout);
      }
      _draft = null;
      _selectedSlot = null;
    });
    _applyLayout(finalLayout);
  }

  Future<void> _confirmDeleteLayout(CameraLayoutScheme layout) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete layout?'),
        content: Text('"${layout.name}" will be removed.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _customLayouts.removeWhere((l) => l.id == layout.id));
    await _deleteLayoutRemote(layout);
  }

  /// Opens the auxiliary window (a second process running its own instance
  /// of this same live screen, wired to the same Supabase project) as a
  /// floating window — no picker sheet, no extra tap. Drag it to another
  /// monitor yourself afterward, same as iVMS's floating-window option.
  ///
  /// The aux window is NOT tied to this window's current layout — it opens
  /// the full CctvLiveScreen (sidebar, search, layout editor, all saved
  /// layouts) so the person using it can pick whatever layout they want,
  /// independently, and it stays live via its own Supabase stream.
  Future<void> _openAuxWindow() {
    return openAuxWindow(
      supabaseUrl: SupabaseConstants.url,
      supabaseAnonKey: SupabaseConstants.anonKey,
      currentLayout: _currentLayout,
    );
  }

  void _toggleZoom(String cameraId) {
    setState(() {
      _zoomedCameraId = _zoomedCameraId == cameraId ? null : cameraId;
    });
  }

  Future<void> _openLayoutFullscreen() async {
    final returnedZoomId = await Navigator.of(context).push<String?>(
      _instantRoute(
        (_) => _LayoutFullscreenPage(
          layout: _currentLayout,
          camerasById: _camerasById,
          feeds: _feeds,
          feedsVersion: _feedsVersion,
          initialZoomedCameraId: _zoomedCameraId,
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _zoomedCameraId = returnedZoomId);
  }

  @override
  void dispose() {
    _watchdogTimer?.cancel();
    _feedsVersion.dispose();
    _searchController.dispose();
    _draftNameController.dispose();
    for (final feed in _feeds.values) {
      feed.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.cameras.isEmpty) {
      // Kept as the original fixed dark "monitor with no signal" look on
      // purpose — this is the video wall with nothing plugged in, so it
      // stays black in both light and dark app themes, exactly like it
      // did before this screen picked up theme support.
      return const ColoredBox(
        color: Colors.black,
        child: Center(
          child: Text(
            'No cameras configured yet.',
            style: TextStyle(color: Colors.white70, fontSize: 16),
          ),
        ),
      );
    }

    // The video wall itself (grid background, tiles, overlay controls)
    // stays black regardless of app theme. The tree panel now lives on the
    // LEFT, like a file explorer sidebar, with a matching toggle tab.
    return Container(
      color: Colors.black,
      child: Stack(
        children: [
          Positioned.fill(
            child: _isEditing
                ? _buildEditGrid()
                : (_zoomedCameraId != null ? _buildZoomedView() : _buildGrid()),
          ),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            top: 0,
            bottom: 0,
            left: _sidePanelOpen ? 0 : -_sidePanelWidth,
            width: _sidePanelWidth,
            child: _buildSidePanel(),
          ),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            top: 0,
            bottom: 0,
            left: _sidePanelOpen ? _sidePanelWidth : 0,
            child: Center(child: _buildToggleTab()),
          ),
          if (!_isEditing && !_sidePanelOpen)
            Positioned(
              bottom: 12,
              right: 12,
              child: SafeArea(
                child: _RoundIconButton(
                  icon: Icons.fullscreen,
                  onTap: _openLayoutFullscreen,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildToggleTab() {
    // Small alert dot on the collapsed tab so an offline camera is still
    // noticeable with the tree closed.
    return ValueListenableBuilder<int>(
      valueListenable: _feedsVersion,
      builder: (context, _, __) {
        final anyErrored = _feeds.values.any((f) => f.hasError);
        return _SidePanelToggleTab(
          isOpen: _sidePanelOpen,
          anyErrored: anyErrored,
          onTap: () => setState(() => _sidePanelOpen = !_sidePanelOpen),
        );
      },
    );
  }

  /// The tree panel itself — kept deliberately plain: a title row, a
  /// simple search box, then flat, indented tree sections, like a file
  /// explorer's sidebar. In edit mode the "Layouts" folder is replaced by
  /// the layout editor (name + grid size) and the camera tree becomes the
  /// drag source for the slots on the wall.
  Widget _buildSidePanel() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card(context),
        border: Border(right: BorderSide(color: AppColors.border(context))),
      ),
      // Material(transparency) sits between this decorated Container and
      // the ExpansionTile headers below (which use ListTile internally).
      // Without it, this Container's opaque background paints over the
      // ListTile's ink splashes — that's the "background color or ink
      // splashes may be invisible" assertion. Transparency type means it
      // adds no visual fill of its own, just a proper ink-painting surface.
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 16, 12, 10),
              child: _buildNavigatorHeader(),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: _buildSearchField(),
            ),
            Divider(height: 1, color: AppColors.border(context)),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 4),
                children: _isEditing
                    ? [_buildEditorSection(), _buildCamerasSection()]
                    : [_buildLayoutsSection(), _buildCamerasSection()],
              ),
            ),
            Divider(height: 1, color: AppColors.border(context)),
            Padding(
              padding: const EdgeInsets.all(10),
              child: _isEditing
                  ? Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _cancelEdit,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppColors.textMain(context),
                              side: BorderSide(color: AppColors.border(context)),
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(6)),
                            ),
                            child: const Text('Cancel',
                                style: TextStyle(
                                    fontWeight: FontWeight.w600, fontSize: 12)),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: _saveDraft,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.accentBlue,
                              foregroundColor: Colors.white,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(6)),
                            ),
                            child: const Text('Save & Apply',
                                style: TextStyle(
                                    fontWeight: FontWeight.w600, fontSize: 12)),
                          ),
                        ),
                      ],
                    )
                  : Column(
                      children: [
                        if (_isDesktopPlatform && !_isAuxWindow) ...[
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: _openAuxWindow,
                              icon: const Icon(Icons.open_in_new, size: 15),
                              label: const Text('Open Aux Window',
                                  style: TextStyle(
                                      fontWeight: FontWeight.w600, fontSize: 12)),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.textMain(context),
                                side: BorderSide(color: AppColors.border(context)),
                                padding: const EdgeInsets.symmetric(vertical: 10),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(6)),
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                        ],
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: _startNewLayout,
                            icon: const Icon(Icons.add, size: 15),
                            label: const Text('New Layout',
                                style: TextStyle(
                                    fontWeight: FontWeight.w600, fontSize: 12)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.accentBlue,
                              foregroundColor: Colors.white,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(6)),
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// Plain title row with a reconnect icon — no pill/badge chrome, just
  /// text, matching a file-explorer header.
  Widget _buildNavigatorHeader() {
    return ValueListenableBuilder<int>(
      valueListenable: _feedsVersion,
      builder: (context, _, __) {
        final anyErrored = _feeds.values.any((f) => f.hasError);

        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                _isEditing ? 'EDIT LAYOUT' : 'CAMERAS',
                style: TextStyle(
                  color: AppColors.textMain(context),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                ),
              ),
            ),
            if (anyErrored)
              Tooltip(
                message: 'Reconnect all offline cameras',
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: _retryAllErrored,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(Icons.refresh_rounded,
                        size: 16, color: AppColors.textMuted(context)),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildSearchField() {
    return Container(
      height: 30,
      decoration: BoxDecoration(
        color: AppColors.sunken(context),
        borderRadius: BorderRadius.circular(6),
      ),
      child: TextField(
        controller: _searchController,
        style: TextStyle(color: AppColors.textMain(context), fontSize: 12),
        textAlignVertical: TextAlignVertical.center,
        decoration: InputDecoration(
          isDense: true,
          isCollapsed: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
          border: InputBorder.none,
          prefixIcon: Icon(Icons.search, size: 15, color: AppColors.textMuted(context)),
          prefixIconConstraints: const BoxConstraints(minWidth: 30, minHeight: 30),
          hintText: 'Search…',
          hintStyle: TextStyle(color: AppColors.textMuted(context), fontSize: 12),
          suffixIcon: _searchQuery.isEmpty
              ? null
              : InkWell(
                  onTap: () => _searchController.clear(),
                  child: Icon(Icons.close, size: 14, color: AppColors.textMuted(context)),
                ),
          suffixIconConstraints: const BoxConstraints(minWidth: 26, minHeight: 26),
        ),
      ),
    );
  }

  /// A bare tree folder: chevron + label (+ count), children indented
  /// underneath. No card, no border, no background — just like a file
  /// explorer's expandable folder row.
  Widget _treeFolder({
    required String title,
    required List<Widget> children,
    bool initiallyExpanded = true,
    String? countLabel,
  }) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        initiallyExpanded: initiallyExpanded,
        dense: true,
        tilePadding: const EdgeInsets.only(left: 8, right: 12),
        childrenPadding: EdgeInsets.zero,
        iconColor: AppColors.textMuted(context),
        collapsedIconColor: AppColors.textMuted(context),
        leading: Icon(
          initiallyExpanded ? Icons.folder_open_outlined : Icons.folder_outlined,
          size: 16,
          color: AppColors.textMuted(context),
        ),
        title: Row(
          children: [
            Text(
              title,
              style: TextStyle(
                color: AppColors.textMain(context),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (countLabel != null) ...[
              const SizedBox(width: 6),
              Text(
                countLabel,
                style: TextStyle(color: AppColors.textMuted(context), fontSize: 10.5),
              ),
            ],
          ],
        ),
        children: children,
      ),
    );
  }

  Widget _buildLayoutsSection() {
    final layouts = List<CameraLayoutScheme>.from(_customLayouts)
      ..sort((a, b) {
        final bySize = (a.columns * a.rows).compareTo(b.columns * b.rows);
        if (bySize != 0) return bySize;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

    return _treeFolder(
      title: 'Layouts',
      countLabel: layouts.isEmpty ? null : '${layouts.length}',
      children: layouts.isEmpty
          ? [
              Padding(
                padding: const EdgeInsets.fromLTRB(38, 0, 12, 10),
                child: Text(
                  'None saved yet — press New Layout below.',
                  style: TextStyle(color: AppColors.textMuted(context), fontSize: 11.5, height: 1.4),
                ),
              ),
            ]
          : [
              for (final layout in layouts)
                _NavRow(
                  label: layout.name,
                  icon: Icons.grid_view_rounded,
                  badge: '${layout.columns}\u00d7${layout.rows}',
                  selected: _currentLayout.id == layout.id,
                  onTap: () => _applyLayout(layout),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _RowAction(
                          icon: Icons.edit_outlined,
                          tooltip: 'Edit',
                          onTap: () => _startEditLayout(layout)),
                      _RowAction(
                          icon: Icons.delete_outline,
                          tooltip: 'Delete',
                          onTap: () => _confirmDeleteLayout(layout)),
                    ],
                  ),
                ),
            ],
    );
  }

  /// Sidebar editor shown in place of the "Layouts" folder while a layout
  /// is being created or edited: name field + grid size chips + hint.
  Widget _buildEditorSection() {
    final d = _draft!;
    final muted = TextStyle(
        color: AppColors.textMuted(context),
        fontSize: 10.5,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.6);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('LAYOUT NAME', style: muted),
          const SizedBox(height: 6),
          Container(
            height: 30,
            decoration: BoxDecoration(
              color: AppColors.sunken(context),
              borderRadius: BorderRadius.circular(6),
            ),
            child: TextField(
              controller: _draftNameController,
              style: TextStyle(color: AppColors.textMain(context), fontSize: 12),
              textAlignVertical: TextAlignVertical.center,
              decoration: InputDecoration(
                isDense: true,
                isCollapsed: true,
                border: InputBorder.none,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                hintText: '${d.columns} x ${d.rows}',
                hintStyle:
                    TextStyle(color: AppColors.textMuted(context), fontSize: 12),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text('GRID', style: muted),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final p in CameraLayoutScheme.presetSizes)
                ChoiceChip(
                  label: Text(p.label),
                  visualDensity: VisualDensity.compact,
                  selected: d.columns == p.columns && d.rows == p.rows,
                  onSelected: (_) => _setDraftSize(p.columns, p.rows),
                  backgroundColor: AppColors.sunken(context),
                  selectedColor: AppColors.accentBlue,
                  labelStyle: TextStyle(
                    color: (d.columns == p.columns && d.rows == p.rows)
                        ? Colors.white
                        : AppColors.textMuted(context),
                    fontWeight: FontWeight.w600,
                    fontSize: 11.5,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                    side: BorderSide(color: AppColors.border(context)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            _isDesktopPlatform
                ? 'Drag a camera onto a slot, or pick a slot and click a camera below.'
                : 'Pick a slot on the wall, then tap a camera below.',
            style: TextStyle(
                color: AppColors.textMuted(context), fontSize: 11, height: 1.4),
          ),
        ],
      ),
    );
  }

  /// A camera row in the tree. Normal mode: click to view it alone.
  /// Edit mode: click to assign it to a slot, or (desktop) drag it onto one.
  Widget _buildCameraRow(CctvCamera camera) {
    final status = _statusOf(_feeds[camera.id]);
    final d = _draft;

    if (d == null) {
      return _NavRow(
        label: camera.name,
        icon: Icons.videocam_outlined,
        statusColor: status.dotColor,
        statusLabel: status.label,
        selected: _currentLayout.id == 'single_${camera.id}',
        onTap: () => _viewSingleCamera(camera),
      );
    }

    final slot = d.slotCameraIds.indexOf(camera.id);
    final row = _NavRow(
      label: camera.name,
      icon: Icons.videocam_outlined,
      statusColor: status.dotColor,
      selected: slot >= 0,
      badge: slot >= 0 ? '#${slot + 1}' : null,
      onTap: () => _assignFromTree(camera.id),
    );

    if (!_isDesktopPlatform) return row; // touch: tap-to-assign only

    return Draggable<String>(
      data: camera.id,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: AppColors.accentBlue,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.videocam, size: 14, color: Colors.white),
              const SizedBox(width: 6),
              Text(camera.name,
                  style: const TextStyle(color: Colors.white, fontSize: 12)),
            ],
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: row),
      child: row,
    );
  }

  Widget _buildCamerasSection() {
    final filtered = _filteredCameras;

    return ValueListenableBuilder<int>(
      valueListenable: _feedsVersion,
      builder: (context, _, __) {
        return _treeFolder(
          title: 'Cameras',
          countLabel: widget.cameras.isEmpty ? null : '${widget.cameras.length}',
          initiallyExpanded: true,
          children: widget.cameras.isEmpty
              ? [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(38, 0, 12, 10),
                    child: Text(
                      'No cameras configured yet.',
                      style: TextStyle(color: AppColors.textMuted(context), fontSize: 11.5),
                    ),
                  ),
                ]
              : filtered.isEmpty
                  ? [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(38, 0, 12, 10),
                        child: Text(
                          'No matches for "$_searchQuery".',
                          style: TextStyle(color: AppColors.textMuted(context), fontSize: 11.5),
                        ),
                      ),
                    ]
                  : [
                      for (final camera in filtered) _buildCameraRow(camera),
                    ],
        );
      },
    );
  }

  Widget _buildZoomedView() {
    final cameraId = _zoomedCameraId!;
    final camera = _camerasById[cameraId];
    final feed = _feeds[cameraId];
    if (camera == null) {
      return const Center(
        child: Text('Camera not found', style: TextStyle(color: Colors.white54)),
      );
    }
    return _CameraTile(
      camera: camera,
      feed: feed,
      onDoubleTap: () => _toggleZoom(cameraId),
    );
  }

  Widget _buildGrid() {
    final layout = _currentLayout;
    const spacing = 1.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final cellWidth =
            (constraints.maxWidth - (layout.columns - 1) * spacing) /
                layout.columns;
        final cellHeight =
            (constraints.maxHeight - (layout.rows - 1) * spacing) /
                layout.rows;
        final aspectRatio = cellWidth / cellHeight;

        return GridView.builder(
          padding: EdgeInsets.zero,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: layout.columns,
            crossAxisSpacing: spacing,
            mainAxisSpacing: spacing,
            childAspectRatio: aspectRatio,
          ),
          itemCount: layout.slotCount,
          itemBuilder: (context, index) {
            final cameraId = layout.slotCameraIds[index];
            final camera = cameraId != null ? _camerasById[cameraId] : null;

            if (camera == null) {
              return const _EmptySlotTile();
            }

            final feed = _feeds[camera.id];
            return _CameraTile(
              camera: camera,
              feed: feed,
              onDoubleTap: layout.slotCount > 1
                  ? () => _toggleZoom(camera.id)
                  : null,
            );
          },
        );
      },
    );
  }

  /// The video wall while editing: same grid as the draft layout, but each
  /// cell is an [_EditSlot] that accepts dropped cameras and can be selected.
  Widget _buildEditGrid() {
    final layout = _draft!;
    const spacing = 1.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final cellWidth =
            (constraints.maxWidth - (layout.columns - 1) * spacing) /
                layout.columns;
        final cellHeight =
            (constraints.maxHeight - (layout.rows - 1) * spacing) /
                layout.rows;

        return GridView.builder(
          padding: EdgeInsets.zero,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: layout.columns,
            crossAxisSpacing: spacing,
            mainAxisSpacing: spacing,
            childAspectRatio: cellWidth / cellHeight,
          ),
          itemCount: layout.slotCount,
          itemBuilder: (context, index) {
            final cameraId = layout.slotCameraIds[index];
            final camera = cameraId != null ? _camerasById[cameraId] : null;
            return _EditSlot(
              index: index,
              camera: camera,
              feed: camera != null ? _feeds[camera.id] : null,
              selected: _selectedSlot == index,
              onTap: () => setState(() => _selectedSlot = index),
              onClear: camera == null ? null : () => _clearSlot(index),
              onDropCamera: (id) => _assignToSlot(index, id),
            );
          },
        );
      },
    );
  }
}

/// A single tree row — icon, name, and either a size badge (layouts) or a
/// live status dot (cameras). Flat background, just a tint when selected
/// and a hover highlight; no borders or card chrome, like a row in a file
/// explorer's tree. [trailing] (e.g. edit/delete buttons) shows on hover
/// or when selected, and always on touch devices.
class _NavRow extends StatefulWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  final String? badge;
  final Color? statusColor;
  final String? statusLabel;
  final Widget? trailing;

  const _NavRow({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.badge,
    this.statusColor,
    this.statusLabel,
    this.trailing,
  });

  @override
  State<_NavRow> createState() => _NavRowState();
}

class _NavRowState extends State<_NavRow> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final bg = widget.selected
        ? AppColors.accentBlue.withOpacity(0.14)
        : (_hovering ? AppColors.sunken(context) : Colors.transparent);

    final row = MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: InkWell(
        onTap: widget.onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.only(left: 38, right: 12, top: 7, bottom: 7),
          color: bg,
          child: Row(
            children: [
              Icon(
                widget.icon,
                size: 15,
                color: widget.selected ? AppColors.accentBlue : AppColors.textMuted(context),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  widget.label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: widget.selected ? AppColors.accentBlue : AppColors.textMain(context),
                    fontSize: 12,
                    fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
              if (widget.statusColor != null) ...[
                const SizedBox(width: 6),
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(color: widget.statusColor, shape: BoxShape.circle),
                ),
              ],
              if (widget.trailing != null &&
                  (_hovering || widget.selected || !_isDesktopPlatform)) ...[
                const SizedBox(width: 4),
                widget.trailing!,
              ],
              if (widget.badge != null) ...[
                const SizedBox(width: 6),
                Text(
                  widget.badge!,
                  style: TextStyle(color: AppColors.textMuted(context), fontSize: 10),
                ),
              ],
            ],
          ),
        ),
      ),
    );

    if (widget.statusLabel == null) return row;
    return Tooltip(message: widget.statusLabel!, child: row);
  }
}

/// Small icon button used for per-row actions in the tree (edit / delete).
class _RowAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _RowAction(
      {required this.icon, required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Icon(icon, size: 14, color: AppColors.textMuted(context)),
        ),
      ),
    );
  }
}

/// One slot on the video wall while a layout is being edited: shows the
/// live feed (if assigned), accepts dragged cameras, and can be selected.
class _EditSlot extends StatelessWidget {
  final int index;
  final CctvCamera? camera;
  final _CameraFeed? feed;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onClear;
  final void Function(String cameraId) onDropCamera;

  const _EditSlot({
    required this.index,
    required this.camera,
    required this.feed,
    required this.selected,
    required this.onTap,
    required this.onClear,
    required this.onDropCamera,
  });

  @override
  Widget build(BuildContext context) {
    return DragTarget<String>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (details) => onDropCamera(details.data),
      builder: (context, candidates, _) {
        final hovering = candidates.isNotEmpty;
        final borderColor = hovering
            ? Colors.greenAccent
            : selected
                ? AppColors.accentBlue
                : Colors.white12;

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (camera != null && feed != null && !feed!.hasError)
                IgnorePointer(
                  child: Video(
                    controller: feed!.controller,
                    fit: BoxFit.fill,
                    controls: NoVideoControls,
                  ),
                )
              else
                const ColoredBox(color: Color(0xFF0D0D0D)),
              if (camera == null)
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.add, color: Colors.white38, size: 22),
                      const SizedBox(height: 4),
                      Text('Slot ${index + 1}',
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 11)),
                    ],
                  ),
                )
              else
                Positioned(
                  left: 6,
                  top: 4,
                  child: Text(
                    camera!.name,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 11,
                      shadows: [Shadow(blurRadius: 4, color: Colors.black)],
                    ),
                  ),
                ),
              Positioned(
                left: 6,
                bottom: 4,
                child: _StatusChip(
                  child: Text('${index + 1}',
                      style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 10,
                          fontWeight: FontWeight.w700)),
                ),
              ),
              if (onClear != null)
                Positioned(
                  right: 4,
                  top: 4,
                  child: _RoundIconButton(
                      icon: Icons.close, size: 14, onTap: onClear!),
                ),
              IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: borderColor,
                      width: (selected || hovering) ? 2 : 1,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The sidebar collapse/expand tab.
///
/// Positioned at the middle of the left edge (instead of pinned to the
/// top) so it never sits over a camera tile's name/details overlay, which
/// always render in the top-left corner of a tile. It also dims itself to
/// a low-opacity sliver when idle and brightens on hover, so even in its
/// new spot it stays out of the way of whatever's playing behind it until
/// someone actually reaches for it.
class _SidePanelToggleTab extends StatefulWidget {
  final bool isOpen;
  final bool anyErrored;
  final VoidCallback onTap;

  const _SidePanelToggleTab({
    required this.isOpen,
    required this.anyErrored,
    required this.onTap,
  });

  @override
  State<_SidePanelToggleTab> createState() => _SidePanelToggleTabState();
}

class _SidePanelToggleTabState extends State<_SidePanelToggleTab> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final dimmed = !widget.isOpen && !_hovering;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: dimmed ? 0.45 : 1.0,
        child: Material(
          color: AppColors.card(context),
          borderRadius: const BorderRadius.horizontal(right: Radius.circular(6)),
          child: InkWell(
            borderRadius: const BorderRadius.horizontal(right: Radius.circular(6)),
            onTap: widget.onTap,
            child: Container(
              constraints: const BoxConstraints(minHeight: 36), // keeps tap target comfortable
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 11),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: AppColors.border(context)),
                  right: BorderSide(color: AppColors.border(context)),
                  bottom: BorderSide(color: AppColors.border(context)),
                ),
              ),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(
                    widget.isOpen ? Icons.chevron_left : Icons.chevron_right,
                    color: AppColors.textMuted(context),
                    size: 15,
                  ),
                  if (!widget.isOpen && widget.anyErrored)
                    Positioned(
                      top: -3,
                      right: -2,
                      child: Container(
                        width: 6,
                        height: 6,
                        decoration: const BoxDecoration(
                          color: Color(0xFFFF3B30),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptySlotTile extends StatelessWidget {
  const _EmptySlotTile();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0D0D0D),
        border: Border.all(color: Colors.white12),
      ),
      child: const Center(
        child: Icon(Icons.videocam_outlined, color: Colors.white24, size: 22),
      ),
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final double size;

  const _RoundIconButton({
    required this.icon,
    required this.onTap,
    this.size = 18,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black45,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, color: Colors.white, size: size),
        ),
      ),
    );
  }
}

/// Compact icon button used inside the per-tile bottom toolbar — smaller
/// and flatter than [_RoundIconButton], sized to sit in a 26px-tall bar.
class _TileToolbarButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;
  final Color? iconColor;

  const _TileToolbarButton({
    required this.icon,
    required this.onTap,
    this.iconColor,
  });

  @override
  State<_TileToolbarButton> createState() => _TileToolbarButtonState();
}

class _TileToolbarButtonState extends State<_TileToolbarButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: _isHovered ? Colors.white.withOpacity(0.15) : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Icon(
            widget.icon,
            size: 15,
            color: widget.iconColor ?? Colors.white70,
          ),
        ),
      ),
    );
  }
}

/// Small dark-strip pill used to host a status icon/badge (recording,
/// unmuted, etc.) in a tile's top-right corner — same fill color as the
/// bottom toolbar so status indicators read as one consistent style.
class _StatusChip extends StatelessWidget {
  final Widget child;
  const _StatusChip({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xCC1B1D21),
        borderRadius: BorderRadius.circular(4),
      ),
      child: child,
    );
  }
}

/// Small pulsing-dot + "REC" label shown on a tile while it's being saved
/// locally, so recording status is visible even with the toolbar hidden.
class _RecBadge extends StatefulWidget {
  const _RecBadge();

  @override
  State<_RecBadge> createState() => _RecBadgeState();
}

class _RecBadgeState extends State<_RecBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FadeTransition(
          opacity: Tween<double>(begin: 1, end: 0.3).animate(_controller),
          child: const DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.redAccent,
              shape: BoxShape.circle,
            ),
            child: SizedBox(width: 7, height: 7),
          ),
        ),
        const SizedBox(width: 4),
        const Text(
          'REC',
          style: TextStyle(
            color: Colors.redAccent,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }
}

class _CameraTile extends StatefulWidget {
  final CctvCamera camera;
  final _CameraFeed? feed;
  final VoidCallback? onDoubleTap;
  final bool cursorHidden;

  const _CameraTile({
    required this.camera,
    required this.feed,
    this.onDoubleTap,
    this.cursorHidden = false,
  });

  @override
  State<_CameraTile> createState() => _CameraTileState();
}

class _CameraTileState extends State<_CameraTile> {
  bool _controlsVisible = false;

  void _handleEnter(PointerEvent details) {
    final feed = widget.feed;
    if (feed == null || feed.hasError) return;
    setState(() => _controlsVisible = true);
  }

  void _handleExit(PointerEvent details) {
    setState(() => _controlsVisible = false);
  }

  void _handleToggleMute() {
    final feed = widget.feed;
    if (feed == null) return;
    feed.toggleMute();
    setState(() {});
  }

  Future<void> _handleToggleRecord() async {
    final feed = widget.feed;
    if (feed == null || feed.hasError) return;

    if (!_isDesktopPlatform) {
      return;
    }

    if (feed.isRecording) {
      await feed.stopRecording();
    } else {
      final path = await _newRecordingFilePath(feed.camera);
      await feed.startRecording(path);
    }

    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final camera = widget.camera;
    final feed = widget.feed;
    final controlsVisible = _controlsVisible && !widget.cursorHidden;

    return MouseRegion(
      onEnter: _handleEnter,
      onExit: _handleExit,
      child: GestureDetector(
        onDoubleTap: widget.onDoubleTap,
        behavior: HitTestBehavior.opaque,
        child: Stack(
          fit: StackFit.expand,
          children: [

            if (feed != null && !feed.hasError)
              Video(
                controller: feed.controller,
                fit: BoxFit.fill,
                controls: NoVideoControls,
              )
            else
              const ColoredBox(color: Colors.black),

            _DetectionOverlay(cameraId: camera.id),
            _AlertBanner(cameraId: camera.id),

            Positioned(
              left: 6,
              top: 4,
              child: Text(
                camera.name,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 11,
                  shadows: [Shadow(blurRadius: 4, color: Colors.black)],
                ),
              ),
            ),

            // Persistent status badges — recording / unmuted — stacked in the
            // top-right as small dark-strip chips.
            if (feed != null && (feed.isRecording || !feed.isMuted))
              Positioned(
                right: 6,
                top: 4,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (feed.isRecording) const _StatusChip(child: _RecBadge()),
                    if (feed.isRecording && !feed.isMuted)
                      const SizedBox(height: 4),
                    if (!feed.isMuted)
                      const _StatusChip(
                        child: Icon(Icons.volume_up, size: 12, color: Colors.white),
                      ),
                  ],
                ),
              ),

            if (feed != null && !feed.hasError) ...[
              // Bottom toolbar bar — revealed on hover
              AnimatedOpacity(
                opacity: controlsVisible ? 1 : 0,
                duration: const Duration(milliseconds: 150),
                child: IgnorePointer(
                  ignoring: !controlsVisible,
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Container(
                      width: double.infinity,
                      height: 26,
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      color: const Color(0xCC1B1D21),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _TileToolbarButton(
                            icon: feed.isMuted ? Icons.volume_off : Icons.volume_up,
                            onTap: _handleToggleMute,
                          ),
                          Container(
                            width: 1,
                            height: 14,
                            margin: const EdgeInsets.symmetric(horizontal: 8),
                            color: Colors.white24,
                          ),
                          _TileToolbarButton(
                            icon: feed.isRecording
                                ? Icons.stop_circle_rounded
                                : Icons.fiber_manual_record,
                            iconColor:
                                feed.isRecording ? Colors.redAccent : Colors.white70,
                            onTap: _handleToggleRecord,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              // Blue selection border — shown while hovering over the tile
              AnimatedOpacity(
                opacity: controlsVisible ? 1 : 0,
                duration: const Duration(milliseconds: 150),
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.blueAccent, width: 1),
                    ),
                  ),
                ),
              ),
            ],

            if (!(feed?.hasError ?? false) && (feed?.isBuffering ?? true))
              const Center(
                child: SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
              ),

            if (feed?.hasError ?? false)
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.videocam_off,
                      color: Colors.redAccent.withOpacity(0.85),
                      size: 30,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'CAMERA DISCONNECTED',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    if (feed!.isAutoRecoverable)
                      const Text(
                        'Reconnecting…',
                        style: TextStyle(color: Colors.white38, fontSize: 11),
                      )
                    else if ((feed!.errorMessage ?? '').isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text(
                          feed!.errorMessage!,
                          maxLines: 2,
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white38, fontSize: 10),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Live YOLO person-detection overlay
// ---------------------------------------------------------------------------

class _DetectionOverlay extends StatelessWidget {
  final String cameraId;
  const _DetectionOverlay({required this.cameraId});

  static const Duration _staleness = Duration(seconds: 3);

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: Supabase.instance.client
          .from('camera_detections')
          .stream(primaryKey: ['camera_id'])
          .eq('camera_id', cameraId),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return const SizedBox.shrink();
        }
        final data = snapshot.data!.first;
        final rawBoxes = (data['detections'] as List?) ?? const [];
        final updatedAtStr = data['updated_at']?.toString();
        final updatedAt =
            updatedAtStr != null ? DateTime.tryParse(updatedAtStr)?.toLocal() : null;

        if (updatedAt == null || DateTime.now().difference(updatedAt) > _staleness) {
          return const SizedBox.shrink();
        }

        final boxes = rawBoxes
            .whereType<Map>()
            .map((b) => _DetectionBox(
                  x1: (b['x1'] as num).toDouble(),
                  y1: (b['y1'] as num).toDouble(),
                  x2: (b['x2'] as num).toDouble(),
                  y2: (b['y2'] as num).toDouble(),
                  conf: (b['conf'] as num).toDouble(),
                  cls: (b['cls'] as String?) ?? 'person',
                ))
            .toList();

        return IgnorePointer(
          child: CustomPaint(
            painter: _DetectionBoxPainter(boxes),
            size: Size.infinite,
          ),
        );
      },
    );
  }
}

class _DetectionBox {
  final double x1, y1, x2, y2, conf;
  final String cls;
  const _DetectionBox({
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
    required this.conf,
    required this.cls,
  });
}

class _DetectionBoxPainter extends CustomPainter {
  final List<_DetectionBox> boxes;
  _DetectionBoxPainter(this.boxes);

  static const Map<String, Color> _classColors = {
    'person': Color(0xFF00E676),
    'car': Color(0xFFFFC400),
  };

  static const Map<String, String> _classLabels = {
    'person': 'Person',
    'car': 'Car',
  };

  @override
  void paint(Canvas canvas, Size size) {
    for (final box in boxes) {
      final color = _classColors[box.cls] ?? Colors.grey;
      final displayLabel = _classLabels[box.cls] ?? box.cls;

      final boxPaint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;

      final rect = Rect.fromLTRB(
        box.x1 * size.width,
        box.y1 * size.height,
        box.x2 * size.width,
        box.y2 * size.height,
      );
      canvas.drawRect(rect, boxPaint);

      final label = '$displayLabel ${(box.conf * 100).toStringAsFixed(0)}%';
      final textPainter = TextPainter(
        text: TextSpan(
          text: label,
          style: const TextStyle(
            color: Colors.black,
            fontSize: 10,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      final labelTop = (rect.top - 14).clamp(0.0, size.height - 14);
      final labelBg = Rect.fromLTWH(
        rect.left,
        labelTop,
        textPainter.width + 6,
        14,
      );
      canvas.drawRect(labelBg, Paint()..color = color);
      textPainter.paint(canvas, Offset(labelBg.left + 3, labelBg.top + 1));
    }
  }

  @override
  bool shouldRepaint(covariant _DetectionBoxPainter oldDelegate) => true;
}

class _AlertBanner extends StatelessWidget {
  final String cameraId;
  const _AlertBanner({required this.cameraId});

  static const Duration _staleness = Duration(seconds: 3);

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: Supabase.instance.client
          .from('camera_detections')
          .stream(primaryKey: ['camera_id'])
          .eq('camera_id', cameraId),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return const SizedBox.shrink();
        }
        final data = snapshot.data!.first;
        final alertType = data['active_alert_type'] as String?;
        final updatedAtStr = data['updated_at']?.toString();
        final updatedAt =
            updatedAtStr != null ? DateTime.tryParse(updatedAtStr)?.toLocal() : null;

        if (alertType == null ||
            updatedAt == null ||
            DateTime.now().difference(updatedAt) > _staleness) {
          return const SizedBox.shrink();
        }

        final level = AlertLevel.fromString(data['active_alert_level'] as String?) ??
            AlertLevel.forAlertType(alertType);
        final color = level.color;

        return Stack(
          fit: StackFit.expand,
          children: [
            // Subtle border, no shadow/glow
            IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: color, width: 2),
                ),
              ),
            ),
            // Small label chip, bottom-right
            Positioned(
              right: 6,
              bottom: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  _shortLabel(alertType),
                  style: const TextStyle(
                    color: Colors.black87,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  String _shortLabel(String alertType) => switch (alertType) {
        'Accident' => 'POSSIBLE ACCIDENT',
        'Violence' => 'POSSIBLE VIOLENCE',
        'fire' => 'POSSIBLE FIRE',
        'curfew' => 'POSSIBLE CURFEW',
        'traffic' => 'POSSIBLE TRAFFIC',
        _ => alertType.toUpperCase(),
      };
}

// ---------------------------------------------------------------------------
// Dedicated fullscreen page
// ---------------------------------------------------------------------------

class _LayoutFullscreenPage extends StatefulWidget {
  final CameraLayoutScheme layout;
  final Map<String, CctvCamera> camerasById;
  final Map<String, _CameraFeed> feeds;
  final ValueNotifier<int> feedsVersion;
  final String? initialZoomedCameraId;

  const _LayoutFullscreenPage({
    required this.layout,
    required this.camerasById,
    required this.feeds,
    required this.feedsVersion,
    this.initialZoomedCameraId,
  });

  @override
  State<_LayoutFullscreenPage> createState() => _LayoutFullscreenPageState();
}

class _LayoutFullscreenPageState extends State<_LayoutFullscreenPage> {
  late String? _zoomedCameraId = widget.initialZoomedCameraId;

  Timer? _cursorHideTimer;
  bool _cursorVisible = true;
  static const Duration _cursorHideDelay = Duration(seconds: 3);

  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    if (_isDesktopPlatform) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        try {
          await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
          await windowManager.setFullScreen(true);
        } catch (e, st) {
          debugPrint('>>> fullscreen setup FAILED: $e\n$st');
        }
      });
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    _scheduleCursorHide();
  }

  void _handlePointerHover([PointerEvent? _]) {
    if (!_cursorVisible) {
      setState(() => _cursorVisible = true);
    }
    _scheduleCursorHide();
  }

  void _scheduleCursorHide() {
    _cursorHideTimer?.cancel();
    _cursorHideTimer = Timer(_cursorHideDelay, () {
      if (mounted) setState(() => _cursorVisible = false);
    });
  }

  @override
  void dispose() {
    _cursorHideTimer?.cancel();
    _focusNode.dispose();
    if (_isDesktopPlatform) {
      windowManager.setFullScreen(false);
      windowManager.setTitleBarStyle(TitleBarStyle.normal);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
    super.dispose();
  }

  void _toggleZoom(String cameraId) {
    setState(() {
      _zoomedCameraId = _zoomedCameraId == cameraId ? null : cameraId;
    });
  }

  void _pop() {
    Navigator.of(context).pop(_zoomedCameraId);
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      _pop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<String?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _pop();
      },
      child: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _handleKeyEvent,
        child: MouseRegion(
          cursor: _cursorVisible ? SystemMouseCursors.basic : SystemMouseCursors.none,
          onHover: _handlePointerHover,
          child: Scaffold(
            backgroundColor: Colors.black,
            body: ValueListenableBuilder<int>(
              valueListenable: widget.feedsVersion,
              builder: (context, _, __) {
                return _zoomedCameraId != null ? _buildZoomedView() : _buildGrid();
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildZoomedView() {
    final cameraId = _zoomedCameraId!;
    final camera = widget.camerasById[cameraId];
    final feed = widget.feeds[cameraId];
    if (camera == null) {
      return const Center(
        child: Text('Camera not found', style: TextStyle(color: Colors.white54)),
      );
    }
    return _CameraTile(
      camera: camera,
      feed: feed,
      onDoubleTap: () => _toggleZoom(cameraId),
      cursorHidden: !_cursorVisible,
    );
  }

  Widget _buildGrid() {
    final layout = widget.layout;
    const spacing = 1.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final cellWidth =
            (constraints.maxWidth - (layout.columns - 1) * spacing) /
                layout.columns;
        final cellHeight =
            (constraints.maxHeight - (layout.rows - 1) * spacing) /
                layout.rows;
        final aspectRatio = cellWidth / cellHeight;

        return GridView.builder(
          padding: EdgeInsets.zero,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: layout.columns,
            crossAxisSpacing: spacing,
            mainAxisSpacing: spacing,
            childAspectRatio: aspectRatio,
          ),
          itemCount: layout.slotCount,
          itemBuilder: (context, index) {
            final cameraId = layout.slotCameraIds[index];
            final camera =
                cameraId != null ? widget.camerasById[cameraId] : null;

            if (camera == null) {
              return const _EmptySlotTile();
            }

            final feed = widget.feeds[camera.id];
            return _CameraTile(
              camera: camera,
              feed: feed,
              onDoubleTap: layout.slotCount > 1
                  ? () => _toggleZoom(camera.id)
                  : null,
              cursorHidden: !_cursorVisible,
            );
          },
        );
      },
    );
  }
}

// =============================================================================
// AUXILIARY DISPLAY SUPPORT  (multi-monitor "pop-out" window, IVMS-style)
// =============================================================================
//
// The aux window is a separate PROCESS of this app (launched with
// `--aux <payload.json>`), so it does NOT share Dart heap state with the
// main window — no existing Supabase client, no existing media_kit init,
// no existing _CameraFeed objects.
//
// The aux window simply hosts the same `CctvLiveScreen.fromSupabase(...)`
// widget the main window uses. That means:
//   - Same sidebar, search, layout editor, layout picking, single-camera
//     view, recording, fullscreen — literally the same code path.
//   - Live updates for free: CctvLiveScreen streams `cameras` from
//     Supabase and loads `camera_layouts`, so new cameras/layouts saved in
//     the main window show up here without a re-launch.
//   - Its own independent RTSP connections/players (separate process), so
//     it doesn't share playback state with the main window — only the
//     Supabase data.
//
// All the aux process needs from the main window is which Supabase
// project to connect to, and where/how to place the window.

final List<Process> _auxProcesses = [];

void closeAllAuxWindows() {
  for (final p in _auxProcesses.toList()) {
    p.kill();
  }
  _auxProcesses.clear();
}

/// Opens ONE auxiliary window running its own full `CctvLiveScreen`
/// instance — sidebar, layout picking, everything — wired to the same
/// Supabase project as the main window. Pass [display] to also place it
/// fullscreen on that monitor; otherwise it opens as a normal floating
/// window you can drag wherever you like, same as iVMS's floating-window
/// option.
Future<void> openAuxWindow({
  Display? display,
  required String supabaseUrl,
  required String supabaseAnonKey,
  CameraLayoutScheme? currentLayout,
}) async {
  final origin = display?.visiblePosition ?? const Offset(0, 0);

  final payload = jsonEncode({
    'supabaseUrl': supabaseUrl,
    'supabaseAnonKey': supabaseAnonKey,
    'maximizeOnOpen': display != null,
    'originX': origin.dx,
    'originY': origin.dy,
    if (currentLayout != null) 'initialLayout': currentLayout.toMap(),
  });

  // Payload goes through a temp file (command lines have a length limit).
  final file = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'safewatch_aux_${DateTime.now().microsecondsSinceEpoch}.json');
  await file.writeAsString(payload);

  try {
    final process = await Process.start(
      Platform.resolvedExecutable,
      ['--aux', file.path],
    );
    _auxProcesses.add(process);

    // Drain output (prevents blocking) and show it for debugging.
    process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((s) => debugPrint('[aux] $s'));
    process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((s) => debugPrint('[aux:err] $s'));

    unawaited(process.exitCode.then((code) {
      debugPrint('Aux window exited with code $code');
      _auxProcesses.remove(process);
    }));
  } catch (e) {
    debugPrint('Failed to start auxiliary window: $e');
  }
}

/// Bottom sheet offering to open the window either as a plain floating
/// window (iVMS-style — you drag it wherever after, including a second
/// monitor if you have one) or, if extra monitors are detected, pinned
/// straight onto one of them. [onPicked] receives `null` for "just open it
/// here as a floating window".
Future<void> showDisplayPicker(
  BuildContext context, {
  required Future<void> Function(Display? display) onPicked,
}) async {
  List<Display> displays = const [];
  Display? primary;
  try {
    displays = await screenRetriever.getAllDisplays();
    primary = await screenRetriever.getPrimaryDisplay();
  } catch (e) {
    debugPrint('Could not list displays: $e');
    // Not fatal — we can still offer the plain floating-window option.
  }

  if (!context.mounted) return;

  final extraDisplays =
      displays.where((d) => primary == null || d.id != primary!.id).toList();

  final chosen = await showModalBottomSheet<_DisplayChoice>(
    context: context,
    backgroundColor: AppColors.card(context),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheetContext) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: AppColors.border(sheetContext),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'OPEN IN NEW WINDOW',
                  style: TextStyle(
                    color: AppColors.textMuted(sheetContext),
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  ListTile(
                    leading: Icon(Icons.open_in_new, color: AppColors.accentBlue),
                    title: Text(
                      'Floating window',
                      style: TextStyle(
                        color: AppColors.textMain(sheetContext),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      'Opens here — drag it to another monitor yourself, same as iVMS.',
                      style: TextStyle(color: AppColors.textMuted(sheetContext), fontSize: 12),
                    ),
                    onTap: () => Navigator.of(sheetContext).pop(const _DisplayChoice(null)),
                  ),
                  if (extraDisplays.isNotEmpty) ...[
                    Divider(color: AppColors.border(sheetContext), height: 1),
                    for (final d in extraDisplays)
                      ListTile(
                        leading: Icon(Icons.monitor, color: AppColors.accentBlue),
                        title: Text(
                          'Send to Display ${displays.indexOf(d) + 1}',
                          style: TextStyle(
                            color: AppColors.textMain(sheetContext),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          '${d.size.width.toInt()} x ${d.size.height.toInt()} — fills that screen',
                          style:
                              TextStyle(color: AppColors.textMuted(sheetContext), fontSize: 12),
                        ),
                        onTap: () => Navigator.of(sheetContext).pop(_DisplayChoice(d)),
                      ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );

  if (chosen != null) {
    await onPicked(chosen.display);
  }
}

class _DisplayChoice {
  final Display? display;
  const _DisplayChoice(this.display);
}

/// Entry widget for the auxiliary window. Same class name and `args` as
/// before, so the `--aux` entry point in main.dart doesn't need to change.
///
/// Once Supabase is initialized and media_kit is ready, the body is just
/// `CctvLiveScreen.fromSupabase(...)` — the exact same screen the main
/// window shows, so the person using this window can pick any saved layout
/// (or build a new one in the sidebar editor) independently of the main
/// window.
class AuxiliaryDisplayApp extends StatelessWidget {
  final Map<String, dynamic> args;
  const AuxiliaryDisplayApp({super.key, required this.args});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: themeController,
      builder: (context, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: themeController.mode,
          home: _AuxiliaryDisplayPage(args: args),
        );
      },
    );
  }
}

class _AuxiliaryDisplayPage extends StatefulWidget {
  final Map<String, dynamic> args;
  const _AuxiliaryDisplayPage({required this.args});

  @override
  State<_AuxiliaryDisplayPage> createState() => _AuxiliaryDisplayPageState();
}

class _AuxiliaryDisplayPageState extends State<_AuxiliaryDisplayPage>
    with WindowListener {
  bool _ready = false;
  bool _closing = false;
  String? _initError;
  CameraLayoutScheme? _initialLayout;

  @override
  void initState() {
    super.initState();
    _isAuxWindow = true;
    _setupWindow();
    _init();
  }

  Future<void> _setupWindow() async {
    try {
      windowManager.addListener(this);
      // Intercept the X button so we can unmount CctvLiveScreen (and let
      // its own dispose() tear down every player/subscription) before the
      // window/process actually goes away.
      await windowManager.setPreventClose(true);
      await windowManager.setTitle('CCTV — Auxiliary Display');

      if (widget.args['maximizeOnOpen'] == true) {
        final x = (widget.args['originX'] as num?)?.toDouble() ?? 0;
        final y = (widget.args['originY'] as num?)?.toDouble() ?? 0;
        await windowManager.setPosition(Offset(x, y));
        await Future.delayed(const Duration(milliseconds: 300));
        await windowManager.setFullScreen(true);
      } else {
        await windowManager.setSize(const Size(1100, 680));
        await windowManager.center();
      }
      await windowManager.show();
      await windowManager.focus();
    } catch (e) {
      debugPrint('Aux window setup failed: $e');
    }
  }

  Future<void> _init() async {
    try {
      final supabaseUrl = widget.args['supabaseUrl'] as String;
      final supabaseAnonKey = widget.args['supabaseAnonKey'] as String;

      await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);
      _ensureMediaKitReady();

      final rawLayout = widget.args['initialLayout'];
      if (rawLayout is Map) {
        _initialLayout =
            CameraLayoutScheme.fromMap(Map<String, dynamic>.from(rawLayout));
      }

      if (mounted) setState(() => _ready = true);
    } catch (e, st) {
      debugPrint('Aux init failed: $e\n$st');
      if (mounted) setState(() => _initError = e.toString());
    }
  }

  @override
  void onWindowClose() {
    _closeWindow();
  }

  /// Unmounts CctvLiveScreen first — its own dispose() stops every
  /// player/stream/timer it owns — before destroying the window/process.
  /// Mirrors the main window's normal Navigator-driven dispose, just
  /// triggered by the OS close button instead.
  Future<void> _closeWindow() async {
    if (_closing) return;
    _closing = true;
    if (mounted) setState(() {});
    // Give CctvLiveScreen's dispose() a moment to run and tear down its
    // players before the process is killed out from under it.
    await Future.delayed(const Duration(milliseconds: 200));

    try {
      windowManager.removeListener(this);
      await windowManager.setPreventClose(false);
    } catch (_) {}
    await windowManager.destroy();
  }

  @override
  void dispose() {
    try {
      windowManager.removeListener(this);
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_closing) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: SizedBox.shrink(),
      );
    }

    if (_initError != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Failed to start auxiliary display:\n$_initError',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
          ),
        ),
      );
    }

    if (!_ready) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Colors.white70)),
      );
    }

    // NOTE: this Scaffold is deliberately NOT const — fromSupabase() is a
    // static factory *method* (it wraps a StreamBuilder), not a const
    // constructor, so `const Scaffold(body: CctvLiveScreen.fromSupabase(...))`
    // fails to compile with "Methods can't be invoked in constant
    // expressions."
    return Scaffold(
      backgroundColor: Colors.black,
      body: CctvLiveScreen.fromSupabase(
        isActive: true,
        initialLayout: _initialLayout,
      ),
    );
  }
}