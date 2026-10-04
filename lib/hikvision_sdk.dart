// Dart FFI bindings for Hikvision HCNetSDK v6.1.9.4_build20220412 (Windows x64).
//
// Struct layouts and function signatures below were read directly from the
// SDK's own header (incEn/HCNetSDK.h) for this exact build — not recalled
// from general knowledge — so field order/sizes match this SDK version.
//
// SETUP REQUIRED:
// 1. Copy these into the SAME folder as your app's built .exe (next to
//    windows/runner's output, or wherever your Flutter Windows build ends
//    up): HCNetSDK.dll, HCCore.dll, PlayCtrl.dll, the HCNetSDKCom/ folder
//    (HCPreview.dll etc.), and the other supporting DLLs from lib/. The SDK
//    dynamically loads several of these itself; leave the folder structure
//    intact rather than flattening it.
// 2. This file covers: init, login (with device serial number for a
//    rock-solid identity), starting real-time preview via the RAW
//    FRAME callback (H.264 elementary stream / audio, handed to you as raw
//    bytes — NOT decoded or rendered), and a lightweight
//    "resolve serial number only" helper for enriching devices your
//    network-layer discovery (SADP/ONVIF/port-scan) already found but
//    couldn't get a serial for without logging in.
//
// NOTE ON LIVE VIDEO: CctvScreen/CctvLiveScreen in this app do NOT use the
// raw-frame path below for rendering. They play the camera's RTSP stream
// directly through media_kit/libmpv, which decodes and renders H.264 on
// its own without any of this SDK. This file is used only for
// `tryGetSerialNumber`, i.e. logging in just long enough to read the
// device's authenticated serial number (and other NET_DVR_DEVICEINFO_V30
// fields) for display/identification purposes, then logging back out.
// The raw-frame / RealPlay path further down remains available if you
// later want SDK-native rendering instead of RTSP, but that still needs
// the separate native decode+texture plugin described at the bottom of
// this file — it is not required for the current RTSP-based live view.

import 'dart:ffi' as ffi;
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

// ---- Win32 base typedefs (as defined by HCNetSDK.h for this build) ----
// DWORD = unsigned int (32-bit), LONG = int (32-bit), BYTE = unsigned char,
// WORD = unsigned short, BOOL = int (32-bit), HWND = opaque pointer.
typedef DWORD = ffi.Uint32;
typedef LONG = ffi.Int32;
typedef BYTE = ffi.Uint8;
typedef WORD = ffi.Uint16;
typedef BOOL = ffi.Int32;
typedef HWND = ffi.Pointer<ffi.Void>;

const int serialNoLen = 48; // SERIALNO_LEN
const int streamIdLen = 32; // STREAM_ID_LEN

// ---- NET_DVR_DEVICEINFO_V30 ----
// Field order copied verbatim from tagNET_DVR_DEVICEINFO_V30 in HCNetSDK.h.
final class NetDvrDeviceInfoV30 extends ffi.Struct {
  @ffi.Array(48)
  external ffi.Array<BYTE> sSerialNumber; // SERIALNO_LEN

  @BYTE()
  external int byAlarmInPortNum;
  @BYTE()
  external int byAlarmOutPortNum;
  @BYTE()
  external int byDiskNum;
  @BYTE()
  external int byDVRType;
  @BYTE()
  external int byChanNum;
  @BYTE()
  external int byStartChan;
  @BYTE()
  external int byAudioChanNum;
  @BYTE()
  external int byIPChanNum;
  @BYTE()
  external int byZeroChanNum;
  @BYTE()
  external int byMainProto;
  @BYTE()
  external int bySubProto;
  @BYTE()
  external int bySupport;
  @BYTE()
  external int bySupport1;
  @BYTE()
  external int bySupport2;
  @WORD()
  external int wDevType;
  @BYTE()
  external int bySupport3;
  @BYTE()
  external int byMultiStreamProto;
  @BYTE()
  external int byStartDChan;
  @BYTE()
  external int byStartDTalkChan;
  @BYTE()
  external int byHighDChanNum;
  @BYTE()
  external int bySupport4;
  @BYTE()
  external int byLanguageType;
  @BYTE()
  external int byVoiceInChanNum;
  @BYTE()
  external int byStartVoiceInChanNo;
  @BYTE()
  external int bySupport5;
  @BYTE()
  external int bySupport6;
  @BYTE()
  external int byMirrorChanNum;
  @WORD()
  external int wStartMirrorChanNo;
  @BYTE()
  external int bySupport7;
  @BYTE()
  external int byRes2;
}

