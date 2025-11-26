import 'package:fixnum/fixnum.dart' as fixnum;
import 'package:grpc/grpc.dart';
import 'package:webitel_desk_track/core/logger.dart';
import 'package:webitel_desk_track/protoc/opentelemetry/gen/opentelemetry/collector/logs/v1/logs_service.pbgrpc.dart';
import 'package:webitel_desk_track/protoc/opentelemetry/gen/opentelemetry/common/v1/common.pb.dart';
import 'package:webitel_desk_track/protoc/opentelemetry/gen/opentelemetry/logs/v1/logs.pb.dart';
import 'package:webitel_desk_track/protoc/opentelemetry/gen/opentelemetry/resource/v1/resource.pb.dart';

class OtelLogClient {
  final LogsServiceClient client;

  OtelLogClient(String endpoint)
    : client = LogsServiceClient(
        ClientChannel(
          Uri.parse(endpoint).host,
          port: Uri.parse(endpoint).port,
          options: const ChannelOptions(
            credentials: ChannelCredentials.insecure(),
          ),
        ),
      );

  Future<void> exportLog(String message, String severity) async {
    final logRecord = LogRecord(
      timeUnixNano: fixnum.Int64(DateTime.now().microsecondsSinceEpoch * 1000),
      body: AnyValue(stringValue: message),
      severityText: severity,
    );

    final resourceLogs = ResourceLogs(
      resource: Resource(
        attributes: [
          KeyValue(
            key: "service.name",
            value: AnyValue(stringValue: "webitel-desk-track"),
          ),
        ],
      ),
      scopeLogs: [
        ScopeLogs(logRecords: [logRecord]),
      ],
    );

    final request = ExportLogsServiceRequest(resourceLogs: [resourceLogs]);

    try {
      await client.export(request);
    } catch (e) {
      logger.error("Failed to export log to OpenTelemetry: $e");
    }
  }
}
