import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../constants/barangay_boundary.dart';
import '../../utils/activity_logger.dart';
import '../../widgets/app_toast.dart';
import '../../constants/app_colors.dart';
import '../../controllers/animated_map_controller.dart';

/// Dedicated screen for setting up and viewing where each DEVICE (CCTV
/// camera or PA speaker) physically is, on the same barangay-boundary map
/// used elsewhere in the app.
///
/// Reads/writes the `cameras` table and the `pa_speakers` table
/// (`latitude` / `longitude` columns on both).
///
/// Flow:
///  - The map takes the full width. A floating "Edit" button sits on top.
///  - Tapping "Edit" turns that button into "Finish" and reveals a floating
///    "+ Add Device Location" button next to it.
///  - "+ Add Device Location" opens a side panel listing ONLY devices (cameras
///    and PA speakers) that don't have a pin yet. A filter lets you show
///    All / Cameras / PA. Rows can be checked for bulk placement, or placed
///    immediately via the per-row pin button.
///  - Placing devices enters a placement queue: tap the map once per queued
///    device. Nothing is written to Supabase until "Finish" is tapped.
///  - While editing, every placed pin can be dragged (local only) and has a
///    delete (x) badge.
///  - Pins use the same teardrop marker as the User Location screen: name
///    label above, status-colored pin with the device icon, pulse when online.
class DeviceLocationScreen extends StatefulWidget {
  final bool isActive;

  const DeviceLocationScreen({super.key, this.isActive = true});

  @override
  State<DeviceLocationScreen> createState() => _DeviceLocationScreenState();
}

// ---------------------------------------------------------------------------
// Device model
// ---------------------------------------------------------------------------

enum _DeviceKind { camera, pa }

extension _DeviceKindX on _DeviceKind {
  String get table => this == _DeviceKind.camera ? 'cameras' : 'pa_speakers';
  String get label => this == _DeviceKind.camera ? 'Camera' : 'PA Speaker';
  IconData get icon =>
      this == _DeviceKind.camera ? Icons.videocam_outlined : Icons.campaign_outlined;
  Color get color =>
      this == _DeviceKind.camera ? const Color(0xFF2082E2) : const Color(0xFF14B8A6);
  String get logAction => this == _DeviceKind.camera ? 'UPDATE_CCTV' : 'UPDATE_PA';
}

class _DevicePin {
  final _DeviceKind kind;
  final Object rawId;
  final String name;
  final String location;
  final String status;
  final LatLng? position;

  const _DevicePin({
    required this.kind,
    required this.rawId,
    required this.name,
    required this.location,
    required this.status,
    required this.position,
  });

  /// Unique across both tables (a camera and a PA speaker can share an id).
  String get key => '${kind.name}:$rawId';

  bool get hasPin => position != null;

  static _DevicePin fromMap(Map<String, dynamic> data, _DeviceKind kind) {
    final lat = data['latitude'];
    final lng = data['longitude'];
    final position =
        (lat is num && lng is num) ? LatLng(lat.toDouble(), lng.toDouble()) : null;
    return _DevicePin(
      kind: kind,
      rawId: data['id'] as Object,
      name: (data['name'] ?? 'Unnamed ${kind.label}').toString(),
      location: (data['location'] ?? '').toString(),
      status: (data['status'] ?? 'Offline').toString(),
      position: position,
    );
  }
}

Color _statusColor(String status) =>
    status.toUpperCase() == 'ONLINE' ? AppColors.accentGreen : AppColors.accentRed;

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

