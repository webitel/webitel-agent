// FIXME DRAFT HARDCODED MP4 RECORDING COMMAND
// if (Platform.isMacOS) {
//   final screenIndices = await getMacScreenIndices();
//   debugPrint('🎥 Found Mac screens: $screenIndices');
//
//   if (screenIndices.isEmpty) {
//     throw Exception('No screens detected for recording.');
//   }
//
//   final inputs = screenIndices
//       .map((i) => '-f avfoundation -framerate 30 -i "$i:none"')
//       .join(' ');
//
//   if (screenIndices.length == 1) {
//     ffmpegCommand =
//         '$inputs  -vcodec libx264 -pix_fmt yuv420p -preset ultrafast -y $filePath';
//   } else {
//     final filters =
//         List.generate(
//           screenIndices.length,
//           (i) => '[$i:v]scale=-2:1080[v$i];',
//         ).join();
//     final stackChain =
//         List.generate(screenIndices.length, (i) => '[v$i]').join();
//
//     ffmpegCommand =
//         '$inputs -filter_complex "$filters$stackChain hstack=inputs=${screenIndices.length}" '
//         ' -vcodec libx264 -pix_fmt yuv420p -preset ultrafast -y $filePath';
//   }
// }

// Future<void> startRecording({required String recordingId}) async {
//   if (_isRecording) return;
//
//   final timestamp = DateTime.now().millisecondsSinceEpoch;
//
//   String? ffmpegCommand;
//
//   if (Platform.isMacOS) {
//     final directory = await _getVideoDirectory();
//     final filePath = '${directory.path}/${recordingId}_$timestamp.mp4';
//     _recordingFilePath = filePath;
//     _videoFile = File(filePath);
//
//     ffmpegCommand =
//         '-f avfoundation -framerate 30 -i "3:none" -vcodec libx264 -pix_fmt yuv420p $filePath';
//     _recordingFilePath = filePath;
//     _videoFile = File(filePath);
//
//     // await Directory(
//     //   '/Users/volodiahunkalo/Downloads/development/webitel-agent-flutter/webitel-agent/videos',
//     // ).create(recursive: true);
//     //
//     // ffmpegCommand =
//     //     '-f avfoundation -framerate 30 -i "3:none" -vcodec libx264 -pix_fmt yuv420p -preset ultrafast $filePath';
//   } else if (Platform.isWindows) {
//     final directory = await _getVideoDirectory();
//     _recordingFilePath = '${directory.path}/${recordingId}_$timestamp.mp4';
//     _videoFile = File(_recordingFilePath!);
//
//     ffmpegCommand =
//         '-f gdigrab -framerate 30 -i desktop -vcodec libx264 -pix_fmt yuv420p -preset ultrafast $_recordingFilePath';
//   } else {
//     throw UnsupportedError('Recording not supported on this platform');
//   }
//
//   _isRecording = true;
//
//   _currentSession = await FFmpegKit.executeAsync(ffmpegCommand ?? '', (
//     session,
//   ) async {
//     final returnCode = await session.getReturnCode();
//     final logs = await session.getAllLogsAsString();
//
//     if (ReturnCode.isSuccess(returnCode)) {
//       if (_recordingFilePath != null &&
//           File(_recordingFilePath!).existsSync()) {
//         final fileSize = await File(_recordingFilePath!).length();
//         debugPrint(
//           '✅ Recording saved: $_recordingFilePath (${fileSize ~/ 1024} KB)',
//         );
//       } else {
//         debugPrint('❌ File not created: $_recordingFilePath');
//       }
//     } else {
//       debugPrint('❌ Recording failed with return code $returnCode');
//       debugPrint('FFmpeg logs:\n$logs');
//     }
//     _isRecording = false;
//   });
//
//   debugPrint('Started screen recording to $_recordingFilePath');
// }

// FIXME DRAFT FOR MKV RECORDING ; COMMENTED AS CPU INTENSIVE ON MAC
// if (Platform.isMacOS) {
//   final screenIndices = await getMacScreenIndices();
//   logger.info('Found Mac screens: $screenIndices');
//
//   if (screenIndices.isEmpty) {
//     throw Exception('No screens detected for recording.');
//   }
//   final inputs = screenIndices
//       .map((i) => '-f avfoundation -framerate 30 -i "$i:none"')
//       .join(' ');
//
//   if (screenIndices.length == 1) {
//     ffmpegCommand =
//         '$inputs -vf "scale=640:480" '
//         '-c:v libx265 -pix_fmt yuv420p -preset ultrafast -y $filePath';
//   } else {
//     final filters =
//         List.generate(
//           screenIndices.length,
//           (i) => '[$i:v]scale=640:480[v$i];',
//         ).join();
//     final stackChain =
//         List.generate(screenIndices.length, (i) => '[v$i]').join();
//
//     ffmpegCommand =
//         '$inputs -filter_complex "$filters$stackChain hstack=inputs=${screenIndices.length}" '
//         ' -c:v libx265 -pix_fmt yuv420p -preset ultrafast -y $filePath';
//   }
// }
// FIXME DRAFT FOR MP4 RECORDING; COMMENTED AS CPU INTENSIVE ON MAC
//
// if (Platform.isMacOS) {
//   final screenIndices = await getMacScreenIndices();
//   logger.i('🎥 Found Mac screens: $screenIndices');
//
//   if (screenIndices.isEmpty) {
//     throw Exception('No screens detected for recording.');
//   }
//
//   final inputs = screenIndices
//       .map((i) => '-f avfoundation -framerate 30 -i "$i:none"')
//       .join(' ');
//
//   if (screenIndices.length == 1) {
//     ffmpegCommand =
//         '$inputs -vf "scale=640:480" -vcodec libx264 -pix_fmt yuv420p '
//         '-preset ultrafast -y $filePath';
//   } else {
//     final filters = List.generate(
//       screenIndices.length,
//       (i) => '[$i:v]scale=640:480[v$i];',
//     ).join();
//     final stackChain =
//         List.generate(screenIndices.length, (i) => '[v$i]').join();
//
//     ffmpegCommand =
//         '$inputs -filter_complex "$filters$stackChain hstack=inputs=${screenIndices.length}" '
//         '-vcodec libx264 -pix_fmt yuv420p -preset ultrafast -y $filePath';
//   }
// }
