import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smartassistant/features/home/home_screen.dart';
import 'package:smartassistant/providers/assistant_provider.dart';
import 'package:smartassistant/providers/ble_provider.dart';
import 'package:smartassistant/providers/settings_provider.dart';

class FakeAssistantProvider extends AssistantProvider {
  @override
  Future<void> initialize() async {}

  @override
  bool get cameraReady => false;
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dotenv.loadFromString(envString: 'OPENROUTER_API_KEY=test_key');
  });

  testWidgets('HomeScreen renders properly in Portrait orientation', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => BleProvider()),
          ChangeNotifierProvider<AssistantProvider>(create: (_) => FakeAssistantProvider()),
          ChangeNotifierProvider(create: (_) => SettingsProvider()),
        ],
        child: const MaterialApp(
          home: HomeScreen(),
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(OrientationBuilder), findsOneWidget);
  });

  testWidgets('HomeScreen renders properly in Landscape orientation', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(2400, 1080);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => BleProvider()),
          ChangeNotifierProvider<AssistantProvider>(create: (_) => FakeAssistantProvider()),
          ChangeNotifierProvider(create: (_) => SettingsProvider()),
        ],
        child: const MaterialApp(
          home: HomeScreen(),
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(SingleChildScrollView), findsWidgets);
  });
}
