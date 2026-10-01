import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/repositories/upload.repository.dart';
import 'package:mocktail/mocktail.dart';

class _MockHttpClient extends Mock implements http.Client {}

class _FakeBaseRequest extends Fake implements http.BaseRequest {}

// keeps the FileDownloader singleton off the disk and off the platform channels
class _NoStorage extends Fake implements PersistentStorage {
  @override
  Future<void> initialize() async {}
}

void main() {
  late _MockHttpClient client;
  late UploadRepository sut;
  late File file;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    FileDownloader(persistentStorage: _NoStorage());
    final db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await StoreService.init(storeRepository: StoreRepository(db));
    await Store.put(StoreKey.serverEndpoint, 'http://demo.immich.app/api');
    registerFallbackValue(_FakeBaseRequest());
    file = File('${Directory.systemTemp.createTempSync().path}/photo.jpg')..writeAsStringSync('bytes');
  });

  setUp(() {
    client = _MockHttpClient();
    sut = UploadRepository();
  });

  // consumes the body like a real client would, so a reused request would blow up on the second send
  void stubSend(FutureOr<http.StreamedResponse> Function(int attempt) answer) {
    var attempt = 0;
    when(() => client.send(any())).thenAnswer((invocation) async {
      final request = invocation.positionalArguments.single as http.BaseRequest;
      await request.finalize().drain<void>();
      return answer(++attempt);
    });
  }

  http.StreamedResponse response(int status, String body) =>
      http.StreamedResponse(Stream.value(utf8.encode(body)), status);

  Future<UploadResult> upload() => sut.uploadFile(
    file: file,
    originalFileName: 'photo.jpg',
    fields: const {'deviceAssetId': 'a1'},
    cancelToken: null,
    logContext: 'a1',
    httpClient: client,
  );

  test('resends once when the first send dies before a response', () async {
    stubSend((attempt) {
      if (attempt == 1) {
        throw http.ClientException('Broken pipe');
      }
      return response(201, '{"id":"remote-1"}');
    });

    final result = await upload();

    expect(result.isSuccess, isTrue);
    expect(result.remoteAssetId, 'remote-1');
    verify(() => client.send(any())).called(2);
  });

  test('a second transport failure is an error, no third send', () async {
    stubSend((_) => throw http.ClientException('Connection reset'));

    final result = await upload();

    expect(result.isSuccess, isFalse);
    expect(result.isCancelled, isFalse);
    verify(() => client.send(any())).called(2);
  });

  test('a cancelled upload is not resent', () async {
    stubSend((_) => throw http.RequestAbortedException());

    final result = await upload();

    expect(result.isCancelled, isTrue);
    verify(() => client.send(any())).called(1);
  });

  test('a cancel during the resend still counts as cancelled', () async {
    stubSend((attempt) {
      if (attempt == 1) {
        throw http.ClientException('Broken pipe');
      }
      throw http.RequestAbortedException();
    });

    final result = await upload();

    expect(result.isCancelled, isTrue);
    verify(() => client.send(any())).called(2);
  });

  test('a server error response is not resent', () async {
    stubSend((_) => response(500, '{"message":"boom"}'));

    final result = await upload();

    expect(result.statusCode, 500);
    expect(result.errorMessage, 'boom');
    verify(() => client.send(any())).called(1);
  });

  group('a redirected upload', () {
    const token = 'session-token';
    const sibling = 'https://origin.example.com/api/assets';

    late List<http.BaseRequest> sent;
    late List<String> bodies;

    setUp(() async {
      await Store.put(StoreKey.serverEndpoint, 'https://photos.example.com/api');
      await Store.put(StoreKey.accessToken, token);
      sent = [];
      bodies = [];
    });

    tearDown(() async {
      await Store.put(StoreKey.serverEndpoint, 'http://demo.immich.app/api');
      await Store.delete(StoreKey.accessToken);
    });

    // like stubSend, but keeps what was sent: a body can only be read once, so it is captured here
    void stubRecording(FutureOr<http.StreamedResponse> Function(int attempt) answer) {
      when(() => client.send(any())).thenAnswer((invocation) async {
        final request = invocation.positionalArguments.single as http.BaseRequest;
        bodies.add(utf8.decode(await request.finalize().toBytes(), allowMalformed: true));
        sent.add(request);
        return answer(sent.length);
      });
    }

    http.StreamedResponse redirect(int status, String location) =>
        http.StreamedResponse(const Stream.empty(), status, headers: {'location': location}, isRedirect: true);

    test('every upload opts in, and is not left to the client to redirect', () async {
      stubRecording((_) => response(201, '{"id":"remote-1"}'));

      await upload();

      expect(sent.single.headers[UploadRepository.directUploadHeader], '1');
      expect(sent.single.followRedirects, isFalse);
      expect(sent.single.headers.keys.map((name) => name.toLowerCase()), isNot(contains('authorization')));
    });

    test('is sent again in full to a sibling host, with the session in a header', () async {
      stubRecording((attempt) => attempt == 1 ? redirect(307, sibling) : response(201, '{"id":"remote-1"}'));

      final result = await upload();

      expect(result.isSuccess, isTrue);
      expect(result.remoteAssetId, 'remote-1');
      expect(sent, hasLength(2));
      expect(sent.last.method, 'POST');
      expect(sent.last.url, Uri.parse(sibling));
      expect(sent.last.headers['Authorization'], 'Bearer $token');
      expect(sent.last.followRedirects, isFalse);
      // the whole file and its fields again, not whatever the first attempt left unread
      expect(bodies.last, contains('bytes'));
      expect(bodies.last, contains('a1'));
      expect(bodies.last.length, bodies.first.length);
    });

    test('the session never appears in a URL', () async {
      stubRecording((attempt) => attempt == 1 ? redirect(307, sibling) : response(201, '{"id":"remote-1"}'));

      await upload();

      for (final request in sent) {
        expect(request.url.toString(), isNot(contains(token)));
      }
    });

    test('the session is not offered to an unrelated host', () async {
      stubRecording((_) => redirect(307, 'https://photos.example.net/api/assets'));

      final result = await upload();

      expect(result.isSuccess, isFalse);
      expect(result.statusCode, 307);
      expect(result.errorMessage, contains('photos.example.net'));
      expect(sent, hasLength(1));
    });

    test('a redirect on the same host is followed without adding credentials', () async {
      stubRecording((attempt) => attempt == 1 ? redirect(308, '/api/v2/assets') : response(201, '{"id":"remote-1"}'));

      final result = await upload();

      expect(result.isSuccess, isTrue);
      expect(sent.last.url, Uri.parse('https://photos.example.com/api/v2/assets'));
      expect(sent.last.headers.keys.map((name) => name.toLowerCase()), isNot(contains('authorization')));
      expect(bodies.last, contains('bytes'));
    });

    test('a redirect that turns the upload into a GET is not followed', () async {
      for (final status in [301, 302, 303]) {
        sent.clear();
        stubRecording((_) => redirect(status, sibling));

        final result = await upload();

        expect(result.isSuccess, isFalse, reason: '$status');
        expect(result.statusCode, status);
        expect(sent, hasLength(1), reason: '$status');
      }
    });

    test('only one hop is followed', () async {
      stubRecording((_) => redirect(307, sibling));

      final result = await upload();

      expect(result.isSuccess, isFalse);
      expect(result.statusCode, 307);
      expect(sent, hasLength(2));
    });

    test('without a session there is nothing to present, so it is not followed', () async {
      await Store.delete(StoreKey.accessToken);
      stubRecording((_) => redirect(307, sibling));

      final result = await upload();

      expect(result.isSuccess, isFalse);
      expect(sent, hasLength(1));
    });

    test('a transport failure after the redirect starts again from the first request', () async {
      stubRecording((attempt) {
        switch (attempt) {
          case 1 || 3:
            return redirect(307, sibling);
          case 2:
            throw http.ClientException('Connection reset');
          default:
            return response(201, '{"id":"remote-1"}');
        }
      });

      final result = await upload();

      expect(result.isSuccess, isTrue);
      expect(sent.map((request) => request.url.host), [
        'photos.example.com',
        'origin.example.com',
        'photos.example.com',
        'origin.example.com',
      ]);
    });

    test('a cancel during the second request counts as cancelled', () async {
      stubRecording((attempt) => attempt == 1 ? redirect(307, sibling) : throw http.RequestAbortedException());

      final result = await upload();

      expect(result.isCancelled, isTrue);
      expect(sent, hasLength(2));
    });
  });

  group('redirectTarget', () {
    final from = Uri.parse('https://photos.example.com/api/assets');

    Uri? target(String? location, {int status = 307, Uri? origin}) =>
        UploadRepository.redirectTarget(origin ?? from, status, location);

    test('accepts another name directly under the same parent domain', () {
      expect(target('https://origin.example.com/api/assets'), Uri.parse('https://origin.example.com/api/assets'));
      expect(target('https://origin.example.com:8443/api/assets?x=1')?.port, 8443);
      expect(target('https://ORIGIN.Example.COM/api/assets')?.host, 'origin.example.com');
    });

    test('resolves a relative location against the request', () {
      expect(target('/api/v2/assets'), Uri.parse('https://photos.example.com/api/v2/assets'));
    });

    test('rejects anything that is not a sibling over https', () {
      const rejected = [
        'https://example.com/api/assets', // the parent itself
        'https://origin.eu.example.com/api/assets', // a level deeper
        'https://origin.example.net/api/assets', // a different domain
        'https://origin.example.com.evil.net/api/assets', // only looks like it
        'https://photos.example.com.evil.net/api/assets',
        'http://origin.example.com/api/assets', // would send the session in the clear
        'https://user:secret@origin.example.com/api/assets',
        'https://10.0.0.2/api/assets',
        'https://[2001:db8::1]/api/assets',
        'https://origin.example.com./api/assets',
        'ftp://origin.example.com/api/assets',
        'mailto:someone@example.com',
        '',
      ];
      for (final location in rejected) {
        expect(target(location), isNull, reason: location);
      }
      expect(target(null), isNull);
    });

    test('only 307 and 308 keep the method and the body', () {
      for (final status in [200, 301, 302, 303, 304, 401, 503]) {
        expect(target('https://origin.example.com/api/assets', status: status), isNull, reason: '$status');
      }
      expect(target('https://origin.example.com/api/assets', status: 308), isNotNull);
    });

    test('addresses are not siblings of each other', () {
      final address = Uri.parse('https://10.0.0.1/api/assets');
      expect(target('https://11.0.0.1/api/assets', origin: address), isNull);
      expect(target('https://10.0.0.2/api/assets', origin: address), isNull);
    });

    test('two sites under a bare top-level domain are not siblings', () {
      expect(target('https://origin.com/api/assets', origin: Uri.parse('https://photos.com/api/assets')), isNull);
      expect(target('https://origin/api/assets', origin: Uri.parse('https://photos/api/assets')), isNull);
    });

    test('a server reached over http never sends the session to another host', () {
      final plain = Uri.parse('http://photos.example.com/api/assets');
      expect(target('https://origin.example.com/api/assets', origin: plain), isNull);
      expect(target('http://origin.example.com/api/assets', origin: plain), isNull);
    });

    test('on the same host the scheme may stay or be upgraded, never downgraded', () {
      final plain = Uri.parse('http://192.168.1.10:2283/api/assets');
      expect(target('/api/v2/assets', origin: plain), Uri.parse('http://192.168.1.10:2283/api/v2/assets'));
      expect(target('https://192.168.1.10/api/assets', origin: plain), isNotNull);
      expect(target('http://photos.example.com/api/assets'), isNull);
    });
  });
}
