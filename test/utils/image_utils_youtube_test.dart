import 'package:PiliPlus/utils/image_utils.dart';
import 'package:flutter_test/flutter_test.dart';

/// bilibili's resize suffix must not reach a YouTube image URL: on a Google
/// one it lands in the size parameter and the request fails (every channel
/// avatar, banner, post image and comment avatar showed the placeholder).
void main() {
  test('YouTube image hosts are left as they are', () {
    const urls = [
      'https://yt3.googleusercontent.com/ytc/AIdro_n1Rib=s160-c-k-c0x00ffffff-no-rj',
      'https://yt3.ggpht.com/RJ-NjQq=s640-c-fcrop64=1,00000000ffffffff-rw-nd-v1',
      'https://i.ytimg.com/vi/b1EMX3wyqCY/hq720.jpg?sqp=-oaymwEc&rs=AOn4CL',
    ];
    for (final url in urls) {
      expect(ImageUtils.thumbnailUrl(url), url);
    }
  });

  test('a protocol-relative YouTube URL gets https and nothing else', () {
    expect(
      ImageUtils.thumbnailUrl('//yt3.ggpht.com/abc=s48-c-k'),
      'https://yt3.ggpht.com/abc=s48-c-k',
    );
  });
}
