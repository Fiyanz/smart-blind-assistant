import 'dart:convert';
import 'dart:math';

import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:http/http.dart' as http;

import '../core/utils/logger.dart';

/// Service untuk mengelola akses lokasi GPS dan pencarian tempat terdekat.
///
/// Digunakan oleh mode Navigasi untuk mengetahui posisi pengguna
/// secara akurat dan mengkonversi koordinat ke alamat yang bisa dibaca.
/// Juga mencari tempat-tempat terdekat via OpenStreetMap Overpass API.
class LocationService {
  static const String _tag = 'LocationService';

  /// URL Overpass API (OpenStreetMap — gratis, tanpa API key)
  static const String _overpassUrl =
      'https://overpass-api.de/api/interpreter';

  Position? _lastPosition;
  Placemark? _lastPlacemark;

  /// Cache tempat-tempat terdekat
  List<NearbyPlace> _nearbyPlaces = [];
  DateTime? _lastPlacesFetchTime;

  /// Durasi cache tempat terdekat (5 menit)
  static const Duration _placesCacheDuration = Duration(minutes: 5);

  /// Posisi terakhir yang diketahui
  Position? get lastPosition => _lastPosition;

  /// Placemark terakhir (alamat)
  Placemark? get lastPlacemark => _lastPlacemark;

  /// Tempat-tempat terdekat yang sudah di-cache
  List<NearbyPlace> get nearbyPlaces => _nearbyPlaces;

  /// Inisialisasi dan minta izin lokasi.
  ///
  /// Return true jika lokasi tersedia dan izin diberikan.
  Future<bool> initialize() async {
    try {
      // Cek apakah layanan lokasi aktif
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        AppLogger.warning(_tag, 'Layanan lokasi tidak aktif');
        return false;
      }

      // Cek dan minta izin lokasi
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          AppLogger.warning(_tag, 'Izin lokasi ditolak');
          return false;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        AppLogger.warning(_tag, 'Izin lokasi ditolak permanen');
        return false;
      }

