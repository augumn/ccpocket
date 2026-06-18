import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/session_runtime_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SessionRuntimeStore', () {
    test('keeps timeline and explorer history separated by session', () {
      final store = SessionRuntimeStore();

      store.applyServerMessage(
        's1',
        AssistantServerMessage(
          message: AssistantMessage(
            id: 'a1',
            role: 'assistant',
            content: const [TextContent(text: 'one')],
            model: 'claude',
          ),
        ),
      );
      store.setExplorerHistory(
        's1',
        currentPath: '/repo/lib',
        recentPeekedFiles: const ['lib/main.dart'],
      );

      store.applyServerMessage(
        's2',
        const StatusMessage(status: ProcessStatus.running),
      );

      expect(store.messages('s1'), hasLength(1));
      expect(store.messages('s2'), hasLength(1));
      expect(store.getExplorerHistory('s1').currentPath, '/repo/lib');
      expect(store.getExplorerHistory('s2').currentPath, isEmpty);
    });

    test('history replaces the cached timeline', () {
      final store = SessionRuntimeStore();
      store.applyServerMessage(
        's1',
        AssistantServerMessage(
          message: AssistantMessage(
            id: 'old',
            role: 'assistant',
            content: const [TextContent(text: 'old')],
            model: 'claude',
          ),
        ),
      );

      store.applyServerMessage(
        's1',
        HistoryMessage(
          messages: [
            const StatusMessage(status: ProcessStatus.idle),
            AssistantServerMessage(
              message: AssistantMessage(
                id: 'new',
                role: 'assistant',
                content: const [TextContent(text: 'new')],
                model: 'claude',
              ),
            ),
          ],
        ),
      );

      final messages = store.messages('s1');
      expect(messages, hasLength(2));
      expect(
        ((messages.last as AssistantServerMessage).message.content.single
                as TextContent)
            .text,
        'new',
      );
      expect(store.latestHistorySeq('s1'), 0);
      expect(store.cachedHistorySeq('s1'), 0);
    });

    test(
      'history merges into sequenced runtime timeline instead of replacing it',
      () {
        final store = SessionRuntimeStore();
        store.applyServerMessage(
          's1',
          const StatusMessage(status: ProcessStatus.idle),
          historySeq: 1,
        );
        store.applyServerMessage(
          's1',
          const UserInputMessage(
            text: 'live input',
            clientMessageId: 'cm-live',
            userMessageUuid: 'codex:user-turn:1',
          ),
          historySeq: 2,
        );
        store.applyServerMessage(
          's1',
          AssistantServerMessage(
            message: AssistantMessage(
              id: 'assistant-live',
              role: 'assistant',
              content: const [TextContent(text: 'live answer')],
              model: 'codex',
            ),
          ),
          historySeq: 3,
        );

        store.applyServerMessage(
          's1',
          HistoryMessage(
            messages: [
              const StatusMessage(status: ProcessStatus.idle),
              const UserInputMessage(
                text: 'live input',
                clientMessageId: 'cm-live',
                userMessageUuid: 'codex:user-turn:1',
              ),
            ],
          ),
        );

        final messages = store.messages('s1');
        expect(messages.map((message) => message.runtimeType), [
          StatusMessage,
          UserInputMessage,
          AssistantServerMessage,
        ]);
        expect(
          (((messages.last as AssistantServerMessage).message.content.single)
                  as TextContent)
              .text,
          'live answer',
        );
        expect(store.latestHistorySeq('s1'), 3);
        expect(store.cachedHistorySeq('s1'), 3);
      },
    );

    test(
      'unsequenced history merge keeps cached user uuid and timestamp instead of downgrading local user entry',
      () {
        final store = SessionRuntimeStore();
        store.applyServerMessage(
          's1',
          const UserInputMessage(
            text: 'Need UAT verification',
            clientMessageId: 'cm-1',
            userMessageUuid: 'codex:user-turn:1',
            timestamp: '2026-06-18T06:00:00.000Z',
          ),
          historySeq: 8,
        );

        store.applyServerMessage(
          's1',
          const HistoryMessage(
            messages: [
              UserInputMessage(
                text: 'Need UAT verification',
                clientMessageId: 'cm-1',
              ),
            ],
          ),
        );

        final messages = store.messages('s1');
        expect(messages, hasLength(1));
        final user = messages.single as UserInputMessage;
        expect(user.text, 'Need UAT verification');
        expect(user.clientMessageId, 'cm-1');
        expect(user.userMessageUuid, 'codex:user-turn:1');
        expect(user.timestamp, '2026-06-18T06:00:00.000Z');
      },
    );

    test(
      'unsequenced history merge does not downgrade assistant text into thinking-only content',
      () {
        final store = SessionRuntimeStore();
        store.applyServerMessage(
          's1',
          AssistantServerMessage(
            message: AssistantMessage(
              id: 'assistant-1',
              role: 'assistant',
              content: const [
                TextContent(text: 'Freight result explanation stays visible.'),
              ],
              model: 'codex',
            ),
          ),
          historySeq: 9,
        );

        store.applyServerMessage(
          's1',
          HistoryMessage(
            messages: [
              AssistantServerMessage(
                message: AssistantMessage(
                  id: 'assistant-1',
                  role: 'assistant',
                  content: const [
                    ThinkingContent(thinking: 'Finalizing report details'),
                  ],
                  model: 'codex',
                ),
              ),
            ],
          ),
        );

        final messages = store.messages('s1');
        expect(messages, hasLength(1));
        final assistant = messages.single as AssistantServerMessage;
        final texts = assistant.message.content
            .whereType<TextContent>()
            .map((part) => part.text)
            .join('\n');
        expect(texts, contains('Freight result explanation stays visible.'));
        expect(assistant.message.content.whereType<ThinkingContent>(), isEmpty);
      },
    );

    test(
      'sequenced updates with the same history seq do not downgrade assistant text into thinking-only content',
      () {
        final store = SessionRuntimeStore();
        store.applyServerMessage(
          's1',
          AssistantServerMessage(
            message: AssistantMessage(
              id: 'assistant-seq-1',
              role: 'assistant',
              content: const [
                TextContent(text: 'Token usage summary remains visible.'),
              ],
              model: 'codex',
            ),
          ),
          historySeq: 12,
        );

        store.applyServerMessage(
          's1',
          AssistantServerMessage(
            message: AssistantMessage(
              id: 'assistant-seq-1',
              role: 'assistant',
              content: const [
                ThinkingContent(thinking: 'Summarizing token totals'),
              ],
              model: 'codex',
            ),
          ),
          historySeq: 12,
        );

        final messages = store.messages('s1');
        expect(messages, hasLength(1));
        final assistant = messages.single as AssistantServerMessage;
        final texts = assistant.message.content
            .whereType<TextContent>()
            .map((part) => part.text)
            .join('\n');
        expect(texts, contains('Token usage summary remains visible.'));
        expect(assistant.message.content.whereType<ThinkingContent>(), isEmpty);
      },
    );

    test('history delta appends newer sequenced entries', () {
      final store = SessionRuntimeStore();
      store.applyServerMessage(
        's1',
        const HistoryDeltaMessage(
          fromSeq: 1,
          toSeq: 2,
          entries: [
            HistoryEntry(
              seq: 2,
              message: StatusMessage(status: ProcessStatus.running),
            ),
          ],
        ),
      );

      expect(store.messages('s1'), hasLength(1));
      expect(store.latestHistorySeq('s1'), 2);
      expect(store.cachedHistorySeq('s1'), 0);
    });

    test('bootstrap history delta replaces unsequenced cached timeline', () {
      final store = SessionRuntimeStore();
      store.applyServerMessage(
        's1',
        AssistantServerMessage(
          message: AssistantMessage(
            id: 'cached',
            role: 'assistant',
            content: const [TextContent(text: 'cached')],
            model: 'claude',
          ),
        ),
      );

      store.applyServerMessage(
        's1',
        const HistoryDeltaMessage(
          fromSeq: 1,
          toSeq: 1,
          entries: [
            HistoryEntry(
              seq: 1,
              message: StatusMessage(status: ProcessStatus.idle),
            ),
          ],
        ),
      );

      final messages = store.messages('s1');
      expect(messages, hasLength(1));
      expect(messages.single, isA<StatusMessage>());
      expect(store.latestHistorySeq('s1'), 1);
      expect(store.cachedHistorySeq('s1'), 1);
    });

    test('history snapshot replaces cached timeline and records sequence', () {
      final store = SessionRuntimeStore();
      store.applyServerMessage(
        's1',
        const StatusMessage(status: ProcessStatus.running),
      );

      store.applyServerMessage(
        's1',
        const HistorySnapshotMessage(
          fromSeq: 5,
          toSeq: 7,
          reason: 'compacted',
          entries: [
            HistoryEntry(
              seq: 7,
              message: StatusMessage(status: ProcessStatus.idle),
            ),
          ],
        ),
      );

      final messages = store.messages('s1').cast<StatusMessage>();
      expect(messages, hasLength(1));
      expect(messages.single.status, ProcessStatus.idle);
      expect(store.latestHistorySeq('s1'), 7);
      expect(store.cachedHistorySeq('s1'), 7);
    });

    test(
      'history snapshot preserves richer cached user and assistant content for matching seq entries',
      () {
        final store = SessionRuntimeStore();
        store.applyServerMessage(
          's1',
          const UserInputMessage(
            text: 'Need the exact token cost.',
            clientMessageId: 'cm-snap-1',
            userMessageUuid: 'codex:user-turn:snap-1',
            timestamp: '2026-06-18T06:00:00.000Z',
          ),
          historySeq: 1,
        );
        store.applyServerMessage(
          's1',
          AssistantServerMessage(
            message: AssistantMessage(
              id: 'assistant-snap-1',
              role: 'assistant',
              content: const [
                TextContent(text: 'The exact token cost is 12345.'),
              ],
              model: 'codex',
            ),
          ),
          historySeq: 2,
        );

        store.applyServerMessage(
          's1',
          const HistorySnapshotMessage(
            fromSeq: 1,
            toSeq: 2,
            reason: 'refresh',
            entries: [
              HistoryEntry(
                seq: 1,
                message: UserInputMessage(
                  text: 'Need the exact token cost.',
                  clientMessageId: 'cm-snap-1',
                ),
              ),
              HistoryEntry(
                seq: 2,
                message: AssistantServerMessage(
                  message: AssistantMessage(
                    id: 'assistant-snap-1',
                    role: 'assistant',
                    content: [
                      ThinkingContent(thinking: 'Calculating token totals'),
                    ],
                    model: 'codex',
                  ),
                ),
              ),
            ],
          ),
        );

        final messages = store.messages('s1');
        expect(messages, hasLength(2));

        final user = messages[0] as UserInputMessage;
        expect(user.userMessageUuid, 'codex:user-turn:snap-1');
        expect(user.timestamp, '2026-06-18T06:00:00.000Z');

        final assistant = messages[1] as AssistantServerMessage;
        final texts = assistant.message.content
            .whereType<TextContent>()
            .map((part) => part.text)
            .join('\n');
        expect(texts, contains('The exact token cost is 12345.'));
        expect(assistant.message.content.whereType<ThinkingContent>(), isEmpty);
      },
    );

    test('tracks latest and cached history sequence separately', () {
      final store = SessionRuntimeStore();
      store.applyServerMessage(
        's1',
        const StatusMessage(status: ProcessStatus.starting),
        historySeq: 1,
      );
      store.applyServerMessage(
        's1',
        const InputAckMessage(clientMessageId: 'cm-1', acceptedSeq: 2),
        historySeq: 2,
      );
      store.applyServerMessage(
        's1',
        AssistantServerMessage(
          message: AssistantMessage(
            id: 'assistant-1',
            role: 'assistant',
            content: const [TextContent(text: 'cached assistant')],
            model: 'gpt-5.5',
          ),
        ),
        historySeq: 4,
      );

      expect(store.latestHistorySeq('s1'), 4);
      expect(store.cachedHistorySeq('s1'), 1);

      store.applyServerMessage(
        's1',
        HistoryDeltaMessage(
          fromSeq: 2,
          toSeq: 4,
          entries: [
            const HistoryEntry(
              seq: 2,
              message: UserInputMessage(text: 'hi', clientMessageId: 'cm-1'),
            ),
            const HistoryEntry(
              seq: 3,
              message: StatusMessage(status: ProcessStatus.running),
            ),
            HistoryEntry(
              seq: 4,
              message: AssistantServerMessage(
                message: AssistantMessage(
                  id: 'assistant-1',
                  role: 'assistant',
                  content: const [TextContent(text: 'canonical assistant')],
                  model: 'gpt-5.5',
                ),
              ),
            ),
          ],
        ),
      );

      final messages = store.messages('s1');
      expect(messages.map((message) => message.runtimeType), [
        StatusMessage,
        UserInputMessage,
        StatusMessage,
        AssistantServerMessage,
      ]);
      expect((messages[1] as UserInputMessage).text, 'hi');
      expect(
        (((messages[3] as AssistantServerMessage).message.content.single)
                as TextContent)
            .text,
        'canonical assistant',
      );
      expect(store.latestHistorySeq('s1'), 4);
      expect(store.cachedHistorySeq('s1'), 4);
    });

    test('ignores transient stream deltas', () {
      final store = SessionRuntimeStore();

      store.applyServerMessage('s1', const StreamDeltaMessage(text: 'hello'));
      store.applyServerMessage('s1', const ThinkingDeltaMessage(text: 'hmm'));

      expect(store.messages('s1'), isEmpty);
    });

    test('migrates runtime state to a new session id', () {
      final store = SessionRuntimeStore();
      store.applyServerMessage(
        'pending',
        const StatusMessage(status: ProcessStatus.running),
      );
      store.setExplorerHistory(
        'pending',
        currentPath: '/repo',
        recentPeekedFiles: const ['README.md'],
      );

      store.migrateSession('pending', 'real');

      expect(store.messages('pending'), isEmpty);
      expect(store.getExplorerHistory('pending').currentPath, isEmpty);
      expect(store.messages('real'), hasLength(1));
      expect(store.getExplorerHistory('real').currentPath, '/repo');
      expect(store.latestHistorySeq('real'), 0);
      expect(store.cachedHistorySeq('real'), 0);
    });

    test('trims old messages per session', () {
      final store = SessionRuntimeStore(maxMessagesPerSession: 2);

      store.applyServerMessage(
        's1',
        const StatusMessage(status: ProcessStatus.starting),
      );
      store.applyServerMessage(
        's1',
        const StatusMessage(status: ProcessStatus.running),
      );
      store.applyServerMessage(
        's1',
        const StatusMessage(status: ProcessStatus.idle),
      );

      final messages = store.messages('s1').cast<StatusMessage>();
      expect(messages, hasLength(2));
      expect(messages.first.status, ProcessStatus.running);
      expect(messages.last.status, ProcessStatus.idle);
    });
  });
}
