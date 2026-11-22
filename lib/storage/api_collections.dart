/*
 * proxypin_mod: API collections (folders, saved requests, assertions) persisted in api_collections.json.
 *
 * Licensed under the Apache License, Version 2.0.
 */
import 'dart:convert';

import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/http/http_client.dart';
import 'package:proxypin/storage/path.dart';
import 'package:proxypin/utils/api_formats.dart';
import 'package:proxypin/utils/har.dart';
import 'package:proxypin/utils/json_tools.dart';

class SavedRequest {
  String name;
  String folder;
  Map<String, dynamic> request; // HAR request object
  List<Assertion> assertions;

  SavedRequest({required this.name, this.folder = '', required this.request, List<Assertion>? assertions})
      : assertions = assertions ?? [];

  factory SavedRequest.fromJson(Map j) => SavedRequest(
        name: '${j['name'] ?? ''}',
        folder: '${j['folder'] ?? ''}',
        request: Map<String, dynamic>.from(j['request'] as Map? ?? const {}),
        assertions: (j['assertions'] as List? ?? const []).whereType<Map>().map(Assertion.fromJson).toList(),
      );

  Map<String, dynamic> toJson() =>
      {'name': name, 'folder': folder, 'request': request, 'assertions': assertions.map((e) => e.toJson()).toList()};

  String get method => '${request['method'] ?? 'GET'}';

  String get url => '${request['url'] ?? ''}';

  HttpRequest toHttpRequest() => Har.toRequest({'request': request, 'response': null});

  /// Saves a captured request; optionally generates assertions from its captured response.
  static SavedRequest fromCaptured(HttpRequest r, {bool generateTests = true}) {
    final har = Har.toHar(r);
    final req = Map<String, dynamic>.from(har['request'] as Map);
    req['httpVersion'] = 'HTTP/1.1';
    req['headers'] = (req['headers'] as List? ?? const [])
        .where((h) => h is Map && !'${h['name']}'.startsWith(':') && '${h['name']}'.toLowerCase() != 'content-length')
        .toList();
    final path = r.requestUri?.path ?? r.requestUrl;
    final segs = (r.requestUri?.pathSegments ?? const <String>[]).where((s) => s.isNotEmpty && !ApiShape.isIdSegment(s)).toList();
    return SavedRequest(
      name: '${r.method.name} $path',
      folder: segs.isEmpty ? (r.requestUri?.host ?? '') : segs.first,
      request: req,
      assertions: generateTests ? generateAssertions(r.response) : [],
    );
  }

  /// "AI-free" test generation: status, time budget, JSON structure.
  static List<Assertion> generateAssertions(HttpResponse? res) {
    if (res == null) return [Assertion(type: AssertionType.status, op: '<', value: '400')];
    final list = <Assertion>[
      Assertion(type: AssertionType.status, op: '==', value: '${res.status.code}'),
      Assertion(type: AssertionType.time, op: '<', value: '3000'),
    ];
    final ct = res.headers.contentType;
    if (ct.isNotEmpty) {
      list.add(Assertion(type: AssertionType.header, target: 'Content-Type', op: 'contains', value: ApiShape.mime(ct)));
    }
    final json = (res.body?.isNotEmpty ?? false) ? ApiShape.tryJson(res.bodyAsString) : null;
    if (json is Map) {
      for (final k in json.keys.take(8)) {
        list.add(Assertion(type: AssertionType.jsonPath, target: "\$['$k']", op: 'exists'));
      }
    } else if (json is List) {
      list.add(Assertion(type: AssertionType.jsonPath, target: r'$', op: 'length==', value: '${json.length}'));
    }
    if (json != null) {
      list.add(Assertion(type: AssertionType.schema, value: const JsonEncoder.withIndent(' ').convert(ApiShape.schemaOf(json))));
    }
    return list;
  }
}

class ApiCollection {
  String name;
  List<SavedRequest> items;

  ApiCollection({required this.name, List<SavedRequest>? items}) : items = items ?? [];

  factory ApiCollection.fromJson(Map j) => ApiCollection(
        name: '${j['name'] ?? ''}',
        items: (j['items'] as List? ?? const []).whereType<Map>().map(SavedRequest.fromJson).toList(),
      );

  Map<String, dynamic> toJson() => {'name': name, 'items': items.map((e) => e.toJson()).toList()};

  List<String> get folders => items.map((e) => e.folder).toSet().toList()..sort();
}

class RunResult {
  final SavedRequest item;
  final HttpResponse? response;
  final int elapsedMs;
  final List<AssertionResult> results;
  final String? error;

  RunResult(this.item, this.response, this.elapsedMs, this.results, [this.error]);

  bool get passed => error == null && results.every((r) => r.passed);
}

class ApiCollections {
  static const fileName = 'api_collections.json';
  static ApiCollections? _instance;
  final List<ApiCollection> collections = [];

  static Future<ApiCollections> get instance async {
    if (_instance != null) return _instance!;
    final store = ApiCollections();
    try {
      final file = await Paths.getPath(fileName);
      final text = await file.readAsString();
      if (text.trim().isNotEmpty) {
        final json = jsonDecode(text);
        store.collections.addAll((json['collections'] as List? ?? const []).whereType<Map>().map(ApiCollection.fromJson));
      }
    } catch (_) {}
    return _instance = store;
  }

  Future<void> save() async {
    final file = await Paths.getPath(fileName);
    await file.writeAsString(jsonEncode({'collections': collections.map((e) => e.toJson()).toList()}));
  }

  static Future<RunResult> run(SavedRequest item, {Duration timeout = const Duration(seconds: 30)}) async {
    final sw = Stopwatch()..start();
    try {
      final res = await HttpClients.proxyRequest(item.toHttpRequest(), timeout: timeout);
      sw.stop();
      final ms = sw.elapsedMilliseconds;
      return RunResult(item, res, ms, item.assertions.map((a) => a.check(res, ms)).toList());
    } catch (e) {
      sw.stop();
      return RunResult(item, null, sw.elapsedMilliseconds, [], '$e');
    }
  }
}
