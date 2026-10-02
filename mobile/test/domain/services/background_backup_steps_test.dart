import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/background_backup_steps.dart';

void main() {
  late List<String> calls;
  late bool uploadsWaiting;
  late bool remoteSyncSucceeds;
  late String? cancelAfter;
  late bool cancelled;

  Future<void> step(String name) async {
    calls.add(name);
    if (cancelAfter == name) {
      cancelled = true;
    }
  }

  Future<BackgroundBackupOutcome> run({
    Future<bool> Function()? hasSomethingToUpload,
    Future<bool> Function()? syncRemote,
    Future<void> Function()? hash,
  }) {
    return runBackgroundBackup(
      syncLocal: () => step('local sync'),
      hash: hash ?? () => step('hash'),
      hasSomethingToUpload:
          hasSomethingToUpload ??
          () async {
            await step('anything to upload?');
            return uploadsWaiting;
          },
      syncRemote:
          syncRemote ??
          () async {
            await step('remote sync');
            return remoteSyncSucceeds;
          },
      backup: () => step('backup'),
      isCancelled: () => cancelled,
    );
  }

  setUp(() {
    calls = [];
    uploadsWaiting = true;
    remoteSyncSucceeds = true;
    cancelAfter = null;
    cancelled = false;
  });

  group('somethingToUpload', () {
    Future<bool> ask({bool backupEnabled = true, String? userId = 'user-id', required Future<int> Function() count}) {
      return somethingToUpload(backupEnabled: backupEnabled, userId: userId, countUploadable: (_) => count());
    }

    test('is true when there are candidates', () async {
      expect(await ask(count: () async => 3), isTrue);
    });

    test('is false when there are none', () async {
      expect(await ask(count: () async => 0), isFalse);
    });

    test('is false with backup switched off, without looking', () async {
      var looked = false;

      final answer = await ask(
        backupEnabled: false,
        count: () async {
          looked = true;
          return 3;
        },
      );

      expect(answer, isFalse);
      expect(looked, isFalse);
    });

    test('is false with nobody signed in, without looking', () async {
      var looked = false;

      final answer = await ask(
        userId: null,
        count: () async {
          looked = true;
          return 3;
        },
      );

      expect(answer, isFalse);
      expect(looked, isFalse);
    });

    test('asks about the signed-in user', () async {
      String? asked;

      await somethingToUpload(
        backupEnabled: true,
        userId: 'user-id',
        countUploadable: (userId) async {
          asked = userId;
          return 0;
        },
      );

      expect(asked, 'user-id');
    });

    test('is true when the count cannot be had, and says why', () async {
      // Staying off the server because the check itself broke would leave
      // pictures on the phone with nothing to say so.
      Object? reported;

      final answer = await somethingToUpload(
        backupEnabled: true,
        userId: 'user-id',
        countUploadable: (_) async => throw StateError('database closed'),
        onCountFailed: (error, _) => reported = error,
      );

      expect(answer, isTrue);
      expect(reported, isStateError);
    });
  });

  group('a background run with nothing to upload', () {
    test('never contacts the server', () async {
      uploadsWaiting = false;

      final outcome = await run();

      expect(outcome, BackgroundBackupOutcome.nothingToUpload);
      expect(calls, ['local sync', 'hash', 'anything to upload?']);
    });

    test('still looks at the phone first, every time', () async {
      uploadsWaiting = false;

      await run();
      await run();

      expect(calls.where((c) => c == 'local sync'), hasLength(2));
      expect(calls.where((c) => c == 'hash'), hasLength(2));
      expect(calls, isNot(contains('remote sync')));
      expect(calls, isNot(contains('backup')));
    });
  });

  group('a background run with something to upload', () {
    test('syncs with the server and then backs up, in that order', () async {
      final outcome = await run();

      expect(outcome, BackgroundBackupOutcome.backedUp);
      expect(calls, ['local sync', 'hash', 'anything to upload?', 'remote sync', 'backup', 'remote sync']);
    });

    test('counts a picture that was only hashed during this run', () async {
      // A picture taken since the last run has no checksum until the hash step
      // has seen it, and without one it is not a candidate. Asking before
      // hashing would leave every new picture for the run after.
      var hashed = false;

      final outcome = await run(
        hash: () async {
          await step('hash');
          hashed = true;
        },
        hasSomethingToUpload: () async {
          await step('anything to upload?');
          return hashed;
        },
      );

      expect(outcome, BackgroundBackupOutcome.backedUp);
      expect(calls, contains('backup'));
    });

    test('syncs once more after backing up, so the next run knows what was sent', () async {
      await run();

      expect(calls.sublist(calls.indexOf('backup')), ['backup', 'remote sync']);
    });

    test('is not failed by that second sync failing', () async {
      var syncs = 0;
      Object? reported;

      final outcome = await runBackgroundBackup(
        syncLocal: () => step('local sync'),
        hash: () => step('hash'),
        hasSomethingToUpload: () async => true,
        syncRemote: () async {
          await step('remote sync');
          syncs++;
          if (syncs == 2) {
            throw StateError('server went away');
          }
          return true;
        },
        backup: () => step('backup'),
        isCancelled: () => cancelled,
        onFollowUpSyncFailed: (error, _) => reported = error,
      );

      expect(outcome, BackgroundBackupOutcome.backedUp);
      expect(syncs, 2);
      expect(reported, isStateError);
    });

    test('is not failed by that second sync reporting no success', () async {
      var syncs = 0;

      final outcome = await run(
        syncRemote: () async {
          await step('remote sync');
          return ++syncs == 1;
        },
      );

      expect(outcome, BackgroundBackupOutcome.backedUp);
      expect(syncs, 2);
    });

    test('does not back up when the remote sync did not succeed', () async {
      remoteSyncSucceeds = false;

      final outcome = await run();

      expect(outcome, BackgroundBackupOutcome.remoteSyncFailed);
      expect(calls, ['local sync', 'hash', 'anything to upload?', 'remote sync']);
    });

    test('lets a failing remote sync fail the run, without backing up', () async {
      await expectLater(
        run(
          syncRemote: () async {
            await step('remote sync');
            throw StateError('server unreachable');
          },
        ),
        throwsStateError,
      );

      expect(calls, isNot(contains('backup')));
    });
  });

  group('a background run that is cancelled', () {
    test('during the local sync, does nothing more', () async {
      cancelAfter = 'local sync';

      final outcome = await run();

      expect(outcome, BackgroundBackupOutcome.cancelled);
      expect(calls, ['local sync']);
    });

    test('during the backup, does not go back to the server afterwards', () async {
      cancelAfter = 'backup';

      final outcome = await run();

      expect(outcome, BackgroundBackupOutcome.backedUp);
      expect(calls, ['local sync', 'hash', 'anything to upload?', 'remote sync', 'backup']);
    });

    test('during hashing, neither asks nor contacts the server', () async {
      cancelAfter = 'hash';

      final outcome = await run();

      expect(outcome, BackgroundBackupOutcome.cancelled);
      expect(calls, ['local sync', 'hash']);
    });
  });

  test('a failure to find out what needs uploading is not taken for "nothing"', () async {
    // The caller decides what to do about not knowing. Here it must surface
    // rather than be reported as a run with nothing to send.
    await expectLater(run(hasSomethingToUpload: () async => throw StateError('database closed')), throwsStateError);

    expect(calls, isNot(contains('remote sync')));
    expect(calls, isNot(contains('backup')));
  });
}
