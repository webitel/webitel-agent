import 'dart:async';
import '../core/constants.dart';
import '../../core/logger/logger.dart';
import '../../service/screenshot/sender.dart';
import '../../service/webrtc/streamer/streamer.dart';
import 'call_handler.dart';

/// Handles incoming WebSocket notifications from the Webitel server.
/// Manages manual screen recording requests, screenshots, and screen sharing.
class NotificationHandler {
  final ScreenshotSenderService? screenshotService;
  final CallHandler callHandler;

  /// Function to execute socket requests (e.g., sending ACKs)
  final Future<Map<String, dynamic>> Function(
    String action, [
    Map<String, dynamic>? data,
  ])
  requestExecutor;

  ScreenStreamer? _screenCapturer;

  void Function(Map<String, dynamic> body)? onScreenRecordStart;
  void Function(Map<String, dynamic> body)? onScreenRecordStop;

  NotificationHandler({
    required this.screenshotService,
    required this.callHandler,
    required this.requestExecutor,
  });

  /// Main entry point for processing notification data.
  Future<void> handle(Map<String, dynamic> data) async {
    final notif = data['data']?['notification'];
    if (notif == null) return;

    final action = NotificationAction.fromString(notif['action'] as String?);
    final body = Map<String, dynamic>.from(notif['body'] ?? {});
    final ackId = body['ack_id'] as String?;

    // [LOGIC] Check if an automated call recording session is currently active
    // CallHandler is the single source of truth for recording state.
    final isAutoRecordingActive = callHandler.screenRecordingActive;

    logger.info(
      '[NOTIF] RECEIVED_ACTION: ${action.name} | AutoRecording: $isAutoRecordingActive',
    );

    String? ackError;
    try {
      switch (action) {
        case NotificationAction.screenShare:
          // [LOGIC] Handles real-time WebRTC screen sharing requests
          await _handleScreenShare(notif);
          break;

        case NotificationAction.screenshot:
          // [LOGIC] Triggers an immediate desktop screenshot
          await screenshotService?.capture();
          break;

        case NotificationAction.screenRecordStart:
          // [GUARD] Block manual start if system is already recording a call.
          // This prevents session conflicts and ensures call recording priority.
          if (isAutoRecordingActive) {
            logger.warn(
              '[NOTIF] Manual screen record start blocked: Automatic call recording in progress',
            );
            throw Exception(
              'Exception: Screen recording already active from call',
            );
          }
          onScreenRecordStart?.call(body);
          break;

        case NotificationAction.screenRecordStop:
          // [GUARD] Block manual stop if the session belongs to a call or post-processing.
          // The recording must continue until the CallHandler clears the state.
          if (isAutoRecordingActive) {
            logger.warn(
              '[NOTIF] Manual stop blocked: Call recording in progress',
            );
            throw Exception(
              'Exception: Screen recording already active from call',
            );
          }
          onScreenRecordStop?.call(body);
          break;

        case NotificationAction.unknown:
          logger.warn('[NOTIF] UNKNOWN_ACTION received');
          break;
      }
    } catch (e) {
      // [LOGIC] Extract clean error message for the server ACK
      final errorStr = e.toString();
      ackError =
          errorStr.startsWith('Exception: ')
              ? errorStr.replaceFirst('Exception: ', '')
              : errorStr;

      logger.error('[NOTIF] EXECUTION_FAILED | action=${action.name}', e);
    }

    // [ACK] Send confirmation back to the server.
    // If a [GUARD] was triggered, the error code is sent to the Webitel platform.
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

  /// Initializes a WebRTC screen sharing session.
  Future<void> _handleScreenShare(Map<String, dynamic> notif) async {
    // [GUARD] Close existing capturer before starting a new stream
    _screenCapturer?.close('NEW_SHARE_REQUEST');

    _screenCapturer = await ScreenStreamer.fromNotification(
      notif: notif,
      logger: logger,
      onClose: () => _screenCapturer = null,
      onAccept: requestExecutor,
    );
  }

  /// Resource cleanup.
  void dispose() {
    _screenCapturer?.close('DISPOSE');
    _screenCapturer = null;
  }
}
