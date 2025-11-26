import 'package:webitel_desk_track/core/logger.dart';

Future<T> retry<T>(
  Future<T> Function() action, {
  int maxRetries = 3,
  Duration delay = const Duration(seconds: 2),
}) async {
  for (int i = 1; i <= maxRetries; i++) {
    try {
      return await action();
    } catch (e, st) {
      logger.error('Retry $i/$maxRetries failed:', e, st);
      if (i == maxRetries) rethrow;
      await Future.delayed(delay);
    }
  }
  throw Exception('Retry limit reached');
}
