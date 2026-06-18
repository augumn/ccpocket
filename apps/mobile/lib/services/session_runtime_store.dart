import '../models/messages.dart';

class ExplorerHistorySnapshot {
  const ExplorerHistorySnapshot({
    this.currentPath = '',
    this.recentPeekedFiles = const [],
  });

  final String currentPath;
  final List<String> recentPeekedFiles;
}

class SessionRuntimeSnapshot {
  const SessionRuntimeSnapshot({
    required this.sessionId,
    this.messages = const [],
    this.historySeq = 0,
    this.cachedHistorySeq = 0,
    this.explorerHistory = const ExplorerHistorySnapshot(),
  });

  final String sessionId;
  final List<ServerMessage> messages;

  /// Highest history sequence observed from the bridge.
  final int historySeq;

  /// Highest contiguous history sequence represented by [messages].
  ///
  /// This can lag behind [historySeq] when live messages arrive with a gap
  /// (for example an input_ack advances acceptedSeq before the corresponding
  /// user_input is cached).
  final int cachedHistorySeq;
  final ExplorerHistorySnapshot explorerHistory;
}

class SessionRuntimeState {
  SessionRuntimeState({required this.sessionId});

  final String sessionId;
  final List<ServerMessage> _messages = [];
  final List<int?> _messageSeqs = [];
  int historySeq = 0;
  int cachedHistorySeq = 0;
  ExplorerHistorySnapshot explorerHistory = const ExplorerHistorySnapshot();

  List<ServerMessage> get messages => List.unmodifiable(_messages);
}

class SessionRuntimeStore {
  SessionRuntimeStore({this.maxMessagesPerSession = 200});

  final int maxMessagesPerSession;
  final Map<String, SessionRuntimeState> _sessions = {};

  SessionRuntimeSnapshot snapshot(String sessionId) {
    final state = _sessions[sessionId];
    if (state == null) {
      return SessionRuntimeSnapshot(sessionId: sessionId);
    }
    return SessionRuntimeSnapshot(
      sessionId: sessionId,
      messages: state.messages,
      historySeq: state.historySeq,
      cachedHistorySeq: state.cachedHistorySeq,
      explorerHistory: state.explorerHistory,
    );
  }

  List<ServerMessage> messages(String sessionId) =>
      snapshot(sessionId).messages;

  int latestHistorySeq(String sessionId) => snapshot(sessionId).historySeq;

  int cachedHistorySeq(String sessionId) =>
      snapshot(sessionId).cachedHistorySeq;

  void applyServerMessage(
    String sessionId,
    ServerMessage message, {
    int? historySeq,
  }) {
    final state = _stateFor(sessionId);
    if (_shouldIgnore(message)) {
      _recordLatestSeq(state, historySeq);
      return;
    }
    if (message is HistoryMessage) {
      final incomingMessages = message.messages
          .where((m) => !_shouldIgnore(m))
          .toList();
      final hasSequencedRuntime = state.historySeq > 0 || state.cachedHistorySeq > 0;
      if (!hasSequencedRuntime || state._messages.isEmpty) {
        state._messages
          ..clear()
          ..addAll(incomingMessages);
        state._messageSeqs
          ..clear()
          ..addAll(List<int?>.filled(state._messages.length, null));
        state.historySeq = 0;
        state.cachedHistorySeq = 0;
      } else {
        for (final incoming in incomingMessages) {
          _mergeUnsequencedHistoryMessage(state, incoming);
        }
      }
      _trim(state);
      return;
    }
    if (message is HistorySnapshotMessage) {
      final previousBySeq = <int, ServerMessage>{};
      for (var i = 0; i < state._messages.length; i++) {
        final seq = state._messageSeqs[i];
        if (seq != null) {
          previousBySeq[seq] = state._messages[i];
        }
      }

      final nextMessages = <ServerMessage>[];
      final nextSeqs = <int?>[];
      for (final entry in message.entries) {
        if (_shouldIgnore(entry.message)) continue;
        final previous = previousBySeq[entry.seq];
        nextMessages.add(
          previous == null
              ? entry.message
              : _mergeEquivalentMessage(previous, entry.message),
        );
        nextSeqs.add(entry.seq);
      }

      state._messages
        ..clear()
        ..addAll(nextMessages);
      state._messageSeqs
        ..clear()
        ..addAll(nextSeqs);
      state.historySeq = message.toSeq;
      state.cachedHistorySeq = message.toSeq;
      _trim(state);
      return;
    }
    if (message is HistoryDeltaMessage) {
      final previousCachedSeq = state.cachedHistorySeq;
      if (state.cachedHistorySeq == 0 &&
          state._messages.isNotEmpty &&
          message.fromSeq <= 1) {
        _clearMessages(state);
      }
      _mergeHistoryEntries(state, message.entries);
      _recordLatestSeq(state, message.toSeq);
      if (_deltaExtendsCachedHistory(previousCachedSeq, message)) {
        state.cachedHistorySeq = message.toSeq;
        _advanceCachedHistorySeq(state);
      }
      _trim(state);
      return;
    }

    final messageSeq = _representsHistoryEntry(message) ? historySeq : null;
    _upsertMessage(state, message, messageSeq);
    _recordLatestSeq(state, historySeq);
    if (messageSeq != null && messageSeq <= state.cachedHistorySeq + 1) {
      if (messageSeq > state.cachedHistorySeq) {
        state.cachedHistorySeq = messageSeq;
      }
      _advanceCachedHistorySeq(state);
    }
    _trim(state);
  }

