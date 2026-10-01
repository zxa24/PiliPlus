/// The channel parsers, on trimmed REAL responses.
///
/// Every file under `test/fixtures/youtube/channel/` was recorded on
/// 2026-09-30 (WEB 2.20260805.01.00, hl=zh-CN, gl=GB) from Kurzgesagt
/// (`UCsXVk37bltHxD1rDPwtNM8Q`) and DW News (`UCknLrEdhRCp1aegoMqRaCZg`), then
/// cut down to under 50 KB: logging fields dropped, long lists cut to their
/// first items plus the last (where a continuation sits), URLs cut to 110
/// characters. Unlike the fixtures one directory up they are committed, so
/// these tests run in a fresh checkout.
library;

import 'package:PiliPlus/services/youtube/youtube.dart';
import 'package:flutter_test/flutter_test.dart';

import 'yt_test_support.dart';

Object? _load(String name) => loadYtFixture('channel/$name.json');

const _kz = (
  name: 'Kurzgesagt – In a Nutshell',
  id: 'UCsXVk37bltHxD1rDPwtNM8Q',
);

void main() {
  group('the 视频 tab', () {
    final json = _load('channel_videos');

    test('the response is the 视频 tab, read by URL suffix', () {
      expect(selectedChannelTab(json), YtChannelTab.videos);
      final tabs = parseChannelTabs(json);
      expect(
        tabs.keys,
        containsAll([
          YtChannelTab.videos,
          YtChannelTab.shorts,
          YtChannelTab.playlists,
          YtChannelTab.posts,
        ]),
      );
      // Kurzgesagt does not stream: no 直播 tab is invented
      expect(tabs.containsKey(YtChannelTab.streams), isFalse);
      expect(tabs[YtChannelTab.videos], YtChannelTab.videos.fallbackParams);
    });

    test('every item is the channel\'s, with views and a date', () {
      final items = parseChannelVideos(json, channel: _kz);
      expect(items, isNotEmpty);
      for (final item in items) {
        expect(item.author, _kz.name);
        expect(item.viewCountText, contains('观看'));
        expect(item.publishedText, isNotNull);
        expect(item.duration, isNotNull);
        expect(item.isLive, isFalse);
      }
    });

    test('the token is the grid\'s, not the header\'s About token', () {
      final token = listContinuationToken(json);
      expect(token, isNotNull);
      // the grid's token measured 1502 chars, the About panel's 136
      expect(token!.length, greaterThan(1000));
      // and the old whole-tree reader picks one of the two as well — this
      // is the regression the list-only reader exists for
      expect(
        collectObjects(json, 'continuationItemRenderer').length,
        greaterThan(1),
      );
    });

    test('the sort chips are 最新 / 最热门 / 最早, the first selected', () {
      final chips = parseSortChips(json);
      expect(chips.map((c) => c.text), ['最新', '最热门', '最早']);
      expect(chips.first.selected, isTrue);
      expect(chips.every((c) => c.token.isNotEmpty), isTrue);
    });

    test(
      'the header: avatar from `image`, banner apart, handle and counts',
      () {
        final info = parseChannelInfo(json, _kz.id)!;
        expect(info.name, _kz.name);
        expect(info.avatar!.width, lessThanOrEqualTo(200));
        expect(info.avatar!.url, isNot(info.banner!.url));
        expect(info.banner!.width, greaterThan(1000));
        expect(info.handle, '@kurzgesagt');
        expect(info.subscriberText, contains('订阅'));
        // Videos + Shorts: kept as YouTube's text
        expect(info.videoCountText, '391 个视频');
        expect(info.description, contains('optimistic nihilism'));
        expect(info.link, contains('shop.kgs.link'));
      },
    );
  });

  group('paging the 视频 tab', () {
    test('a continuation: items via appendContinuationItemsAction, and a '
        'next token', () {
      final json = _load('channel_videos_cont');
      expect(parseChannelVideos(json, channel: _kz), isNotEmpty);
      expect(listContinuationToken(json), isNotNull);
    });

    test('the last page: items and no token', () {
      final json = _load('channel_videos_last');
      expect(parseChannelVideos(json, channel: _kz), isNotEmpty);
      expect(listContinuationToken(json), isNull);
    });

    test('a Home-shaped response yields no list token at all', () {
      // DW News's Home tab: one token per shelf (in engagement panels) and
      // the header's About tokens — none of them pages a list
      final json = _load('channel_home');
      expect(selectedChannelTab(json), isNull);
      expect(collectObjects(json, 'continuationItemRenderer'), isNotEmpty);
      expect(listContinuationToken(json), isNull);
    });
  });

  group('the 直播 tab', () {
    final json = _load('channel_streams');
    const dw = (name: 'DW News', id: 'UCknLrEdhRCp1aegoMqRaCZg');

    test('it is listed and selected', () {
      expect(selectedChannelTab(json), YtChannelTab.streams);
      expect(parseChannelTabs(json), contains(YtChannelTab.streams));
    });

    test('a stream live now is live under zh-CN, whose badge says 直播', () {
      final items = parseChannelVideos(json, channel: dw);
      final live = items.first;
      expect(live.isLive, isTrue);
      // one row with one part: the viewers
      expect(live.viewCountText, contains('正在观看'));
      expect(live.publishedText, isNull);
      expect(live.author, dw.name);
    });

    test('a past stream has its date', () {
      final past = parseChannelVideos(json, channel: dw).skip(1).first;
      expect(past.isLive, isFalse);
      expect(past.publishedText, startsWith('直播时间'));
      expect(past.duration, isNotNull);
    });
  });

  group('no regression outside a channel', () {
    test('a two-row lockup still reads row 0 as the author', () {
      // the playlist page's lockups have two rows, as related videos do
      final items = parseChannelVideos(_load('playlist_page'));
      expect(items, isNotEmpty);
      for (final item in items) {
        expect(item.author, _kz.name);
        expect(item.viewCountText, contains('观看'));
        expect(item.publishedText, isNotNull);
      }
    });

    test('with no channel given, one row stays the author (as before)', () {
      final items = parseRelatedVideos(_load('channel_videos'));
      expect(items.first.author, contains('观看'));
    });
  });

  group('Shorts', () {
    test('shortsLockupViewModel: id, title, views, a portrait thumbnail', () {
      final json = _load('channel_shorts');
      expect(selectedChannelTab(json), YtChannelTab.shorts);
      final shorts = parseChannelShorts(json);
      expect(shorts, isNotEmpty);
      final first = shorts.first;
      expect(first.videoId, hasLength(11));
      expect(first.title, isNotEmpty);
      expect(first.viewCountText, contains('观看'));
      final thumb = first.bestThumbnail!;
      expect(thumb.height!, greaterThan(thumb.width!));
      expect(listContinuationToken(json), isNotNull);
    });
  });

  group('playlists', () {
    test('SHOW lockups are playlists, with the count badge and the id', () {
      final json = _load('channel_playlists');
      expect(selectedChannelTab(json), YtChannelTab.playlists);
      final lists = parseChannelPlaylists(json);
      expect(lists, isNotEmpty);
      final first = lists.first;
      expect(first.playlistId, startsWith('PL'));
      expect(first.title, 'Space Exploration');
      expect(first.countText, '28 集');
      expect(first.firstVideoTitle, isNotNull);
      expect(first.bestThumbnail, isNotNull);
      // 17 items and no grid token on this channel
      expect(listContinuationToken(json), isNull);
    });

    test('a playlist page: its header and the view-model page token', () {
      final json = _load('playlist_page');
      final info = parsePlaylistInfo(
        json,
        'PLFs4vir_WsTwCrTf_-NjTgt1foROcMC18',
      )!;
      expect(info.title, 'Space Exploration');
      expect(info.ownerName, _kz.name);
      expect(info.ownerChannelId, _kz.id);
      expect(info.countText, '28 个视频');
      expect(info.count, 28);
      expect(info.viewCountText, contains('观看'));
      // a continuationItemViewModel, which pageContinuationToken misses
      expect(pageContinuationToken(json), isNull);
      expect(listContinuationToken(json), isNotNull);
    });

    test('the uploads playlist header (playlistHeaderRenderer)', () {
      final json = _load('playlist_uploads');
      final info = parsePlaylistInfo(json, 'UUsXVk37bltHxD1rDPwtNM8Q')!;
      expect(info.count, 391);
      expect(info.ownerChannelId, _kz.id);
      expect(listContinuationToken(json), isNotNull);
    });
  });

  group('posts', () {
    final json = _load('channel_posts');
    late final posts = parseChannelPosts(json);

    test('the tab, and one post per attachment kind', () {
      expect(selectedChannelTab(json), YtChannelTab.posts);
      expect(posts, hasLength(3));
      expect(listContinuationToken(json), isNotNull);
    });

    test('a single image', () {
      final post = posts.firstWhere((p) => p.images.length == 1);
      expect(post.postId, startsWith('Ugkx'));
      expect(post.author, _kz.name);
      expect(post.authorChannelId, _kz.id);
      expect(post.authorAvatar, isNotNull);
      expect(post.publishedText, isNotNull);
      expect(post.likeCountText, isNotNull);
      expect(post.commentCountText, isNotNull);
      expect(post.detailParams, isNotEmpty);
      // its links are unwrapped from YouTube's redirect
      final link = post.runs.firstWhere((r) => r.url != null);
      expect(link.url, startsWith('https://shop.kgs.link'));
    });

    test('several images', () {
      expect(posts.any((p) => p.images.length > 1), isTrue);
    });

    test('an embedded video', () {
      final post = posts.firstWhere((p) => p.video != null);
      expect(post.video!.videoId, hasLength(11));
      expect(post.video!.title, isNotEmpty);
      expect(post.images, isEmpty);
    });
  });

  group('a post\'s detail page', () {
    test('the post and its comments token', () {
      final detail = parsePostDetail(_load('post_detail'))!;
      expect(detail.post.postId, 'UgkxcPlmPYSssRiOIpjXHKuhlTBf_t-OnmSh');
      expect(detail.commentsToken, isNotNull);
    });

    test('its comments parse as a video\'s do, with the page token apart '
        'from the threads\'', () {
      final page = parseComments(_load('post_comments'));
      expect(page.items, isNotEmpty);
      expect(page.items.first.content, isNotEmpty);
      expect(page.items.any((c) => c.hasReplies), isTrue);
      expect(page.continuation, isNotNull);
      expect(
        page.items.map((c) => c.replyToken),
        isNot(contains(page.continuation)),
      );
    });
  });

  test('a redirect link is unwrapped to its target', () {
    expect(
      unwrapYtRedirect(
        'https://www.youtube.com/redirect?event=x&q=https%3A%2F%2Fexample.com%2Fa',
      ),
      'https://example.com/a',
    );
    expect(unwrapYtRedirect('https://example.com/b'), 'https://example.com/b');
  });
}