// ---- NET_DVR_DEVICEINFO_V40 ----
final class NetDvrDeviceInfoV40 extends ffi.Struct {
  external NetDvrDeviceInfoV30 struDeviceV30;

  @BYTE()
  external int bySupportLock;
  @BYTE()
  external int byRetryLoginTime;
  @BYTE()
  external int byPasswordLevel;
  @BYTE()
  external int byProxyType;
  @DWORD()
  external int dwSurplusLockTime;
  @BYTE()
  external int byCharEncodeType;
  @BYTE()
  external int bySupportDev5;
  @BYTE()
  external int bySupport;
  @BYTE()
  external int byLoginMode;
  @DWORD()
  external int dwOEMCode;
  @ffi.Int32()
  external int iResidualValidity;
  @BYTE()
  external int byResidualValidity;
  @BYTE()
  external int bySingleStartDTalkChan;
  @BYTE()
  external int bySingleDTalkChanNums;
  @BYTE()
  external int byPassWordResetLevel;
  @BYTE()
  external int bySupportStreamEncrypt;
  @BYTE()
  external int byMarketType;

  @ffi.Array(238)
  external ffi.Array<BYTE> byRes2;
}

// ---- NET_DVR_USER_LOGIN_INFO ----
final class NetDvrUserLoginInfo extends ffi.Struct {
  @ffi.Array(129)
  external ffi.Array<ffi.Uint8> sDeviceAddress; // NET_DVR_DEV_ADDRESS_MAX_LEN

  @BYTE()
  external int byUseTransport;
  @WORD()
  external int wPort;

  @ffi.Array(64)
  external ffi.Array<ffi.Uint8> sUserName; // NET_DVR_LOGIN_USERNAME_MAX_LEN

  @ffi.Array(64)
  external ffi.Array<ffi.Uint8> sPassword; // NET_DVR_LOGIN_PASSWD_MAX_LEN

  external ffi.Pointer<ffi.NativeFunction<ffi.Void Function(LONG, DWORD, ffi.Pointer<NetDvrDeviceInfoV30>, ffi.Pointer<ffi.Void>)>> cbLoginResult;
  external ffi.Pointer<ffi.Void> pUser;

  @BOOL()
  external int bUseAsynLogin;
  @BYTE()
  external int byProxyType;
  @BYTE()
  external int byUseUTCTime;
  @BYTE()
  external int byLoginMode; // 0-Private 1-ISAPI 2-adapt
  @BYTE()
  external int byHttps; // 0-tcp 1-tls 2-adapt
  @LONG()
  external int iProxyID;
  @BYTE()
  external int byVerifyMode;

  @ffi.Array(119)
  external ffi.Array<BYTE> byRes3;
}

// ---- NET_DVR_PREVIEWINFO ----
final class NetDvrPreviewInfo extends ffi.Struct {
  @LONG()
  external int lChannel;
  @DWORD()
  external int dwStreamType;
  @DWORD()
  external int dwLinkMode;

  external HWND hPlayWnd; // pass ffi.nullptr — we're not using SDK window rendering

  @DWORD()
  external int bBlocked;
  @DWORD()
  external int bPassbackRecord;
  @BYTE()
  external int byPreviewMode;

  @ffi.Array(32)
  external ffi.Array<BYTE> byStreamID; // STREAM_ID_LEN

  @BYTE()
  external int byProtoType;
  @BYTE()
  external int byRes1;
  @BYTE()
  external int byVideoCodingType;
  @DWORD()
  external int dwDisplayBufNum;
  @BYTE()
  external int byNPQMode;
  @BYTE()
  external int byRecvMetaData;
  @BYTE()
  external int byDataType;

  @ffi.Array(213)
  external ffi.Array<BYTE> byRes;
}

// dwDataType values for the real-data callback (from HCNetSDK.h):
const int netDvrSysHead = 1; // system header (sent once at stream start)
const int netDvrStreamData = 2; // video stream data (what you want to decode)
const int netDvrAudioStreamData = 3; // audio stream data

typedef _RealDataCallbackNative = ffi.Void Function(
    LONG lRealHandle, DWORD dwDataType, ffi.Pointer<BYTE> pBuffer, DWORD dwBufSize, ffi.Pointer<ffi.Void> pUser);
typedef RealDataCallback = void Function(int lRealHandle, int dwDataType, ffi.Pointer<BYTE> pBuffer, int dwBufSize, ffi.Pointer<ffi.Void> pUser);

