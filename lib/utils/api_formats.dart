/*
 * proxypin_mod: API formats.
 *  - OpenAPI 3 generated from captured traffic
 *  - Postman Collection v2.1 export (folders by host / first path segment)
 *  - Import of Postman, OpenAPI / Swagger and Charles (.chlsj) into a HAR log
 *
 * Licensed under the Apache License, Version 2.0.
 */
import 'dart:convert';

import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/utils/redact.dart';

/// Shared helpers.
class ApiShape {
  static final RegExp _num = RegExp(r'^\d+$');
  static final RegExp _hex = RegExp(r'^[0-9a-fA-F-]{16,}$');

  static bool isIdSegment(String seg) => _num.hasMatch(seg) || _hex.hasMatch(seg);

  /// /title/123/season/2 -> /title/{id}/season/{id2}
  static String template(String path) {
    var n = 0;
    return path.split('/').map((seg) {
      if (seg.isEmpty || !isIdSegment(seg)) return seg;
      n++;
      return n == 1 ? '{id}' : '{id$n}';
    }).join('/');
  }

  static dynamic tryJson(String s) {
    final t = s.trimLeft();
    if (!(t.startsWith('{') || t.startsWith('['))) return null;
    try {
      return jsonDecode(s);
    } catch (_) {
      return null;
    }
  }

  /// JSON schema inferred from a sample value.
  static Map<String, dynamic> schemaOf(dynamic v, [int depth = 0]) {
    if (depth > 8) return {};
    if (v == null) return {'nullable': true};
    if (v is bool) return {'type': 'boolean'};
    if (v is int) return {'type': 'integer'};
    if (v is num) return {'type': 'number'};
    if (v is String) return {'type': 'string'};
    if (v is List) {
      return {'type': 'array', 'items': v.isEmpty ? <String, dynamic>{} : schemaOf(v.first, depth + 1)};
    }
    if (v is Map) {
      return {
        'type': 'object',
        'properties': v.map((k, val) => MapEntry(k.toString(), schemaOf(val, depth + 1))),
      };
    }
    return {};
  }

  /// Sample value built from a schema (used when importing OpenAPI).
  static dynamic sampleOf(dynamic schema, Map root, [int depth = 0]) {
    if (schema is! Map || depth > 6) return null;
    if (schema['example'] != null) return schema['example'];
    final ref = schema[r'$ref'];
    if (ref is String) return sampleOf(resolveRef(root, ref), root, depth + 1);
    if (schema['enum'] is List && (schema['enum'] as List).isNotEmpty) return (schema['enum'] as List).first;
    for (final k in ['allOf', 'oneOf', 'anyOf']) {
      if (schema[k] is List && (schema[k] as List).isNotEmpty) return sampleOf((schema[k] as List).first, root, depth + 1);
    }
    switch (schema['type']) {
      case 'object':
        final props = schema['properties'];
        if (props is! Map) return {};
        return props.map((k, v) => MapEntry(k.toString(), sampleOf(v, root, depth + 1)));
      case 'array':
        final item = sampleOf(schema['items'], root, depth + 1);
        return item == null ? [] : [item];
      case 'integer':
      case 'number':
        return 0;
      case 'boolean':
        return false;
      case 'string':
        return schema['format'] == 'date-time' ? DateTime.now().toUtc().toIso8601String() : 'string';
    }
    if (schema['properties'] is Map) return sampleOf({...schema, 'type': 'object'}, root, depth + 1);
    return null;
  }

  static dynamic resolveRef(Map root, String ref) {
    if (!ref.startsWith('#/')) return null;
    dynamic node = root;
    for (final part in ref.substring(2).split('/')) {
      if (node is! Map) return null;
      node = node[part.replaceAll('~1', '/').replaceAll('~0', '~')];
    }
    return node;
  }

  static String mime(String contentType) {
    final i = contentType.indexOf(';');
    return (i < 0 ? contentType : contentType.substring(0, i)).trim();
  }

