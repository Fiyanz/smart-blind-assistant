import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/utils/logger.dart';
import '../core/utils/permissions_handler.dart';
import '../models/ble_device.dart';
import '../services/ble_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Provider untuk state koneksi BLE.
///
/// Mengelola scanning, daftar perangkat, koneksi aktif,
/// dan meneruskan trigger events dari ESP32.
class BleProvider extends ChangeNotifier {
  static const String _tag = 'BleProvider';

  final BleService _bleService = BleService();

  // ─── State ─────────────────────────────────────────────────

  bool _isScanning = false;
  List<BleDevice> _devices = [];
  BleDevice? _connectedDevice;
  StreamSubscription<List<BleDevice>>? _scanSubscription;

  /// Status error terakhir (untuk ditampilkan di UI)
  String? _lastError;

  /// Apakah sedang scanning
  bool get isScanning => _isScanning;

  /// Daftar perangkat BLE yang ditemukan
  List<BleDevice> get devices => _devices;

  /// Perangkat yang sedang terhubung
  BleDevice? get connectedDevice => _connectedDevice;

  /// Apakah ada perangkat yang terhubung
  bool get isConnected => _connectedDevice != null;

  /// Error terakhir
  String? get lastError => _lastError;

  /// Stream trigger dari ESP32 (dipakai oleh AssistantProvider)
  Stream<int> get triggerStream => _bleService.triggerStream;

  // ─── Scan ──────────────────────────────────────────────────

  /// Mulai scan perangkat BLE.
  /// Melakukan pengecekan adapter & permission sebelum scan.
  Future<void> startScan() async {
    _lastError = null;

    // 1. Cek permission Bluetooth
    final bleGranted = await AppPermissions.isBluetoothGranted();
    if (!bleGranted) {
      AppLogger.warning(_tag, 'Permission Bluetooth belum diberikan, meminta...');
      final granted = await AppPermissions.requestAll();
      if (!granted) {
        _lastError = 'Izin Bluetooth ditolak. Buka Pengaturan untuk mengizinkan.';
        AppLogger.error(_tag, _lastError!);
        notifyListeners();
        return;
      }
    }

    // 2. Cek adapter state (Bluetooth ON/OFF)
    final adapterOn = await _bleService.isAdapterOn();
    if (!adapterOn) {
      AppLogger.warning(_tag, 'Bluetooth adapter OFF, mencoba menyalakan...');
      await _bleService.turnOnBluetooth();

      // Tunggu sebentar lalu cek lagi
      await Future.delayed(const Duration(seconds: 2));
      final retryOn = await _bleService.isAdapterOn();
      if (!retryOn) {
        _lastError = 'Bluetooth mati. Nyalakan Bluetooth di Pengaturan.';
        AppLogger.error(_tag, _lastError!);
        notifyListeners();
        return;
      }
    }

    // 3. Cek Location permission (diperlukan BLE scan di Android ≤11)
    if (Platform.isAndroid) {
      final locationGranted = await Permission.locationWhenInUse.isGranted;
      if (!locationGranted) {
        AppLogger.warning(_tag, 'Izin Lokasi belum diberikan, meminta...');
        final result = await Permission.locationWhenInUse.request();
        if (!result.isGranted) {
          _lastError = 'Izin Lokasi ditolak. Diperlukan untuk scan Bluetooth.';
          AppLogger.error(_tag, _lastError!);
          notifyListeners();
          return;
        }
      }

      // 4. Cek apakah Location Services (GPS) aktif
      final serviceStatus = await Permission.locationWhenInUse.serviceStatus;
      if (!serviceStatus.isEnabled) {
        _lastError = 'Lokasi (GPS) mati. Nyalakan Lokasi di Pengaturan untuk scan Bluetooth.';
        AppLogger.error(_tag, _lastError!);
        notifyListeners();
        return;
      }
      AppLogger.info(_tag, 'Lokasi aktif dan izin diberikan');
    }

    // 5. Load last connected device ID
    String? lastBleId;
    try {
      final prefs = await SharedPreferences.getInstance();
      lastBleId = prefs.getString('last_ble_id');
    } catch (e) {
      AppLogger.warning(_tag, 'Gagal load last_ble_id: $e');
    }

    // 6. Mulai scan
    _isScanning = true;
    _devices = [];
    bool isAutoConnecting = false;
    notifyListeners();

    AppLogger.info(_tag, 'Semua syarat terpenuhi, mulai scanning...');

    _scanSubscription?.cancel();
    _scanSubscription = _bleService.startScan().listen(
      (foundDevices) {
        _devices = foundDevices;
        AppLogger.info(
            _tag, 'Update: ${foundDevices.length} perangkat ditemukan');
        notifyListeners();

        // Coba auto-connect jika id cocok
        if (lastBleId != null && !isAutoConnecting) {
          try {
            final target = foundDevices.firstWhere((d) => d.id == lastBleId);
            isAutoConnecting = true;
            AppLogger.info(_tag, 'Menemukan perangkat sebelumnya (${target.name}), mencoba auto-connect...');
            stopScan().then((_) {
              connectToDevice(target);
            });
          } catch (e) {
            // Device belum ada di batch ini
          }
        }
      },
      onError: (error) {
        AppLogger.error(_tag, 'Error saat scanning', error);
        _lastError = 'Error scanning: $error';
        _isScanning = false;
        notifyListeners();
      },
      onDone: () {
        AppLogger.info(_tag, 'Scan stream selesai');
        _isScanning = false;
        notifyListeners();
      },
    );

    // Auto-stop setelah timeout
    Future.delayed(const Duration(seconds: 12), () {
      if (_isScanning) stopScan();
    });

    AppLogger.info(_tag, 'Scanning dimulai');
  }

