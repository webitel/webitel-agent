import 'package:flutter_test/flutter_test.dart';
import 'package:webitel_desk_track/config/service.dart';

void main() {
  test('the same server written differently is the same environment', () {
    expect(
      AppConfig.sameServer('https://example.com', 'https://example.com/'),
      isTrue,
    );
    expect(
      AppConfig.sameServer('https://Example.com/', ' https://example.com'),
      isTrue,
    );
    expect(
      AppConfig.sameServer(
        'https://example.com:8443',
        'https://example.com:8443/',
      ),
      isTrue,
    );
  });

  test('another host, port or scheme is another environment', () {
    expect(
      AppConfig.sameServer('https://dev.example.com', 'https://example.com'),
      isFalse,
    );
    expect(
      AppConfig.sameServer('https://example.com:8443', 'https://example.com'),
      isFalse,
    );
    expect(
      AppConfig.sameServer('http://example.com', 'https://example.com'),
      isFalse,
    );
  });

  test('a path prefix is part of the environment', () {
    expect(
      AppConfig.sameServer('https://example.com/a', 'https://example.com/b'),
      isFalse,
    );
    expect(
      AppConfig.sameServer('https://example.com/a/', 'https://example.com/a'),
      isTrue,
    );
  });
}
