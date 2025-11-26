enum NotificationAction {
  screenShare,
  screenshot,
  screenRecordStart,
  screenRecordStop,
  unknown;

  static NotificationAction fromString(String? action) {
    switch (action) {
      case 'screen_share':
        return NotificationAction.screenShare;
      case 'screenshot':
        return NotificationAction.screenshot;
      case 'ss_record_start':
        return NotificationAction.screenRecordStart;
      case 'ss_record_stop':
        return NotificationAction.screenRecordStop;
      default:
        return NotificationAction.unknown;
    }
  }
}
