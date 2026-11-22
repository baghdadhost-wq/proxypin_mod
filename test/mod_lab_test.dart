import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/storage/api_collections.dart';
import 'package:proxypin/utils/api_formats.dart';
import 'package:proxypin/utils/har.dart';
import 'package:proxypin/utils/json_tools.dart';

HttpRequest req(String url, int status, String body, {String method = 'GET'}) => Har.toRequest({
      'time': 120,
      'request': {'method': method, 'url': url, 'httpVersion': 'HTTP/2', 'headers': [
        {'name': ':authority', 'value': 'x'},
        {'name': 'Accept', 'value': '*/*'},
      ]},
      'response': {
        'status': status,
        'statusText': '',
        'httpVersion': 'HTTP/1.1',
        'headers': [
          {'name': 'Content-Type', 'value': 'application/json; charset=utf-8'}
        ],
        'content': {'text': body},
      }
    });

final data = jsonDecode('''{
  "store": {"name": "s", "items": [
    {"id": 1, "price": 5, "tags": ["a"]},
    {"id": 2, "price": 15, "name": "x"},
    {"id": 3, "price": 25}
  ]},
  "meta": {"id": 99}
}''');

void main() {
  test('jsonpath', () {
    expect(JsonPath.query(data, r'$.store.name'), ['s']);
    expect(JsonPath.query(data, r"$['store']['name']"), ['s']);
    expect(JsonPath.query(data, r'$.store.items[0].id'), [1]);
    expect(JsonPath.query(data, r'$.store.items[-1].id'), [3]);
    expect(JsonPath.query(data, r'$.store.items[*].id'), [1, 2, 3]);
    expect(JsonPath.query(data, r'$.store.items[0:2].id'), [1, 2]);
    expect(JsonPath.query(data, r'$..id'), [1, 2, 3, 99]);
    expect(JsonPath.query(data, r'$.store.items[?(@.price>10)].id'), [2, 3]);
    expect(JsonPath.query(data, r"$.store.items[?(@.name=='x')].id"), [2]);
    expect(JsonPath.query(data, r'$.store.items[?(@.tags)].id'), [1]);
    expect(JsonPath.query(data, r'$.nope'), isEmpty);
  });

  test('schema', () {
    final schema = ApiShape.schemaOf(data);
    expect(JsonSchema.validate(data, schema), isEmpty);
    final strict = {
      'type': 'object',
      'required': ['store', 'missing'],
      'properties': {
        'meta': {
          'type': 'object',
          'properties': {
            'id': {'type': 'string'}
          }
        }
      }
    };
    final errors = JsonSchema.validate(data, strict);
    expect(errors.length, 2);
    expect(errors.any((e) => e.contains('missing')), isTrue);
    expect(errors.any((e) => e.contains(r'$.meta.id')), isTrue);
    expect(
        JsonSchema.validate([1, 'a'], {
          'type': 'array',
          'items': {'type': 'integer'}
        }).length,
        1);
  });

  test('assertions', () {
    final r = req('https://a.com/api/x', 200, jsonEncode(data));
    Assertion a(AssertionType t, {String target = '', String op = '==', String value = ''}) =>
        Assertion(type: t, target: target, op: op, value: value);
    bool ok(Assertion x, [int ms = 100]) => x.check(r.response, ms).passed;
    expect(ok(a(AssertionType.status, value: '200')), isTrue);
    expect(ok(a(AssertionType.status, op: '<', value: '400')), isTrue);
    expect(ok(a(AssertionType.status, value: '201')), isFalse);
    expect(ok(a(AssertionType.time, op: '<', value: '50'), 100), isFalse);
    expect(ok(a(AssertionType.header, target: 'content-type', op: 'contains', value: 'json')), isTrue);
    expect(ok(a(AssertionType.bodyContains, value: '"price"')), isTrue);
    expect(ok(a(AssertionType.jsonPath, target: r'$.meta.id', value: '99')), isTrue);
    expect(ok(a(AssertionType.jsonPath, target: r'$.store.items', op: 'length==', value: '3')), isTrue);
    expect(ok(a(AssertionType.jsonPath, target: r'$.store.name', op: '=~', value: '^s\$')), isTrue);
    expect(ok(a(AssertionType.jsonPath, target: r'$.store.zzz', op: 'exists')), isFalse);
    expect(ok(a(AssertionType.schema, value: jsonEncode(ApiShape.schemaOf(data)))), isTrue);
    expect(a(AssertionType.status).check(null, 0).passed, isFalse);
  });

  test('generated tests pass on the response they came from; saved request is http/1.1', () {
    final r = req('https://a.com/api/title/5?x=1', 200, jsonEncode(data));
    final saved = SavedRequest.fromCaptured(r);
    expect(saved.folder, 'api');
    expect(saved.assertions.length, greaterThan(3));
    for (final x in saved.assertions) {
      expect(x.check(r.response, 100).passed, isTrue, reason: x.describe);
    }
    final back = SavedRequest.fromJson(jsonDecode(jsonEncode(saved.toJson())));
    final http = back.toHttpRequest();
    expect(http.protocolVersion, 'HTTP/1.1');
    expect(http.headers.get(':authority'), isNull);
    expect(http.requestUrl, 'https://a.com/api/title/5?x=1');
    expect(back.assertions.length, saved.assertions.length);
  });

  test('session diff', () {
    final a = [
      req('https://a.com/api/title/1', 200, '{"id":1,"name":"x"}'),
      req('https://a.com/api/old', 200, '{}'),
      req('https://a.com/api/same', 200, '{"a":1}'),
    ];
    final b = [
      req('https://a.com/api/title/2', 500, '{"id":"1","year":2020}'),
      req('https://a.com/api/new', 200, '{}'),
      req('https://a.com/api/same', 200, '{"a":2}'),
    ];
    final d = SessionDiff.compare(a, b);
    DiffEntry e(String k) => d.firstWhere((x) => x.endpoint.endsWith(k));
    expect(e('/api/new').kind, DiffKind.added);
    expect(e('/api/old').kind, DiffKind.removed);
    expect(e('/api/same').kind, DiffKind.same);
    final changed = e('/api/title/{id}');
    expect(changed.kind, DiffKind.changed);
    expect(changed.details.join(' '), contains('200 → 500'));
    expect(changed.details.join(' '), contains(r'$.name'));
    expect(changed.details.join(' '), contains(r'$.year'));
    expect(changed.details.join(' '), contains(r'$.id'));
  });
}
