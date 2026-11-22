import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/utils/api_export.dart';
import 'package:proxypin/utils/api_formats.dart';
import 'package:proxypin/utils/golang.dart';
import 'package:proxypin/utils/har.dart';
import 'package:proxypin/utils/redact.dart';

const jwt = 'eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.c2lnbmF0dXJlc2lnbmF0dXJl';

HttpRequest req(String method, String url,
    {Map<String, String> headers = const {},
    String? body,
    String? mime,
    int? status,
    String? resBody,
    String resType = 'application/json'}) {
  return Har.toRequest({
    'startedDateTime': DateTime.now().toUtc().toIso8601String(),
    'time': 5,
    'request': {
      'method': method,
      'url': url,
      'httpVersion': 'HTTP/1.1',
      'headers': [
        ...headers.entries.map((e) => {'name': e.key, 'value': e.value}),
        if (mime != null) {'name': 'Content-Type', 'value': mime},
      ],
      if (body != null) 'postData': {'mimeType': mime ?? '', 'text': body},
    },
    'response': status == null
        ? null
        : {
            'status': status,
            'statusText': 'OK',
            'httpVersion': 'HTTP/1.1',
            'headers': [
              {'name': 'Content-Type', 'value': resType}
            ],
            'content': {'mimeType': resType, 'text': resBody ?? ''},
          },
  });
}

List<HttpRequest> sample() => [
      req('GET', 'https://tv.almanasa.tv/api/title/123?lang=ar&access_token=abc',
          headers: {'Authorization': 'Bearer $jwt', 'x-app-name': 'almanasa-web', 'Cookie': 'sid=1'},
          status: 200,
          resBody: '{"id":123,"name":"Film","email":"a@b.com","items":[{"n":1}]}'),
      req('GET', 'https://tv.almanasa.tv/api/title/123?lang=ar&access_token=abc',
          headers: {'Authorization': 'Bearer $jwt'}, status: 200, resBody: '{"id":123}'),
      req('POST', 'https://sso.almanasa.tv/realms/manasa/protocol/openid-connect/token',
          body: 'grant_type=password&username=0783&password=secret1', mime: 'application/x-www-form-urlencoded',
          status: 401, resBody: '{"error":"unauthorized_client"}'),
      req('GET', 'https://tv.almanasa.tv/img/poster.jpg', status: 200, resType: 'image/jpeg'),
      req('GET', 'https://cdn.almanasa.tv/v/stream.mpd', status: 200, resBody: '<MPD/>', resType: 'application/dash+xml'),
      req('GET', 'https://cdn.almanasa.tv/v/seg-1.m4s', status: 200, resType: 'video/mp4'),
      req('GET', 'https://google.com/api/x', status: 200, resBody: '{}'),
    ];

