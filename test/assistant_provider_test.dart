// Unit tests for AssistantProvider, especially switchMode functionality
import 'package:flutter_test/flutter_test.dart';
import 'package:smartassistant/providers/assistant_provider.dart';

void main() {
  group('AssistantProvider.switchMode', () {
    group('Mode cycling', () {
      test('should cycle from asisten to autopilot', () {
        // Assert
        expect(AssistantMode.asisten.next, equals(AssistantMode.autopilot));
      });

      test('should cycle from autopilot to obrolan', () {
        // Assert
        expect(AssistantMode.autopilot.next, equals(AssistantMode.obrolan));
      });

      test('should cycle from obrolan back to asisten', () {
        // Assert
        expect(AssistantMode.obrolan.next, equals(AssistantMode.asisten));
      });
    });
  });

  group('AssistantModeExtension', () {
    test('should return correct labels', () {
      expect(AssistantMode.asisten.label, equals('Mode Asisten'));
      expect(AssistantMode.autopilot.label, equals('Mode Autopilot'));
      expect(AssistantMode.obrolan.label, equals('Mode Obrolan'));
    });

    test('should return correct promptMode strings', () {
      expect(AssistantMode.asisten.promptMode, equals('asisten'));
      expect(AssistantMode.autopilot.promptMode, equals('autopilot'));
      expect(AssistantMode.obrolan.promptMode, equals('obrolan'));
    });

    test('should correctly identify continuous modes', () {
      expect(AssistantMode.asisten.isContinuous, isFalse);
      expect(AssistantMode.autopilot.isContinuous, isTrue);
      expect(AssistantMode.obrolan.isContinuous, isFalse);
    });
  });
}