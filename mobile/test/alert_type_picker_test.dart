import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radar_mobile/models/alert_type_category.dart';
import 'package:radar_mobile/theme/flexoki_theme.dart';
import 'package:radar_mobile/widgets/alert_type_picker.dart';

void main() {
  testWidgets('switch paints optimistically before a slow callback completes', (
    tester,
  ) async {
    var selected = true;
    var callbackStarted = false;
    final release = Completer<void>();
    await _pumpPicker(
      tester,
      isSelected: (_) => selected,
      onChanged: (type, value) async {
        callbackStarted = true;
        await release.future;
        selected = value;
      },
    );

    final toggle = find.byKey(const ValueKey('test-alert-Example Alert'));
    await tester.tap(toggle);
    await tester.pump();

    expect(callbackStarted, isTrue);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);

    release.complete();
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
  });

  testWidgets('failed callbacks report the error and clear optimistic state', (
    tester,
  ) async {
    await _pumpPicker(
      tester,
      isSelected: (_) => true,
      onChanged: (type, value) => throw StateError('save failed'),
    );

    final toggle = find.byKey(const ValueKey('test-alert-Example Alert'));
    await tester.tap(toggle);
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isA<StateError>());
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
  });
}

Future<void> _pumpPicker(
  WidgetTester tester, {
  required bool Function(String type) isSelected,
  required AlertTypeChanged onChanged,
}) => tester.pumpWidget(
  MaterialApp(
    theme: Flexoki.darkTheme,
    home: Scaffold(
      body: AlertTypePicker(
        header: const SettingsPageHeader(title: 'Test alerts'),
        category: AlertTypeCategory.other,
        types: const ['Example Alert'],
        isSelected: isSelected,
        onChanged: onChanged,
        semanticAction: 'Test',
        toggleKeyPrefix: 'test-alert',
        controller: null,
      ),
    ),
  ),
);