// ---- Native function signatures ----
typedef _NetDvrInitNative = BOOL Function();
typedef _NetDvrCleanupNative = BOOL Function();
typedef _NetDvrSetConnectTimeNative = BOOL Function(DWORD dwWaitTime, DWORD dwTryTimes);
typedef _NetDvrLoginV40Native = LONG Function(ffi.Pointer<NetDvrUserLoginInfo> pLoginInfo, ffi.Pointer<NetDvrDeviceInfoV40> lpDeviceInfo);
typedef _NetDvrLogoutNative = BOOL Function(LONG lUserID);
typedef _NetDvrGetLastErrorNative = DWORD Function();
typedef _NetDvrRealPlayV40Native = LONG Function(
    LONG lUserID, ffi.Pointer<NetDvrPreviewInfo> lpPreviewInfo, ffi.Pointer<ffi.NativeFunction<_RealDataCallbackNative>> fRealDataCallBack, ffi.Pointer<ffi.Void> pUser);
typedef _NetDvrStopRealPlayNative = BOOL Function(LONG lRealHandle);

typedef _NetDvrInitDart = int Function();
typedef _NetDvrCleanupDart = int Function();
typedef _NetDvrSetConnectTimeDart = int Function(int dwWaitTime, int dwTryTimes);
typedef _NetDvrLoginV40Dart = int Function(ffi.Pointer<NetDvrUserLoginInfo> pLoginInfo, ffi.Pointer<NetDvrDeviceInfoV40> lpDeviceInfo);
typedef _NetDvrLogoutDart = int Function(int lUserID);
typedef _NetDvrGetLastErrorDart = int Function();
typedef _NetDvrRealPlayV40Dart = int Function(
    int lUserID, ffi.Pointer<NetDvrPreviewInfo> lpPreviewInfo, ffi.Pointer<ffi.NativeFunction<_RealDataCallbackNative>> fRealDataCallBack, ffi.Pointer<ffi.Void> pUser);
typedef _NetDvrStopRealPlayDart = int Function(int lRealHandle);

/// A single raw stream chunk delivered from the camera. `videoCodingType`
/// on [NetDvrPreviewInfo]/system-header parsing tells you H.264 vs H.265 —
/// for most Hikvision IP cameras it's H.264 unless configured otherwise.
class HikvisionRawFrame {
  final int dataType; // netDvrSysHead / netDvrStreamData / netDvrAudioStreamData
  final Uint8List bytes;
  HikvisionRawFrame(this.dataType, this.bytes);
}

/// Thin, direct wrapper around the pieces of HCNetSDK needed for:
/// login (+ getting the device's serial number as a rock-solid identity),
/// and starting a real-time preview that hands you raw stream bytes via a
/// Dart callback. Decoding/rendering those bytes is NOT done here — see the
/// note at the bottom of this file for why that's a separate native plugin.
class HikvisionSdk {
  late final ffi.DynamicLibrary _lib;
  late final _NetDvrInitDart _init;
  late final _NetDvrCleanupDart _cleanup;
  late final _NetDvrSetConnectTimeDart _setConnectTime;
  late final _NetDvrLoginV40Dart _loginV40;
  late final _NetDvrLogoutDart _logout;
  late final _NetDvrGetLastErrorDart _getLastError;
  late final _NetDvrRealPlayV40Dart _realPlayV40;
  late final _NetDvrStopRealPlayDart _stopRealPlay;

  bool _initialized = false;

  /// [dllPath] should point at HCNetSDK.dll, sitting alongside its
  /// dependent DLLs (HCCore.dll, PlayCtrl.dll, HCNetSDKCom\, etc — copy the
  /// whole lib/ folder structure from the SDK, not just this one file).
  HikvisionSdk({String dllPath = 'HCNetSDK.dll'}) {
    _lib = ffi.DynamicLibrary.open(dllPath);
    _init = _lib.lookupFunction<_NetDvrInitNative, _NetDvrInitDart>('NET_DVR_Init');
    _cleanup = _lib.lookupFunction<_NetDvrCleanupNative, _NetDvrCleanupDart>('NET_DVR_Cleanup');
    _setConnectTime = _lib.lookupFunction<_NetDvrSetConnectTimeNative, _NetDvrSetConnectTimeDart>('NET_DVR_SetConnectTime');
    _loginV40 = _lib.lookupFunction<_NetDvrLoginV40Native, _NetDvrLoginV40Dart>('NET_DVR_Login_V40');
    _logout = _lib.lookupFunction<_NetDvrLogoutNative, _NetDvrLogoutDart>('NET_DVR_Logout_V30');
    _getLastError = _lib.lookupFunction<_NetDvrGetLastErrorNative, _NetDvrGetLastErrorDart>('NET_DVR_GetLastError');
    _realPlayV40 = _lib.lookupFunction<_NetDvrRealPlayV40Native, _NetDvrRealPlayV40Dart>('NET_DVR_RealPlay_V40');
    _stopRealPlay = _lib.lookupFunction<_NetDvrStopRealPlayNative, _NetDvrStopRealPlayDart>('NET_DVR_StopRealPlay');
  }

