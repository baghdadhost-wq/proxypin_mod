/*
 * proxypin_mod: JSONPath, JSON Schema validation, assertions and session diff.
 * Pure Dart, no extra packages.
 *
 * Licensed under the Apache License, Version 2.0.
 */
import 'dart:convert';

import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/utils/api_formats.dart';

/// JSONPath subset: $  .key  ['key']  [0]  [-1]  [*]  .*  ..key  [0,2]  [1:3]  [?(@.key==value)]
class JsonPath {
  static List<dynamic> query(dynamic data, String path) {
    var p = path.trim();
    if (p.isEmpty || p == r'$') return [data];
    if (p.startsWith(r'$')) p = p.substring(1);
    var current = <dynamic>[data];
    final tokens = _tokenize(p);
    for (final t in tokens) {
      final next = <dynamic>[];
      for (final node in current) {
        _apply(node, t, next);
      }
      current = next;
    }
    return current;
  }

  static List<String> _tokenize(String p) {
    final out = <String>[];
    var i = 0;
    while (i < p.length) {
      final c = p[i];
      if (c == '.') {
        if (i + 1 < p.length && p[i + 1] == '.') {
          // recursive descent: '..name' or '..*'
          var j = i + 2;
          while (j < p.length && p[j] != '.' && p[j] != '[') {
            j++;
          }
          out.add('..${p.substring(i + 2, j)}');
          i = j;
        } else {
          var j = i + 1;
          while (j < p.length && p[j] != '.' && p[j] != '[') {
            j++;
          }
          out.add(p.substring(i + 1, j));
          i = j;
        }
      } else if (c == '[') {
        var depth = 0;
        var j = i;
        String? quote;
        for (; j < p.length; j++) {
          final ch = p[j];
          if (quote != null) {
            if (ch == quote) quote = null;
            continue;
          }
          if (ch == "'" || ch == '"') {
            quote = ch;
          } else if (ch == '[') {
            depth++;
          } else if (ch == ']') {
            depth--;
            if (depth == 0) break;
          }
        }
        out.add(p.substring(i, j + 1));
        i = j + 1;
      } else {
        var j = i;
        while (j < p.length && p[j] != '.' && p[j] != '[') {
          j++;
        }
        out.add(p.substring(i, j));
        i = j;
      }
    }
    return out.where((e) => e.isNotEmpty).toList();
  }

  static void _apply(dynamic node, String t, List out) {
    if (t.startsWith('..')) {
      final name = t.substring(2);
      void walk(dynamic n) {
        if (n is Map) {
          if (name == '*') {
            out.addAll(n.values);
          } else if (n.containsKey(name)) {
            out.add(n[name]);
          }
          n.values.forEach(walk);
        } else if (n is List) {
          if (name == '*') out.addAll(n);
          n.forEach(walk);
        }
      }

      walk(node);
      return;
    }
    if (t == '*') {
      if (node is Map) out.addAll(node.values);
      if (node is List) out.addAll(node);
      return;
    }
    if (!t.startsWith('[')) {
      if (node is Map && node.containsKey(t)) out.add(node[t]);
      return;
    }
    final inner = t.substring(1, t.length - 1).trim();
    if (inner == '*') {
      if (node is Map) out.addAll(node.values);
      if (node is List) out.addAll(node);
      return;
    }
    if (inner.startsWith('?(') && inner.endsWith(')')) {
      final items = node is List ? node : node is Map ? node.values.toList() : const [];
      for (final it in items) {
        if (_filter(it, inner.substring(2, inner.length - 1))) out.add(it);
      }
      return;
    }
    if (inner.startsWith("'") || inner.startsWith('"')) {
      for (final k in inner.split(',')) {
        final key = k.trim();
        final name = key.substring(1, key.length - 1);
        if (node is Map && node.containsKey(name)) out.add(node[name]);
      }
      return;
    }
    if (node is! List) return;
    if (inner.contains(':')) {
      final parts = inner.split(':');
      int norm(int v) => v < 0 ? node.length + v : v;
      final start = parts[0].trim().isEmpty ? 0 : norm(int.tryParse(parts[0].trim()) ?? 0);
      final end = parts.length < 2 || parts[1].trim().isEmpty ? node.length : norm(int.tryParse(parts[1].trim()) ?? 0);
      for (var i = start.clamp(0, node.length); i < end.clamp(0, node.length); i++) {
        out.add(node[i]);
      }
      return;
    }
    for (final s in inner.split(',')) {
      final idx = int.tryParse(s.trim());
      if (idx == null) continue;
      final i = idx < 0 ? node.length + idx : idx;
      if (i >= 0 && i < node.length) out.add(node[i]);
    }
  }

