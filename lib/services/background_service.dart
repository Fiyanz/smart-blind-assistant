import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../core/utils/logger.dart';
import '../core/utils/platform_helper.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'supabase_service.dart';

/// Service untuk menjalankan proses di background.
///
/// Memastikan BLE listener dan workflow tetap aktif
/// meskipun layar HP terkunci atau aplikasi di-minimize.
/// Hanya aktif di mobile (Android/iOS).
///
/// Fitur:
/// - Foreground service notification (Android) agar tidak di-kill OS
/// - Auto-restart setelah reboot (via BootReceiver di AndroidManifest)
/// - WakeLock otomatis dari flutter_background_service
/// - Heartbeat monitoring
/// - Integrasi dengan notification update (status asisten)
class BackgroundService {
  static const String _tag = 'BackgroundService';

  /// Notification channel ID (harus sama dengan yang dipakai configure)
  static const String _notificationChannelId = 'sight_assist_channel';
  static const String _notificationChannelName = 'SightAssist Background';
  static const String _notificationTitle = 'SightAssist';
  static const int _notificationId = 888;

  /// Singleton instance
  static final FlutterBackgroundService _service = FlutterBackgroundService();

  /// Apakah service sudah diinisialisasi
  static bool _initialized = false;

  /// Inisialisasi dan konfigurasi background service.
  ///
  /// Harus dipanggil sekali di main() sebelum runApp().
  /// Konfigurasi meliputi:
  /// - Buat notification channel (WAJIB sebelum startForeground di Android 8+)
  /// - Android: foreground service dengan persistent notification
  /// - iOS: background fetch handler
  static Future<void> initialize() async {
    if (!PlatformHelper.isBackgroundServiceSupported) {
      AppLogger.info(_tag, 'Background service tidak didukung di platform ini');
      return;
    }

    if (_initialized) {
      AppLogger.info(_tag, 'Background service sudah diinisialisasi');
      return;
    }

    try {
      // ─── Buat Notification Channel (WAJIB sebelum start foreground service) ──
      // Tanpa ini, Android akan crash: "Bad notification for startForeground"
      if (Platform.isAndroid) {
        final flnPlugin = FlutterLocalNotificationsPlugin();
        const channel = AndroidNotificationChannel(
          _notificationChannelId,
          _notificationChannelName,
          description: 'Notifikasi untuk background service SightAssist',
          importance: Importance.high,
        );
        await flnPlugin
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()
            ?.createNotificationChannel(channel);
        AppLogger.info(_tag, 'Notification channel "$_notificationChannelId" dibuat');
      }

      // ─── Konfigurasi Background Service ───────────────────────
      await _service.configure(
        androidConfiguration: AndroidConfiguration(
          onStart: _onStart,
          autoStart: false, // TIDAK auto-start — dimulai dari HomeScreen setelah permission OK
          autoStartOnBoot: true, // Auto-start setelah reboot (permission sudah granted)
          isForegroundMode: true, // Foreground = persistent, tidak di-kill OS
          notificationChannelId: _notificationChannelId,
          initialNotificationTitle: _notificationTitle,
          initialNotificationContent: 'Sistem aktif — siap membantu',
          foregroundServiceNotificationId: _notificationId,
        ),
        iosConfiguration: IosConfiguration(
          autoStart: false,
          onForeground: _onStart,
          onBackground: _onIosBackground,
        ),
      );

      _initialized = true;
      AppLogger.info(_tag, 'Background service berhasil dikonfigurasi');
    } catch (e) {
      AppLogger.error(_tag, 'Gagal mengkonfigurasi background service', e);
    }
  }

