import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wakelock_plus/wakelock_plus.dart';

import 'app.dart';
import 'core/constants/app_constants.dart';
import 'core/utils/logger.dart';
import 'core/utils/platform_helper.dart';
import 'providers/assistant_provider.dart';
import 'providers/ble_provider.dart';
import 'providers/settings_provider.dart';
import 'services/background_service.dart';
import 'services/supabase_service.dart';

/// Entry point aplikasi SightAssist.
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Mencegah layar mati otomatis agar kamera selalu siap jika ditekan dari BLE
  WakelockPlus.enable();

  // Kunci orientasi ke portrait (hanya di mobile)
  if (PlatformHelper.isMobile) {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);
  }

  // Load environment variables
  await dotenv.load(fileName: ".env");
  
  // Simpan config Supabase ke SharedPreferences agar bisa dibaca di background isolate
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('SUPABASE_URL', AppConstants.supabaseUrl);
  await prefs.setString('SUPABASE_ANON_KEY', AppConstants.supabaseAnonKey);

  // Inisialisasi Supabase
  await SupabaseService.initialize();

  // Inisialisasi background service (hanya di mobile)
  // Hanya configure, TIDAK start — start dilakukan di HomeScreen
  // setelah permission notifikasi diberikan (Android 13+)
  if (PlatformHelper.isBackgroundServiceSupported) {
    await BackgroundService.initialize();
    AppLogger.info('Main', 'Background service dikonfigurasi');
  } else {
    AppLogger.info('Main', 'Background service di-skip (platform desktop)');
  }

  // Muat pengaturan user
  final settingsProvider = SettingsProvider();
  await settingsProvider.loadSettings();

  AppLogger.info('Main', 'SightAssist dimulai');

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => BleProvider()),
        ChangeNotifierProvider(create: (_) => AssistantProvider()),
        ChangeNotifierProvider.value(value: settingsProvider),
      ],
      child: const SightAssistApp(),
    ),
  );
}
