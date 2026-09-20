import 'package:PiliPlus/utils/accounts/account_manager/account_mgr.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parseBlockServer accepts a real block server', () {
    expect(AccountManager.parseBlockServer('https://www.bsbsb.top'), isNotNull);
    expect(
      AccountManager.parseBlockServer('https://sb.example.com:8443/api-root'),
      isNotNull,
    );
  });

  test('parseBlockServer refuses bilibili hosts and junk', () {
    for (final bad in [
      '',
      '   ',
      '/',
      'bsbsb.top', // no scheme
      'ftp://sb.example.com',
      'javascript:alert(1)',
      'https://api.bilibili.com/sb',
      'https://bilibili.com',
      'https://WWW.BILIBILI.COM/x',
      'https://live.bilibili.com',
      'https://i0.hdslb.com',
      'https://b23.tv',
      'https://bilibili.tv',
      'https://user:pw@sb.example.com',
    ]) {
      expect(
        AccountManager.parseBlockServer(bad),
        isNull,
        reason: 'must be refused: "$bad"',
      );
    }
  });
}
