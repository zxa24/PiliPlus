import 'dart:io';

import 'package:PiliPlus/common/widgets/dialog/qr_share.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const url = 'https://www.bilibili.com/video/BV18yt46NEC5/?p=2&t=83.5';

  testWidgets('the dialog shows the code, the title and the actions', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showQrShare(context, url: url, title: '标题'),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('分享为二维码'), findsOneWidget);
    expect(find.text('标题'), findsOneWidget);
    for (final action in ['复制链接', '保存图片', '关闭']) {
      expect(find.text(action), findsOneWidget);
    }
  });

  testWidgets('the saved image is a PNG of the link', (tester) async {
    final bytes = await tester.runAsync(() => qrPng(url, size: 512));
    expect(bytes, isNotNull);
    // PNG signature
    expect(bytes!.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    // for decoding by an independent reader outside the test
    final out = Platform.environment['QR_PNG_OUT'];
    if (out != null) File(out).writeAsBytesSync(bytes);
  });
}
