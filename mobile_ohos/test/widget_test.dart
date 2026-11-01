import 'package:flutter_test/flutter_test.dart';
import 'package:codeassist_ohos/main.dart';

void main() {
  testWidgets('app builds', (tester) async {
    await tester.pumpWidget(const CodeAssistOhosApp());
    expect(find.byType(CodeAssistOhosApp), findsOneWidget);
  });
}
