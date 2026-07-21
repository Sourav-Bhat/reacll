class Person {
  final int id;
  final String name;
  final String? company; // disambiguator: "Sonnetix", "Acme (prev)", "Friends"
  final String? role;
  final String? email;
  final String? notes;
  final int convoCount;
  const Person({
    required this.id,
    required this.name,
    this.company,
    this.role,
    this.email,
    this.notes,
    this.convoCount = 0,
  });

  /// "Ravi · Sonnetix" when a company is set — disambiguates same names.
  String get label => (company != null && company!.trim().isNotEmpty)
      ? '$name · ${company!.trim()}'
      : name;

  /// "Role · Company" for list subtitles, or null if neither set.
  String? get subtitle {
    final parts = [role, company]
        .where((s) => s != null && s.trim().isNotEmpty)
        .map((s) => s!.trim())
        .toList();
    return parts.isEmpty ? null : parts.join(' · ');
  }
}

class ConversationSummary {
  final int id;
  final String title;
  final DateTime happenedAt;
  final int durationSec;
  final String peopleNames; // "Priya, Ravi" or ''
  final bool busy; // still transcribing
  const ConversationSummary({
    required this.id,
    required this.title,
    required this.happenedAt,
    required this.durationSec,
    required this.peopleNames,
    required this.busy,
  });
}

class Artifact {
  final int id;
  final int conversationId;
  final String kind; // recording | imported_audio | transcript | note
  final String? filePath;
  final String status; // pending | transcribing | done | failed
  const Artifact({
    required this.id,
    required this.conversationId,
    required this.kind,
    required this.filePath,
    required this.status,
  });
}

class ConversationDetail {
  final int id;
  final String title;
  final DateTime happenedAt;
  final int durationSec;
  final List<Person> people; // attendees
  final List<Person> mentioned; // referenced only, not present
  final List<String> topics;
  final List<Artifact> artifacts;
  final String transcriptText; // concatenated transcripts
  const ConversationDetail({
    required this.id,
    required this.title,
    required this.happenedAt,
    required this.durationSec,
    required this.people,
    this.mentioned = const [],
    required this.topics,
    required this.artifacts,
    required this.transcriptText,
  });
}

class Fact {
  final int id;
  final int conversationId;
  final String kind; // commitment | decision | fact | thread
  final String text;
  final String? personName; // raw extracted name (may be unresolved)
  final String? resolvedName; // linked person's name
  final String? dueHint;
  final DateTime happenedAt;
  final bool superseded;
  final String status; // open | done | dismissed
  final String conversationTitle;
  const Fact({
    required this.id,
    required this.conversationId,
    required this.kind,
    required this.text,
    this.personName,
    this.resolvedName,
    this.dueHint,
    required this.happenedAt,
    this.superseded = false,
    this.status = 'open',
    this.conversationTitle = '',
  });
}

class Clarification {
  final int id;
  final int conversationId;
  final String question;
  final String? reason;
  final int? factId;
  final String kind; // 'text' | 'speaker' (FR-15 enrollment)
  final int? speakerLabel;
  const Clarification({
    required this.id,
    required this.conversationId,
    required this.question,
    this.reason,
    this.factId,
    this.kind = 'text',
    this.speakerLabel,
  });
}

class SearchHit {
  final int conversationId;
  final String title;
  final DateTime happenedAt;
  final String snippet; // matched words wrapped in [ ]
  const SearchHit({
    required this.conversationId,
    required this.title,
    required this.happenedAt,
    required this.snippet,
  });
}