  ExplorerHistorySnapshot getExplorerHistory(String sessionId) =>
      snapshot(sessionId).explorerHistory;

  void setExplorerHistory(
    String sessionId, {
    required String currentPath,
    required List<String> recentPeekedFiles,
  }) {
    final normalizedPath = currentPath.trim();
    final normalizedFiles = recentPeekedFiles
        .map((file) => file.trim())
        .where((file) => file.isNotEmpty)
        .take(10)
        .toList();
    if (normalizedPath.isEmpty && normalizedFiles.isEmpty) {
      final state = _sessions[sessionId];
      if (state == null) return;
      state.explorerHistory = const ExplorerHistorySnapshot();
      _removeIfEmpty(state);
      return;
    }
    _stateFor(sessionId).explorerHistory = ExplorerHistorySnapshot(
      currentPath: normalizedPath,
      recentPeekedFiles: normalizedFiles,
    );
  }

  void migrateSession(String fromSessionId, String toSessionId) {
    if (fromSessionId == toSessionId) return;
    final source = _sessions.remove(fromSessionId);
    if (source == null) return;
    final target = _stateFor(toSessionId);
    if (source._messages.isNotEmpty) {
      target._messages
        ..clear()
        ..addAll(source._messages);
      target._messageSeqs
        ..clear()
        ..addAll(source._messageSeqs);
    }
    target.historySeq = source.historySeq;
    target.cachedHistorySeq = source.cachedHistorySeq;
    target.explorerHistory = source.explorerHistory;
    _trim(target);
  }

  void clearSession(String sessionId) {
    _sessions.remove(sessionId);
  }

  void clearAll() {
    _sessions.clear();
  }

  SessionRuntimeState _stateFor(String sessionId) {
    return _sessions.putIfAbsent(
      sessionId,
      () => SessionRuntimeState(sessionId: sessionId),
    );
  }

  bool _shouldIgnore(ServerMessage message) {
    return message is PastHistoryMessage ||
        message is StreamDeltaMessage ||
        message is ThinkingDeltaMessage ||
        message is InputAckMessage ||
        message is InputRejectedMessage;
  }

  bool _representsHistoryEntry(ServerMessage message) =>
      !_shouldIgnore(message);

  void _recordLatestSeq(SessionRuntimeState state, int? historySeq) {
    if (historySeq != null && historySeq > state.historySeq) {
      state.historySeq = historySeq;
    }
  }

  void _clearMessages(SessionRuntimeState state) {
    state._messages.clear();
    state._messageSeqs.clear();
  }

  void _mergeHistoryEntries(
    SessionRuntimeState state,
    List<HistoryEntry> entries,
  ) {
    for (final entry in entries) {
      if (_shouldIgnore(entry.message)) continue;
      _upsertMessage(state, entry.message, entry.seq);
    }
    _sortSequencedMessages(state);
  }

  void _upsertMessage(
    SessionRuntimeState state,
    ServerMessage message,
    int? historySeq,
  ) {
    final existingIndex = historySeq == null
        ? -1
        : state._messageSeqs.indexOf(historySeq);
    if (existingIndex >= 0) {
      state._messages[existingIndex] = _mergeEquivalentMessage(
        state._messages[existingIndex],
        message,
      );
      state._messageSeqs[existingIndex] = historySeq;
      return;
    }
    state._messages.add(message);
    state._messageSeqs.add(historySeq);
  }

