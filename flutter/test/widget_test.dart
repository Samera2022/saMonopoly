// Smoke and unit tests for the saMonopoly Flutter app.

import 'package:flutter_test/flutter_test.dart';

import 'package:sa_monopoly/main.dart';
import 'package:sa_monopoly/config_provider.dart';

void main() {
  testWidgets('Home screen renders the main menu', (WidgetTester tester) async {
    await tester.pumpWidget(const SaMonopolyApp());
    await tester.pump();

    // Title and the primary menu entry should be visible.
    expect(find.text('saMonopoly'), findsOneWidget);
    expect(find.text('进入游戏'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
  });

  test('ConfigProvider reports failure when no engine is connected', () {
    // Without a BridgeClient the config store is unavailable, so a save must
    // fail rather than silently pretend to succeed.
    final config = ConfigProvider();
    final result = config.updateSettings(
      game: const GameConfig(),
      llmApi: const LlmApiConfig(),
    );
    expect(result.success, isFalse);
    expect(result.error, isNotNull);
  });

  test('ConfigSaveResult exposes success and failure states', () {
    const ok = ConfigSaveResult.success();
    const bad = ConfigSaveResult.failure('boom');
    expect(ok.success, isTrue);
    expect(ok.error, isNull);
    expect(bad.success, isFalse);
    expect(bad.error, 'boom');
  });
}