  static const skipHeaders = {
    'host', 'content-length', 'connection', 'accept-encoding', 'user-agent', 'accept', 'accept-language',
    'origin', 'referer', 'sec-fetch-site', 'sec-fetch-mode', 'sec-fetch-dest', 'sec-ch-ua', 'sec-ch-ua-mobile',
    'sec-ch-ua-platform', 'pragma', 'cache-control', 'priority', 'te', 'if-none-match', 'if-modified-since',
  };
}

/// OpenAPI 3.0 document from captured requests.
class OpenApiBuilder {
  static Map<String, dynamic> build(List<HttpRequest> list, {String title = 'Captured API', bool redact = true}) {
    final servers = <String>{};
    final paths = <String, Map<String, dynamic>>{};
    var bearer = false;

    for (final r in list) {
      final uri = r.requestUri;
      if (uri == null || uri.host.isEmpty) continue;
      servers.add('${uri.scheme}://${uri.host}${uri.hasPort && uri.port != 443 && uri.port != 80 ? ':${uri.port}' : ''}');

      final path = ApiShape.template(uri.path.isEmpty ? '/' : uri.path);
      final method = r.method.name.toLowerCase();
      if (method == 'options' || method == 'connect') continue;
      final item = paths.putIfAbsent(path, () => <String, dynamic>{});
      final op = item.putIfAbsent(
          method,
          () => <String, dynamic>{
                'summary': '${r.method.name} $path',
                'operationId': _opId(method, path, item.length + paths.length),
                'parameters': <Map<String, dynamic>>[],
                'responses': <String, dynamic>{},
              }) as Map<String, dynamic>;

      final params = op['parameters'] as List<Map<String, dynamic>>;
      bool has(String name, String where) => params.any((p) => p['name'] == name && p['in'] == where);

      // path params
      for (final m in RegExp(r'\{(id\d*)\}').allMatches(path)) {
        if (!has(m.group(1)!, 'path')) {
          params.add({'name': m.group(1), 'in': 'path', 'required': true, 'schema': {'type': 'string'}});
        }
      }
      // query params
      uri.queryParameters.forEach((k, v) {
        if (has(k, 'query')) return;
        params.add({
          'name': k,
          'in': 'query',
          'schema': {'type': 'string'},
          'example': redact && Redactor.isSensitiveKey(k) ? Redactor.mask : v,
        });
      });
      // custom headers (x-app-*, etc.)
      r.headers.forEach((name, values) {
        final lower = name.toLowerCase();
        if (lower == 'authorization') {
          bearer = true;
          return;
        }
        if (ApiShape.skipHeaders.contains(lower) || lower == 'cookie' || lower == 'content-type') return;
        if (has(name, 'header')) return;
        params.add({
          'name': name,
          'in': 'header',
          'schema': {'type': 'string'},
          'example': redact ? (Redactor.isSensitiveKey(name) ? Redactor.mask : Redactor.scrubText(values.join(', '))) : values.join(', '),
        });
      });

      // request body
      if (op['requestBody'] == null && (r.body?.isNotEmpty ?? false)) {
        final type = ApiShape.mime(r.headers.contentType);
        final json = ApiShape.tryJson(r.bodyAsString);
        if (json != null) {
          op['requestBody'] = {
            'content': {
              type.isEmpty ? 'application/json' : type: {
                'schema': ApiShape.schemaOf(json),
                'example': redact ? Redactor.value(json) : json,
              }
            }
          };
        } else if (type.contains('x-www-form-urlencoded')) {
          final form = Uri.splitQueryString(r.bodyAsString);
          op['requestBody'] = {
            'content': {
              type: {
                'schema': {'type': 'object', 'properties': form.map((k, v) => MapEntry(k, {'type': 'string'}))},
                'example': redact ? Redactor.value(form) : form,
              }
            }
          };
        } else {
          op['requestBody'] = {
            'content': {
              type.isEmpty ? 'application/octet-stream' : type: {'schema': {'type': 'string'}}
            }
          };
        }
      }

      // responses
      final res = r.response;
      final responses = op['responses'] as Map<String, dynamic>;
      final code = '${res?.status.code ?? 'default'}';
      if (res != null && !responses.containsKey(code)) {
        final type = ApiShape.mime(res.headers.contentType);
        final entry = <String, dynamic>{'description': res.status.reasonPhrase.isEmpty ? code : res.status.reasonPhrase};
        final text = (res.body?.isNotEmpty ?? false) && !res.contentType.isBinary ? res.bodyAsString : '';
        final json = text.isEmpty ? null : ApiShape.tryJson(text);
        if (json != null) {
          final example = redact ? Redactor.value(json) : json;
          entry['content'] = {
            type.isEmpty ? 'application/json' : type: {
              'schema': ApiShape.schemaOf(json),
              if (text.length <= 8 * 1024) 'example': example,
            }
          };
        } else if (type.isNotEmpty) {
          entry['content'] = {
            type: {'schema': {'type': 'string'}}
          };
        }
        responses[code] = entry;
      }
    }

    // operations without any captured response still need one
    for (final item in paths.values) {
      for (final op in item.values) {
        final responses = (op as Map<String, dynamic>)['responses'] as Map<String, dynamic>;
        if (responses.isEmpty) responses['default'] = {'description': 'no response captured'};
        if ((op['parameters'] as List).isEmpty) op.remove('parameters');
      }
    }

    final sortedPaths = Map.fromEntries(paths.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
    return {
      'openapi': '3.0.3',
      'info': {'title': title, 'version': '1.0.0', 'description': 'Generated by proxypin_mod from captured traffic'},
      'servers': servers.map((s) => {'url': s}).toList(),
      if (bearer)
        'components': {
          'securitySchemes': {
            'bearerAuth': {'type': 'http', 'scheme': 'bearer', 'bearerFormat': 'JWT'}
          }
        },
      if (bearer)
        'security': [
          {'bearerAuth': []}
        ],
      'paths': sortedPaths,
    };
  }

  static String _opId(String method, String path, int n) {
    final words = path.split('/').where((s) => s.isNotEmpty && !s.startsWith('{')).map((s) => s.replaceAll(RegExp(r'[^A-Za-z0-9]'), ''));
    final base = '$method${words.map((w) => w.isEmpty ? '' : w[0].toUpperCase() + w.substring(1)).join()}';
    return base.isEmpty ? 'op$n' : base;
  }
}

/// Postman Collection v2.1 export.
class PostmanBuilder {
  static Map<String, dynamic> build(List<HttpRequest> list, {String name = 'proxypin_mod', bool redact = true}) {
    final folders = <String, Map<String, List<Map<String, dynamic>>>>{};
    for (final r in list) {
      final uri = r.requestUri;
      if (uri == null) continue;
      final host = uri.host.isEmpty ? 'other' : uri.host;
      final segs = uri.pathSegments.where((s) => s.isNotEmpty && !ApiShape.isIdSegment(s)).toList();
      final sub = segs.isEmpty ? '/' : segs.length == 1 ? segs.first : '${segs[0]}/${segs[1]}';
      folders.putIfAbsent(host, () => {}).putIfAbsent(sub, () => []).add(_item(r, redact));
    }
    return {
      'info': {
        'name': name,
        'schema': 'https://schema.getpostman.com/json/collection/v2.1.0/collection.json',
      },
      'item': folders.entries
          .map((h) => {
                'name': h.key,
                'item': h.value.entries.map((f) => {'name': f.key, 'item': f.value}).toList(),
              })
          .toList(),
    };
  }

