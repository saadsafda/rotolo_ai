import 'json.dart';

/// One reply from the `ask-portfolio` function. Text comes from the model;
/// [blocks] and [sources] are built on the server from the records, so every
/// figure in a card is exact.
class AssistantReply {
  const AssistantReply({
    required this.answer,
    this.blocks = const [],
    this.sources = const [],
    this.suggestions = const [],
    this.dataMode,
    this.asOf,
  });

  final String answer;
  final List<AssistantBlock> blocks;
  final List<AssistantSource> sources;
  final List<String> suggestions;
  final String? dataMode;
  final DateTime? asOf;

  factory AssistantReply.fromJson(Json j) => AssistantReply(
        answer: asString(j['answer']) ?? '',
        blocks: [for (final b in asMapList(j['blocks'])) ?AssistantBlock.tryParse(b)],
        sources: asMapList(j['sources']).map(AssistantSource.fromJson).toList(),
        suggestions: asStringList(j['suggestions']),
        dataMode: asString(j['data_mode']),
        asOf: asDateTime(j['as_of']),
      );
}

sealed class AssistantBlock {
  const AssistantBlock();
  static AssistantBlock? tryParse(Json j) => switch (asString(j['type'])) {
        'metric' => MetricBlock(
            label: asString(j['label']) ?? '',
            value: asString(j['value']) ?? '',
            caption: asString(j['caption']),
            chipText: asString(asMap(j['chip'])['text']),
            chipTone: asString(asMap(j['chip'])['tone']),
          ),
        'bars' => BarsBlock(
            title: asString(j['title']),
            bars: [
              for (final b in asMapList(j['bars']))
                BarDatum(
                  label: asString(b['label']) ?? '',
                  value: (b['value'] is num) ? (b['value'] as num).toDouble() : 0,
                  display: asString(b['display']) ?? '',
                  highlight: asBool(b['highlight']) ?? false,
                ),
            ],
          ),
        'list' => ListBlock(
            title: asString(j['title']) ?? '',
            items: [
              for (final i in asMapList(j['items']))
                ListItem(
                  title: asString(i['title']) ?? '',
                  subtitle: asString(i['subtitle']),
                  trailing: asString(i['trailing']),
                  tone: asString(i['tone']),
                  route: _safeRoute(asString(i['route'])),
                ),
            ],
          ),
        'draft' => DraftBlock(
            title: asString(j['title']) ?? 'Draft',
            body: asString(j['body']) ?? '',
            note: asString(j['note']) ?? 'Not sent.',
          ),
        _ => null,
      };
}

class MetricBlock extends AssistantBlock {
  const MetricBlock({required this.label, required this.value, this.caption, this.chipText, this.chipTone});
  final String label;
  final String value;
  final String? caption;
  final String? chipText;
  final String? chipTone;
}

class BarDatum {
  const BarDatum({required this.label, required this.value, required this.display, this.highlight = false});
  final String label;
  final double value;
  final String display;
  final bool highlight;
}

class BarsBlock extends AssistantBlock {
  const BarsBlock({this.title, required this.bars});
  final String? title;
  final List<BarDatum> bars;
}

class ListItem {
  const ListItem({required this.title, this.subtitle, this.trailing, this.tone, this.route});
  final String title;
  final String? subtitle;
  final String? trailing;
  final String? tone;
  final String? route;
}

class ListBlock extends AssistantBlock {
  const ListBlock({required this.title, required this.items});
  final String title;
  final List<ListItem> items;
}

class DraftBlock extends AssistantBlock {
  const DraftBlock({required this.title, required this.body, required this.note});
  final String title;
  final String body;
  final String note;
}

class AssistantSource {
  const AssistantSource({required this.kind, required this.title, required this.subtitle, this.route});
  final String kind; // ledger | lease | deal | email | tasks | time | payments | report
  final String title;
  final String subtitle;
  final String? route;

  factory AssistantSource.fromJson(Json j) => AssistantSource(
        kind: asString(j['kind']) ?? 'report',
        title: asString(j['title']) ?? '',
        subtitle: asString(j['subtitle']) ?? '',
        route: _safeRoute(asString(j['route'])),
      );
}

/// Only in-app paths are followed; anything else from the server is dropped.
String? _safeRoute(String? r) =>
    r != null && RegExp(r'^/(reports|payments|tasks|more)(/[A-Za-z0-9_\-/]*)?$').hasMatch(r) ? r : null;

/// What the user sees as an error bubble.
class AssistantFailure implements Exception {
  const AssistantFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class ChatTurn {
  const ChatTurn(this.role, this.text);
  final String role; // user | assistant
  final String text;
  Json toJson() => {'role': role, 'text': text};
}
