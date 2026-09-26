/// LibrePili: scanning a QR code with the camera, the same way on every
/// platform (research/qr-code-design-2026-09-25.md, R2).
///
/// Pops with the text of the first code read, or nothing.
///
/// What goes wrong is told in three plain cases, measured on Windows (R0):
/// - no camera: the list is empty;
/// - no permission: on a phone or a Mac the plugin says so; on Windows it
///   does not (opening fails with "Failed to create capture engine", or a
///   running picture simply stops), so the switch the system settings write
///   is read instead;
/// - no picture: another app holding the camera does not make opening fail —
///   the picture just never comes, or stops. Only waiting for frames tells.
library;

import 'dart:async';
import 'dart:io' show Platform, Process;
import 'dart:math' as math;

import 'package:PiliPlus/utils/permission_handler.dart' show openAppSettings;
import 'package:camera/camera.dart' hide ImageFormat;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_zxing/flutter_zxing.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens the scanner; the text read, or null.
Future<String?> scanQrCode() async =>
    await Get.to<String>(() => const ScanPage());

enum _Problem { noCamera, noPermission, cannotOpen, noPicture }

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  /// For the self-test (`--scan-probe`): what the page shows, and how many
  /// frames it has had. Nothing else reads it.
  static String? debugProblem;
  static var debugFrames = 0;
  static String? debugRead;

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  CameraController? _camera;
  _Problem? _problem;
  String? _detail;
  var _decoding = false;
  var _done = false;
  DateTime? _lastFrame;
  Timer? _watch;

  /// A picture that stops for this long is not coming back by itself.
  static const _noFrameFor = Duration(seconds: 2);

  @override
  void initState() {
    super.initState();
    zx.startCameraProcessing();
    _open();
  }

  @override
  void dispose() {
    _watch?.cancel();
    _camera?.dispose();
    zx.stopCameraProcessing();
    super.dispose();
  }

  Future<void> _open() async {
    _watch?.cancel();
    final old = _camera;
    _camera = null;
    await old?.dispose();
    if (!mounted) return;
    setState(() {
      _problem = null;
      _detail = null;
    });
    final List<CameraDescription> cameras;
    try {
      cameras = await availableCameras();
    } catch (e) {
      return _fail(await _whyNotOpen(), '$e');
    }
    // an infrared camera (Windows Hello) lists as one but shows nothing
    // usable; a back camera reads codes better on a phone
    final usable = cameras
        .where((c) => !c.name.toUpperCase().contains(' IR '))
        .toList();
    if (usable.isEmpty) return _fail(_Problem.noCamera, null);
    final camera = usable.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => usable.first,
    );
    CameraController? controller;
    for (final preset in [ResolutionPreset.high, ResolutionPreset.medium]) {
      controller = CameraController(
        camera,
        preset,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.yuv420
            : ImageFormatGroup.bgra8888,
      );
      try {
        await controller.initialize();
        break;
      } on CameraException catch (e) {
        await controller.dispose();
        controller = null;
        if (e.code.startsWith('CameraAccess') ||
            e.code == 'permission_denied') {
          return _fail(_Problem.noPermission, e.description);
        }
        if (preset == ResolutionPreset.medium) {
          return _fail(await _whyNotOpen(), e.description ?? e.code);
        }
      }
    }
    if (controller == null || !mounted) {
      await controller?.dispose();
      return;
    }
    _camera = controller;
    _lastFrame = DateTime.now();
    try {
      await controller.startImageStream(_onFrame);
    } catch (e) {
      return _fail(await _whyNotOpen(), '$e');
    }
    setState(() {});
    _watch = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      final last = _lastFrame;
      if (last == null || _problem != null) return;
      if (DateTime.now().difference(last) > _noFrameFor) {
        final why = await _whyNotOpen();
        _fail(why == _Problem.noPermission ? why : _Problem.noPicture, null);
      }
    });
  }

  Future<void> _onFrame(CameraImage image) async {
    _lastFrame = DateTime.now();
    ScanPage.debugFrames++;
    if (_problem == _Problem.noPicture && mounted) {
      // the picture came back
      setState(() => _problem = null);
    }
    if (_decoding || _done) return;
    _decoding = true;
    try {
      // what the frame is and how big: without them the decoder read a
      // 0×0 luminance image and found nothing in any frame (the scan page
      // never read a code until these were given, as the plugin's own
      // reader gives them)
      final format = cameraImageFormat(image);
      if (format == ImageFormat.none) return;
      final code = await zx.processCameraImage(
        image,
        DecodeParams(
          imageFormat: format,
          width: image.width,
          height: image.height,
          tryHarder: true,
          tryRotate: true,
          tryInverted: true,
        ),
      );
      final text = code.text;
      if (code.isValid && text != null && text.isNotEmpty && !_done) {
        _done = true;
        ScanPage.debugRead = text;
        Get.back(result: text);
      }
    } catch (_) {
      // one frame that did not decode is not a problem
    } finally {
      _decoding = false;
    }
  }

  void _fail(_Problem problem, String? detail) {
    _watch?.cancel();
    ScanPage.debugProblem =
        '${problem.name}${detail == null ? '' : ': $detail'}';
    if (!mounted) return;
    setState(() {
      _problem = problem;
      _detail = detail;
    });
  }

  /// Why the camera cannot be used when the plugin does not say: on Windows
  /// the switch the system settings write (verified: turning it off there
  /// stopped the picture and made opening fail with a generic error).
  static Future<_Problem> _whyNotOpen() async {
    if (Platform.isWindows && await _windowsCameraDenied()) {
      return _Problem.noPermission;
    }
    return _Problem.cannotOpen;
  }

  static Future<bool> _windowsCameraDenied() async {
    const key =
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam';
    Future<bool> denied(String path) async {
      try {
        final result = await Process.run('reg', ['query', path, '/v', 'Value']);
        return '${result.stdout}'.contains('Deny');
      } catch (_) {
        return false;
      }
    }

    return await denied(key) || await denied('$key\\NonPackaged');
  }

  Future<void> _openSettings() async {
    if (Platform.isWindows) {
      await launchUrl(Uri.parse('ms-settings:privacy-webcam'));
    } else {
      await openAppSettings();
    }
  }

  @override
  Widget build(BuildContext context) {
    final camera = _camera;
    final problem = _problem;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('扫一扫'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: problem != null
          ? _problemView(problem)
          : camera == null || !camera.value.isInitialized
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              fit: StackFit.expand,
              children: [
                // the preview sizes itself for the orientation; wrapped in the
                // sensor's own (landscape) ratio as well it was stretched on
                // a phone held upright. Filled and cropped, as the plugin's
                // own reader shows it
                LayoutBuilder(
                  builder: (context, box) {
                    final side = math.max(box.maxWidth, box.maxHeight);
                    return ClipRect(
                      child: OverflowBox(
                        maxWidth: side,
                        maxHeight: side,
                        child: FittedBox(
                          fit: BoxFit.cover,
                          child: SizedBox(
                            width: side,
                            child: CameraPreview(camera),
                          ),
                        ),
                      ),
                    );
                  },
                ),
                Center(
                  child: Container(
                    width: 240,
                    height: 240,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white70, width: 2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                const Positioned(
                  left: 0,
                  right: 0,
                  bottom: 48,
                  child: Text(
                    '将二维码放入框内',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _problemView(_Problem problem) {
    final (title, hint) = switch (problem) {
      _Problem.noCamera => ('没有找到摄像头', '这台设备上没有可用的摄像头。'),
      _Problem.noPermission => ('没有摄像头权限', '请在系统设置中允许 LibrePili 使用摄像头，然后重试。'),
      _Problem.cannotOpen => ('无法打开摄像头', '摄像头可能正被其他应用使用，或被系统设置阻止。'),
      _Problem.noPicture => ('摄像头没有画面', '摄像头可能正被其他应用使用，关闭后重试。'),
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.videocam_off_outlined,
              color: Colors.white70,
              size: 48,
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: const TextStyle(color: Colors.white, fontSize: 18),
            ),
            const SizedBox(height: 8),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
            if (_detail != null) ...[
              const SizedBox(height: 8),
              Text(
                _detail!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ],
            const SizedBox(height: 24),
            Wrap(
              spacing: 12,
              children: [
                if (problem == _Problem.noPermission)
                  FilledButton(
                    onPressed: _openSettings,
                    child: const Text('打开系统设置'),
                  ),
                if (problem != _Problem.noCamera)
                  OutlinedButton(onPressed: _open, child: const Text('重试')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
