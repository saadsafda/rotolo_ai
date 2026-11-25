import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/assistant.dart';
import 'providers.dart';

class ChatEntry {
  const ChatEntry({
    required this.id,
    required this.user,
    required this.text,
    required this.at,
    this.reply,
    this.error,
    this.pending = false,
    this.feedback = 0,
  });

  final int id;
  final bool user;
  final String text;
  final DateTime at;
  final AssistantReply? reply;
  final String? error;
  final bool pending;
  final int feedback; // 1 helpful, -1 not helpful (kept on this device)

  ChatEntry copyWith({AssistantReply? reply, String? error, bool? pending, int? feedback}) => ChatEntry(
        id: id,
        user: user,
        text: text,
        at: at,
        reply: reply ?? this.reply,
        error: error ?? this.error,
        pending: pending ?? this.pending,
        feedback: feedback ?? this.feedback,
      );
}

/// Conversations per signed-in user, kept in memory for this app session.
/// Keyed by user id instead of watching the session, so an account switch can
/// never show someone else's thread or rebuild providers mid-frame.
class AssistantThreads extends Notifier<Map<String, List<ChatEntry>>> {
  int _seq = 0;

  @override
  Map<String, List<ChatEntry>> build() => const {};

  List<ChatEntry> _thread(String uid) => state[uid] ?? const [];
  void _set(String uid, List<ChatEntry> t) => state = {...state, uid: t};

  bool isBusy(String uid) => _thread(uid).any((e) => e.pending);

  void addEmailReceipt(String uid, String message) {
    _set(uid, [..._thread(uid), ChatEntry(id: ++_seq, user: false, text: message, at: ref.read(clockProvider)())]);
  }

  Future<void> send(String uid, String text) async {
    final q = text.trim();
    if (q.isEmpty || isBusy(uid)) return;
    final now = ref.read(clockProvider)();
    final question = ChatEntry(id: ++_seq, user: true, text: q, at: now);
    final answer = ChatEntry(id: ++_seq, user: false, text: '', at: now, pending: true);
    _set(uid, [..._thread(uid), question, answer]);
    await _answer(uid, answer.id);
  }

  Future<void> retry(String uid, int answerId) async {
    final t = _thread(uid);
    final i = t.indexWhere((e) => e.id == answerId);
    if (i < 0 || isBusy(uid)) return;
    _set(uid, [...t.take(i), ChatEntry(id: answerId, user: false, text: '', at: ref.read(clockProvider)(), pending: true), ...t.skip(i + 1)]);
    await _answer(uid, answerId);
  }

  Future<void> _answer(String uid, int answerId) async {
    // Conversation up to (not including) the pending answer; failed turns are left out.
    final history = <ChatTurn>[
      for (final e in _thread(uid).takeWhile((e) => e.id != answerId))
        if (e.user)
          ChatTurn('user', e.text)
        else if (e.reply != null)
          ChatTurn('assistant', e.reply!.answer),
    ];
    ChatEntry done;
    final pending = _thread(uid).firstWhere((e) => e.id == answerId);
    try {
      final reply = await ref.read(repositoryProvider).ask(history);
      done = ChatEntry(id: answerId, user: false, text: reply.answer, at: ref.read(clockProvider)(), reply: reply);
    } on AssistantFailure catch (e) {
      done = ChatEntry(id: answerId, user: false, text: '', at: pending.at, error: e.message);
    } catch (_) {
      done = ChatEntry(id: answerId, user: false, text: '', at: pending.at, error: 'The assistant could not answer right now. Try again.');
    }
    _set(uid, [for (final e in _thread(uid)) e.id == answerId ? done : e]);
  }

  void setFeedback(String uid, int id, int value) =>
      _set(uid, [for (final e in _thread(uid)) e.id == id ? e.copyWith(feedback: e.feedback == value ? 0 : value) : e]);

  void clear(String uid) => _set(uid, const []);
}

final assistantThreadsProvider =
    NotifierProvider<AssistantThreads, Map<String, List<ChatEntry>>>(AssistantThreads.new);