  static Map<String, dynamic> _item(HttpRequest r, bool redact) {
    final url = redact ? Redactor.url(r.requestUrl) : r.requestUrl;
    final headers = <Map<String, String>>[];
    r.headers.forEach((name, values) {
      if (name.toLowerCase() == 'content-length' || name.toLowerCase() == 'host') return;
      final v = values.join(', ');
      headers.add({'key': name, 'value': redact ? (Redactor.isSensitiveKey(name) ? Redactor.mask : Redactor.scrubText(v)) : v});
    });
    final item = <String, dynamic>{
      'name': '${r.method.name} ${r.requestUri?.path ?? r.requestUrl}',
      'request': {
        'method': r.method.name,
        'header': headers,
        'url': url,
      },
    };
    if (r.body?.isNotEmpty ?? false) {
      final text = r.bodyAsString;
      final type = r.headers.contentType;
      final raw = redact ? Redactor.body(text, contentType: type) : text;
      (item['request'] as Map)['body'] = {
        'mode': 'raw',
        'raw': raw,
        if (type.contains('json')) 'options': {'raw': {'language': 'json'}},
      };
    }
    return item;
  }
}

/// Converts other formats into a HAR log so the existing history import can read them.
class ImportConverter {
  /// Returns a HAR map ({"log": ...}) or null when [data] is not a known format.
  static Map<String, dynamic>? toHar(dynamic data) {
    if (data is Map && data['log'] is Map) return Map<String, dynamic>.from(data); // already HAR
    if (data is Map && (data['openapi'] != null || data['swagger'] != null)) return _openApi(data);
    if (data is Map && data['info'] is Map && '${data['info']['schema'] ?? ''}'.contains('postman')) return _postman(data);
    if (data is Map && data['item'] is List) return _postman(data);
    if (data is List && data.isNotEmpty && data.first is Map && (data.first as Map).containsKey('host')) {
      return _charles(data);
    }
    return null;
  }

