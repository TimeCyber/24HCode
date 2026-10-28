import 'package:flutter_test/flutter_test.dart';
import 'package:codeassist_mobile/main.dart';

void main() {
  testWidgets('App boots', (WidgetTester tester) async {
    await tester.pumpWidget(const CodeAssistApp());
    await tester.pump();
    expect(find.text('CodeAssist'), findsWidgets);
  });
}