  /// Hentikan scan BLE.
  Future<void> stopScan() async {
    _isScanning = false;
    _scanSubscription?.cancel();
    _scanSubscription = null;
    await _bleService.stopScan();
    notifyListeners();

    AppLogger.info(_tag, 'Scanning dihentikan, ${_devices.length} perangkat ditemukan');
  }

  // ─── Connect ───────────────────────────────────────────────

  /// Mencoba auto-connect ke perangkat terakhir yang terhubung saat aplikasi dibuka.
  Future<void> autoConnectToLastDevice() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastBleId = prefs.getString('last_ble_id');

      if (lastBleId != null && lastBleId.isNotEmpty) {
        AppLogger.info(_tag, 'Mencoba auto-connect ke perangkat terakhir: $lastBleId');
        
        // Buat dummy BleDevice dengan nama 'SightAssist (Auto)'
        final dummyDevice = BleDevice(
          id: lastBleId,
          name: 'SightAssist (Auto)',
          rssi: 0,
        );
        
        // Panggil connectToDevice, service akan handle dengan autoConnect: true
        await connectToDevice(dummyDevice, autoConnect: true);
      }
    } catch (e) {
      AppLogger.warning(_tag, 'Gagal melakukan auto-connect: $e');
    }
  }

  /// Hubungkan ke perangkat BLE.
  Future<bool> connectToDevice(BleDevice device, {bool autoConnect = false}) async {
    final success = await _bleService.connect(device.id, autoConnect: autoConnect);

    if (success) {
      _connectedDevice = device.copyWith(isConnected: true);
      AppLogger.info(_tag, 'Terhubung ke ${device.name}');
      
      // Simpan device id untuk auto-connect selanjutnya
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('last_ble_id', device.id);
      } catch (e) {
        AppLogger.error(_tag, 'Gagal menyimpan last_ble_id', e);
      }
    } else {
      AppLogger.error(_tag, 'Gagal terhubung ke ${device.name}');
    }

    notifyListeners();
    return success;
  }

  /// Putuskan koneksi.
  Future<void> disconnect() async {
    await _bleService.disconnect();
    _connectedDevice = null;
    
    // Jangan hapus last_ble_id agar bisa auto-reconnect saat app dibuka lagi,
    // kecuali jika user secara eksplisit "Forget Device" (belum ada fitur ini).
    notifyListeners();
    AppLogger.info(_tag, 'Koneksi diputus');
  }

  // ─── Dispose ───────────────────────────────────────────────

  @override
  void dispose() {
    _scanSubscription?.cancel();
    _bleService.dispose();
    super.dispose();
  }
}