  /// @.a.b == 1, @.name == 'x', @.n > 3, @.flag (exists and truthy)
  static bool _filter(dynamic item, String expr) {
    final m = RegExp(r'^@([^=!<>]*)\s*(==|!=|>=|<=|>|<|=~)?\s*(.*)$').firstMatch(expr.trim());
    if (m == null) return false;
    final values = query(item, '\$${m.group(1)!.trim()}');
    final op = m.group(2);
    if (op == null) return values.isNotEmpty && values.first != null && values.first != false;
    if (values.isEmpty) return op == '!=';
    final left = values.first;
    final rawRight = m.group(3)!.trim();
    if (op == '=~') {
      final re = rawRight.startsWith('/') && rawRight.lastIndexOf('/') > 0
          ? rawRight.substring(1, rawRight.lastIndexOf('/'))
          : rawRight;
      return RegExp(re).hasMatch('$left');
    }
    final right = _literal(rawRight);
    return Assertion.compare(left, op, right);
  }

  static dynamic _literal(String s) {
    if ((s.startsWith("'") && s.endsWith("'")) || (s.startsWith('"') && s.endsWith('"'))) {
      return s.substring(1, s.length - 1);
    }
    if (s == 'true') return true;
    if (s == 'false') return false;
    if (s == 'null') return null;
    return num.tryParse(s) ?? s;
  }
}

/// JSON Schema (draft-07 subset) validator.
class JsonSchema {
  static List<String> validate(dynamic data, dynamic schema, {Map? root, String path = r'$'}) {
    root ??= schema is Map ? schema : {};
    final errors = <String>[];
    if (schema is! Map) return errors;
    final ref = schema[r'$ref'];
    if (ref is String) return validate(data, ApiShape.resolveRef(root, ref), root: root, path: path);

    final type = schema['type'];
    if (type != null) {
      final types = type is List ? type.map((e) => '$e').toList() : ['$type'];
      if (!types.any((t) => _isType(data, t))) {
        errors.add('$path: النوع المتوقع ${types.join('|')} لكن وُجد ${_typeOf(data)}');
        return errors;
      }
    }
    if (data == null && schema['nullable'] == true) return errors;
    if (schema['enum'] is List && !(schema['enum'] as List).any((e) => jsonEncode(e) == jsonEncode(data))) {
      errors.add('$path: القيمة ليست ضمن ${jsonEncode(schema['enum'])}');
    }
    if (schema.containsKey('const') && jsonEncode(schema['const']) != jsonEncode(data)) {
      errors.add('$path: يجب أن تساوي ${jsonEncode(schema['const'])}');
    }
    if (data is num) {
      if (schema['minimum'] is num && data < schema['minimum']) errors.add('$path: أقل من ${schema['minimum']}');
      if (schema['maximum'] is num && data > schema['maximum']) errors.add('$path: أكبر من ${schema['maximum']}');
    }
    if (data is String) {
      if (schema['minLength'] is int && data.length < schema['minLength']) errors.add('$path: أقصر من ${schema['minLength']}');
      if (schema['maxLength'] is int && data.length > schema['maxLength']) errors.add('$path: أطول من ${schema['maxLength']}');
      if (schema['pattern'] is String && !RegExp(schema['pattern']).hasMatch(data)) {
        errors.add('$path: لا يطابق النمط ${schema['pattern']}');
      }
    }
    if (data is Map) {
      for (final r in (schema['required'] as List? ?? const [])) {
        if (!data.containsKey(r)) errors.add('$path: الحقل المطلوب "$r" غير موجود');
      }
      final props = schema['properties'] is Map ? schema['properties'] as Map : const {};
      props.forEach((k, s) {
        if (data.containsKey(k)) errors.addAll(validate(data[k], s, root: root, path: '$path.$k'));
      });
      if (schema['additionalProperties'] == false) {
        for (final k in data.keys) {
          if (!props.containsKey(k)) errors.add('$path: حقل غير مسموح "$k"');
        }
      } else if (schema['additionalProperties'] is Map) {
        for (final k in data.keys) {
          if (!props.containsKey(k)) {
            errors.addAll(validate(data[k], schema['additionalProperties'], root: root, path: '$path.$k'));
          }
        }
      }
    }
    if (data is List) {
      if (schema['minItems'] is int && data.length < schema['minItems']) errors.add('$path: عناصر أقل من ${schema['minItems']}');
      if (schema['maxItems'] is int && data.length > schema['maxItems']) errors.add('$path: عناصر أكثر من ${schema['maxItems']}');
      if (schema['items'] is Map) {
        for (var i = 0; i < data.length; i++) {
          errors.addAll(validate(data[i], schema['items'], root: root, path: '$path[$i]'));
        }
      }
    }
    if (schema['allOf'] is List) {
      for (final s in schema['allOf']) {
        errors.addAll(validate(data, s, root: root, path: path));
      }
    }
    if (schema['anyOf'] is List) {
      final ok = (schema['anyOf'] as List).any((s) => validate(data, s, root: root, path: path).isEmpty);
      if (!ok) errors.add('$path: لا يطابق أي خيار في anyOf');
    }
    if (schema['oneOf'] is List) {
      final n = (schema['oneOf'] as List).where((s) => validate(data, s, root: root, path: path).isEmpty).length;
      if (n != 1) errors.add('$path: يجب أن يطابق خياراً واحداً في oneOf (طابق $n)');
    }
    return errors;
  }

