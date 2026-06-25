import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../core/constants/app_constants.dart';
import '../core/utils/logger.dart';
import '../core/utils/platform_helper.dart';
import '../models/ble_device.dart';

/// Service untuk komunikasi Bluetooth Low Energy (BLE) dengan ESP32.
///
/// Mengelola scanning, koneksi, dan mendengarkan notifikasi
/// trigger dari tombol fisik ESP32.
/// Hanya aktif di mobile (Android/iOS).
class BleService {
  static const String _tag = 'BleService';

  BluetoothDevice? _connectedDevice;
  StreamSubscription<List<int>>? _notificationSubscription;

  /// Stream controller untuk trigger events dari ESP32
  final StreamController<int> _triggerController =
      StreamController<int>.broadcast();

  /// Stream yang di-listen oleh provider untuk menerima trigger events
  Stream<int> get triggerStream => _triggerController.stream;

  /// Apakah sedang terhubung ke perangkat
  bool get isConnected => _connectedDevice != null;

  // ─── Scan ──────────────────────────────────────────────────

  /// Cek apakah Bluetooth adapter ON dan siap digunakan.
  /// Mengembalikan true jika adapter sudah ON.
  Future<bool> isAdapterOn() async {
    if (!PlatformHelper.isBleSupported) return false;

    try {
      final state = await FlutterBluePlus.adapterState.first;
      AppLogger.info(_tag, 'Adapter state: $state');
      return state == BluetoothAdapterState.on;
    } catch (e) {
      AppLogger.error(_tag, 'Gagal cek adapter state', e);
      return false;
    }
  }

  /// Request user untuk menyalakan Bluetooth (Android only).
  Future<void> turnOnBluetooth() async {
    if (!PlatformHelper.isBleSupported) return;
    try {
      await FlutterBluePlus.turnOn();
      AppLogger.info(_tag, 'Request turn on Bluetooth');
    } catch (e) {
      AppLogger.error(_tag, 'Gagal turn on Bluetooth', e);
    }
  }

  /// Mulai scan perangkat BLE di sekitar.
  ///
  /// Mengembalikan stream dari perangkat yang ditemukan.
  /// Sebelum memanggil ini, pastikan adapter sudah ON via [isAdapterOn].
  Stream<List<BleDevice>> startScan() {
    if (!PlatformHelper.isBleSupported) {
      AppLogger.warning(_tag, 'BLE tidak didukung di platform ini');
      return Stream.value([]);
    }

    AppLogger.info(_tag, 'Mulai scanning BLE...');

    // Set log level verbose untuk debugging
    FlutterBluePlus.setLogLevel(LogLevel.verbose);

    // Pastikan scan sebelumnya dihentikan dulu (fire-and-forget OK karena
    // startScan akan menunggu internal lock)
    FlutterBluePlus.stopScan();

    // Mulai scan dengan konfigurasi optimal:
    // - androidScanMode: lowLatency → scan lebih agresif, device lebih cepat muncul
    // - TANPA withServices → semua device muncul (tidak filter by service UUID)
    // - TANPA androidUsesFineLocation → kompatibel dengan neverForLocation di manifest
    // - removeIfGone → hapus device yang hilang setelah 5 detik
    // - continuousUpdates & continuousDivisor → update stream real-time
    FlutterBluePlus.startScan(
      timeout: Duration(seconds: AppConstants.bleScanTimeoutSeconds),
      androidScanMode: AndroidScanMode.lowLatency,
      removeIfGone: const Duration(seconds: 5),
      continuousUpdates: true,
      continuousDivisor: 1,
    );

    return FlutterBluePlus.onScanResults.map((results) {
      AppLogger.info(
          _tag, 'scanResults: ${results.length} raw results');

      final devices = <BleDevice>[];
      for (final r in results) {
        // Ambil nama dari platformName atau advName
        final name = r.device.platformName.isNotEmpty
            ? r.device.platformName
            : r.advertisementData.advName.isNotEmpty
                ? r.advertisementData.advName
                : '';

        // Cek apakah device advertise service UUID SightAssist
        final hasSightAssistService = r.advertisementData.serviceUuids
            .any((uuid) =>
                uuid.str.toLowerCase() ==
                AppConstants.bleServiceUuid.toLowerCase());

        // Tampilkan device yang punya nama ATAU advertise SightAssist service
        if (name.isNotEmpty || hasSightAssistService) {
          final displayName =
              name.isNotEmpty ? name : 'Unknown (${r.device.remoteId.str})';
          AppLogger.info(
              _tag,
              'Device: $displayName, RSSI: ${r.rssi}, '
              'Services: ${r.advertisementData.serviceUuids}');
          devices.add(BleDevice(
            name: displayName,
            id: r.device.remoteId.str,
            rssi: r.rssi,
          ));
        }
      }

      AppLogger.info(_tag, '${devices.length} perangkat ditampilkan');
      return devices;
    });
  }

