import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../models/assistant.dart';
import '../models/assistant_chat.dart';
import 'providers.dart';

class AssistantWorkspace {
  const AssistantWorkspace({
    required this.userId,
    this.history = const [],
    this.chat,
    this.saving = false,
    this.saveError,
  });

  final String userId;
  final List<ChatSummary> history;
  final SavedChat? chat;
  final bool saving;
  final String? saveError;

  List<ChatEntry> get entries => chat?.entries ?? const [];
  bool get busy => saving || entries.any((entry) => entry.pending);
}

class AssistantThreads extends AsyncNotifier<AssistantWorkspace?> {
  @override
  Future<AssistantWorkspace?> build() async {
    final user = ref.watch(sessionProvider);
    if (user == null) return null;
    final repo = ref.watch(repositoryProvider);
    final history = await repo.listAssistantChats();
    final latest = history.isEmpty ? null : await repo.getAssistantChat(history.first.id);
    return AssistantWorkspace(userId: user.id, history: history, chat: latest);
  }

  AssistantWorkspace? _current(String uid) {
    if (!ref.mounted || ref.read(sessionProvider)?.id != uid) return null;
    final current = state.asData?.value;
    return current?.userId == uid ? current : null;
  }

  bool isBusy(String uid) => _current(uid)?.busy ?? true;

  void newChat(String uid) {
    final current = _current(uid);
    if (current == null || current.busy) return;
    state = AsyncData(AssistantWorkspace(userId: uid, history: current.history));
  }

  Future<void> openChat(String uid, String id) async {
    final current = _current(uid);
    if (current == null || current.busy || current.chat?.summary.id == id && current.saveError == null) return;
    state = AsyncData(AssistantWorkspace(userId: uid, history: current.history, chat: current.chat, saving: true));
    try {
      final chat = await ref.read(repositoryProvider).getAssistantChat(id);
      if (_current(uid) == null) return;
      state = AsyncData(AssistantWorkspace(userId: uid, history: current.history, chat: chat));
    } catch (_) {
      if (_current(uid) == null) return;
      state = AsyncData(AssistantWorkspace(
        userId: uid, history: current.history, chat: current.chat, saveError: 'Could not open that chat. Try opening it again.',
      ));
    }
  }

  Future<void> addEmailReceipt(String uid, String message) async {
    final current = _current(uid);
    if (current == null || current.busy) return;
    final entry = ChatEntry(
      id: (current.entries.lastOrNull?.id ?? 0) + 1,
      user: false, text: message, at: ref.read(clockProvider)(),
    );
    await _save(uid, _draft(current, [...current.entries, entry]));
  }

  Future<void> send(String uid, String text) async {
    final current = _current(uid);
    final question = text.trim();
    if (current == null || current.busy || question.isEmpty) return;
    final nextId = (current.entries.lastOrNull?.id ?? 0) + 1;
    final now = ref.read(clockProvider)();
    final pending = ChatEntry(id: nextId + 1, user: false, text: '', at: now, pending: true);
    final chat = _draft(current, [
      ...current.entries,
      ChatEntry(id: nextId, user: true, text: question, at: now),
      pending,
    ]);
    await _save(uid, chat);
    await _answer(uid, chat.summary.id, pending);
  }

  Future<void> retry(String uid, int answerId) async {
    final current = _current(uid);
    if (current == null || current.busy) return;
    final index = current.entries.indexWhere((entry) => entry.id == answerId && entry.error != null);
    if (index < 1 || !current.entries[index - 1].user) return;
    final pending = ChatEntry(id: answerId, user: false, text: '', at: ref.read(clockProvider)(), pending: true);
    final entries = [...current.entries]..[index] = pending;
    final chat = _draft(current, entries);
    await _save(uid, chat);
    await _answer(uid, chat.summary.id, pending);
  }

  Future<void> retrySave(String uid) async {
    final current = _current(uid);
    final chat = current?.chat;
    if (chat != null && !current!.busy) await _save(uid, chat);
  }

  SavedChat _draft(AssistantWorkspace current, List<ChatEntry> entries) {
    final firstQuestion = entries.where((entry) => entry.user).firstOrNull?.text ?? 'Email activity';
    return SavedChat(
      summary: ChatSummary(
        current.chat?.summary.id ?? const Uuid().v4(),
        String.fromCharCodes(firstQuestion.replaceAll(RegExp(r'\s+'), ' ').runes.take(160)),
        ref.read(clockProvider)(),
      ),
      version: current.chat?.version ?? 0,
      entries: entries,
    );
  }

  Future<void> _save(String uid, SavedChat draft) async {
    final current = _current(uid);
    if (current == null) return;
    state = AsyncData(AssistantWorkspace(userId: uid, history: current.history, chat: draft, saving: true));
    try {
      final saved = await ref.read(repositoryProvider).saveAssistantChat(
        draft.summary, draft.entries, version: draft.version == 0 ? null : draft.version,
      );
      if (_current(uid)?.chat?.summary.id != draft.summary.id) return;
      final history = [saved.summary, ...current.history.where((item) => item.id != saved.summary.id)];
      final active = SavedChat(summary: saved.summary, version: saved.version, entries: draft.entries);
      state = AsyncData(AssistantWorkspace(userId: uid, history: history, chat: active));
    } catch (error) {
      if (_current(uid)?.chat?.summary.id != draft.summary.id) return;
      state = AsyncData(AssistantWorkspace(
        userId: uid, history: current.history, chat: draft,
        saveError: error is AssistantFailure ? error.message : 'This chat could not be saved. Try saving again.',
      ));
    }
  }

  Future<void> _answer(String uid, String chatId, ChatEntry pending) async {
    final current = _current(uid);
    if (current?.chat?.summary.id != chatId) return;
    final history = <ChatTurn>[
      for (final entry in current!.entries.takeWhile((entry) => entry.id != pending.id))
        if (entry.user)
          ChatTurn('user', entry.text)
        else if (entry.reply != null)
          ChatTurn('assistant', entry.reply!.answer, contextTools: entry.reply!.contextTools),
    ];
    ChatEntry done;
    try {
      final reply = await ref.read(repositoryProvider).ask(history);
      if (_current(uid)?.chat?.summary.id != chatId) return;
      done = ChatEntry(id: pending.id, user: false, text: reply.answer, at: ref.read(clockProvider)(), reply: reply);
    } catch (error) {
      done = ChatEntry(
        id: pending.id, user: false, text: '', at: pending.at,
        error: error is AssistantFailure ? error.message : 'The assistant could not answer right now. Try again.',
      );
    }
    final latest = _current(uid);
    if (latest?.chat?.summary.id != chatId) return;
    await _save(uid, _draft(latest!, [
      for (final entry in latest.entries) entry.id == pending.id ? done : entry,
    ]));
  }
}

final assistantThreadsProvider =
    AsyncNotifierProvider<AssistantThreads, AssistantWorkspace?>(AssistantThreads.new);
