// Smoke test for the saMonopoly Flutter app.
//
// Verifies that the app builds without errors and renders key UI components.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sa_monopoly/main.dart';

void main() {
  testWidgets('App builds and renders the game screen',
      (WidgetTester tester) async {
    // Build the SaMonopolyApp and trigger a frame.
    await tester.pumpWidget(const SaMonopolyApp());

    // The app bar should display the title.
    expect(find.text('saMonopoly'), findsOneWidget);

    // The settings icon button should be present in the app bar.
    expect(find.byIcon(Icons.settings), findsOneWidget);

    // Action buttons should be rendered.
    expect(find.text('Roll'), findsOneWidget);
    expect(find.text('End Turn'), findsOneWidget);

    // Active player name should be visible (Player 1 is active by default).
    expect(find.text('Player 1'), findsOneWidget);
  });

  testWidgets('Game can be restarted via settings dialog',
      (WidgetTester tester) async {
    await tester.pumpWidget(const SaMonopolyApp());

    // Tap the settings icon.
    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();

    // The settings dialog should appear.
    expect(find.text('Game Settings'), findsOneWidget);
    expect(find.text('Start Game'), findsOneWidget);

    // Tap "Start Game" to restart with the same settings.
    await tester.tap(find.text('Start Game'));
    await tester.pumpAndSettle();

    // After restarting, the game board should still be visible.
    expect(find.text('saMonopoly'), findsOneWidget);
    expect(find.text('Roll'), findsOneWidget);
  });
}