  /// Hentikan scan BLE.
  Future<void> stopScan() async {
    if (!PlatformHelper.isBleSupported) return;
    await FlutterBluePlus.stopScan();
    AppLogger.info(_tag, 'Scan dihentikan');
  }

  // ─── Connect ───────────────────────────────────────────────

  /// Hubungkan ke perangkat BLE berdasarkan device ID.
  /// Jika autoConnect = true, OS akan mencoba auto-reconnect saat perangkat nyala/masuk range.
  Future<bool> connect(String deviceId, {bool autoConnect = false}) async {
    if (!PlatformHelper.isBleSupported) {
      AppLogger.warning(_tag, 'BLE tidak didukung di platform ini');
      return false;
    }

    try {
      AppLogger.info(_tag, 'Menghubungkan ke $deviceId... (autoConnect: $autoConnect)');

      final device = BluetoothDevice.fromId(deviceId);
      await device.connect(timeout: const Duration(seconds: 10), autoConnect: autoConnect);

      _connectedDevice = device;
      AppLogger.info(_tag, 'Terhubung ke ${device.platformName}');

      // Discover services & subscribe ke trigger characteristic
      await _discoverAndSubscribe();

      return true;
    } catch (e) {
      AppLogger.error(_tag, 'Gagal menghubungkan ke $deviceId', e);
      return false;
    }
  }

  /// Discover BLE services dan subscribe ke characteristic trigger.
  Future<void> _discoverAndSubscribe() async {
    if (_connectedDevice == null) return;

    final services = await _connectedDevice!.discoverServices();

    for (final service in services) {
      if (service.uuid.str.toLowerCase() ==
          AppConstants.bleServiceUuid.toLowerCase()) {
        AppLogger.info(_tag, 'Service ditemukan: ${service.uuid}');

        for (final char in service.characteristics) {
          if (char.uuid.str.toLowerCase() ==
              AppConstants.bleTriggerCharUuid.toLowerCase()) {
            AppLogger.info(_tag, 'Characteristic ditemukan: ${char.uuid}');

            // Subscribe ke notifikasi
            await char.setNotifyValue(true);
            _notificationSubscription = char.onValueReceived.listen((value) {
              AppLogger.info(_tag, 'Trigger diterima: $value');
              if (value.isNotEmpty) {
                _triggerController.add(value[0]);
              }
            });

            AppLogger.info(_tag, 'Subscribed ke trigger notifications');
            return;
          }
        }
      }
    }

    AppLogger.warning(_tag, 'Characteristic trigger tidak ditemukan!');
  }

  // ─── Disconnect ────────────────────────────────────────────

  /// Putuskan koneksi BLE.
  Future<void> disconnect() async {
    try {
      _notificationSubscription?.cancel();
      _notificationSubscription = null;

      await _connectedDevice?.disconnect();
      _connectedDevice = null;

      AppLogger.info(_tag, 'Koneksi diputus');
    } catch (e) {
      AppLogger.error(_tag, 'Error saat disconnect', e);
    }
  }

  /// Bersihkan resource.
  void dispose() {
    _notificationSubscription?.cancel();
    _triggerController.close();
  }
}
