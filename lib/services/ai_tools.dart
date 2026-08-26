import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;

import '../core/utils/logger.dart';
import '../core/utils/time_utils.dart';
import '../services/location_service.dart';

/// Definisi dan eksekutor function calling tools untuk AI Sinar.
///
/// Menyediakan deklarasi tools dalam format Gemini API dan
/// eksekusi lokal saat AI memutuskan untuk memanggil tool.
class AiToolsService {
  static const String _tag = 'AiToolsService';

  /// Referensi ke LocationService untuk akses GPS
  final LocationService locationService;

  /// Callback untuk mengubah kecepatan TTS
  final Future<void> Function(double speed)? onSetTtsSpeed;

  /// Callback untuk mengganti mode asisten
  final void Function(String mode)? onSwitchMode;

  /// Callback untuk capture + scan obstacles (return deskripsi AI)
  final Future<String> Function()? onScanObstacles;

  /// Callback untuk capture + OCR (return teks terbaca)
  final Future<String> Function()? onReadText;

  /// Callback untuk capture + identifikasi uang (return nominal)
  final Future<String> Function()? onIdentifyMoney;

  AiToolsService({
    required this.locationService,
    this.onSetTtsSpeed,
    this.onSwitchMode,
    this.onScanObstacles,
    this.onReadText,
    this.onIdentifyMoney,
  });

  // ─── Tool Declarations (OpenAI / OpenRouter format) ──────

