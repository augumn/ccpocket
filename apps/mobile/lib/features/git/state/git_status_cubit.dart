import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../models/messages.dart';
import '../../../services/bridge_service.dart';

class GitStatusEntry {
  final String sessionId;
  final String projectPath;
  final bool loading;
  final bool hasUncommittedChanges;
  final int stagedCount;
  final int unstagedCount;
  final int untrackedCount;
  final String? error;

  const GitStatusEntry({
    required this.sessionId,
    required this.projectPath,
    this.loading = false,
    this.hasUncommittedChanges = false,
    this.stagedCount = 0,
    this.unstagedCount = 0,
    this.untrackedCount = 0,
    this.error,
  });

  bool get showBadge => !loading && error == null && hasUncommittedChanges;

  GitStatusEntry copyWith({
    String? projectPath,
    bool? loading,
    bool? hasUncommittedChanges,
    int? stagedCount,
    int? unstagedCount,
    int? untrackedCount,
    String? error,
    bool clearError = false,
  }) {
    return GitStatusEntry(
      sessionId: sessionId,
      projectPath: projectPath ?? this.projectPath,
      loading: loading ?? this.loading,
      hasUncommittedChanges:
          hasUncommittedChanges ?? this.hasUncommittedChanges,
      stagedCount: stagedCount ?? this.stagedCount,
      unstagedCount: unstagedCount ?? this.unstagedCount,
      untrackedCount: untrackedCount ?? this.untrackedCount,
      error: clearError ? null : error ?? this.error,
    );
  }
}

class GitStatusState {
  final Map<String, GitStatusEntry> entriesBySession;

  const GitStatusState({this.entriesBySession = const {}});

  GitStatusEntry? entryFor(String sessionId) => entriesBySession[sessionId];

  GitStatusState upsert(GitStatusEntry entry) {
    return GitStatusState(
      entriesBySession: {...entriesBySession, entry.sessionId: entry},
    );
  }

  GitStatusState remove(String sessionId) {
    if (!entriesBySession.containsKey(sessionId)) return this;
    return GitStatusState(
      entriesBySession: Map.of(entriesBySession)..remove(sessionId),
    );
  }
}

class GitStatusCubit extends Cubit<GitStatusState> {
  final BridgeService _bridge;
  late final StreamSubscription<GitStatusResultMessage> _statusSub;
  late final StreamSubscription<String> _stoppedSub;

  GitStatusCubit({required BridgeService bridge})
    : _bridge = bridge,
      super(const GitStatusState()) {
    _statusSub = _bridge.gitStatusResults.listen(_onStatusResult);
    _stoppedSub = _bridge.stoppedSessions.listen(clearSession);
  }

  void refresh({required String sessionId, required String projectPath}) {
    if (projectPath.isEmpty) return;
    final current = state.entryFor(sessionId);
    emit(
      state.upsert(
        (current ??
                GitStatusEntry(sessionId: sessionId, projectPath: projectPath))
            .copyWith(
              projectPath: projectPath,
              loading: true,
              clearError: true,
            ),
      ),
    );
    _bridge.send(ClientMessage.gitStatus(projectPath, sessionId: sessionId));
  }

  void refreshIfKnown(String sessionId) {
    final current = state.entryFor(sessionId);
    if (current == null) return;
    refresh(sessionId: sessionId, projectPath: current.projectPath);
  }

  void clearSession(String sessionId) {
    emit(state.remove(sessionId));
  }

  void _onStatusResult(GitStatusResultMessage result) {
    final sessionId = result.sessionId;
    if (sessionId == null || sessionId.isEmpty) return;
    emit(
      state.upsert(
        GitStatusEntry(
          sessionId: sessionId,
          projectPath: result.projectPath,
          loading: false,
          hasUncommittedChanges: result.hasUncommittedChanges,
          stagedCount: result.stagedCount,
          unstagedCount: result.unstagedCount,
          untrackedCount: result.untrackedCount,
          error: result.error,
        ),
      ),
    );
  }

  @override
  Future<void> close() async {
    await _statusSub.cancel();
    await _stoppedSub.cancel();
    return super.close();
  }
}
