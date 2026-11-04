import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_patcher_example/main.dart';

void main() {
  testWidgets('shows the demo and where updates come from', (tester) async {
    await tester.pumpWidget(const ExampleApp());
    expect(find.text(message), findsOneWidget);
    expect(find.text('http://127.0.0.1:8686'), findsOneWidget);
    expect(find.text('Check for update'), findsOneWidget);
  });
}
