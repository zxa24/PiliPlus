import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:flutter_test/flutter_test.dart';

/// mpv's per-file `network-timeout`: longer for what the app's own loopback
/// servers serve (the parallel fetch answers once the upstream gives the
/// size, 17A), media_kit's 5 s for anything else (user 2026-10-20, 7C).
void main() {
  const longer = {
    'network-timeout': '${PlPlayerController.loopbackNetworkTimeout}',
  };

  test('longer than media_kit\'s 5 s', () {
    expect(PlPlayerController.loopbackNetworkTimeout, greaterThan(5));
  });

  test('a stand-in on the loopback, alone or in an EDL', () {
    const video =
        'http://127.0.0.1:52011/0123456789abcdef0123456789abcdef/'
        'upos-sz-mirrorcos.bilivideo.com';
    const audio =
        'http://127.0.0.1:52011/fedcba9876543210fedcba9876543210/'
        'upos-sz-mirrorcos.bilivideo.com';
    expect(PlPlayerController.loopbackExtras(video), longer);
    expect(
      PlPlayerController.loopbackExtras(
        'edl://!no_chapters;%${video.length}%$video;'
        '!new_stream;!no_chapters;%${audio.length}%$audio',
      ),
      longer,
    );
    // the Invidious relay, by name or IPv6
    expect(
      PlPlayerController.loopbackExtras('http://localhost:8080/v'),
      longer,
    );
    expect(PlPlayerController.loopbackExtras('http://[::1]:8080/v'), longer);
  });

  test('a CDN read directly, a local file: none', () {
    const cdn =
        'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/1/2/3-1-30080.m4s'
        '?e=x';
    const audio =
        'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/1/2/3-1-30280.m4s'
        '?e=x';
    expect(PlPlayerController.loopbackExtras(cdn), isEmpty);
    expect(
      PlPlayerController.loopbackExtras(
        'edl://!no_chapters;%${cdn.length}%$cdn;'
        '!new_stream;!no_chapters;%${audio.length}%$audio',
      ),
      isEmpty,
    );
    expect(
      PlPlayerController.loopbackExtras(
        'https://rr1---sn-x.googlevideo.com/videoplayback?id=1',
      ),
      isEmpty,
    );
    expect(
      PlPlayerController.loopbackExtras('/storage/emulated/0/a/video.m4s'),
      isEmpty,
    );
    // a CDN's path that names the loopback is not the loopback
    expect(
      PlPlayerController.loopbackExtras('https://a.example/127.0.0.1/x'),
      isEmpty,
    );
  });
}