  /// Must be called once before anything else.
  void init() {
    if (_initialized) return;
    final ok = _init() != 0;
    if (!ok) {
      throw StateError('NET_DVR_Init failed (error code ${_getLastError()})');
    }
    _setConnectTime(3000, 3); // 3s timeout, 3 retries — matches SDK default
    _initialized = true;
  }

  void cleanup() {
    if (!_initialized) return;
    _cleanup();
    _initialized = false;
  }

  int get lastError => _getLastError();

  /// Logs into a camera at [ip]:[port] (SDK port, typically 8000) with the
  /// given credentials. Returns a [HikvisionLoginResult] on success
  /// (including the device's serial number — use this, not just MAC, as
  /// your strongest persistent camera identity, since it's authenticated
  /// straight from the device rather than inferred from the network layer).
  /// Throws [StateError] on failure; check `.lastError` for the SDK error code.
  HikvisionLoginResult login({
    required String ip,
    required String username,
    required String password,
    int port = 8000,
  }) {
    if (!_initialized) init();

    final loginInfo = calloc<NetDvrUserLoginInfo>();
    final deviceInfo = calloc<NetDvrDeviceInfoV40>();
    try {
      _writeCString(loginInfo.ref.sDeviceAddress, ip, 129);
      _writeCString(loginInfo.ref.sUserName, username, 64);
      _writeCString(loginInfo.ref.sPassword, password, 64);
      loginInfo.ref.wPort = port;
      loginInfo.ref.byLoginMode = 0; // 0 = private protocol (standard SDK login)
      loginInfo.ref.bUseAsynLogin = 0; // synchronous login — call blocks until done

      final userId = _loginV40(loginInfo, deviceInfo);
      if (userId < 0) {
        throw StateError('NET_DVR_Login_V40 failed for $ip:$port (error code ${_getLastError()})');
      }

      final serial = _readCString(deviceInfo.ref.struDeviceV30.sSerialNumber, serialNoLen);
      final chanNum = deviceInfo.ref.struDeviceV30.byChanNum;
      final devType = deviceInfo.ref.struDeviceV30.wDevType;
      final ipChanNum = deviceInfo.ref.struDeviceV30.byIPChanNum;
      return HikvisionLoginResult(
        userId: userId,
        serialNumber: serial,
        channelNum: chanNum,
        ipChannelNum: ipChanNum,
        deviceTypeCode: devType,
      );
    } finally {
      calloc.free(loginInfo);
      calloc.free(deviceInfo);
    }
  }

  /// Convenience wrapper for the common "just find the device's identity
  /// details and disconnect" case. Used both by
  /// CameraDiscoveryService.identifySerialViaSdk (to enrich a device found
  /// via ONVIF/ARP-cache/port-scan, which doesn't come with a serial for
  /// free the way a SADP reply does) and by CctvScreen when a camera is
  /// added/edited, so the serial/channel info shown to the user comes
  /// straight from the device rather than being typed in by hand.
  /// Logs in, grabs the details, logs straight back out.
  ///
  /// Returns null instead of throwing if the login fails (bad credentials,
  /// unreachable, wrong SDK port, not actually a Hikvision device, etc.)
  /// so callers can loop over a whole discovered-device list, or a single
  /// save action, without wrapping every call in try/catch.
  HikvisionLoginResult? tryGetDeviceInfo({
    required String ip,
    required String username,
    required String password,
    int port = 8000,
  }) {
    try {
      final result = login(ip: ip, username: username, password: password, port: port);
      logout(result.userId);
      return result;
    } catch (_) {
      return null;
    }
  }

  /// Back-compat convenience — just the serial number string, or null.
  String? tryGetSerialNumber({
    required String ip,
    required String username,
    required String password,
    int port = 8000,
  }) {
    final info = tryGetDeviceInfo(ip: ip, username: username, password: password, port: port);
    if (info == null || info.serialNumber.isEmpty) return null;
    return info.serialNumber;
  }

  void logout(int userId) => _logout(userId);