void main() {
  final domains = ApiExport.parseDomains('almanasa.tv');

  test('filters', () {
    int count(ExportFilter f) => ApiExport.select(sample(), domains, f, '').length;
    expect(count(ExportFilter.api), 4); // 2 title + token + mpd
    expect(count(ExportFilter.json), 3);
    expect(count(ExportFilter.auth), 3); // access_token in url x2 + token endpoint
    expect(count(ExportFilter.media), 1);
    expect(count(ExportFilter.errors), 1);
    expect(count(ExportFilter.all), 6);
    expect(ApiExport.select(sample(), [], ExportFilter.all, '').length, 7);
    expect(ApiExport.select(sample(), domains, ExportFilter.all, '/api/').length, 2);
  });

  test('compact export dedupes and redacts', () {
    final data = ApiExport.build(sample(), domains, redact: true);
    final text = jsonEncode(data);
    expect(data['exportedCalls'], 3);
    expect(text.contains(jwt), isFalse);
    expect(text.contains('secret1'), isFalse);
    expect(text.contains('a@b.com'), isFalse);
    expect(text.contains('sid=1'), isFalse);
    expect(text.contains('access_token=abc'), isFalse);
    expect(text.contains('almanasa-web'), isTrue);
    expect(text.contains('"name":"Film"'), isTrue);
    final plain = jsonEncode(ApiExport.build(sample(), domains, redact: false));
    expect(plain.contains(jwt), isTrue);
  });

  test('all formats render', () {
    for (final f in ExportFormat.values) {
      final (content, count) = ApiExport.render(sample(), domains, filter: ExportFilter.api, format: f, redact: true);
      expect(count, greaterThan(0), reason: f.name);
      expect(content.contains(jwt), isFalse, reason: f.name);
      expect(content.contains('secret1'), isFalse, reason: f.name);
      jsonDecode(content);
    }
  });

  test('openapi', () {
    final doc = OpenApiBuilder.build(ApiExport.select(sample(), domains, ExportFilter.api, ''));
    final paths = doc['paths'] as Map;
    expect(paths.containsKey('/api/title/{id}'), isTrue);
    final op = paths['/api/title/{id}']['get'] as Map;
    expect((op['parameters'] as List).any((p) => p['name'] == 'id' && p['in'] == 'path'), isTrue);
    expect((op['parameters'] as List).any((p) => p['name'] == 'x-app-name' && p['in'] == 'header'), isTrue);
    expect(doc['components']['securitySchemes']['bearerAuth'], isNotNull);
    // round trip: our own OpenAPI imports back
    final har = ImportConverter.toHar(jsonDecode(jsonEncode(doc)))!;
    final entries = har['log']['entries'] as List;
    expect(entries.length, greaterThan(0));
    for (final e in entries) {
      Har.toRequest(e);
    }
  });

  test('postman round trip', () {
    final col = PostmanBuilder.build(sample(), redact: false);
    final har = ImportConverter.toHar(jsonDecode(jsonEncode(col)))!;
    final list = (har['log']['entries'] as List).map((e) => Har.toRequest(e)).toList();
    expect(list.length, 7);
    expect(list.any((r) => r.method.name == 'POST' && r.bodyAsString.contains('grant_type')), isTrue);
  });

  test('postman variables and swagger 2 and charles', () {
    final pm = {
      'info': {'name': 'x', 'schema': 'https://schema.getpostman.com/json/collection/v2.1.0/collection.json'},
      'variable': [
        {'key': 'base', 'value': 'https://api.example.com'}
      ],
      'item': [
        {
          'name': 'folder',
          'item': [
            {
              'name': 'a',
              'request': {
                'method': 'POST',
                'url': {'raw': '{{base}}/v1/login'},
                'header': [
                  {'key': 'X-A', 'value': '1'}
                ],
                'body': {'mode': 'raw', 'raw': '{"u":1}', 'options': {'raw': {'language': 'json'}}}
              }
            }
          ]
        }
      ]
    };
    final e1 = ImportConverter.toHar(pm)!['log']['entries'] as List;
    expect(e1.single['request']['url'], 'https://api.example.com/v1/login');

    final sw = {
      'swagger': '2.0',
      'host': 'petstore.example.com',
      'basePath': '/v2',
      'schemes': ['https'],
      'paths': {
        '/pet/{petId}': {
          'get': {
            'parameters': [
              {'name': 'petId', 'in': 'path', 'type': 'integer'},
              {'name': 'q', 'in': 'query', 'type': 'string'}
            ]
          }
        }
      }
    };
    final e2 = ImportConverter.toHar(sw)!['log']['entries'] as List;
    expect(e2.single['request']['url'], startsWith('https://petstore.example.com/v2/pet/'));
    Har.toRequest(e2.single);

    final ch = [
      {
        'scheme': 'https',
        'host': 'a.example.com',
        'port': 443,
        'method': 'GET',
        'path': '/x',
        'query': 'y=1',
        'request': {
          'header': {
            'headers': [
              {'name': 'A', 'value': 'b'}
            ]
          }
        },
        'response': {'status': 200, 'body': {'text': '{}'}}
      }
    ];
    final e3 = ImportConverter.toHar(ch)!['log']['entries'] as List;
    final r = Har.toRequest(e3.single);
    expect(r.requestUrl, 'https://a.example.com/x?y=1');
    expect(r.response?.status.code, 200);
  });

  test('redactor', () {
    expect(Redactor.body('a=1&password=x&token=y'), 'a=1&password=<hidden>&token=<hidden>');
    expect(Redactor.value({'author': 'Ali', 'refresh_token': 'z', 'code': 200}),
        {'author': 'Ali', 'refresh_token': '<hidden>', 'code': 200});
    expect(Redactor.scrubText('Bearer abcdefghijklmnop'), 'Bearer <hidden>');
  });

  test('go export', () {
    final code = copyAsGo(sample()[2]);
    expect(code.contains('http.NewRequest(`POST`'), isTrue);
    expect(code.contains('"strings"'), isTrue);
  });
}
