// Guards the crash seen when saving an edited local port:
// "A TextEditingController was used after being disposed", which unwound into
// framework.dart's '_dependents.isEmpty' assertion.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veil_client/theme.dart';
import 'package:veil_client/widgets/common.dart';

class _Host extends StatefulWidget {
  const _Host();
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  int port = 10808;

  Future<void> _edit() async {
    final value = await promptForText(
      context,
      title: 'SOCKS port',
      initial: '$port',
      numeric: true,
    );
    if (value == null || !mounted) return;
    final v = int.tryParse(value);
    if (v != null) setState(() => port = v);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: TextButton(onPressed: _edit, child: Text('$port')),
        ),
      );
}

void main() {
  testWidgets('saving an edited port does not throw', (tester) async {
    await tester.pumpWidget(
        MaterialApp(theme: buildVeilTheme(), home: const _Host()));

    await tester.tap(find.text('10808'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '10999');
    await tester.tap(find.text('Save'));
    // The controller must survive the dialog's exit transition.
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('10999'), findsOneWidget);
  });

  testWidgets('cancelling leaves the value alone and does not throw',
      (tester) async {
    await tester.pumpWidget(
        MaterialApp(theme: buildVeilTheme(), home: const _Host()));

    await tester.tap(find.text('10808'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '1');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('10808'), findsOneWidget);
  });
}