class _DeviceLocationScreenState extends State<DeviceLocationScreen>
    with TickerProviderStateMixin {
  static const LatLng _fallbackCenter = LatLng(14.6837, 121.0766);
  static const List<LatLng> _maskOuterRing = [
    LatLng(-85, -180),
    LatLng(-85, 180),
    LatLng(85, 180),
    LatLng(85, -180),
  ];

  // --- Tile theming matrices (same as User Location screen) ---
  static const List<double> _lightSaturationMatrix = <double>[
    0.68504, 0.28608, 0.02888, 0, 0,
    0.08504, 0.88608, 0.02888, 0, 0,
    0.08504, 0.28608, 0.62888, 0, 0,
    0, 0, 0, 1, 0,
  ];
  static const List<double> _grayscaleMatrix = <double>[
    0.2126, 0.7152, 0.0722, 0, 0,
    0.2126, 0.7152, 0.0722, 0, 0,
    0.2126, 0.7152, 0.0722, 0, 0,
    0, 0, 0, 1, 0,
  ];
  static const List<double> _invertMatrix = <double>[
    -1, 0, 0, 0, 255,
    0, -1, 0, 0, 255,
    0, 0, -1, 0, 255,
    0, 0, 0, 1, 0,
  ];
  static const List<double> _duotoneMatrix = <double>[
    0.4941, 0, 0, 0, 22,
    0, 0.5137, 0, 0, 32,
    0, 0, 0.5412, 0, 46,
    0, 0, 0, 1, 0,
  ];

  final SupabaseClient _supabase = Supabase.instance.client;
  final MapController _mapController = MapController();
  late final AnimatedMapController _animatedMapController =
      AnimatedMapController(vsync: this, mapController: _mapController);

  late final Stream<List<Map<String, dynamic>>> _cameraStream = _supabase
      .from('cameras')
      .stream(primaryKey: ['id'])
      .order('created_at', ascending: false);

  late final Stream<List<Map<String, dynamic>>> _paStream = _supabase
      .from('pa_speakers')
      .stream(primaryKey: ['id'])
      .order('created_at', ascending: false);

  String? _selectedKey;

  /// Placement queue (single or bulk). While non-empty and `_placementIndex`
  /// is in range, we're waiting for a map tap for that device.
  List<_DevicePin> _placementQueue = [];
  int _placementIndex = 0;

  bool _isSaving = false;
  bool _isEditMode = false;
  bool _isAddingDevice = false;

  String _addSearch = '';

  /// Panel type filter: null = all devices.
  _DeviceKind? _addKindFilter;

  /// Devices checked in the panel for bulk placement (by `key`).
  final Set<String> _checkedForBulk = {};

  /// Local, unsaved positions (by `key`) — dragged pins AND newly placed ones.
  final Map<String, LatLng> _editedPositions = {};

  /// Latest snapshot of all devices (cameras + PA).
  List<_DevicePin> _allPins = const [];

  bool get _isPlacing => _placementIndex < _placementQueue.length;

  _DevicePin? get _currentPlacing =>
      _isPlacing ? _placementQueue[_placementIndex] : null;

  LatLng? _effectivePosition(_DevicePin pin) => _editedPositions[pin.key] ?? pin.position;

  bool _hasEffectivePin(_DevicePin pin) => _effectivePosition(pin) != null;

  List<_DevicePin> get _unsetDevices =>
      _allPins.where((p) => !_hasEffectivePin(p)).toList();

  String _formatPin(LatLng? p) {
    if (p == null) return 'Not set';
    return '${p.latitude.toStringAsFixed(6)}, ${p.longitude.toStringAsFixed(6)}';
  }

  void _fitAllPoints(List<LatLng> points) {
    if (points.isEmpty) return;
    if (points.length == 1) {
      _animatedMapController.animateTo(destCenter: points.first, destZoom: 16);
      return;
    }
    _animatedMapController.animateFitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds.fromPoints(points),
        padding: const EdgeInsets.all(60),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (BarangayBoundary.points.isNotEmpty) {
        _fitAllPoints(BarangayBoundary.points);
      }
    });
  }

  @override
  void dispose() {
    _animatedMapController.dispose();
    super.dispose();
  }

  void _selectDevice(_DevicePin pin) {
    setState(() => _selectedKey = pin.key);
    final pos = _effectivePosition(pin);
    if (pos != null) {
      _animatedMapController.animateTo(destCenter: pos, destZoom: 17);
    }
  }

  void _startPlacing(_DevicePin pin) {
    setState(() {
      _isAddingDevice = false;
      _selectedKey = pin.key;
      _placementQueue = [pin];
      _placementIndex = 0;
    });
  }

  void _startBulkPlacing(List<_DevicePin> pins) {
    if (pins.isEmpty) return;
    setState(() {
      _isAddingDevice = false;
      _checkedForBulk.clear();
      _placementQueue = pins;
      _placementIndex = 0;
      _selectedKey = pins.first.key;
    });
  }

  void _handleMapTapForPlacement(LatLng point) {
    final device = _currentPlacing;
    if (device == null) return;
    setState(() {
      _editedPositions[device.key] = point;
      _selectedKey = device.key;
      _placementIndex++;
      if (_placementIndex >= _placementQueue.length) {
        _placementQueue = [];
        _placementIndex = 0;
      }
    });
  }

  void _skipCurrentPlacement() {
    setState(() {
      _placementIndex++;
      if (_placementIndex >= _placementQueue.length) {
        _placementQueue = [];
        _placementIndex = 0;
      }
    });
  }

  void _cancelRemainingPlacement() {
    setState(() {
      _placementQueue = [];
      _placementIndex = 0;
    });
  }

  void _enterEditMode() => setState(() => _isEditMode = true);

  void _toggleAddPanel() => setState(() => _isAddingDevice = !_isAddingDevice);

  void _toggleBulkChecked(String key, bool checked) {
    setState(() {
      if (checked) {
        _checkedForBulk.add(key);
      } else {
        _checkedForBulk.remove(key);
      }
    });
  }

  void _toggleSelectAll(List<_DevicePin> visibleUnset) {
    final allChecked =
        visibleUnset.isNotEmpty && visibleUnset.every((p) => _checkedForBulk.contains(p.key));
    setState(() {
      for (final p in visibleUnset) {
        if (allChecked) {
          _checkedForBulk.remove(p.key);
        } else {
          _checkedForBulk.add(p.key);
        }
      }
    });
  }

  Future<void> _clearPin(_DevicePin pin) async {
    // Never saved to Supabase yet — just drop the staged change.
    if (pin.position == null) {
      setState(() => _editedPositions.remove(pin.key));
      return;
    }

    final confirmed = await _showActionConfirmDialog(
      title: 'Remove this pin?',
      message:
          '"${pin.name}" will no longer show on the map until a new location is set.',
      confirmLabel: 'REMOVE',
      confirmColor: AppColors.accentRed,
      icon: Icons.delete_outline,
    );
    if (!confirmed) return;

    setState(() => _isSaving = true);
    _showBlockingLoader('Removing location...');
    try {
      final oldPin = _formatPin(pin.position);
      await _supabase.from(pin.kind.table).update({
        'latitude': null,
        'longitude': null,
      }).eq('id', pin.rawId);

      await ActivityLogger.log(
        action: pin.kind.logAction,
        details: 'Removed map location for ${pin.kind.label.toLowerCase()} "${pin.name}"',
        changes: [
          LogChange(field: 'Map Location', from: oldPin, to: 'Not set'),
        ],
      );

      if (!mounted) return;
      setState(() => _editedPositions.remove(pin.key));
      AppToast.success(context, 'Location removed for "${pin.name}"');
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'Failed to remove location: $e');
    } finally {
      _hideBlockingLoader();
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// Live-drag for pins in edit mode. Only updates the local staged position.
  void _handlePanUpdate(_DevicePin pin, DragUpdateDetails details) {
    final current = _effectivePosition(pin);
    if (current == null) return;
    final camera = _mapController.camera;
    final currentPoint = camera.latLngToScreenPoint(current);
    final newPoint = math.Point<double>(
      currentPoint.x + details.delta.dx,
      currentPoint.y + details.delta.dy,
    );
    final newLatLng = camera.pointToLatLng(newPoint);
    setState(() => _editedPositions[pin.key] = newLatLng);
  }

  /// Saves every staged change in one batch, then exits edit mode.
  Future<void> _finishEditing() async {
    if (_isPlacing) return;

    final changed = Map<String, LatLng>.from(_editedPositions);

    if (changed.isEmpty) {
      setState(() {
        _isEditMode = false;
        _isAddingDevice = false;
        _checkedForBulk.clear();
      });
      return;
    }

    final count = changed.length;
    final confirmed = await _showActionConfirmDialog(
      title: 'Save changes?',
      message:
          'You made $count device location change${count == 1 ? '' : 's'}. Save ${count == 1 ? 'it' : 'them'} before finishing?',
      confirmLabel: 'SAVE',
      confirmColor: AppColors.accentBlue,
      icon: Icons.save_outlined,
    );
    if (!confirmed) {
      setState(() {
        _editedPositions.clear();
        _isEditMode = false;
        _isAddingDevice = false;
        _checkedForBulk.clear();
      });
      if (mounted) AppToast.success(context, 'Changes discarded');
      return;
    }

    setState(() => _isSaving = true);
    _showBlockingLoader('Saving changes...');

    int successCount = 0;
    final List<String> failedNames = [];

    try {
      for (final entry in changed.entries) {
        _DevicePin? pin;
        for (final p in _allPins) {
          if (p.key == entry.key) {
            pin = p;
            break;
          }
        }
        if (pin == null) continue;
        if (pin.position != null &&
            pin.position!.latitude == entry.value.latitude &&
            pin.position!.longitude == entry.value.longitude) {
          continue;
        }
        try {
          final oldPin = _formatPin(pin.position);
          final newPin = _formatPin(entry.value);
          final isNewPlacement = pin.position == null;
          final updated = await _supabase
              .from(pin.kind.table)
              .update({
                'latitude': entry.value.latitude,
                'longitude': entry.value.longitude,
              })
              .eq('id', pin.rawId)
              .select();

          if (updated.isEmpty) {
            throw Exception("You don't have permission to update this device.");
          }

          await ActivityLogger.log(
            action: pin.kind.logAction,
            details: isNewPlacement
                ? 'Set map location for ${pin.kind.label.toLowerCase()} "${pin.name}"'
                : 'Updated ${pin.kind.label.toLowerCase()} "${pin.name}"',
            changes: [
              LogChange(field: 'Map Location', from: oldPin, to: newPin),
            ],
          );
          successCount++;
        } catch (_) {
          failedNames.add(pin.name);
        }
      }
    } finally {
      _hideBlockingLoader();
      if (mounted) {
        setState(() {
          _isSaving = false;
          _editedPositions.clear();
          _isEditMode = false;
          _isAddingDevice = false;
          _checkedForBulk.clear();
        });
      }
    }

    if (!mounted) return;
    if (failedNames.isEmpty) {
      if (successCount > 0) {
        AppToast.success(
          context,
          'Updated $successCount device location${successCount == 1 ? '' : 's'}',
        );
      }
    } else {
      AppToast.error(context, 'Failed to update: ${failedNames.join(', ')}');
    }
  }

  // --- SHARED DIALOG / LOADER HELPERS ---

  void _showBlockingLoader(String message) {
    showDialog(
      context: context,
      useRootNavigator: true,
      barrierDismissible: false,
      barrierColor: Colors.black.withOpacity(0.55),
      builder: (_) => Center(child: _buildLoadingCard(message)),
    );
  }

  void _hideBlockingLoader() {
    final navigator = Navigator.of(context, rootNavigator: true);
    if (navigator.canPop()) {
      navigator.pop();
    }
  }

  Widget _buildLoadingCard(String message) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 22),
      decoration: BoxDecoration(
        color: AppColors.card(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(color: AppColors.accentBlue, strokeWidth: 3),
          ),
          const SizedBox(height: 14),
          Text(
            message,
            style: TextStyle(color: AppColors.textMain(context), fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Future<bool> _showActionConfirmDialog({
    required String title,
    required String message,
    required String confirmLabel,
    required Color confirmColor,
    required IconData icon,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: true,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 40),
        child: Container(
          width: 340,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AppColors.card(context),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border(context)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: confirmColor.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(icon, color: confirmColor, size: 18),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(color: AppColors.textMain(context), fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Divider(color: AppColors.border(context), height: 1, thickness: 1),
              const SizedBox(height: 14),
              Text(
                message,
                style: TextStyle(color: AppColors.textMuted(context), fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(dialogContext, rootNavigator: true).pop(false),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.textMain(context),
                        side: BorderSide(color: AppColors.border(context)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      child: const Text('CANCEL',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => Navigator.of(dialogContext, rootNavigator: true).pop(true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: confirmColor,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      child: Text(confirmLabel,
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card(context),
        border: Border.all(color: AppColors.border(context)),
      ),
      clipBehavior: Clip.antiAlias,
      child: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _cameraStream,
        builder: (context, camSnapshot) {
          return StreamBuilder<List<Map<String, dynamic>>>(
            stream: _paStream,
            builder: (context, paSnapshot) {
              final allPins = <_DevicePin>[
                for (final row in camSnapshot.data ?? const <Map<String, dynamic>>[])
                  _DevicePin.fromMap(row, _DeviceKind.camera),
                for (final row in paSnapshot.data ?? const <Map<String, dynamic>>[])
                  _DevicePin.fromMap(row, _DeviceKind.pa),
              ];
              _allPins = allPins;

              _DevicePin? selected;
              if (_selectedKey != null) {
                for (final p in allPins) {
                  if (p.key == _selectedKey) {
                    selected = p;
                    break;
                  }
                }
              }

              return Row(
                children: [
                  Expanded(child: _buildMap(allPins, selected)),
                  if (_isAddingDevice) ...[
                    VerticalDivider(color: AppColors.border(context), width: 1, thickness: 1),
                    SizedBox(width: 300, child: _buildAddDevicePanel()),
                  ],
                ],
              );
            },
          );
        },
      ),
    );
  }

  // --- "ADD DEVICE LOCATION" PANEL (unset devices only) ---

  Widget _kindChip(String label, _DeviceKind? kind) {
    final selected = _addKindFilter == kind;
    final color = kind?.color ?? AppColors.accentBlue;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => setState(() => _addKindFilter = kind),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? color : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: selected ? color : AppColors.border(context)),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : AppColors.textMuted(context),
            fontSize: 11.5,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget _buildAddDevicePanel() {
    final unset = _unsetDevices
        .where((p) => _addKindFilter == null || p.kind == _addKindFilter)
        .where((p) => p.name.toLowerCase().contains(_addSearch.toLowerCase()))
        .toList();
    final allChecked = unset.isNotEmpty && unset.every((p) => _checkedForBulk.contains(p.key));
    final checkedInView = unset.where((p) => _checkedForBulk.contains(p.key)).toList();

    return Container(
      color: AppColors.card(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Add Device Location',
                    style: TextStyle(color: AppColors.textMain(context), fontSize: 14, fontWeight: FontWeight.bold),
                  ),
                ),
                InkWell(
                  onTap: () => setState(() => _isAddingDevice = false),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(Icons.close, color: AppColors.textMuted(context), size: 18),
                  ),
                ),
              ],
            ),
          ),
          Divider(color: AppColors.border(context), height: 1, thickness: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
            child: Wrap(
              spacing: 6,
              children: [
                _kindChip('All', null),
                _kindChip('Cameras', _DeviceKind.camera),
                _kindChip('PA', _DeviceKind.pa),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
            child: SizedBox(
              height: 36,
              child: TextField(
                style: TextStyle(color: AppColors.textMain(context), fontSize: 13),
                onChanged: (v) => setState(() => _addSearch = v),
                decoration: InputDecoration(
                  hintText: 'Search devices',
                  hintStyle: TextStyle(color: AppColors.textMuted(context), fontSize: 13),
                  prefixIcon: Icon(Icons.search, color: AppColors.textMuted(context), size: 16),
                  filled: true,
                  fillColor: AppColors.bg(context),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
          ),
          if (unset.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
              child: Row(
                children: [
                  Text(
                    '${unset.length} unplaced',
                    style: TextStyle(color: AppColors.textMuted(context), fontSize: 11.5),
                  ),
                  const Spacer(),
                  InkWell(
                    onTap: () => _toggleSelectAll(unset),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                      child: Text(
                        allChecked ? 'Clear selection' : 'Select all',
                        style: const TextStyle(
                          color: AppColors.accentBlue,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: unset.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        _unsetDevices.isEmpty
                            ? 'All devices already have a location set.'
                            : 'No matching devices.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppColors.textMuted(context), fontSize: 13),
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: unset.length,
                    separatorBuilder: (_, __) => Divider(color: AppColors.border(context), height: 1),
                    itemBuilder: (context, index) {
                      final pin = unset[index];
                      final checked = _checkedForBulk.contains(pin.key);
                      return InkWell(
                        onTap: () => _toggleBulkChecked(pin.key, !checked),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 34,
                                height: 34,
                                child: Checkbox(
                                  value: checked,
                                  onChanged: (v) => _toggleBulkChecked(pin.key, v ?? false),
                                  activeColor: AppColors.accentBlue,
                                ),
                              ),
                              Icon(pin.kind.icon, color: pin.kind.color, size: 16),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      pin.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          color: AppColors.textMain(context),
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600),
                                    ),
                                    Text(
                                      pin.kind.label,
                                      style: TextStyle(color: AppColors.textMuted(context), fontSize: 10.5),
                                    ),
                                  ],
                                ),
                              ),
                              Tooltip(
                                message: 'Place this one now',
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(6),
                                  onTap: () => _startPlacing(pin),
                                  child: const Padding(
                                    padding: EdgeInsets.all(6),
                                    child: Icon(Icons.add_location_alt_outlined,
                                        color: AppColors.accentBlue, size: 18),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          if (checkedInView.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.bg(context),
                border: Border(top: BorderSide(color: AppColors.border(context))),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${checkedInView.length} selected',
                      style: TextStyle(color: AppColors.textMuted(context), fontSize: 12.5),
                    ),
                  ),
                  ElevatedButton.icon(
                    onPressed: () => _startBulkPlacing(checkedInView),
                    icon: const Icon(Icons.pin_drop_outlined, size: 16),
                    label: Text('Place ${checkedInView.length}'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accentBlue,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // --- MAP + FLOATING CONTROLS ---

  Widget _buildMap(List<_DevicePin> allPins, _DevicePin? selected) {
    final initialCenter =
        BarangayBoundary.points.isNotEmpty ? BarangayBoundary.points.first : _fallbackCenter;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final maskColor = AppColors.bg(context).withOpacity(isDark ? 0.90 : 0.80);

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: initialCenter,
            initialZoom: 16,
            minZoom: 14,
            maxZoom: 19,
            onTap: (_, point) {
              if (_isPlacing) _handleMapTapForPlacement(point);
            },
          ),
          children: [
            _buildThemedTileLayer(isDark),
            if (BarangayBoundary.points.isNotEmpty)
              PolygonLayer(
                polygons: [
                  Polygon(
                    points: _maskOuterRing,
                    holePointsList: [BarangayBoundary.points],
                    color: maskColor,
                    isFilled: true,
                  ),
                  Polygon(
                    points: BarangayBoundary.points,
                    color: Colors.transparent,
                    borderColor: AppColors.accentBlue,
                    borderStrokeWidth: 3,
                    isFilled: false,
                  ),
                ],
              ),
            MarkerLayer(
              markers: [
                for (final pin in allPins)
                  if (_effectivePosition(pin) != null)
                    // alignment: topCenter => the tip of the teardrop (bottom
                    // center of the marker box) sits exactly on the coordinate.
                    Marker(
                      point: _effectivePosition(pin)!,
                      width: 112,
                      height: 66,
                      alignment: Alignment.topCenter,
                      child: _DeviceMarker(
                        pin: pin,
                        selected: pin.key == selected?.key,
                        editMode: _isEditMode,
                        onTap: () => _selectDevice(pin),
                        onPanUpdate: (d) => _handlePanUpdate(pin, d),
                        onDelete: () => _clearPin(pin),
                      ),
                    ),
              ],
            ),
            RichAttributionWidget(
              alignment: AttributionAlignment.bottomLeft,
              showFlutterMapAttribution: false,
              attributions: [
                TextSourceAttribution('OpenStreetMap contributors'),
              ],
              popupBackgroundColor: AppColors.card(context),
            ),
          ],
        ),

        Positioned(top: 12, left: 12, child: _buildLegend(allPins)),

        Positioned(
          top: 12,
          right: 12,
          child: Row(
            children: [
              if (_isEditMode) ...[
                _buildAddDeviceLocationButton(),
                const SizedBox(width: 8),
              ],
              _buildEditFinishButton(),
            ],
          ),
        ),

        if (_isPlacing)
          Positioned(
            left: 12,
            right: 64,
            bottom: 12,
            child: _buildPlacementBar(),
          ),

        Positioned(
          bottom: 12,
          right: 12,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _ZoomControls(animatedMapController: _animatedMapController),
              const SizedBox(height: 8),
              Material(
                color: AppColors.card(context),
                shape: const CircleBorder(),
                elevation: 3,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => _fitAllPoints(BarangayBoundary.points),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(Icons.crop_free, color: AppColors.textMain(context), size: 18),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Plain OpenStreetMap tiles themed to the app's light/dark mode (same
  /// technique as the User Location screen's `_ThemedOsmTileLayer`).
  Widget _buildThemedTileLayer(bool isDark) {
    final tiles = TileLayer(
      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      userAgentPackageName: 'com.yourcompany.admin_app',
    );

    if (!isDark) {
      return ColorFiltered(
        colorFilter: const ColorFilter.matrix(_lightSaturationMatrix),
        child: ColorFiltered(
          colorFilter: ColorFilter.mode(
            Colors.white.withOpacity(0.04),
            BlendMode.screen,
          ),
          child: tiles,
        ),
      );
    }

    return ColorFiltered(
      colorFilter: const ColorFilter.matrix(_duotoneMatrix),
      child: ColorFiltered(
        colorFilter: const ColorFilter.matrix(_invertMatrix),
        child: ColorFiltered(
          colorFilter: const ColorFilter.matrix(_grayscaleMatrix),
          child: tiles,
        ),
      ),
    );
  }

  Widget _buildLegend(List<_DevicePin> allPins) {
    Widget dot(Color color) => Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        );

    Widget kindRow(_DeviceKind kind) {
      final count = allPins.where((p) => p.kind == kind && _hasEffectivePin(p)).length;
      return Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(color: kind.color, shape: BoxShape.circle),
          child: Icon(kind.icon, color: Colors.white, size: 11),
        ),
        const SizedBox(width: 6),
        Text('${kind.label} ($count)',
            style: TextStyle(color: AppColors.textMuted(context), fontSize: 11)),
      ]);
    }

    return Material(
      color: AppColors.card(context).withOpacity(0.92),
      borderRadius: BorderRadius.circular(8),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            kindRow(_DeviceKind.camera),
            const SizedBox(height: 4),
            kindRow(_DeviceKind.pa),
            const SizedBox(height: 8),
            Row(mainAxisSize: MainAxisSize.min, children: [
              dot(AppColors.accentGreen),
              const SizedBox(width: 6),
              Text('Online', style: TextStyle(color: AppColors.textMuted(context), fontSize: 11)),
            ]),
            const SizedBox(height: 4),
            Row(mainAxisSize: MainAxisSize.min, children: [
              dot(AppColors.accentRed),
              const SizedBox(width: 6),
              Text('Offline', style: TextStyle(color: AppColors.textMuted(context), fontSize: 11)),
            ]),
            if (_isEditMode) ...[
              const SizedBox(height: 4),
              Text('Drag to move • × to remove',
                  style: TextStyle(color: AppColors.textMuted(context), fontSize: 10.5)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPlacementBar() {
    final device = _currentPlacing;
    final position = _placementIndex + 1;
    final total = _placementQueue.length;
    return Material(
      color: AppColors.card(context),
      borderRadius: BorderRadius.circular(10),
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            const Icon(Icons.touch_app_outlined, color: AppColors.accentBlue, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text.rich(
                TextSpan(
                  style: TextStyle(color: AppColors.textMain(context), fontSize: 12.5),
                  children: [
                    const TextSpan(text: 'Tap the map to place  '),
                    TextSpan(
                      text: device?.name ?? '',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    if (total > 1) TextSpan(text: '   ($position of $total)'),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (total > 1)
              TextButton(
                onPressed: _skipCurrentPlacement,
                child: const Text('Skip', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              ),
            TextButton(
              onPressed: _cancelRemainingPlacement,
              style: TextButton.styleFrom(foregroundColor: AppColors.accentRed),
              child: const Text('Cancel', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEditFinishButton() {
    final disabled = _isSaving || _isPlacing;
    return Material(
      color: _isEditMode ? AppColors.accentRed : AppColors.card(context),
      borderRadius: BorderRadius.circular(8),
      elevation: 3,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: disabled ? null : (_isEditMode ? _finishEditing : _enterEditMode),
        child: Opacity(
          opacity: disabled && _isEditMode ? 0.6 : 1,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _isEditMode ? Icons.check : Icons.edit_outlined,
                  size: 16,
                  color: _isEditMode ? Colors.white : AppColors.textMain(context),
                ),
                const SizedBox(width: 7),
                Text(
                  _isEditMode ? 'Finish' : 'Edit',
                  style: TextStyle(
                    color: _isEditMode ? Colors.white : AppColors.textMain(context),
                    fontSize: 12.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAddDeviceLocationButton() {
    final hasUnset = _unsetDevices.isNotEmpty;
    final enabled = hasUnset && !_isPlacing;
    return Material(
      color: _isAddingDevice ? AppColors.accentBlue : AppColors.card(context),
      borderRadius: BorderRadius.circular(8),
      elevation: 3,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: enabled ? _toggleAddPanel : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.add_location_alt_outlined,
                size: 16,
                color: !enabled
                    ? AppColors.textMuted(context).withOpacity(0.45)
                    : (_isAddingDevice ? Colors.white : AppColors.accentBlue),
              ),
              const SizedBox(width: 7),
              Text(
                hasUnset ? 'Add Device Location' : 'All devices placed',
                style: TextStyle(
                  color: !enabled
                      ? AppColors.textMuted(context).withOpacity(0.45)
                      : (_isAddingDevice ? Colors.white : AppColors.textMain(context)),
                  fontSize: 12.5,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Pin widgets (same teardrop pin as the User Location screen)
// ---------------------------------------------------------------------------

/// Round icon badge with a Life360-style pointer at the bottom. The tip is at
/// bottom-center of [size], so a Marker with `alignment: Alignment.topCenter`
/// puts that tip exactly on the coordinate.
class _PinPainter extends CustomPainter {
  final Color fill;
  final double borderWidth;
  final bool selected;

  const _PinPainter({
    required this.fill,
    this.borderWidth = 2.5,
    this.selected = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final outerR = size.width / 2;
    final r = outerR - borderWidth / 2;
    final cy = outerR;
    final hw = outerR * 0.36;
    final baseY = cy + outerR * 0.85;
    final tipY = size.height;

    final circle = Path()..addOval(Rect.fromCircle(center: Offset(cx, cy), radius: r));
    final pointer = Path()
      ..moveTo(cx - hw, baseY)
      ..lineTo(cx, tipY)
      ..lineTo(cx + hw, baseY)
      ..close();
    final shape = Path.combine(PathOperation.union, circle, pointer);

    canvas.drawShadow(shape, Colors.black, 3, true);

    if (selected) {
      canvas.drawPath(
        shape,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = borderWidth + 5
          ..color = Colors.black.withOpacity(0.55),
      );
    }

    canvas.drawPath(pointer, Paint()..color = Colors.white);
    canvas.drawPath(circle, Paint()..color = fill);
    canvas.drawPath(
      circle,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = borderWidth
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_PinPainter o) =>
      o.fill != fill || o.borderWidth != borderWidth || o.selected != selected;
}

/// Device marker: name label above, teardrop pin below (status-colored fill,
/// device icon inside, pulse ring when online). In edit mode the pin is
/// draggable and shows a delete badge on its corner.
class _DeviceMarker extends StatelessWidget {
  final _DevicePin pin;
  final bool selected;
  final bool editMode;
  final VoidCallback onTap;
  final void Function(DragUpdateDetails) onPanUpdate;
  final VoidCallback onDelete;

  const _DeviceMarker({
    required this.pin,
    required this.selected,
    required this.editMode,
    required this.onTap,
    required this.onPanUpdate,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final ringColor = _statusColor(pin.status);
    final online = pin.status.toUpperCase() == 'ONLINE';

    const pinW = 30.0, pinH = 38.0;
    // Extra width so the delete badge sits INSIDE the hit-test bounds.
    const boxW = pinW + 16;

    return Tooltip(
      message: '${pin.kind.label}: ${pin.name}',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onPanUpdate: editMode ? onPanUpdate : null,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Container(
              constraints: const BoxConstraints(maxWidth: 108),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.card(context).withOpacity(0.92),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                pin.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textMain(context),
                  fontSize: 9.5,
                  fontWeight: FontWeight.w600,
                  height: 1.1,
                ),
              ),
            ),
            const SizedBox(height: 2),
            SizedBox(
              width: boxW,
              height: pinH,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  if (online && !editMode)
                    Positioned(
                      left: 8,
                      width: pinW,
                      top: 0,
                      height: pinW,
                      child: Center(child: _PulseRing(color: ringColor)),
                    ),
                  Positioned(
                    left: 8,
                    top: 0,
                    width: pinW,
                    height: pinH,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        CustomPaint(
                          size: const Size(pinW, pinH),
                          painter: _PinPainter(fill: ringColor, selected: selected),
                        ),
                        Positioned(
                          left: 0,
                          right: 0,
                          top: 0,
                          height: pinW,
                          child: Center(child: Icon(pin.kind.icon, color: Colors.white, size: 15)),
                        ),
                      ],
                    ),
                  ),
                  // Small kind-colored dot so cameras vs PA are distinguishable
                  // at a glance even though the pin fill shows status.
                  Positioned(
                    left: 4,
                    top: -2,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: pin.kind.color,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 1.2),
                      ),
                    ),
                  ),
                  if (editMode)
                    Positioned(
                      right: 0,
                      top: 0,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: onDelete,
                        child: Container(
                          width: 16,
                          height: 16,
                          decoration: BoxDecoration(
                            color: AppColors.accentRed,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 1.2),
                          ),
                          child: const Icon(Icons.close, color: Colors.white, size: 11),
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
}

/// Soft looping expanding ring behind an "online" marker.
class _PulseRing extends StatefulWidget {
  final Color color;

  const _PulseRing({required this.color});

  @override
  State<_PulseRing> createState() => _PulseRingState();
}

class _PulseRingState extends State<_PulseRing> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = _controller.value;
        return Container(
          width: 28 + (t * 16),
          height: 28 + (t * 16),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: widget.color.withOpacity((1 - t) * 0.55),
              width: 2,
            ),
          ),
        );
      },
    );
  }
}

/// Compact +/- zoom control.
class _ZoomControls extends StatelessWidget {
  final AnimatedMapController animatedMapController;

  const _ZoomControls({required this.animatedMapController});

  void _step(double delta) {
    final camera = animatedMapController.camera;
    final next = (camera.zoom + delta).clamp(14.0, 19.0);
    animatedMapController.animateTo(destZoom: next);
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.card(context),
      borderRadius: BorderRadius.circular(8),
      elevation: 3,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.border(context)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
              onTap: () => _step(1),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Icon(Icons.add, color: AppColors.textMain(context), size: 16),
              ),
            ),
            Divider(height: 1, color: AppColors.border(context)),
            InkWell(
              borderRadius: const BorderRadius.vertical(bottom: Radius.circular(8)),
              onTap: () => _step(-1),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Icon(Icons.remove, color: AppColors.textMain(context), size: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}