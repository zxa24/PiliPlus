/// LibrePili: a video shared as a QR code — shown, saved as an image, or
/// its link copied (research/qr-code-design-2026-09-25.md, R1).
///
/// The link carries the part and the playback position when there is one
/// (user 2026-09-25), so scanning it opens the same place.
library;

import 'dart:typed_data' show Uint8List;

import 'package:PiliPlus/utils/image_utils.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:material_ui/material_ui.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:pretty_qr_code/pretty_qr_code.dart';

/// Shows [url] as a QR code under [title].
void showQrShare(BuildContext context, {required String url, String? title}) {
  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('分享为二维码'),
      content: SizedBox(
        width: 280,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // white under the code whatever the theme: a dark background
            // with dark modules does not scan
            Container(
              width: 240,
              height: 240,
              color: Colors.white,
              padding: const EdgeInsets.all(12),
              child: PrettyQrView.data(
                data: url,
                decoration: const PrettyQrDecoration(
                  shape: PrettyQrSquaresSymbol(color: Colors.black87),
                ),
              ),
            ),
            if (title != null) ...[
              const SizedBox(height: 12),
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Utils.copyText(url),
          child: const Text('复制链接'),
        ),
        TextButton(
          onPressed: () => _save(url),
          child: const Text('保存图片'),
        ),
        TextButton(onPressed: Get.back, child: const Text('关闭')),
      ],
    ),
  );
}

/// The code as a PNG, black on white with a margin, large enough to print.
Future<Uint8List?> qrPng(String url, {int size = 1024}) async {
  final image = QrImage(
    QrCode.fromData(data: url, errorCorrectLevel: QrErrorCorrectLevel.M),
  );
  final bytes = await image.toImageAsBytes(
    size: size,
    decoration: const PrettyQrDecoration(
      background: Colors.white,
      quietZone: PrettyQrQuietZone.standard,
      shape: PrettyQrSquaresSymbol(color: Colors.black),
    ),
  );
  return bytes?.buffer.asUint8List();
}

Future<void> _save(String url) async {
  final bytes = await qrPng(url);
  if (bytes == null) return;
  await ImageUtils.saveByteImg(
    bytes: bytes,
    fileName:
        'librepili_qr_${DateFormat('yyyyMMddHHmmss').format(DateTime.now())}',
  );
}
