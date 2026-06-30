import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:provider/provider.dart';

import 'app.dart';
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

  // Kunci orientasi ke portrait (hanya di mobile)
  if (PlatformHelper.isMobile) {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);
  }

  // Load environment variables
  await dotenv.load(fileName: ".env");

  // Inisialisasi Supabase
  await SupabaseService.initialize();

  // Inisialisasi background service (hanya di mobile)
  if (PlatformHelper.isBackgroundServiceSupported) {
    await BackgroundService.initialize();
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