  static Map<String, dynamic> _har(String title, List<Map<String, dynamic>> entries) => {
        'log': {
          'version': '1.2',
          'creator': {'name': 'proxypin_mod import', 'version': '1'},
          'pages': [
            {'title': title, 'id': 'import', 'startedDateTime': DateTime.now().toUtc().toIso8601String()}
          ],
          'entries': entries,
        }
      };

  static Map<String, dynamic> _entry(String method, String url, List<Map<String, String>> headers,
      {String? body, String? mime, int? status, List<Map<String, String>>? resHeaders, String? resBody}) {
    return {
      'startedDateTime': DateTime.now().toUtc().toIso8601String(),
      'time': 0,
      'request': {
        'method': method.toUpperCase(),
        'url': url,
        'httpVersion': 'HTTP/1.1',
        'headers': headers,
        'queryString': [],
        'cookies': [],
        if (body != null) 'postData': {'mimeType': mime ?? '', 'text': body},
      },
      'response': status == null
          ? null
          : {
              'status': status,
              'statusText': '',
              'httpVersion': 'HTTP/1.1',
              'headers': resHeaders ?? [],
              'content': {'mimeType': '', 'text': resBody ?? ''},
            },
    };
  }

  static bool _validUrl(String url) {
    final u = Uri.tryParse(url);
    return u != null && (u.scheme == 'http' || u.scheme == 'https') && u.host.isNotEmpty;
  }

