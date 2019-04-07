import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart' as shelf;
import 'package:logging/logging.dart';
import 'package:pub_server/repository.dart';
import 'package:yaml/yaml.dart';
import 'package:archive/archive.dart';
import 'package:googleapis/oauth2/v2.dart';

import 'http_proxy_repository.dart';
import 'database.dart';
import 'storage.dart';

final Logger _logger = new Logger('unpub.repository');

class UnpubRepository extends PackageRepository {
  UnpubDatabase database;
  UnpubStorage storage;
  HttpProxyRepository proxy;

  UnpubRepository({
    @required this.database,
    @required this.storage,
    @required String proxyUrl,
  }) : proxy = HttpProxyRepository(http.Client(), Uri.parse(proxyUrl));

  @override
  Stream<PackageVersion> versions(String package) async* {
    var items = await database.getAllVersions(package).toList();

    if (items.isEmpty) {
      yield* proxy.versions(package);
    } else {
      yield* Stream.fromIterable(items);
    }
  }

  @override
  Future<PackageVersion> lookupVersion(String package, String version) async {
    var item = await database.getVersion(package, version);
    return item ?? proxy.lookupVersion(package, version);
  }

  @override
  bool get supportsUpload => true;

  Future<Tokeninfo> _getOperatorInfo(shelf.Request request) async {
    var authHeader = request.headers[HttpHeaders.authorizationHeader];
    if (authHeader == null) return null;

    var token = authHeader.split(' ').last;
    var info = await Oauth2Api(http.Client()).tokeninfo(accessToken: token);
    return info;
  }

  @override
  Future<PackageVersion> upload(Stream<List<int>> data, {request}) async {
    var info = await _getOperatorInfo(request);
    if (info == null) {
      throw UnauthorizedAccessException('google oauth fail');
    }

    _logger.info('Start uploading package.');
    var bb = await data.fold(
        BytesBuilder(), (BytesBuilder byteBuilder, d) => byteBuilder..add(d));
    var tarballBytes = bb.takeBytes();
    var tarBytes = GZipDecoder().decodeBytes(tarballBytes);
    var archive = TarDecoder().decodeBytes(tarBytes);
    ArchiveFile pubspecArchiveFile;
    for (var file in archive.files) {
      if (file.name == 'pubspec.yaml') {
        pubspecArchiveFile = file;
        break;
      }
    }

    if (pubspecArchiveFile == null) {
      throw 'Did not find any pubspec.yaml file in upload. Aborting.';
    }

    // TODO: Error handling.
    var pubspec = loadYaml(utf8.decode(_getBytes(pubspecArchiveFile)));

    var package = pubspec['name'] as String;
    var version = pubspec['version'] as String;

    var existing = await database.getVersion(package, version);

    // TODO: Ensure version is greater than existing versions
    if (existing != null) {
      throw StateError('`$package` already exists at version `$version`.');
    }

    var uploaders = await database.getUploadersOfPackage(package);
    if (!uploaders.contains(info.email)) {
      throw UnauthorizedAccessException(
          '${info.email} is not an uploader of $package package');
    }

    var pubspecContent = utf8.decode(pubspecArchiveFile.content);

    // Upload package tar to storage
    await storage.upload(package, version, tarballBytes);

    // Write package meta to database
    await database.addVersion(package, version, pubspecContent);

    return PackageVersion(package, version, pubspecContent);
  }

  @override
  Future<Stream<List<int>>> download(String package, String version) async {
    throw 'Should redirect to tos';
  }

  @override
  bool get supportsDownloadUrl => true;

  @override
  Future<Uri> downloadUrl(String package, String version) async {
    var item = await database.getVersion(package, version);
    if (item == null) {
      return proxy.downloadUrl(package, version);
    }
    return storage.downloadUri(package, version);
  }

  bool get supportsUploaders => false;

  Future addUploader(String package, String userEmail, {request}) async {
    var info = await _getOperatorInfo(request);
    if (info == null) {
      throw UnauthorizedAccessException('google oauth fail');
    }

    var uploaders = await database.getUploadersOfPackage(package);
    if (!uploaders.contains(info.email)) {
      throw UnauthorizedAccessException(
          '${info.email} is not an uploader of $package package');
    }

    if (userEmail == info.email) {
      throw StateError('cannot add self');
    }

    await database.addUploader(package, userEmail);
  }

  Future removeUploader(String package, String userEmail, {request}) async {
    var info = await _getOperatorInfo(request);
    if (info == null) {
      throw UnauthorizedAccessException('google oauth fail');
    }

    var uploaders = await database.getUploadersOfPackage(package);
    if (!uploaders.contains(info.email)) {
      throw UnauthorizedAccessException(
          '${info.email} is not an uploader of $package package');
    }

    if (userEmail == info.email) {
      throw StateError('cannot remove self');
    }

    if (uploaders.length <= 1) {
      throw StateError('at least one uploader');
    }

    await database.removeUploader(package, userEmail);
  }
}

List<int> _getBytes(ArchiveFile file) => file.content as List<int>;
