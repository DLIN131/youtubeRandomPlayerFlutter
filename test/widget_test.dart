import 'package:flutter_test/flutter_test.dart';

import 'package:youtube_random_player_flutter_bg/app.dart';

void main() {
  testWidgets('App builds', (WidgetTester tester) async {
    await tester.pumpWidget(const YoutubeRandomPlayerApp());
    expect(find.text('Youtube Random Player (Flutter)'), findsOneWidget);
  });
}