  /// Entry point saat service dimulai (Android & iOS foreground).
  ///
  /// Berjalan di isolate terpisah. Setup:
  /// - DartPluginRegistrant untuk akses plugin
  /// - Listener 'stop' untuk graceful shutdown
  /// - Listener 'updateNotification' untuk update notifikasi dari app
  /// - Heartbeat periodik untuk monitoring
  @pragma('vm:entry-point')
  static Future<void> _onStart(ServiceInstance service) async {
    DartPluginRegistrant.ensureInitialized();

    // Inisialisasi env dan Supabase untuk isolate background
    try {
      await dotenv.load(fileName: ".env");
      await SupabaseService.initialize();
    } catch (e) {
      debugPrint('Gagal inisialisasi Supabase di background: $e');
    }

    AppLogger.info(_tag, 'Background service dimulai (isolate)');

    // ─── Stop Listener ──────────────────────────────────────
    service.on('stop').listen((event) {
      AppLogger.info(_tag, 'Stop command diterima, menghentikan service...');
      service.stopSelf();
    });

    // ─── Notification Update Listener ──────────────────────
    // Menerima update dari main app untuk mengubah konten notifikasi
    service.on('updateNotification').listen((event) {
      if (service is AndroidServiceInstance) {
        final title = event?['title'] as String? ?? _notificationTitle;
        final content = event?['content'] as String? ?? 'Sistem aktif';
        service.setForegroundNotificationInfo(
          title: title,
          content: content,
        );
      }
    });

    // ─── Set as Foreground (Android) ────────────────────────
    if (service is AndroidServiceInstance) {
      service.setAsForegroundService();
      service.setForegroundNotificationInfo(
        title: _notificationTitle,
        content: 'Sistem aktif — siap membantu',
      );
    }

    // ─── Heartbeat Periodik ─────────────────────────────────
    // Mengirim sinyal setiap 30 detik untuk monitoring
    Timer.periodic(const Duration(seconds: 30), (timer) {
      if (service is AndroidServiceInstance) {
        // Pastikan tetap foreground
        service.setAsForegroundService();
      }

      service.invoke('heartbeat', {
        'timestamp': DateTime.now().toIso8601String(),
        'uptime_minutes': timer.tick ~/ 2,
      });
    });
  }

  /// Entry point untuk iOS background.
  @pragma('vm:entry-point')
  static Future<bool> _onIosBackground(ServiceInstance service) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    return true;
  }

  // ─── Public API ──────────────────────────────────────────

  /// Mulai background service.
  ///
  /// Dipanggil dari app setelah initialize().
  /// Aman dipanggil berulang (cek isRunning dulu).
  static Future<void> start() async {
    if (!PlatformHelper.isBackgroundServiceSupported) {
      AppLogger.info(_tag, 'Background service tidak didukung di platform ini');
      return;
    }

    if (!_initialized) {
      AppLogger.warning(_tag, 'Service belum diinisialisasi! Panggil initialize() dulu');
      await initialize();
    }

    final running = await _service.isRunning();
    if (running) {
      AppLogger.info(_tag, 'Background service sudah berjalan');
      return;
    }

    await _service.startService();
    AppLogger.info(_tag, 'Background service dimulai');
  }

  /// Hentikan background service.
  static Future<void> stop() async {
    if (!PlatformHelper.isBackgroundServiceSupported) return;

    final running = await _service.isRunning();
    if (!running) {
      AppLogger.info(_tag, 'Background service sudah mati');
      return;
    }

    _service.invoke('stop');
    AppLogger.info(_tag, 'Background service dihentikan');
  }

  /// Cek apakah service sedang berjalan.
  static Future<bool> isRunning() async {
    if (!PlatformHelper.isBackgroundServiceSupported) return false;
    return await _service.isRunning();
  }

  /// Update notifikasi foreground (dari main app).
  ///
  /// Digunakan untuk menampilkan status asisten di notifikasi:
  /// - Mode aktif (Asisten / Autopilot / Obrolan)
  /// - Status saat ini (Mendengarkan, Memproses, dll.)
  /// - BLE connection status
  static void updateNotification({
    String? title,
    required String content,
  }) {
    if (!PlatformHelper.isBackgroundServiceSupported) return;
    if (!Platform.isAndroid) return;

    _service.invoke('updateNotification', {
      'title': title ?? _notificationTitle,
      'content': content,
    });
  }

  /// Dengarkan heartbeat dari service (untuk monitoring di UI).
  static Stream<Map<String, dynamic>?> get onHeartbeat {
    return _service.on('heartbeat');
  }

  /// Pastikan service berjalan, start jika belum.
  ///
  /// Dipanggil dari HomeScreen saat app resume atau BLE connect.
  /// Aman dipanggil kapan saja.
  static Future<void> ensureRunning() async {
    if (!PlatformHelper.isBackgroundServiceSupported) return;

    final running = await isRunning();
    if (!running) {
      AppLogger.warning(_tag, 'Service mati, me-restart...');
      await start();
    }
  }
}
