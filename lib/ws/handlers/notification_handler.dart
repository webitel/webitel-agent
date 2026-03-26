import 'dart:async';
import '../core/constants.dart';
import '../../core/logger/logger.dart';
import '../../service/screenshot/sender.dart';
import '../../service/webrtc/streamer/streamer.dart';

class NotificationHandler {
  final ScreenshotSenderService? screenshotService;
  final Future<Map<String, dynamic>> Function(
    String action, [
    Map<String, dynamic>? data,
  ])
  requestExecutor;

  ScreenStreamer? _screenCapturer;
  bool isRecordingFromCall = false;

  void Function(Map<String, dynamic> body)? onScreenRecordStart;
  void Function(Map<String, dynamic> body)? onScreenRecordStop;

  NotificationHandler({
    required this.screenshotService,
    required this.requestExecutor,
  });

  Future<void> handle(Map<String, dynamic> data) async {
    final notif = data['data']?['notification'];
    if (notif == null) return;

    final action = NotificationAction.fromString(notif['action'] as String?);
    final body = Map<String, dynamic>.from(notif['body'] ?? {});
    final ackId = body['ack_id'] as String?;

    logger.info('[NOTIF] RECEIVED_ACTION: ${action.name} | AckID: $ackId');

    String? ackError;
    try {
      switch (action) {
        case NotificationAction.screenShare:
          await _handleScreenShare(notif);
          break;
        case NotificationAction.screenshot:
          await screenshotService?.capture();
          break;
        case NotificationAction.screenRecordStart:
          break;
        case NotificationAction.screenRecordStop:
          onScreenRecordStop?.call(body);
          break;
        case NotificationAction.unknown:
          logger.warn('[NOTIF] UNKNOWN_ACTION received');
          break;
      }
    } catch (e) {
      ackError = e.toString();
      logger.error('[NOTIF] EXECUTION_FAILED', e);
    }

    // [ACK] Confirm receipt to server
    if (ackId != null) {
      await requestExecutor(SocketActions.ack, {
        'ack_id': ackId,
        if (ackError != null) 'error': ackError,
      }).catchError((e) {
        logger.error('[NOTIF] ACK_FAILED for ID: $ackId', e);
        return <String, dynamic>{};
      });
    }
  }

  Future<void> _handleScreenShare(Map<String, dynamic> notif) async {
    _screenCapturer?.close('NEW_SHARE_REQUEST');
    _screenCapturer = await ScreenStreamer.fromNotification(
      notif: notif,
      logger: logger,
      onClose: () => _screenCapturer = null,
      onAccept: requestExecutor,
    );
  }

  void dispose() {
    _screenCapturer?.close('DISPOSE');
    _screenCapturer = null;
  }
}