  static bool _isType(dynamic v, String t) {
    switch (t) {
      case 'object':
        return v is Map;
      case 'array':
        return v is List;
      case 'string':
        return v is String;
      case 'integer':
        return v is int || (v is double && v == v.roundToDouble());
      case 'number':
        return v is num;
      case 'boolean':
        return v is bool;
      case 'null':
        return v == null;
    }
    return true;
  }

  static String _typeOf(dynamic v) => v == null
      ? 'null'
      : v is Map
          ? 'object'
          : v is List
              ? 'array'
              : v is String
                  ? 'string'
                  : v is int
                      ? 'integer'
                      : v is num
                          ? 'number'
                          : v is bool
                              ? 'boolean'
                              : 'unknown';
}

enum AssertionType {
  status('رمز الحالة'),
  time('زمن الاستجابة (ms)'),
  header('هيدر الاستجابة'),
  bodyContains('المحتوى يحتوي'),
  jsonPath('JSONPath'),
  schema('JSON Schema');

  final String label;

  const AssertionType(this.label);

  static AssertionType of(String? n) => AssertionType.values.firstWhere((e) => e.name == n, orElse: () => status);
}

class AssertionResult {
  final Assertion assertion;
  final bool passed;
  final String message;

  AssertionResult(this.assertion, this.passed, this.message);
}

/// One check on a response.
///  status   : op + value         (== 200, < 400)
///  time     : op + value         (< 1000)
///  header   : target=name, op (exists, ==, contains, =~) + value
///  bodyContains : value
///  jsonPath : target=path, op (exists, ==, !=, >, <, contains, =~, length==) + value
///  schema   : value = JSON schema text
class Assertion {
  AssertionType type;
  String target;
  String op;
  String value;

  Assertion({required this.type, this.target = '', this.op = '==', this.value = ''});

  factory Assertion.fromJson(Map j) => Assertion(
      type: AssertionType.of(j['type']), target: '${j['target'] ?? ''}', op: '${j['op'] ?? '=='}', value: '${j['value'] ?? ''}');

