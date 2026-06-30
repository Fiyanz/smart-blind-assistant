import 'dart:io';

import 'package:camera/camera.dart';
import 'package:path_provider/path_provider.dart';

import '../core/utils/logger.dart';

/// Service untuk mengelola kamera perangkat.
///
/// Menginisialisasi kamera dan mengambil satu frame
/// saat trigger diterima dari ESP32 atau tombol manual.
class CameraService {
  static const String _tag = 'CameraService';

  CameraController? _controller;
  List<CameraDescription>? _cameras;

  /// Apakah kamera sudah diinisialisasi
  bool get isInitialized => _controller?.value.isInitialized ?? false;

  /// Getter untuk controller (dipakai oleh UI untuk preview kamera)
  CameraController? get controller => _controller;

  // ─── Initialize ────────────────────────────────────────────

  /// Inisialisasi kamera dengan resolusi medium.
  Future<bool> initialize() async {
    try {
      _cameras = await availableCameras();

      if (_cameras == null || _cameras!.isEmpty) {
        AppLogger.error(_tag, 'Tidak ada kamera tersedia');
        return false;
      }

      // Pilih kamera belakang (atau kamera pertama di desktop)
      final backCamera = _cameras!.firstWhere(
        (cam) => cam.lensDirection == CameraLensDirection.back,
        orElse: () => _cameras!.first,
      );

      _controller = CameraController(
        backCamera,
        ResolutionPreset.medium,
        enableAudio: false,
      );

      await _controller!.initialize();
      AppLogger.info(_tag, 'Kamera diinisialisasi: ${backCamera.name}');

      return true;
    } catch (e) {
      AppLogger.error(_tag, 'Gagal inisialisasi kamera', e);
      return false;
    }
  }

  // ─── Capture ───────────────────────────────────────────────

  /// Ambil satu frame gambar dari kamera.
  ///
  /// Mengembalikan path file gambar yang disimpan di temp directory,
  /// atau `null` jika gagal.
  Future<String?> captureFrame() async {
    if (_controller == null || !_controller!.value.isInitialized) {
      AppLogger.warning(_tag, 'Kamera belum siap, mencoba inisialisasi ulang...');
      final success = await initialize();
      if (!success) {
        AppLogger.error(_tag, 'Kamera gagal diinisialisasi ulang');
        return null;
      }
      // Beri sedikit jeda agar sensor kamera siap
      await Future.delayed(const Duration(milliseconds: 500));
    }

    try {
      return await _takeAndSavePicture();
    } catch (e) {
      AppLogger.error(_tag, 'Gagal mengambil gambar (kemungkinan layar mati/background), mencoba re-init...', e);
      
      // Jika gagal (sering terjadi di Android saat layar mati karena plugin menutup kamera),
      // kita coba inisialisasi ulang sekali lagi dan ambil gambar.
      final success = await initialize();
      if (success) {
        await Future.delayed(const Duration(milliseconds: 500));
        try {
          return await _takeAndSavePicture();
        } catch (e2) {
          AppLogger.error(_tag, 'Gagal mengambil gambar setelah re-init', e2);
          return null;
        }
      }
      return null;
    }
  }

  Future<String?> _takeAndSavePicture() async {
    // Ambil gambar
    final XFile image = await _controller!.takePicture();

    // Pindahkan ke temp directory dengan nama unik
    final tempDir = await getTemporaryDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final targetPath = '${tempDir.path}/sight_capture_$timestamp.jpg';

    final File targetFile = File(image.path);
    await targetFile.copy(targetPath);

    AppLogger.info(_tag, 'Gambar disimpan: $targetPath');
    return targetPath;
  }

  // ─── Dispose ───────────────────────────────────────────────

  /// Bebaskan resource kamera.
  Future<void> dispose() async {
    await _controller?.dispose();
    _controller = null;
    AppLogger.info(_tag, 'Kamera disposed');
  }
}


