import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/utils/debug_print.dart';
import 'package:logging/logging.dart';

final uploadRepositoryProvider = Provider((ref) => UploadRepository());

class UploadRepository {
  final Logger logger = Logger('UploadRepository');
  void Function(TaskStatusUpdate)? onUploadStatus;
  void Function(TaskProgressUpdate)? onTaskProgress;

  UploadRepository() {
    FileDownloader().registerCallbacks(
      group: kBackupGroup,
      taskStatusCallback: (update) => onUploadStatus?.call(update),
      taskProgressCallback: (update) => onTaskProgress?.call(update),
    );
    FileDownloader().registerCallbacks(
      group: kBackupLivePhotoGroup,
      taskStatusCallback: (update) => onUploadStatus?.call(update),
      taskProgressCallback: (update) => onTaskProgress?.call(update),
    );
    FileDownloader().registerCallbacks(
      group: kManualUploadGroup,
      taskStatusCallback: (update) => onUploadStatus?.call(update),
      taskProgressCallback: (update) => onTaskProgress?.call(update),
    );
  }

  Future<void> enqueueBackground(UploadTask task) {
    return FileDownloader().enqueue(task);
  }

  Future<List<bool>> enqueueBackgroundAll(List<UploadTask> tasks) {
    return FileDownloader().enqueueAll(tasks);
  }

  Future<void> deleteDatabaseRecords(String group) {
    return FileDownloader().database.deleteAllRecords(group: group);
  }

  Future<bool> cancelAll(String group) {
    return FileDownloader().cancelAll(group: group);
  }

  Future<int> reset(String group) {
    return FileDownloader().reset(group: group);
  }

  /// Get a list of tasks that are ENQUEUED or RUNNING
  Future<List<Task>> getActiveTasks(String group) {
    return FileDownloader().allTasks(group: group);
  }

  Future<void> start() {
    return FileDownloader().start();
  }

  Future<void> getUploadInfo() async {
    final [enqueuedTasks, runningTasks, canceledTasks, waitingTasks, pausedTasks] = await Future.wait([
      FileDownloader().database.allRecordsWithStatus(TaskStatus.enqueued, group: kBackupGroup),
      FileDownloader().database.allRecordsWithStatus(TaskStatus.running, group: kBackupGroup),
      FileDownloader().database.allRecordsWithStatus(TaskStatus.canceled, group: kBackupGroup),
      FileDownloader().database.allRecordsWithStatus(TaskStatus.waitingToRetry, group: kBackupGroup),
      FileDownloader().database.allRecordsWithStatus(TaskStatus.paused, group: kBackupGroup),
    ]);

    dPrint(
      () =>
          """
      Upload Info:
      Enqueued: ${enqueuedTasks.length}
      Running: ${runningTasks.length}
      Canceled: ${canceledTasks.length}
      Waiting: ${waitingTasks.length}
      Paused: ${pausedTasks.length}
    """,
    );
  }

  /// Sent with every upload, to tell a gateway in front of the server that this
  /// client will send the file again to wherever a 307 or 308 points.
  ///
  /// It is opt-in because following such a redirect takes work an ordinary
  /// client does not do: the body has to be built a second time and the session
  /// has to be presented to a host the login cookie is not scoped to. A gateway
  /// that redirected every upload would break the web client and every other
  /// app, so it is expected to redirect only the requests that carry this.
  static const directUploadHeader = 'x-direct-upload';

  /// Where a redirected upload should be sent again, or null if the response is
  /// not a redirect this client is prepared to follow.
  ///
  /// The answer decides where the session token goes, so it is deliberately
  /// narrow. The redirect itself arrives from the server the user logged in to,
  /// which is what makes it believable at all; the checks here are a second
  /// line behind that, not a substitute for it:
  ///
  ///  - 307 and 308 only. The other redirect codes mean "fetch this with GET",
  ///    and a GET cannot carry a file.
  ///  - Never from https down to http.
  ///  - The same host, or another name directly under the same parent domain,
  ///    as with photos.example.com and origin.example.com. A different host
  ///    must be https at both ends.
  ///
  /// "Same parent domain" is judged by the names alone. No public suffix list
  /// is consulted, so two unrelated sites under a shared suffix such as
  /// example.co.uk and other.co.uk would count as siblings.
  @visibleForTesting
  static Uri? redirectTarget(Uri from, int statusCode, String? location) {
    if (statusCode != 307 && statusCode != 308) {
      return null;
    }
    if (location == null || location.isEmpty) {
      return null;
    }

    final Uri to;
    try {
      to = from.resolve(location);
    } on FormatException {
      return null;
    }
    if (to.host.isEmpty || to.userInfo.isNotEmpty) {
      return null;
    }

    if (to.host == from.host) {
      return to.scheme == from.scheme || to.scheme == 'https' ? to : null;
    }
    if (from.scheme != 'https' || to.scheme != 'https') {
      return null;
    }
    return _isSiblingHost(from.host, to.host) ? to : null;
  }

  static bool _isSiblingHost(String a, String b) {
    // Addresses have no parent domain: 10.0.0.1 and 11.0.0.1 are not siblings.
    if (InternetAddress.tryParse(a) != null || InternetAddress.tryParse(b) != null) {
      return false;
    }
    final labelsA = a.split('.');
    final labelsB = b.split('.');
    if (labelsA.any((label) => label.isEmpty) || labelsB.any((label) => label.isEmpty)) {
      return false;
    }
    // Under a bare top-level domain every site would be a sibling of every other.
    if (labelsA.length < 3 || labelsA.length != labelsB.length) {
      return false;
    }
    return labelsA.skip(1).join('.') == labelsB.skip(1).join('.');
  }