  void _mergeUnsequencedHistoryMessage(
    SessionRuntimeState state,
    ServerMessage message,
  ) {
    final existingIndex = state._messages.indexWhere(
      (existing) => _messagesEquivalent(existing, message),
    );
    if (existingIndex >= 0) {
      state._messages[existingIndex] = _mergeEquivalentMessage(
        state._messages[existingIndex],
        message,
      );
      return;
    }
    _upsertMessage(state, message, null);
  }

  ServerMessage _mergeEquivalentMessage(
    ServerMessage existing,
    ServerMessage incoming,
  ) {
    if (existing is UserInputMessage && incoming is UserInputMessage) {
      return UserInputMessage(
        text: existing.text.isNotEmpty ? existing.text : incoming.text,
        clientMessageId: existing.clientMessageId ?? incoming.clientMessageId,
        userMessageUuid: existing.userMessageUuid ?? incoming.userMessageUuid,
        isSynthetic: existing.isSynthetic || incoming.isSynthetic,
        isMeta: existing.isMeta || incoming.isMeta,
        imageCount: incoming.imageCount > 0
            ? incoming.imageCount
            : existing.imageCount,
        imageUrls: incoming.imageUrls.isNotEmpty
            ? incoming.imageUrls
            : existing.imageUrls,
        timestamp: existing.timestamp ?? incoming.timestamp,
      );
    }
    if (existing is AssistantServerMessage && incoming is AssistantServerMessage) {
      return _mergeAssistantServerMessage(existing, incoming);
    }
    return incoming;
  }

  bool _messagesEquivalent(ServerMessage a, ServerMessage b) {
    if (a is UserInputMessage && b is UserInputMessage) {
      if (_userMessagesEquivalent(a, b)) return true;
    }

    final aStableKey = _messageStableKey(a);
    final bStableKey = _messageStableKey(b);
    if (aStableKey != null && bStableKey != null) {
      return aStableKey == bStableKey;
    }

    final aWeakKey = _messageWeakKey(a);
    final bWeakKey = _messageWeakKey(b);
    if (aWeakKey != null && bWeakKey != null) {
      return aWeakKey == bWeakKey;
    }

    if (a is UserInputMessage && b is UserInputMessage) {
      return a.text == b.text &&
          a.clientMessageId == b.clientMessageId &&
          a.userMessageUuid == b.userMessageUuid;
    }

    return false;
  }

  bool _userMessagesEquivalent(UserInputMessage a, UserInputMessage b) {
    final aUuid = a.userMessageUuid;
    final bUuid = b.userMessageUuid;
    if (aUuid != null &&
        aUuid.isNotEmpty &&
        bUuid != null &&
        bUuid.isNotEmpty) {
      return aUuid == bUuid;
    }

    final aClientId = a.clientMessageId;
    final bClientId = b.clientMessageId;
    if (aClientId != null &&
        aClientId.isNotEmpty &&
        bClientId != null &&
        bClientId.isNotEmpty) {
      return aClientId == bClientId;
    }

    return a.text == b.text &&
        a.imageCount == b.imageCount &&
        (aClientId == null ||
            aClientId.isEmpty ||
            bClientId == null ||
            bClientId.isEmpty);
  }

  String? _messageStableKey(ServerMessage message) {
    return switch (message) {
      AssistantServerMessage(:final message, :final messageUuid) =>
        messageUuid != null && messageUuid.isNotEmpty
          ? 'assistant:uuid:$messageUuid'
          : message.id.isNotEmpty
          ? 'assistant:id:${message.id}'
          : null,
      ToolResultMessage(:final toolUseId) => 'tool_result:$toolUseId',
      PermissionRequestMessage(:final toolUseId) =>
        'permission_request:$toolUseId',
      PermissionResolvedMessage(:final toolUseId) =>
        'permission_resolved:$toolUseId',
      UserInputMessage(:final userMessageUuid)
          when userMessageUuid != null && userMessageUuid.isNotEmpty =>
        'user:uuid:$userMessageUuid',
      UserInputMessage(:final clientMessageId)
          when clientMessageId != null && clientMessageId.isNotEmpty =>
        'user:client:$clientMessageId',
      _ => null,
    };
  }

