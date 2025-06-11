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
    required this.team,
    required this.channels,
  });

  factory AgentSession.fromJson(Map<String, dynamic> json) {
    return AgentSession(
      agentId: json['agent_id'],
      isAdmin: json['is_admin'],
      isSupervisor: json['is_supervisor'],
      status: json['status'],
      statusDuration: json['status_duration'],
      lastStatusChange: json['last_status_change'],
      onDemand: json['on_demand'],
      statusPayload: json['status_payload'],
      team: json['team'] != null ? Team.fromJson(json['team']) : null,
      channels:
          (json['channels'] as List)
              .map((e) => AgentChannel.fromJson(e))
              .toList(),
    );
  }
}

class Team {
  final int id;
  final String name;

  Team({required this.id, required this.name});

  factory Team.fromJson(Map<String, dynamic> json) {
    return Team(id: json['id'], name: json['name']);
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
      channel: json['channel'],
      joinedAt: json['joined_at'],
      maxOpen: json['max_open'],
      noAnswer: json['no_answer'],
      open: json['open'],
      state: json['state'],
    );
  }
}