  Map<String, dynamic> toJson() => {'type': type.name, 'target': target, 'op': op, 'value': value};

  static const ops = ['==', '!=', '>', '<', '>=', '<=', 'exists', 'contains', '=~', 'length=='];

  String get describe {
    switch (type) {
      case AssertionType.status:
      case AssertionType.time:
        return '${type.label} $op $value';
      case AssertionType.header:
      case AssertionType.jsonPath:
        return '${type.label} $target $op ${op == 'exists' ? '' : value}'.trim();
      case AssertionType.bodyContains:
        return '${type.label} "$value"';
      case AssertionType.schema:
        return type.label;
    }
  }

  AssertionResult check(HttpResponse? res, int elapsedMs) {
    if (res == null) return AssertionResult(this, false, 'لا توجد استجابة');
    try {
      switch (type) {
        case AssertionType.status:
          final ok = compare(res.status.code, op, num.tryParse(value) ?? value);
          return AssertionResult(this, ok, 'الحالة ${res.status.code}');
        case AssertionType.time:
          final ok = compare(elapsedMs, op, num.tryParse(value) ?? 0);
          return AssertionResult(this, ok, 'الزمن $elapsedMs ms');
        case AssertionType.header:
          final v = res.headers.get(target);
          if (op == 'exists') return AssertionResult(this, v != null, v == null ? 'غير موجود' : v);
          return AssertionResult(this, v != null && compare(v, op, value), 'القيمة: ${v ?? 'غير موجود'}');
        case AssertionType.bodyContains:
          final ok = res.bodyAsString.contains(value);
          return AssertionResult(this, ok, ok ? 'موجود' : 'غير موجود');
        case AssertionType.jsonPath:
          final data = jsonDecode(res.bodyAsString);
          final found = JsonPath.query(data, target);
          if (op == 'exists') return AssertionResult(this, found.isNotEmpty, '${found.length} نتيجة');
          if (found.isEmpty) return AssertionResult(this, false, 'لا توجد نتيجة');
          final left = found.length == 1 ? found.first : found;
          final right = JsonPath._literal(value);
          return AssertionResult(this, compare(left, op, right), 'القيمة: ${_short(jsonEncode(left))}');
        case AssertionType.schema:
          final errors = JsonSchema.validate(jsonDecode(res.bodyAsString), jsonDecode(value));
          return AssertionResult(this, errors.isEmpty, errors.isEmpty ? 'مطابق' : errors.take(5).join('\n'));
      }
    } catch (e) {
      return AssertionResult(this, false, 'خطأ: $e');
    }
  }

  static String _short(String s) => s.length > 120 ? '${s.substring(0, 120)}…' : s;

  static bool compare(dynamic left, String op, dynamic right) {
    switch (op) {
      case 'exists':
        return left != null;
      case 'contains':
        if (left is List) return left.any((e) => '$e' == '$right');
        if (left is Map) return left.containsKey('$right');
        return '$left'.contains('$right');
      case '=~':
        return RegExp('$right').hasMatch('$left');
      case 'length==':
        final n = left is List ? left.length : left is Map ? left.length : '$left'.length;
        return n == (right is num ? right : num.tryParse('$right'));
    }
    final ln = left is num ? left : num.tryParse('$left');
    final rn = right is num ? right : num.tryParse('$right');
    if (ln != null && rn != null) {
      switch (op) {
        case '==':
          return ln == rn;
        case '!=':
          return ln != rn;
        case '>':
          return ln > rn;
        case '<':
          return ln < rn;
        case '>=':
          return ln >= rn;
        case '<=':
          return ln <= rn;
      }
    }
    final l = left is String ? left : jsonEncode(left);
    final r = right is String ? right : jsonEncode(right);
    switch (op) {
      case '==':
        return l == r;
      case '!=':
        return l != r;
      default:
        return l.compareTo(r) * (op.startsWith('>') ? 1 : -1) > 0 || (op.endsWith('=') && l == r);
    }
  }
}

enum DiffKind { added, removed, changed, same }

