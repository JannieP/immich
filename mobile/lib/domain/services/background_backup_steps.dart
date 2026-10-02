/// How one background backup run ended.
enum BackgroundBackupOutcome {
  /// The run was cancelled before it had decided what to do.
  cancelled,

  /// Everything the phone means to back up is already on the server, as far as
  /// the phone's own database knows. The server was not contacted.
  nothingToUpload,

  /// There was something to send, but syncing with the server did not succeed.
  remoteSyncFailed,

  /// The backup step ran.
  backedUp,
}

/// Whether a background run has anything to send, from what the phone knows.
///
/// A run with backup switched off, or with nobody signed in, uploads nothing
/// whatever the library holds, so it has nothing to send either.
///
/// [countUploadable] failing is a different matter from it answering zero. Not
/// knowing is not the same as knowing there is nothing, and the cost of
/// guessing wrong is lopsided: contacting the server needlessly wastes a
/// request, while staying away wrongly leaves a picture on the phone alone.
/// So a failure counts as "yes", and the run carries on as it always did.
Future<bool> somethingToUpload({
  required bool backupEnabled,
  required String? userId,
  required Future<int> Function(String userId) countUploadable,
  void Function(Object error, StackTrace stack)? onCountFailed,
}) async {
  if (!backupEnabled || userId == null) {
    return false;
  }

  try {
    return await countUploadable(userId) > 0;
  } catch (error, stack) {
    onCountFailed?.call(error, stack);
    return true;
  }
}

/// The steps of one background backup run, in the order they have to happen.
///
/// The local steps come first, and the server is contacted only if they leave
/// something to send. It used to be the other way round: every run began by
/// syncing with the server and only then looked for work. The periodic worker
/// runs every hour, so a phone asked the server "anything new?" twenty-four
/// times a day whether or not it had taken a picture. A server that is always
/// running does not notice. One that stops when idle, and is started by the
/// first request to arrive, was being started by exactly these requests and
/// then sat out its idle timer for nothing: forty starts a day from two phones
/// that had uploaded nothing.
///
/// Nothing is lost by asking the phone first. Which pictures still need sending
/// is worked out from the phone's own database -- the local library against the
/// copy of the server's asset list it already holds -- so the answer does not
/// need the network. If that copy is out of date the mistake goes the safe way:
/// a picture the server already has still looks unsent, the server is asked,
/// and the sync that follows corrects it. What does wait is news travelling the
/// other way, such as an asset deleted on the server. That arrives the next
/// time the app is opened, or the next time a run has something to send.
///
/// Kept apart from the service that owns the Flutter engine so that the order
/// can be tested without one.
Future<BackgroundBackupOutcome> runBackgroundBackup({
  required Future<void> Function() syncLocal,
  required Future<void> Function() hash,
  required Future<bool> Function() hasSomethingToUpload,
  required Future<bool> Function() syncRemote,
  required Future<void> Function() backup,
  required bool Function() isCancelled,
  void Function(Object error, StackTrace stack)? onFollowUpSyncFailed,
}) async {
  await syncLocal();
  if (isCancelled()) {
    return BackgroundBackupOutcome.cancelled;
  }

  // Before the question below, not after it: a picture taken since the last run
  // has no checksum yet, and only a hashed picture can be a candidate.
  await hash();
  if (isCancelled()) {
    return BackgroundBackupOutcome.cancelled;
  }

  if (!await hasSomethingToUpload()) {
    return BackgroundBackupOutcome.nothingToUpload;
  }

  // The first use of the network. The upload re-reads its candidates after
  // this, so anything the sync shows the server to have already is not sent.
  if (!await syncRemote()) {
    return BackgroundBackupOutcome.remoteSyncFailed;
  }

  await backup();

  // Learn what the backup has just sent, while the server is still there to
  // ask. An upload does not update the phone's copy of the server's asset list;
  // only a sync does. Without this one, the pictures uploaded a moment ago
  // still look unsent at the next run, and that run contacts the server for no
  // better reason than to be told they arrived.
  //
  // Only a convenience for the next run, so it may fail without failing this
  // one: the backup is already done.
  if (!isCancelled()) {
    try {
      await syncRemote();
    } catch (error, stack) {
      onFollowUpSyncFailed?.call(error, stack);
    }
  }

  return BackgroundBackupOutcome.backedUp;
}
