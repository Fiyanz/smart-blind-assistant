import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:smartassistant/services/ai_tools.dart';
import 'package:smartassistant/services/location_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LocationService locationService;
  late AiToolsService aiToolsService;

  double? updatedTtsSpeed;
  String? switchedMode;

  setUpAll(() async {
    await initializeDateFormatting('id_ID', null);
  });

  setUp(() {
    dotenv.loadFromString(envString: 'OPENROUTER_API_KEY=test_key');
    locationService = LocationService();
    updatedTtsSpeed = null;
    switchedMode = null;

    aiToolsService = AiToolsService(
      locationService: locationService,
      onSetTtsSpeed: (speed) async {
        updatedTtsSpeed = speed;
      },
      onSwitchMode: (mode) {
        switchedMode = mode;
      },
      onScanObstacles: () async => 'Aman, jalur terbuka.',
      onReadText: () async => 'Toko Buku Maju Jaya',
      onIdentifyMoney: () async => 'Uang 50 ribu rupiah warna biru',
    );
  });

  group('AiToolsService Tool Declarations', () {
    test('should declare exactly 10 function tools', () {
      final declarations = aiToolsService.getToolDeclarations();
      expect(declarations.length, equals(10));

      final toolNames = declarations
          .map((e) => (e['function'] as Map<String, dynamic>)['name'])
          .toSet();
      expect(toolNames, containsAll([
        'open_gps',
        'get_current_time',
        'get_current_location',
        'get_nearby_places',
        'get_weather',
        'set_tts_speed',
        'scan_obstacles',
        'read_text_from_image',
        'identify_money',
        'switch_mode',
      ]));
    });
  });

  group('AiToolsService Execution', () {
    test('get_current_time should return formatted time fields', () async {
      final result = await aiToolsService.executeTool('get_current_time', {});
      expect(result.containsKey('hari'), isTrue);
      expect(result.containsKey('tanggal'), isTrue);
      expect(result.containsKey('waktu'), isTrue);
      expect(result.containsKey('periode'), isTrue);
      expect((result['waktu'] as String).contains('WIB'), isTrue);
    });

    test('set_tts_speed should invoke callback with parsed rate', () async {
      final result = await aiToolsService.executeTool('set_tts_speed', {'speed': 'cepat'});
      expect(result['berhasil'], isTrue);
      expect(result['kecepatan_baru'], equals('cepat'));
      expect(result['nilai'], equals(0.7));
      expect(updatedTtsSpeed, equals(0.7));
    });

    test('switch_mode should invoke callback with target mode', () async {
      final result = await aiToolsService.executeTool('switch_mode', {'mode': 'autopilot'});
      expect(result['berhasil'], isTrue);
      expect(result['mode_baru'], equals('autopilot'));
      expect(switchedMode, equals('autopilot'));
    });

    test('scan_obstacles should invoke callback', () async {
      final result = await aiToolsService.executeTool('scan_obstacles', {});
      expect(result['hasil_scan'], equals('Aman, jalur terbuka.'));
    });

    test('read_text_from_image should invoke callback', () async {
      final result = await aiToolsService.executeTool('read_text_from_image', {});
      expect(result['teks_terbaca'], equals('Toko Buku Maju Jaya'));
    });

    test('identify_money should invoke callback', () async {
      final result = await aiToolsService.executeTool('identify_money', {});
      expect(result['identifikasi_uang'], equals('Uang 50 ribu rupiah warna biru'));
    });

    test('unknown tool should return error map gracefully', () async {
      final result = await aiToolsService.executeTool('non_existent_tool', {});
      expect(result.containsKey('error'), isTrue);
    });
  });
}