  String? _messageWeakKey(ServerMessage message) {
    return switch (message) {
      StatusMessage(:final status) => 'status:${status.name}',
      UserInputMessage(:final text) => 'user:text:$text',
      AssistantServerMessage(:final message) =>
        'assistant:${_assistantContentSignature(message)}',
      ResultMessage(
        :final subtype,
        :final sessionId,
        :final stopReason,
        :final result,
        :final error,
      ) =>
        ['result', subtype, sessionId, stopReason, result, error].join('\u0001'),
      ErrorMessage(:final message, :final errorCode) =>
        ['error', errorCode, message].join('\u0001'),
      ToolUseSummaryMessage(:final summary, :final precedingToolUseIds) =>
        ['tool_use_summary', summary, ...precedingToolUseIds].join('\u0001'),
      _ => null,
    };
  }

  String _assistantContentSignature(AssistantMessage message) {
    return message.content
        .map((content) {
          return switch (content) {
            TextContent(:final text) => 'text:$text',
            ThinkingContent(:final thinking) => 'thinking:$thinking',
            ToolUseContent(:final id, :final name) => 'tool_use:$id:$name',
          };
        })
        .join('\u0001');
  }

  int _assistantMessageRichnessScore(AssistantMessage message) {
    var score = 0;
    for (final content in message.content) {
      switch (content) {
        case TextContent(:final text):
          score += 1000 + text.trim().length;
        case ToolUseContent():
          score += 100;
        case ThinkingContent(:final thinking):
          score += thinking.trim().length;
      }
    }
    return score;
  }

  AssistantServerMessage _mergeAssistantServerMessage(
    AssistantServerMessage existing,
    AssistantServerMessage incoming,
  ) {
    final existingScore = _assistantMessageRichnessScore(existing.message);
    final incomingScore = _assistantMessageRichnessScore(incoming.message);
    if (incomingScore < existingScore) return existing;
    if (incomingScore == existingScore &&
        incoming.message.content.length < existing.message.content.length) {
      return existing;
    }
    return incoming;
  }

  void _sortSequencedMessages(SessionRuntimeState state) {
    final pairs = <({ServerMessage message, int? seq})>[];
    for (var i = 0; i < state._messages.length; i++) {
      pairs.add((message: state._messages[i], seq: state._messageSeqs[i]));
    }
    pairs.sort((a, b) {
      final aSeq = a.seq;
      final bSeq = b.seq;
      if (aSeq == null && bSeq == null) return 0;
      if (aSeq == null) return 1;
      if (bSeq == null) return -1;
      return aSeq.compareTo(bSeq);
    });
    state._messages
      ..clear()
      ..addAll(pairs.map((pair) => pair.message));
    state._messageSeqs
      ..clear()
      ..addAll(pairs.map((pair) => pair.seq));
  }

  void _advanceCachedHistorySeq(SessionRuntimeState state) {
    var nextSeq = state.cachedHistorySeq + 1;
    while (state._messageSeqs.contains(nextSeq)) {
      state.cachedHistorySeq = nextSeq;
      nextSeq++;
    }
  }

  bool _deltaExtendsCachedHistory(
    int cachedHistorySeq,
    HistoryDeltaMessage message,
  ) {
    if (message.fromSeq > cachedHistorySeq + 1) return false;
    if (message.toSeq <= cachedHistorySeq) return true;

    final entrySeqs = message.entries
        .where((entry) => !_shouldIgnore(entry.message))
        .map((entry) => entry.seq)
        .toSet();
    for (var seq = message.fromSeq; seq <= message.toSeq; seq++) {
      if (seq <= cachedHistorySeq) continue;
      if (!entrySeqs.contains(seq)) return false;
    }
    return true;
  }

  void _trim(SessionRuntimeState state) {
    if (maxMessagesPerSession <= 0) {
      _clearMessages(state);
      return;
    }
    final overflow = state._messages.length - maxMessagesPerSession;
    if (overflow > 0) {
      state._messages.removeRange(0, overflow);
      state._messageSeqs.removeRange(0, overflow);
    }
  }

  void _removeIfEmpty(SessionRuntimeState state) {
    if (state._messages.isEmpty &&
        state.explorerHistory.currentPath.isEmpty &&
        state.explorerHistory.recentPeekedFiles.isEmpty) {
      _sessions.remove(state.sessionId);
    }
  }
}
