import 'assistant.dart';
import 'json.dart';

class ChatEntry {
  const ChatEntry({
    required this.id,
    required this.user,
    required this.text,
    required this.at,
    this.reply,
    this.error,
    this.pending = false,
  });

  final int id;
  final bool user;
  final String text;
  final DateTime at;
  final AssistantReply? reply;
  final String? error;
  final bool pending;

  factory ChatEntry.fromJson(Json json) => ChatEntry(
        id: asInt(json['id'])!,
        user: asBool(json['user']) ?? false,
        text: asString(json['text']) ?? '',
        at: asDateTime(json['at'])!,
        reply: json['reply'] is Map ? AssistantReply.fromJson(asMap(json['reply'])) : null,
        error: json['pending'] == true ? 'This reply was interrupted. Try again.' : asString(json['error']),
      );

  Json toJson() => {
        'id': id, 'user': user, 'text': text, 'at': at.toIso8601String(),
        'reply': reply?.toJson(), 'error': error, 'pending': pending,
      };
}

class ChatSummary {
  const ChatSummary(this.id, this.title, this.updatedAt);
  final String id;
  final String title;
  final DateTime updatedAt;

  factory ChatSummary.fromJson(Json json) =>
      ChatSummary(asString(json['id'])!, asString(json['title'])!, asDateTime(json['updated_at'])!);
}

class SavedChat {
  const SavedChat({required this.summary, required this.version, required this.entries});
  final ChatSummary summary;
  final int version;
  final List<ChatEntry> entries;

  factory SavedChat.fromJson(Json json) => SavedChat(
        summary: ChatSummary.fromJson(json),
        version: asInt(json['version'])!,
        entries: asMapList(json['entries']).map(ChatEntry.fromJson).toList(),
      );
}