class DiffEntry {
  final DiffKind kind;
  final String endpoint;
  final List<String> details;

  DiffEntry(this.kind, this.endpoint, [this.details = const []]);
}

/// Compares two sessions by endpoint (METHOD host/templated/path).
class SessionDiff {
  static String key(HttpRequest r) {
    final u = r.requestUri;
    return '${r.method.name} ${u?.host ?? ''}${ApiShape.template(u?.path ?? '')}';
  }

  static List<DiffEntry> compare(List<HttpRequest> a, List<HttpRequest> b) {
    Map<String, HttpRequest> index(List<HttpRequest> l) {
      final m = <String, HttpRequest>{};
      for (final r in l) {
        if (r.method == HttpMethod.connect) continue;
        m.putIfAbsent(key(r), () => r);
      }
      return m;
    }

    final ia = index(a), ib = index(b);
    final out = <DiffEntry>[];
    for (final k in ib.keys) {
      if (!ia.containsKey(k)) out.add(DiffEntry(DiffKind.added, k));
    }
    for (final k in ia.keys) {
      if (!ib.containsKey(k)) out.add(DiffEntry(DiffKind.removed, k));
    }
    for (final k in ia.keys.where(ib.containsKey)) {
      final details = _details(ia[k]!, ib[k]!);
      out.add(DiffEntry(details.isEmpty ? DiffKind.same : DiffKind.changed, k, details));
    }
    out.sort((x, y) => x.kind.index != y.kind.index ? x.kind.index - y.kind.index : x.endpoint.compareTo(y.endpoint));
    return out;
  }

  static List<String> _details(HttpRequest a, HttpRequest b) {
    final d = <String>[];
    final sa = a.response?.status.code, sb = b.response?.status.code;
    if (sa != sb) d.add('الحالة: $sa → $sb');
    final qa = a.requestUri?.queryParameters.keys.toSet() ?? {}, qb = b.requestUri?.queryParameters.keys.toSet() ?? {};
    if (qa.difference(qb).isNotEmpty) d.add('متغيرات محذوفة: ${qa.difference(qb).join(', ')}');
    if (qb.difference(qa).isNotEmpty) d.add('متغيرات جديدة: ${qb.difference(qa).join(', ')}');
    final ja = _json(a.response), jb = _json(b.response);
    if (ja != null && jb != null) {
      final fa = _fields(ja), fb = _fields(jb);
      final removed = fa.keys.where((k) => !fb.containsKey(k)).toList();
      final added = fb.keys.where((k) => !fa.containsKey(k)).toList();
      final typeChanged = fa.keys.where((k) => fb.containsKey(k) && fa[k] != fb[k]).toList();
      if (removed.isNotEmpty) d.add('حقول محذوفة: ${removed.take(10).join(', ')}${removed.length > 10 ? '…' : ''}');
      if (added.isNotEmpty) d.add('حقول جديدة: ${added.take(10).join(', ')}${added.length > 10 ? '…' : ''}');
      if (typeChanged.isNotEmpty) {
        d.add('نوع تغيّر: ${typeChanged.take(10).map((k) => '$k (${fa[k]}→${fb[k]})').join(', ')}');
      }
    } else if ((ja == null) != (jb == null)) {
      d.add('نوع المحتوى تغيّر');
    }
    return d;
  }

  static dynamic _json(HttpResponse? r) {
    if (r == null || (r.body?.isEmpty ?? true)) return null;
    return ApiShape.tryJson(r.bodyAsString);
  }

  /// path -> type, arrays collapsed to [] (first element).
  static Map<String, String> _fields(dynamic v, [String path = r'$', Map<String, String>? out, int depth = 0]) {
    out ??= {};
    if (depth > 8) return out;
    if (v is Map) {
      out[path] = 'object';
      v.forEach((k, val) => _fields(val, '$path.$k', out, depth + 1));
    } else if (v is List) {
      out[path] = 'array';
      if (v.isNotEmpty) _fields(v.first, '$path[]', out, depth + 1);
    } else {
      out[path] = JsonSchema._typeOf(v);
    }
    return out;
  }
}
