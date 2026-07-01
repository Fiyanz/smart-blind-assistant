import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Konstanta global aplikasi SightAssist.
///
/// Semua konfigurasi yang bersifat tetap disimpan di sini
/// agar mudah diubah dari satu tempat.
class AppConstants {
  AppConstants._(); // Mencegah instansiasi

  // ─── BLE (ESP32) ───────────────────────────────────────────
  /// UUID Service BLE pada ESP32 (sesuaikan dengan firmware)
  static const String bleServiceUuid =
      '4fafc201-1fb5-459e-8fcc-c5c9c331914b';

  /// UUID Characteristic untuk menerima trigger dari tombol ESP32
  static const String bleTriggerCharUuid =
      'beb5483e-36e1-4688-b7f5-ea07361b26a8';

  /// Durasi maksimal scan BLE (detik)
  static const int bleScanTimeoutSeconds = 10;

  // ─── BLE Commands ──────────────────────────────────────────
  /// Command: voice command (tombol 1)
  static const int bleCmdVoice = 0x01;

  /// Command: ganti mode / cycle mode (tombol 2)
  static const int bleCmdNextMode = 0x02;

  /// Command: emergency stop / stop all (tombol 1+2)
  static const int bleCmdStopAll = 0x03;

  // ─── API (OpenRouter) ──────────────────────────────────────
  /// Base URL OpenRouter API
  static const String openRouterBaseUrl =
      'https://openrouter.ai/api/v1/chat/completions';

  /// API Key OpenRouter
  static String get openRouterApiKey => dotenv.env['OPENROUTER_API_KEY'] ?? '';

  /// Model AI yang digunakan (Gemini Vision via OpenRouter)
  static const String aiModel = 'google/gemini-2.5-flash';

  // ─── Supabase ──────────────────────────────────────────────
  /// URL Supabase
  static String get supabaseUrl => dotenv.env['SUPABASE_URL'] ?? '';

  /// Anon Key Supabase
  static String get supabaseAnonKey => dotenv.env['SUPABASE_ANON_KEY'] ?? '';

  // ─── Kamera ────────────────────────────────────────────────
  /// Resolusi kamera yang digunakan
  /// ResolutionPreset: low, medium, high, veryHigh, ultraHigh, max
  static const String cameraResolution = 'medium';

  // ─── TTS ───────────────────────────────────────────────────
  /// Bahasa default TTS
  static const String defaultTtsLanguage = 'id-ID';

  /// Kecepatan bicara TTS (0.0 - 1.0)
  static const double defaultTtsSpeechRate = 0.5;

  /// Pitch TTS (0.5 - 2.0)
  static const double defaultTtsPitch = 1.0;

  // ─── Timeout ───────────────────────────────────────────────
  /// Timeout HTTP request (detik)
  static const int httpTimeoutSeconds = 30;
}