      AppLogger.info(_tag, 'Lokasi siap digunakan');
      return true;
    } catch (e) {
      AppLogger.error(_tag, 'Gagal inisialisasi lokasi', e);
      return false;
    }
  }

  /// Ambil posisi GPS saat ini.
  ///
  /// Menggunakan akurasi tinggi untuk navigasi.
  /// Return null jika gagal.
  Future<Position?> getCurrentPosition() async {
    try {
      _lastPosition = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
      AppLogger.info(_tag,
          'Posisi: ${_lastPosition!.latitude}, ${_lastPosition!.longitude} '
          '(akurasi: ${_lastPosition!.accuracy.toStringAsFixed(1)}m)');
      return _lastPosition;
    } catch (e) {
      AppLogger.error(_tag, 'Gagal mendapatkan posisi', e);
      return null;
    }
  }

  /// Konversi koordinat ke alamat menggunakan reverse geocoding.
  ///
  /// Return Placemark dengan info: jalan, kelurahan, kecamatan, kota, dll.
  Future<Placemark?> getPlacemarkFromPosition(Position position) async {
    try {
      final placemarks = await placemarkFromCoordinates(
        position.latitude,
        position.longitude,
      );

      if (placemarks.isNotEmpty) {
        _lastPlacemark = placemarks.first;
        AppLogger.info(_tag,
            'Alamat: ${_lastPlacemark!.street}, '
            '${_lastPlacemark!.subLocality}, '
            '${_lastPlacemark!.locality}, '
            '${_lastPlacemark!.subAdministrativeArea}');
        return _lastPlacemark;
      }

      AppLogger.warning(_tag, 'Tidak ada placemark ditemukan');
      return null;
    } catch (e) {
      AppLogger.error(_tag, 'Gagal reverse geocoding', e);
      return null;
    }
  }

  // ─── Nearby Places (OpenStreetMap Overpass API) ─────────────

  /// Cari tempat-tempat terdekat dari koordinat GPS menggunakan Overpass API.
  ///
  /// Mencari dalam radius 1km: supermarket, minimarket, masjid,
  /// rumah sakit, apotek, ATM, restoran, SPBU, dll.
  /// Hasil di-cache selama 5 menit untuk menghemat request.
  Future<List<NearbyPlace>> fetchNearbyPlaces(
      double latitude, double longitude) async {
    // Gunakan cache jika masih valid
    if (_lastPlacesFetchTime != null &&
        DateTime.now().difference(_lastPlacesFetchTime!) <
            _placesCacheDuration &&
        _nearbyPlaces.isNotEmpty) {
      AppLogger.info(
          _tag, 'Menggunakan cache tempat terdekat (${_nearbyPlaces.length})');
      return _nearbyPlaces;
    }

    try {
      AppLogger.info(_tag, 'Mencari tempat terdekat via Overpass API...');

      // Query Overpass untuk berbagai jenis tempat dalam radius 1000m
      final query = '''
[out:json][timeout:10];
(
  node["shop"="supermarket"](around:1000,$latitude,$longitude);
  node["shop"="convenience"](around:1000,$latitude,$longitude);
  node["shop"="mall"](around:1000,$latitude,$longitude);
  node["amenity"="place_of_worship"](around:1000,$latitude,$longitude);
  node["amenity"="hospital"](around:1000,$latitude,$longitude);
  node["amenity"="clinic"](around:1000,$latitude,$longitude);
  node["amenity"="pharmacy"](around:1000,$latitude,$longitude);
  node["amenity"="bank"](around:1000,$latitude,$longitude);
  node["amenity"="atm"](around:1000,$latitude,$longitude);
  node["amenity"="restaurant"](around:1000,$latitude,$longitude);
  node["amenity"="cafe"](around:1000,$latitude,$longitude);
  node["amenity"="fuel"](around:1000,$latitude,$longitude);
  node["amenity"="school"](around:1000,$latitude,$longitude);
  node["amenity"="police"](around:1000,$latitude,$longitude);
  way["shop"="supermarket"](around:1000,$latitude,$longitude);
  way["shop"="convenience"](around:1000,$latitude,$longitude);
  way["shop"="mall"](around:1000,$latitude,$longitude);
  way["amenity"="hospital"](around:1000,$latitude,$longitude);
  way["amenity"="place_of_worship"](around:1000,$latitude,$longitude);
);
out center body;
''';

      final response = await http
          .post(
            Uri.parse(_overpassUrl),
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
            body: 'data=${Uri.encodeComponent(query)}',
          )
          .timeout(const Duration(seconds: 12));

      if (response.statusCode != 200) {
        AppLogger.error(
            _tag, 'Overpass API error: ${response.statusCode}');
        return _nearbyPlaces; // Return cache lama jika ada
      }

      final json = jsonDecode(response.body);
      final elements = json['elements'] as List<dynamic>? ?? [];

      final places = <NearbyPlace>[];
      final seenNames = <String>{}; // Deduplikasi

      for (final element in elements) {
        final tags = element['tags'] as Map<String, dynamic>? ?? {};
        final name = tags['name'] as String?;
        if (name == null || name.isEmpty) continue;

        // Deduplikasi berdasarkan nama
        final nameKey = name.toLowerCase();
        if (seenNames.contains(nameKey)) continue;
        seenNames.add(nameKey);

        // Ambil koordinat (node punya lat/lon langsung, way punya center)
        double? lat;
        double? lon;
        if (element['type'] == 'node') {
          lat = (element['lat'] as num?)?.toDouble();
          lon = (element['lon'] as num?)?.toDouble();
        } else if (element['center'] != null) {
          lat = (element['center']['lat'] as num?)?.toDouble();
          lon = (element['center']['lon'] as num?)?.toDouble();
        }

        if (lat == null || lon == null) continue;

        // Hitung jarak
        final distance = _calculateDistance(latitude, longitude, lat, lon);

        // Tentukan kategori
        final category = _categorizePlace(tags);

        places.add(NearbyPlace(
          name: name,
          category: category,
          distanceMeters: distance.round(),
          latitude: lat,
          longitude: lon,
        ));
      }

      // Urutkan berdasarkan jarak
      places.sort((a, b) => a.distanceMeters.compareTo(b.distanceMeters));

      // Ambil maksimal 15 tempat terdekat
      _nearbyPlaces = places.take(15).toList();
      _lastPlacesFetchTime = DateTime.now();

      AppLogger.info(
          _tag, 'Ditemukan ${_nearbyPlaces.length} tempat terdekat');
      return _nearbyPlaces;
    } catch (e) {
      AppLogger.error(_tag, 'Gagal mencari tempat terdekat', e);
      return _nearbyPlaces; // Return cache lama jika ada
    }
  }

  /// Hitung jarak antara dua koordinat GPS (Haversine formula).
  /// Return jarak dalam meter.
  double _calculateDistance(
      double lat1, double lon1, double lat2, double lon2) {
    const earthRadius = 6371000.0; // meter
    final dLat = _toRadians(lat2 - lat1);
    final dLon = _toRadians(lon2 - lon1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_toRadians(lat1)) *
            cos(_toRadians(lat2)) *
            sin(dLon / 2) *
            sin(dLon / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthRadius * c;
  }

  double _toRadians(double degrees) => degrees * pi / 180;

  /// Kategorikan tempat berdasarkan tags OpenStreetMap.
  String _categorizePlace(Map<String, dynamic> tags) {
    final amenity = tags['amenity'] as String? ?? '';
    final shop = tags['shop'] as String? ?? '';

    if (shop == 'supermarket') return 'supermarket';
    if (shop == 'convenience') return 'minimarket';
    if (shop == 'mall') return 'mall';
    if (amenity == 'place_of_worship') {
      final religion = tags['religion'] as String? ?? '';
      if (religion == 'muslim') return 'masjid';
      if (religion == 'christian') return 'gereja';
      if (religion == 'buddhist') return 'vihara';
      if (religion == 'hindu') return 'pura';
      return 'tempat ibadah';
    }
    if (amenity == 'hospital') return 'rumah sakit';
    if (amenity == 'clinic') return 'klinik';
    if (amenity == 'pharmacy') return 'apotek';
    if (amenity == 'bank') return 'bank';
    if (amenity == 'atm') return 'ATM';
    if (amenity == 'restaurant') return 'restoran';
    if (amenity == 'cafe') return 'kafe';
    if (amenity == 'fuel') return 'SPBU';
    if (amenity == 'school') return 'sekolah';
    if (amenity == 'police') return 'kantor polisi';
    return 'tempat';
  }

  /// Format tempat-tempat terdekat menjadi string untuk prompt AI.
  ///
  /// Contoh output:
  /// ```
  /// Tempat-tempat terdekat:
  /// - Indomaret (minimarket) — sekitar 150m
  /// - Masjid Al-Ikhlas (masjid) — sekitar 300m
  /// - Apotek Kimia Farma (apotek) — sekitar 500m
  /// ```
  String formatNearbyPlaces() {
    if (_nearbyPlaces.isEmpty) return '';

    final buffer = StringBuffer();
    buffer.writeln('Tempat-tempat terdekat (data dari OpenStreetMap):');
    for (final place in _nearbyPlaces) {
      buffer.writeln(
          '- ${place.name} (${place.category}) — sekitar ${place.formattedDistance}');
    }
    return buffer.toString().trim();
  }

  // ─── Location Description ──────────────────────────────────

  /// Dapatkan deskripsi lokasi lengkap untuk prompt AI.
  ///
  /// Menggabungkan informasi GPS + reverse geocoding + tempat terdekat
  /// menjadi string deskriptif yang bisa langsung dimasukkan ke prompt.
  ///
  /// Contoh output:
  /// "Lokasi saat ini: Jalan Sudirman, Setiabudi, Jakarta Selatan.
  ///  Koordinat: -6.2088, 106.8456 (akurasi: 5.2m)
  ///  Tempat-tempat terdekat:
  ///  - Indomaret (minimarket) — sekitar 150m"
  Future<String> getLocationDescription() async {
    try {
      final position = await getCurrentPosition();
      if (position == null) {
        return 'Lokasi tidak tersedia';
      }

      final placemark = await getPlacemarkFromPosition(position);

      final buffer = StringBuffer();
      buffer.write('Lokasi saat ini: ');

      if (placemark != null) {
        // Bangun alamat dari komponen yang tersedia
        final parts = <String>[];

        if (placemark.street != null && placemark.street!.isNotEmpty) {
          parts.add(placemark.street!);
        }
        if (placemark.subLocality != null && placemark.subLocality!.isNotEmpty) {
          parts.add(placemark.subLocality!);
        }
        if (placemark.locality != null && placemark.locality!.isNotEmpty) {
          parts.add(placemark.locality!);
        }
        if (placemark.subAdministrativeArea != null &&
            placemark.subAdministrativeArea!.isNotEmpty) {
          parts.add(placemark.subAdministrativeArea!);
        }
        if (placemark.administrativeArea != null &&
            placemark.administrativeArea!.isNotEmpty) {
          parts.add(placemark.administrativeArea!);
        }

        if (parts.isNotEmpty) {
          buffer.write(parts.join(', '));
        } else {
          buffer.write('Alamat tidak diketahui');
        }
        buffer.write('. ');
      }

      buffer.write('Koordinat: '
          '${position.latitude.toStringAsFixed(6)}, '
          '${position.longitude.toStringAsFixed(6)} '
          '(akurasi: ${position.accuracy.toStringAsFixed(1)}m)');

      // Ambil tempat-tempat terdekat (non-blocking, gunakan cache jika ada)
      await fetchNearbyPlaces(position.latitude, position.longitude);
      final placesInfo = formatNearbyPlaces();
      if (placesInfo.isNotEmpty) {
        buffer.write('\n\n$placesInfo');
      }

      return buffer.toString();
    } catch (e) {
      AppLogger.error(_tag, 'Gagal mendapatkan deskripsi lokasi', e);
      return 'Lokasi tidak tersedia';
    }
  }

  /// Dapatkan deskripsi lokasi singkat untuk UI overlay.
  ///
  /// Contoh: "Jl. Sudirman, Jakarta Selatan"
  String getShortLocationLabel() {
    if (_lastPlacemark == null) return 'Menunggu lokasi...';

    final parts = <String>[];
    if (_lastPlacemark!.street != null && _lastPlacemark!.street!.isNotEmpty) {
      parts.add(_lastPlacemark!.street!);
    }
    if (_lastPlacemark!.locality != null && _lastPlacemark!.locality!.isNotEmpty) {
      parts.add(_lastPlacemark!.locality!);
    }
    if (_lastPlacemark!.subAdministrativeArea != null &&
        _lastPlacemark!.subAdministrativeArea!.isNotEmpty) {
      parts.add(_lastPlacemark!.subAdministrativeArea!);
    }

    return parts.isNotEmpty ? parts.join(', ') : 'Lokasi tidak diketahui';
  }

  /// Dispose service.
  void dispose() {
    // Geolocator tidak memerlukan dispose eksplisit
    AppLogger.info(_tag, 'LocationService disposed');
  }
}

// ─── Model ─────────────────────────────────────────────────

/// Model untuk tempat terdekat dari OpenStreetMap.
class NearbyPlace {
  final String name;
  final String category;
  final int distanceMeters;
  final double latitude;
  final double longitude;

  const NearbyPlace({
    required this.name,
    required this.category,
    required this.distanceMeters,
    required this.latitude,
    required this.longitude,
  });

  /// Format jarak yang mudah dibaca.
  /// Di bawah 1000m: "150m", di atas: "1.2km"
  String get formattedDistance {
    if (distanceMeters < 1000) {
      return '${distanceMeters}m';
    } else {
      return '${(distanceMeters / 1000).toStringAsFixed(1)}km';
    }
  }

  @override
  String toString() =>
      'NearbyPlace($name, $category, $formattedDistance)';
}
