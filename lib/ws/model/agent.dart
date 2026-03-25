class AgentSession {
  final int agentId;
  final bool isAdmin;
  final bool isSupervisor;
  final String status;
  final int statusDuration;
  final int lastStatusChange;
  final bool onDemand;
  final String statusPayload;
  final Team? team;
  final List<AgentChannel> channels;

  AgentSession({
    required this.agentId,
    required this.isAdmin,
    required this.isSupervisor,
    required this.status,
    required this.statusDuration,
    required this.lastStatusChange,
    required this.onDemand,
    required this.statusPayload,
    this.team,
    required this.channels,
  });

  factory AgentSession.fromJson(Map<String, dynamic> json) {
    // Safe parsing of channels list to avoid "Null is not a subtype of List"
    final channelsData = json['channels'];
    final List<AgentChannel> channelList = [];

    if (channelsData is List) {
      for (var item in channelsData) {
        if (item is Map<String, dynamic>) {
          channelList.add(AgentChannel.fromJson(item));
        }
      }
    }

    return AgentSession(
      agentId: json['agent_id'] ?? 0,
      isAdmin: json['is_admin'] ?? false,
      isSupervisor: json['is_supervisor'] ?? false,
      status: json['status'] ?? 'offline',
      statusDuration: json['status_duration'] ?? 0,
      lastStatusChange: json['last_status_change'] ?? 0,
      onDemand: json['on_demand'] ?? false,
      statusPayload: json['status_payload'] ?? '',
      team:
          json['team'] != null
              ? Team.fromJson(json['team'] as Map<String, dynamic>)
              : null,
      channels: channelList,
    );
  }
}

class Team {
  final int id;
  final String name;

  Team({required this.id, required this.name});

  factory Team.fromJson(Map<String, dynamic> json) {
    return Team(id: json['id'] ?? 0, name: json['name'] ?? '');
  }
}

class AgentChannel {
  final String channel;
  final int joinedAt;
  final int maxOpen;
  final int noAnswer;
  final int open;
  final String state;

  AgentChannel({
    required this.channel,
    required this.joinedAt,
    required this.maxOpen,
    required this.noAnswer,
    required this.open,
    required this.state,
  });

  factory AgentChannel.fromJson(Map<String, dynamic> json) {
    return AgentChannel(
      channel: json['channel'] ?? 'unknown',
      joinedAt: json['joined_at'] ?? 0,
      maxOpen: json['max_open'] ?? 0,
      noAnswer: json['no_answer'] ?? 0,
      open: json['open'] ?? 0,
      state: json['state'] ?? 'idle',
    );
  }
}
