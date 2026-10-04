import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Holds the MP3 used for PA announcements and plays it on the default
/// audio output (e.g. your Bluetooth speaker).
class PaAudioService extends ChangeNotifier {
  PaAudioService._();
  static final PaAudioService instance = PaAudioService._();

  static const _prefsKey = 'pa_fire_audio_path';

  Player? _player;
  String? _path;
  bool _playing = false;

  String? get path => _path;
  bool get hasFile => _path != null;
  bool get isPlaying => _playing;
  String get fileName =>
      _path == null ? '' : _path!.split(RegExp(r'[\\/]')).last;

  /// Call once at startup (after MediaKit.ensureInitialized()).
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefsKey);
    if (saved != null && File(saved).existsSync()) _path = saved;
    notifyListeners();
  }

  Player _ensurePlayer() {
    final existing = _player;
    if (existing != null) return existing;
    final p = Player();
    p.stream.playing.listen((v) {
      _playing = v;
      notifyListeners();
    });
    return _player = p;
  }

  /// Opens the file dialog. Returns true if a file was chosen.
  Future<bool> pick() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp3'],
      dialogTitle: 'Select announcement MP3',
    );
    final picked = result?.files.single.path;
    if (picked == null) return false;

    await stop();
    _path = picked;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, picked);
    notifyListeners();
    return true;
  }

  Future<void> clear() async {
    await stop();
    _path = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
    notifyListeners();
  }

  /// Returns false if no file is set or it no longer exists on disk.
  Future<bool> play() async {
    final p = _path;
    if (p == null || !File(p).existsSync()) return false;
    final player = _ensurePlayer();
    await player.setVolume(100);
    await player.open(Media(Uri.file(p).toString()));
    return true;
  }

  Future<void> stop() async {
    await _player?.stop();
  }
}