  // ---------- Postman ----------
  static Map<String, dynamic> _postman(Map data) {
    final vars = <String, String>{};
    for (final v in (data['variable'] as List? ?? const [])) {
      if (v is Map && v['key'] != null) vars['${v['key']}'] = '${v['value'] ?? ''}';
    }
    String sub(String s) => s.replaceAllMapped(RegExp(r'\{\{([^}]+)\}\}'), (m) => vars[m.group(1)!.trim()] ?? m.group(0)!);

    final entries = <Map<String, dynamic>>[];
    void walk(List items) {
      for (final it in items) {
        if (it is! Map) continue;
        if (it['item'] is List) {
          walk(it['item'] as List);
          continue;
        }
        final req = it['request'];
        if (req is! Map && req is! String) continue;
        final r = req is String ? {'method': 'GET', 'url': req} : req as Map;
        final rawUrl = r['url'] is Map ? '${(r['url'] as Map)['raw'] ?? ''}' : '${r['url'] ?? ''}';
        var url = sub(rawUrl);
        if (!url.startsWith('http')) url = 'https://$url';
        if (!_validUrl(url)) continue;

        final headers = <Map<String, String>>[];
        for (final h in (r['header'] as List? ?? const [])) {
          if (h is Map && h['disabled'] != true && h['key'] != null) {
            headers.add({'name': '${h['key']}', 'value': sub('${h['value'] ?? ''}')});
          }
        }
        final auth = r['auth'];
        if (auth is Map && auth['type'] == 'bearer') {
          final list = auth['bearer'];
          final token = list is List
              ? list.whereType<Map>().firstWhere((e) => e['key'] == 'token', orElse: () => const {})['value']
              : null;
          if (token != null) headers.add({'name': 'Authorization', 'value': 'Bearer ${sub('$token')}'});
        }

        String? body;
        String? mime;
        final b = r['body'];
        if (b is Map) {
          switch (b['mode']) {
            case 'raw':
              body = sub('${b['raw'] ?? ''}');
              final lang = (b['options'] is Map && b['options']['raw'] is Map) ? b['options']['raw']['language'] : null;
              mime = lang == 'json' ? 'application/json' : null;
              break;
            case 'urlencoded':
              body = (b['urlencoded'] as List? ?? const [])
                  .whereType<Map>()
                  .where((e) => e['disabled'] != true)
                  .map((e) => '${Uri.encodeQueryComponent('${e['key']}')}=${Uri.encodeQueryComponent(sub('${e['value'] ?? ''}'))}')
                  .join('&');
              mime = 'application/x-www-form-urlencoded';
              break;
            case 'graphql':
              final g = b['graphql'];
              if (g is Map) {
                body = jsonEncode({'query': g['query'], 'variables': ApiShape.tryJson('${g['variables'] ?? ''}') ?? {}});
                mime = 'application/json';
              }
              break;
          }
        }
        if (mime != null && !headers.any((h) => h['name']!.toLowerCase() == 'content-type')) {
          headers.add({'name': 'Content-Type', 'value': mime});
        }
        entries.add(_entry('${r['method'] ?? 'GET'}', url, headers, body: body, mime: mime));
      }
    }

    walk(data['item'] as List? ?? const []);
    final title = data['info'] is Map ? '${data['info']['name'] ?? 'Postman'}' : 'Postman';
    return _har('[Postman] $title', entries);
  }

