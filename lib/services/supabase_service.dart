import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/constants/app_constants.dart';
import '../core/utils/logger.dart';

/// Service untuk menangani pengiriman log dan riwayat AI ke Supabase
class SupabaseService {
  static const String _tag = 'SupabaseService';
  
  // Singleton pattern
  static final SupabaseService _instance = SupabaseService._internal();
  factory SupabaseService() => _instance;
  SupabaseService._internal();

  SupabaseClient? _client;
  String? _userId;

  String? get userId => _userId;

  /// Mengecek apakah Supabase sudah dikonfigurasi dengan benar di .env
  bool get isConfigured =>
      AppConstants.supabaseUrl.isNotEmpty &&
      AppConstants.supabaseAnonKey.isNotEmpty;

  /// Mendapatkan instance Supabase client, null jika belum terkonfigurasi
  SupabaseClient? get client {
    if (_client != null) return _client;
    
    if (isConfigured) {
      try {
        _client = Supabase.instance.client;
        return _client;
      } catch (e) {
        // Abaikan error jika dipanggil sebelum initialize() selesai
        return null;
      }
    }
    return null;
  }

  /// Inisialisasi Supabase
  /// Harus dipanggil setelah load dotenv di main.dart
  static Future<void> initialize() async {
    if (AppConstants.supabaseUrl.isEmpty || AppConstants.supabaseAnonKey.isEmpty) {
      AppLogger.warning(_tag, 'Supabase belum dikonfigurasi (URL/Key kosong di .env)');
      return;
    }

    try {
      await Supabase.initialize(
        url: AppConstants.supabaseUrl,
        publishableKey: AppConstants.supabaseAnonKey,
      );
      final prefs = await SharedPreferences.getInstance();
      _instance._userId = prefs.getString('user_id');
      if (_instance._userId == null) {
        _instance._userId = 'user_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(10000)}';
        await prefs.setString('user_id', _instance._userId!);
      }
      AppLogger.info(_tag, 'Supabase berhasil diinisialisasi (user: ${_instance._userId})');
    } catch (e) {
      AppLogger.error(_tag, 'Gagal menginisialisasi Supabase', e);
    }
  }

  /// Mengirim log error atau peringatan ke tabel app_logs
  Future<void> sendLog({
    required String level,
    required String tag,
    required String message,
    String? errorDetails,
    String? location,
  }) async {
    if (client == null) return;

    try {
      final data = {
        'level': level,
        'tag': tag,
        'message': message,
        'error_details': errorDetails,
        'user_id': ?_userId,
        'location': ?location,
      };
      await client!.from('app_logs').insert(data);
    } catch (e) {
      // Jangan pakai AppLogger.error di sini untuk menghindari infinite loop 
      // jika error logging yang gagal
      // debugPrint dipanggil secara native jika di debug mode
      debugPrint('Gagal mengirim log ke Supabase: $e');
    }
  }

  /// Menyimpan riwayat prompt dan respons AI ke tabel ai_histories
  Future<void> saveAiHistory({
    required String mode,
    required String prompt,
    required String response,
    required String model,
    String? location,
  }) async {
    if (client == null) {
      AppLogger.warning(_tag, 'Gagal menyimpan riwayat AI: Supabase belum terkonfigurasi');
      return;
    }

    try {
      final data = {
        'mode': mode,
        'prompt': prompt,
        'response': response,
        'model': model,
        'user_id': ?_userId,
        'location': ?location,
      };
      await client!.from('ai_histories').insert(data);
      AppLogger.info(_tag, 'Riwayat AI berhasil disimpan ke Supabase');
    } catch (e) {
      AppLogger.error(_tag, 'Gagal mengirim riwayat AI ke Supabase', e);
    }
  }
}
