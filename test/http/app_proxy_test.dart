import 'package:PiliPlus/http/app_proxy.dart';
import 'package:flutter_test/flutter_test.dart';

/// The 设置代理 rule every client of the app follows, given the setting.
void main() {
  group('findProxy', () {
    test('everything through the proxy while it is set', () {
      for (final url in [
        'https://api.bilibili.com/x',
        'https://www.youtube.com/youtubei/v1/player',
        'https://inv.nadeko.net/watch?v=x',
        'https://huggingface.co/model.bin',
        'https://10.0.0.5/dav/',
      ]) {
        expect(
          AppProxy.findProxyWith(Uri.parse(url), '192.168.1.2:7890'),
          'PROXY 192.168.1.2:7890',
          reason: url,
        );
      }
    });

    test("the app's own loopback servers directly", () {
      for (final url in [
        'http://127.0.0.1:5000/abc/host',
        'http://localhost:5000/',
        'http://[::1]:5000/',
        'http://127.1.2.3/',
      ]) {
        expect(
          AppProxy.findProxyWith(Uri.parse(url), '192.168.1.2:7890'),
          'DIRECT',
          reason: url,
        );
      }
    });

    test('a host or port missing is no proxy', () {
      expect(AppProxy.hostPortOf('', '7890'), isNull);
      expect(AppProxy.hostPortOf('proxy', ''), isNull);
      expect(AppProxy.hostPortOf('proxy', 'x'), isNull);
      expect(AppProxy.hostPortOf(' proxy ', ' 7890 '), 'proxy:7890');
    });
  });

  group('mpv', () {
    test('a remote stream through the proxy, as an http:// URL', () {
      expect(
        AppProxy.mpvWith(
          'https://rr1---sn-x.googlevideo.com/videoplayback?a=1',
          'proxy:7890',
        ),
        'http://proxy:7890',
      );
    });

    test('nothing set while the setting is off', () {
      expect(AppProxy.mpvWith('https://example.com/v.mp4', null), '');
    });

    test('a file read from the loopback is not sent to the proxy', () {
      expect(
        AppProxy.mpvWith(
          'http://127.0.0.1:41234/abcd/upos.bilivideo.com',
          'p:1',
        ),
        '',
      );
    });

    test('an EDL with a loopback part goes direct as a whole', () {
      const video = 'http://127.0.0.1:41234/ab/cn-gd.bilivideo.com';
      const audio = 'http://127.0.0.1:41234/cd/cn-gd.bilivideo.com';
      const edl =
          'edl://!no_chapters;%${video.length}%$video;'
          '!new_stream;!no_chapters;%${audio.length}%$audio';
      expect(AppProxy.mpvWith(edl, 'p:1'), '');
    });

    test('an EDL of remote parts goes through the proxy', () {
      const video = 'https://a.example.com/v.m4s';
      const audio = 'https://b.example.com/a.m4s';
      const edl =
          'edl://!no_chapters;%${video.length}%$video;'
          '!new_stream;!no_chapters;%${audio.length}%$audio';
      expect(AppProxy.mpvWith(edl, 'p:1'), 'http://p:1');
    });

    test('a local file has no URL and takes the proxy harmlessly', () {
      expect(AppProxy.mpvWith(r'C:\videos\a.mp4', 'p:1'), 'http://p:1');
    });
  });
}
