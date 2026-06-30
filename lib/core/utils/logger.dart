import 'package:flutter/foundation.dart';

import '../../services/supabase_service.dart';

/// Utility logging wrapper.
///
/// Menambahkan timestamp dan tag ke setiap pesan log.
/// Hanya aktif di debug mode (tidak akan muncul di release build).
class AppLogger {
  AppLogger._();

  static void info(String tag, String message) {
    _log('INFO', tag, message);
  }

  static void warning(String tag, String message) {
    _log('WARN', tag, message);
  }

  static void error(String tag, String message, [Object? error]) {
    _log('ERROR', tag, message, error);
    if (error != null) {
      debugPrint('  └─ $error');
    }
  }

  static void _log(String level, String tag, String message, [Object? error]) {
    final timestamp = DateTime.now().toIso8601String().substring(11, 23);
    debugPrint('[$timestamp] [$level] [$tag] $message');

    // Kirim ke Supabase
    // Jangan kirim log INFO dari SupabaseService sendiri untuk mencegah infinite loop
    if (tag != 'SupabaseService' || level == 'ERROR') {
      SupabaseService().sendLog(
        level: level,
        tag: tag,
        message: message,
        errorDetails: error?.toString(),
      );
    }
  }
}