  /// Starts real-time preview on [channel] (1 for a single-channel IP
  /// camera) and delivers raw stream bytes to [onFrame] as they arrive.
  /// Returns a play handle — pass it to [stopRealPlay] when done.
  ///
  /// IMPORTANT: [onFrame] runs on a native SDK thread via an FFI callback.
  /// Keep it fast (copy bytes out and hand off, e.g. to a StreamController
  /// or straight to your native rendering plugin) — do not do heavy Dart
  /// work directly inside it.
  ///
  /// Not used by CctvLiveScreen today (that widget plays RTSP directly via
  /// media_kit instead). Kept here for the case where SDK-native rendering
  /// is wanted later — see the note at the bottom of this file.
  int startRealPlay({
    required int userId,
    required void Function(HikvisionRawFrame frame) onFrame,
    int channel = 1,
  }) {
    final previewInfo = calloc<NetDvrPreviewInfo>();
    previewInfo.ref.lChannel = channel;
    previewInfo.ref.dwStreamType = 0; // main stream
    previewInfo.ref.dwLinkMode = 0; // TCP
    previewInfo.ref.hPlayWnd = ffi.nullptr; // no SDK-side window rendering
    previewInfo.ref.bBlocked = 1;

    final callback = ffi.NativeCallable<_RealDataCallbackNative>.listener(
      (int lRealHandle, int dwDataType, ffi.Pointer<BYTE> pBuffer, int dwBufSize, ffi.Pointer<ffi.Void> pUser) {
        final bytes = Uint8List.fromList(pBuffer.asTypedList(dwBufSize));
        onFrame(HikvisionRawFrame(dwDataType, bytes));
      },
    );
    _activeCallbacks.add(callback); // keep alive for the life of the stream

    try {
      final handle = _realPlayV40(userId, previewInfo, callback.nativeFunction, ffi.nullptr);
      if (handle < 0) {
        callback.close();
        _activeCallbacks.remove(callback);
        throw StateError('NET_DVR_RealPlay_V40 failed (error code ${_getLastError()})');
      }
      _handleToCallback[handle] = callback;
      return handle;
    } finally {
      calloc.free(previewInfo);
    }
  }

  void stopRealPlay(int playHandle) {
    _stopRealPlay(playHandle);
    final cb = _handleToCallback.remove(playHandle);
    if (cb != null) {
      cb.close();
      _activeCallbacks.remove(cb);
    }
  }

  final List<ffi.NativeCallable> _activeCallbacks = [];
  final Map<int, ffi.NativeCallable> _handleToCallback = {};

  void _writeCString(ffi.Array<ffi.Uint8> array, String value, int maxLen) {
    final bytes = value.codeUnits;
    final len = bytes.length < maxLen - 1 ? bytes.length : maxLen - 1;
    for (var i = 0; i < len; i++) {
      array[i] = bytes[i];
    }
    array[len] = 0;
  }

  String _readCString(ffi.Array<BYTE> array, int maxLen) {
    final codeUnits = <int>[];
    for (var i = 0; i < maxLen; i++) {
      final b = array[i];
      if (b == 0) break;
      codeUnits.add(b);
    }
    return String.fromCharCodes(codeUnits);
  }
}

class HikvisionLoginResult {
  final int userId;
  final String serialNumber;
  final int channelNum;
  final int ipChannelNum;
  final int deviceTypeCode;
  HikvisionLoginResult({
    required this.userId,
    required this.serialNumber,
    required this.channelNum,
    this.ipChannelNum = 0,
    this.deviceTypeCode = 0,
  });
}

// ---------------------------------------------------------------------
// WHAT'S NOT HERE YET: turning HikvisionRawFrame bytes into a picture.
//
// `dwDataType == netDvrStreamData` chunks are raw H.264 (typically)
// elementary-stream data — not decoded, not a bitmap. To actually show
// video in your Flutter UI *via this SDK path*, the frame-callback path
// above needs one more piece: a native Windows plugin that (a) decodes
// the H.264 (via PlayCtrl.dll's decoder, which ships in this SDK, or your
// own via FFmpeg) and (b) writes decoded frames into a Flutter Texture
// (via the `texture_rgba_renderer` package or a custom ANGLE/D3D11
// shared-texture registration). That's C++ code living in windows/ of
// your Flutter project, not something pure Dart/FFI can do, since
// Flutter's texture registrar isn't exposed to Dart directly.
//
// CctvLiveScreen in this app sidesteps all of that by playing the
// camera's RTSP stream directly through media_kit/libmpv, which already
// decodes and renders H.264/H.265 for you — so live view works today
// without this plugin. Say the word if you'd rather have SDK-native
// rendering instead of RTSP and I'll scaffold that plugin next — it's a
// bigger, mostly C++ piece of work, separate from everything in this file.
// ---------------------------------------------------------------------