  Future<UploadResult> uploadFile({
    required File file,
    required String originalFileName,
    required Map<String, String> fields,
    required Completer<void>? cancelToken,
    void Function(int bytes, int totalBytes)? onProgress,
    required String logContext,
    Client? httpClient,
  }) async {
    final String savedEndpoint = Store.get(StoreKey.serverEndpoint);
    final uploadUrl = Uri.parse('$savedEndpoint/assets');

    ProgressMultipartRequest buildRequest(Uri url, Map<String, String> headers) {
      final request = ProgressMultipartRequest('POST', url, abortTrigger: cancelToken?.future, onProgress: onProgress);
      // Redirects are followed by hand in send() below. Left to the client, a
      // redirect is answered by replaying this request, whose body is a stream
      // that has already been partly read and cannot be read again.
      request.followRedirects = false;
      request.headers.addAll(headers);
      request.fields.addAll(fields);
      request.files.add(MultipartFile("assetData", file.openRead(), file.lengthSync(), filename: originalFileName));
      return request;
    }

    Future<StreamedResponse> send(Client client) async {
      final response = await client.send(buildRequest(uploadUrl, const {directUploadHeader: '1'}));
      final target = redirectTarget(uploadUrl, response.statusCode, response.headers['location']);
      if (target == null) {
        return response;
      }

      final headers = <String, String>{};
      if (target.host != uploadUrl.host) {
        // The login cookie is scoped to the host it was issued for and is not
        // sent to this one, so the session goes in a header instead. A header
        // rather than the URL: URLs end up in access logs and proxies.
        final token = Store.tryGet(StoreKey.accessToken);
        if (token == null) {
          return response;
        }
        headers['Authorization'] = 'Bearer $token';
      }

      // The redirect has no body worth reading, but an unread one holds the connection.
      unawaited(response.stream.drain<void>().catchError((_) {}));
      logger.info("Upload $logContext redirected to ${target.host}");
      // One hop only: whatever this returns is the answer, redirect or not.
      return client.send(buildRequest(target, headers));
    }

    try {
      final client = httpClient ?? NetworkRepository.client;
      StreamedResponse response;
      try {
        response = await send(client);
      } on RequestAbortedException {
        rethrow;
      } on ClientException catch (error) {
        logger.warning("Upload $logContext failed before a response, resending once: $error");
        response = await send(client);
      }

      final responseBodyString = await response.stream.bytesToString();

      if (![200, 201].contains(response.statusCode)) {
        String? errorMessage;

        if (response.statusCode == 413) {
          errorMessage = 'Error(413) File is too large to upload';
          return UploadResult.error(statusCode: response.statusCode, errorMessage: errorMessage);
        }

        if (response.statusCode >= 300 && response.statusCode < 400) {
          errorMessage = 'Upload was redirected somewhere this app will not follow: ${response.headers['location']}';
          return UploadResult.error(statusCode: response.statusCode, errorMessage: errorMessage);
        }

        try {
          final error = jsonDecode(responseBodyString);
          errorMessage = error['message'] ?? error['error'];
        } catch (_) {
          errorMessage = responseBodyString.isNotEmpty
              ? responseBodyString
              : 'Upload failed with status ${response.statusCode}';
        }

        return UploadResult.error(statusCode: response.statusCode, errorMessage: errorMessage);
      }

      try {
        final responseBody = jsonDecode(responseBodyString);
        return UploadResult.success(remoteAssetId: responseBody['id'] as String);
      } catch (e) {
        return UploadResult.error(errorMessage: 'Failed to parse server response');
      }
    } on RequestAbortedException {
      logger.warning("Upload $logContext was cancelled");
      return UploadResult.cancelled();
    } catch (error, stackTrace) {
      logger.warning("Error uploading $logContext: $error: $stackTrace");
      return UploadResult.error(errorMessage: error.toString());
    }
  }
}

class ProgressMultipartRequest extends MultipartRequest with Abortable {
  ProgressMultipartRequest(super.method, super.url, {this.abortTrigger, this.onProgress});

  @override
  final Future<void>? abortTrigger;

  final void Function(int bytes, int totalBytes)? onProgress;

  @override
  ByteStream finalize() {
    final byteStream = super.finalize();
    if (onProgress == null) {
      return byteStream;
    }

    final total = contentLength;
    var bytes = 0;
    final stream = byteStream.transform(
      StreamTransformer.fromHandlers(
        handleData: (List<int> data, EventSink<List<int>> sink) {
          bytes += data.length;
          onProgress!(bytes, total);
          sink.add(data);
        },
      ),
    );
    return ByteStream(stream);
  }
}

class UploadResult {
  final bool isSuccess;
  final bool isCancelled;
  final String? remoteAssetId;
  final String? errorMessage;
  final int? statusCode;

  const UploadResult({
    required this.isSuccess,
    required this.isCancelled,
    this.remoteAssetId,
    this.errorMessage,
    this.statusCode,
  });

  factory UploadResult.success({required String remoteAssetId}) {
    return UploadResult(isSuccess: true, isCancelled: false, remoteAssetId: remoteAssetId);
  }

  factory UploadResult.error({String? errorMessage, int? statusCode}) {
    return UploadResult(isSuccess: false, isCancelled: false, errorMessage: errorMessage, statusCode: statusCode);
  }

  factory UploadResult.cancelled() {
    return const UploadResult(isSuccess: false, isCancelled: true);
  }
}