  /// Daftar semua tool declarations untuk dikirim ke OpenRouter API.
  ///
  /// Format sesuai standar JSON Schema function calling OpenAI/OpenRouter.
  List<Map<String, dynamic>> getToolDeclarations() {
    return [
      {
        'type': 'function',
        'function': {
          'name': 'get_current_time',
          'description':
              'Ambil waktu, hari, dan tanggal saat ini dalam zona waktu WIB (Indonesia). '
                  'Panggil tool ini jika pengguna bertanya tentang jam, waktu, hari, atau tanggal.',
          'parameters': {
            'type': 'object',
            'properties': {},
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'get_current_location',
          'description':
              'Ambil posisi GPS saat ini dan alamat lengkap pengguna melalui reverse geocoding. '
                  'Panggil tool ini jika pengguna bertanya "saya di mana?", "ini jalan apa?", atau membutuhkan konteks lokasi.',
          'parameters': {
            'type': 'object',
            'properties': {},
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'get_nearby_places',
          'description':
              'Cari tempat-tempat terdekat (masjid, ATM, minimarket, rumah sakit, restoran, SPBU, dll) '
                  'dari posisi GPS pengguna saat ini menggunakan data OpenStreetMap. '
                  'Panggil tool ini jika pengguna bertanya "masjid terdekat?", "ada ATM di dekat sini?", atau mencari tempat.',
          'parameters': {
            'type': 'object',
            'properties': {
              'category': {
                'type': 'string',
                'description':
                    'Kategori tempat yang dicari (opsional). Contoh: masjid, ATM, minimarket, rumah sakit, restoran, apotek, SPBU, bank, kafe, sekolah. Kosongkan untuk semua kategori.',
              },
            },
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'get_weather',
          'description':
              'Ambil informasi cuaca saat ini (suhu, kondisi langit, kelembapan, kecepatan angin) '
                  'berdasarkan lokasi GPS pengguna. Panggil tool ini jika pengguna bertanya "cuaca hari ini?", "mau hujan gak?", atau "panas gak?".',
          'parameters': {
            'type': 'object',
            'properties': {},
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'set_tts_speed',
          'description':
              'Ubah kecepatan bicara asisten (text-to-speech). '
                  'Panggil tool ini jika pengguna minta "bicara lebih cepat", "pelankan suaranya", atau "kecepatan normal".',
          'parameters': {
            'type': 'object',
            'properties': {
              'speed': {
                'type': 'string',
                'description':
                    'Kecepatan baru: "lambat" (0.3), "normal" (0.5), "cepat" (0.7), "sangat_cepat" (0.9)',
                'enum': ['lambat', 'normal', 'cepat', 'sangat_cepat'],
              },
            },
            'required': ['speed'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'scan_obstacles',
          'description':
              'Aktifkan kamera dan scan gambar untuk mendeteksi penghalang/rintangan di depan pengguna. '
                  'Panggil tool ini jika pengguna bertanya "ada apa di depan?", "cek penghalang", "ada rintangan?", atau "awas".',
          'parameters': {
            'type': 'object',
            'properties': {},
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'read_text_from_image',
          'description':
              'Aktifkan kamera dan bacakan SEMUA teks/tulisan yang terlihat di depan pengguna (OCR). '
                  'Panggil tool ini jika pengguna minta "bacakan tulisan itu", "baca label", "apa yang tertulis?", atau "baca papan nama".',
          'parameters': {
            'type': 'object',
            'properties': {},
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'identify_money',
          'description':
              'Aktifkan kamera dan identifikasi nominal uang yang dipegang pengguna. '
                  'Panggil tool ini jika pengguna bertanya "uang berapa ini?", "ini uang apa?", atau "nominal berapa?".',
          'parameters': {
            'type': 'object',
            'properties': {},
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'open_gps',
          'description':
              'Buka pengaturan lokasi/GPS di HP atau aktifkan/cek status GPS jika pengguna minta "buka GPS", "nyalakan lokasi", "aktifkan GPS", atau "cek GPS".',
          'parameters': {
            'type': 'object',
            'properties': {},
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'switch_mode',
          'description':
              'Ganti mode operasi asisten. Mode tersedia: "asisten" (tanya-jawab visual), "autopilot" (pantau jalan otomatis), "obrolan" (ngobrol bebas tanpa gambar). '
                  'Panggil tool ini jika pengguna minta "ganti ke mode autopilot", "mode obrolan", atau "kembali ke mode asisten".',
          'parameters': {
            'type': 'object',
            'properties': {
              'mode': {
                'type': 'string',
                'description': 'Mode tujuan: asisten, autopilot, atau obrolan',
                'enum': ['asisten', 'autopilot', 'obrolan'],
              },
            },
            'required': ['mode'],
          },
        },
      },
    ];
  }

  // ─── Tool Executors ────────────────────────────────────────

  /// Eksekusi tool berdasarkan nama dan argumen yang diberikan AI.
  ///
  /// Return Map hasil eksekusi yang akan dikirim kembali ke AI
  /// sebagai tool response.
  Future<Map<String, dynamic>> executeTool(
      String toolName, Map<String, dynamic> args) async {
    AppLogger.info(_tag, 'Executing tool: $toolName with args: $args');

    try {
      switch (toolName) {
        case 'open_gps':
          return await _executeOpenGps();

        case 'get_current_time':
          return _executeGetCurrentTime();

        case 'get_current_location':
          return await _executeGetCurrentLocation();

        case 'get_nearby_places':
          return await _executeGetNearbyPlaces(
              args['category'] as String? ?? '');

        case 'get_weather':
          return await _executeGetWeather();

        case 'set_tts_speed':
          return await _executeSetTtsSpeed(args['speed'] as String? ?? 'normal');

        case 'scan_obstacles':
          return await _executeScanObstacles();

        case 'read_text_from_image':
          return await _executeReadText();

        case 'identify_money':
          return await _executeIdentifyMoney();

        case 'switch_mode':
          return _executeSwitchMode(args['mode'] as String? ?? 'asisten');

        default:
          return {'error': 'Tool "$toolName" tidak dikenali'};
      }
    } catch (e) {
      AppLogger.error(_tag, 'Error executing tool $toolName', e);
      return {'error': 'Gagal menjalankan $toolName: $e'};
    }
  }

  // ─── Individual Tool Implementations ───────────────────────

  Future<Map<String, dynamic>> _executeOpenGps() async {
    try {
      final isEnabled = await locationService.isLocationServiceEnabled();
      final opened = await locationService.openLocationSettings();
      final pos = await locationService.getCurrentPosition();
      return {
        'status_gps': isEnabled ? 'aktif' : 'tidak_aktif',
        'pengaturan_dibuka': opened,
        'posisi_tersedia': pos != null,
        'pesan': isEnabled
            ? 'Layanan lokasi sudah aktif.'
            : 'Membuka layar pengaturan GPS di perangkat pengguna.',
      };
    } catch (e) {
      return {'error': 'Gagal membuka GPS: $e'};
    }
  }

  Map<String, dynamic> _executeGetCurrentTime() {
    final now = TimeUtils.getWibTime();
    String dayName;
    String dateFull;
    String timeFull;
    try {
      dayName = DateFormat('EEEE', 'id_ID').format(now);
      dateFull = DateFormat('d MMMM yyyy', 'id_ID').format(now);
      timeFull = DateFormat('HH:mm', 'id_ID').format(now);
    } catch (_) {
      dayName = DateFormat('EEEE').format(now);
      dateFull = DateFormat('d MMMM yyyy').format(now);
      timeFull = DateFormat('HH:mm').format(now);
    }

    final hour = now.hour;
    final String periode;
    if (hour >= 3 && hour < 11) {
      periode = 'pagi';
    } else if (hour >= 11 && hour < 15) {
      periode = 'siang';
    } else if (hour >= 15 && hour < 18) {
      periode = 'sore';
    } else {
      periode = 'malam';
    }

    return {
      'hari': dayName,
      'tanggal': dateFull,
      'waktu': '$timeFull WIB',
      'periode': periode,
    };
  }

  Future<Map<String, dynamic>> _executeGetCurrentLocation() async {
    final position = await locationService.getCurrentPosition();
    if (position == null) {
      return {'error': 'Tidak bisa mendapatkan lokasi GPS'};
    }

    final placemark =
        await locationService.getPlacemarkFromPosition(position);

    final result = <String, dynamic>{
      'latitude': position.latitude,
      'longitude': position.longitude,
      'akurasi_meter': position.accuracy.toStringAsFixed(1),
    };

    if (placemark != null) {
      final parts = <String>[];
      if (placemark.street?.isNotEmpty == true) parts.add(placemark.street!);
      if (placemark.subLocality?.isNotEmpty == true) {
        parts.add(placemark.subLocality!);
      }
      if (placemark.locality?.isNotEmpty == true) {
        parts.add(placemark.locality!);
      }
      if (placemark.subAdministrativeArea?.isNotEmpty == true) {
        parts.add(placemark.subAdministrativeArea!);
      }
      if (placemark.administrativeArea?.isNotEmpty == true) {
        parts.add(placemark.administrativeArea!);
      }
      result['alamat'] = parts.join(', ');
    }

    return result;
  }

  Future<Map<String, dynamic>> _executeGetNearbyPlaces(
      String category) async {
    final position = await locationService.getCurrentPosition();
    if (position == null) {
      return {'error': 'Tidak bisa mendapatkan lokasi GPS untuk mencari tempat'};
    }

    final places = await locationService.fetchNearbyPlaces(
        position.latitude, position.longitude);

    if (places.isEmpty) {
      return {'pesan': 'Tidak ditemukan tempat terdekat dari posisi saat ini'};
    }

    // Filter berdasarkan kategori jika diberikan
    final filtered = category.isEmpty
        ? places
        : places
            .where((p) =>
                p.category.toLowerCase().contains(category.toLowerCase()) ||
                p.name.toLowerCase().contains(category.toLowerCase()))
            .toList();

    if (filtered.isEmpty) {
      return {
        'pesan': 'Tidak ditemukan "$category" di sekitar posisi saat ini',
        'semua_tempat': places
            .take(5)
            .map((p) => '${p.name} (${p.category}) — ${p.formattedDistance}')
            .toList(),
      };
    }

    return {
      'tempat_ditemukan': filtered
          .take(10)
          .map((p) => {
                'nama': p.name,
                'kategori': p.category,
                'jarak': p.formattedDistance,
              })
          .toList(),
    };
  }

  Future<Map<String, dynamic>> _executeGetWeather() async {
    final position = await locationService.getCurrentPosition();
    if (position == null) {
      return {'error': 'Tidak bisa mendapatkan lokasi GPS untuk cek cuaca'};
    }

    try {
      // Gunakan Open-Meteo API (gratis, tanpa API key)
      final url = Uri.parse(
          'https://api.open-meteo.com/v1/forecast'
          '?latitude=${position.latitude}'
          '&longitude=${position.longitude}'
          '&current=temperature_2m,relative_humidity_2m,weather_code,wind_speed_10m'
          '&timezone=Asia/Jakarta');

      final response =
          await http.get(url).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        return {'error': 'Gagal mengambil data cuaca'};
      }

      final json = jsonDecode(response.body);
      final current = json['current'] as Map<String, dynamic>?;

      if (current == null) {
        return {'error': 'Data cuaca tidak tersedia'};
      }

      final weatherCode = current['weather_code'] as int? ?? 0;

      return {
        'suhu_celcius': current['temperature_2m'],
        'kelembapan_persen': current['relative_humidity_2m'],
        'kecepatan_angin_kmjam': current['wind_speed_10m'],
        'kondisi': _weatherCodeToDescription(weatherCode),
      };
    } catch (e) {
      AppLogger.error(_tag, 'Gagal mengambil cuaca', e);
      return {'error': 'Gagal mengambil data cuaca: $e'};
    }
  }

  String _weatherCodeToDescription(int code) {
    // WMO Weather interpretation codes
    if (code == 0) return 'cerah';
    if (code <= 3) return 'berawan sebagian';
    if (code <= 48) return 'berkabut';
    if (code <= 57) return 'gerimis';
    if (code <= 67) return 'hujan';
    if (code <= 77) return 'hujan salju';
    if (code <= 82) return 'hujan deras';
    if (code <= 86) return 'hujan salju lebat';
    if (code >= 95) return 'badai petir';
    return 'tidak diketahui';
  }

  Future<Map<String, dynamic>> _executeSetTtsSpeed(String speed) async {
    final speedMap = {
      'lambat': 0.3,
      'normal': 0.5,
      'cepat': 0.7,
      'sangat_cepat': 0.9,
    };

    final value = speedMap[speed] ?? 0.5;

    if (onSetTtsSpeed != null) {
      await onSetTtsSpeed!(value);
      return {
        'berhasil': true,
        'kecepatan_baru': speed,
        'nilai': value,
      };
    }

    return {'error': 'Pengaturan kecepatan bicara tidak tersedia'};
  }

  Future<Map<String, dynamic>> _executeScanObstacles() async {
    if (onScanObstacles != null) {
      try {
        // Berikan haptic feedback bahwa scanning dimulai
        try {
          HapticFeedback.mediumImpact();
        } catch (_) {}

        final result = await onScanObstacles!();
        return {'hasil_scan': result};
      } catch (e) {
        return {'error': 'Gagal scan penghalang: $e'};
      }
    }
    return {'error': 'Fitur scan penghalang tidak tersedia'};
  }

  Future<Map<String, dynamic>> _executeReadText() async {
    if (onReadText != null) {
      try {
        final result = await onReadText!();
        return {'teks_terbaca': result};
      } catch (e) {
        return {'error': 'Gagal membaca teks: $e'};
      }
    }
    return {'error': 'Fitur baca teks tidak tersedia'};
  }

  Future<Map<String, dynamic>> _executeIdentifyMoney() async {
    if (onIdentifyMoney != null) {
      try {
        final result = await onIdentifyMoney!();
        return {'identifikasi_uang': result};
      } catch (e) {
        return {'error': 'Gagal identifikasi uang: $e'};
      }
    }
    return {'error': 'Fitur identifikasi uang tidak tersedia'};
  }

  Map<String, dynamic> _executeSwitchMode(String mode) {
    if (onSwitchMode != null) {
      onSwitchMode!(mode);
      return {
        'berhasil': true,
        'mode_baru': mode,
      };
    }
    return {'error': 'Tidak bisa mengganti mode'};
  }
}