  // ---------- OpenAPI 3 / Swagger 2 ----------
  static Map<String, dynamic> _openApi(Map doc) {
    String base;
    if (doc['openapi'] != null) {
      final servers = doc['servers'];
      base = servers is List && servers.isNotEmpty && servers.first is Map ? '${servers.first['url']}' : 'https://example.com';
      final vars = servers is List && servers.isNotEmpty && servers.first is Map ? servers.first['variables'] : null;
      if (vars is Map) {
        vars.forEach((k, v) => base = base.replaceAll('{$k}', '${v is Map ? v['default'] ?? '' : ''}'));
      }
    } else {
      final schemes = doc['schemes'];
      final scheme = schemes is List && schemes.isNotEmpty ? '${schemes.first}' : 'https';
      base = '$scheme://${doc['host'] ?? 'example.com'}${doc['basePath'] ?? ''}';
    }
    if (!base.startsWith('http')) base = 'https://example.com${base.startsWith('/') ? '' : '/'}$base';
    if (base.endsWith('/')) base = base.substring(0, base.length - 1);

    final entries = <Map<String, dynamic>>[];
    final paths = doc['paths'];
    if (paths is Map) {
      paths.forEach((path, item) {
        if (item is! Map) return;
        final shared = item['parameters'] as List? ?? const [];
        for (final method in ['get', 'post', 'put', 'patch', 'delete', 'head']) {
          final op = item[method];
          if (op is! Map) continue;
          final params = [...shared, ...(op['parameters'] as List? ?? const [])]
              .map((x) => x is Map && x[r'$ref'] is String ? ApiShape.resolveRef(doc, x[r'$ref']) : x)
              .whereType<Map>()
              .toList();

          var p = '$path';
          final query = <String>[];
          final headers = <Map<String, String>>[];
          String? body;
          String? mime;
          for (final prm in params) {
            final ex = prm['example'] ?? ApiShape.sampleOf(prm['schema'] ?? prm, doc) ?? '1';
            switch (prm['in']) {
              case 'path':
                p = p.replaceAll('{${prm['name']}}', Uri.encodeComponent('$ex'));
                break;
              case 'query':
                query.add('${Uri.encodeQueryComponent('${prm['name']}')}=${Uri.encodeQueryComponent('$ex')}');
                break;
              case 'header':
                headers.add({'name': '${prm['name']}', 'value': '$ex'});
                break;
              case 'body': // swagger 2
                body = jsonEncode(ApiShape.sampleOf(prm['schema'], doc) ?? {});
                mime = 'application/json';
                break;
            }
          }
          p = p.replaceAll(RegExp(r'\{[^}]*\}'), '1');

          final rb = op['requestBody'] is Map && (op['requestBody'] as Map)[r'$ref'] is String
              ? ApiShape.resolveRef(doc, (op['requestBody'] as Map)[r'$ref'])
              : op['requestBody'];
          if (rb is Map && rb['content'] is Map && (rb['content'] as Map).isNotEmpty) {
            final content = rb['content'] as Map;
            final type = content.containsKey('application/json') ? 'application/json' : '${content.keys.first}';
            final media = content[type];
            final sample = media is Map ? (media['example'] ?? ApiShape.sampleOf(media['schema'], doc)) : null;
            mime = type;
            body = type.contains('json')
                ? jsonEncode(sample ?? {})
                : sample is Map
                    ? sample.entries.map((e) => '${Uri.encodeQueryComponent('${e.key}')}=${Uri.encodeQueryComponent('${e.value}')}').join('&')
                    : '${sample ?? ''}';
          }
          if (mime != null) headers.add({'name': 'Content-Type', 'value': mime});

          final url = '$base$p${query.isEmpty ? '' : '?${query.join('&')}'}';
          if (!_validUrl(url)) continue;
          entries.add(_entry(method, url, headers, body: body, mime: mime));
        }
      });
    }
    final title = doc['info'] is Map ? '${doc['info']['title'] ?? 'OpenAPI'}' : 'OpenAPI';
    return _har('[OpenAPI] $title', entries);
  }

  // ---------- Charles JSON session (.chlsj) ----------
  static Map<String, dynamic> _charles(List sessions) {
    List<Map<String, String>> hdrs(dynamic part) {
      final h = part is Map && part['header'] is Map ? (part['header'] as Map)['headers'] : null;
      return (h as List? ?? const [])
          .whereType<Map>()
          .map((e) => {'name': '${e['name']}', 'value': '${e['value'] ?? ''}'})
          .toList();
    }

    String? text(dynamic part) {
      final b = part is Map ? part['body'] : null;
      if (b is Map) return b['text'] == null ? null : '${b['text']}';
      return null;
    }

    final entries = <Map<String, dynamic>>[];
    for (final s in sessions) {
      if (s is! Map) continue;
      final scheme = '${s['scheme'] ?? 'https'}';
      final port = s['actualPort'] ?? s['port'];
      final defaultPort = (scheme == 'https' && '$port' == '443') || (scheme == 'http' && '$port' == '80');
      final url =
          '$scheme://${s['host']}${port == null || defaultPort ? '' : ':$port'}${s['path'] ?? '/'}${s['query'] == null ? '' : '?${s['query']}'}';
      if (!_validUrl(url) || '${s['method']}' == 'CONNECT') continue;
      final req = s['request'];
      final res = s['response'];
      final status = res is Map ? int.tryParse('${res['status'] ?? ''}') : null;
      final e = _entry('${s['method'] ?? 'GET'}', url, hdrs(req),
          body: text(req), status: status, resHeaders: hdrs(res), resBody: text(res));
      final start = s['times'] is Map ? (s['times'] as Map)['start'] : null;
      if (start != null && DateTime.tryParse('$start') != null) e['startedDateTime'] = '$start';
      entries.add(e);
    }
    return _har('[Charles] import', entries);
  }
}
