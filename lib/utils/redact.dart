/*
 * proxypin_mod: hide sensitive data before exporting.
 * Works on plain maps/lists (our JSON export, HAR, Postman, OpenAPI) and on raw strings.
 *
 * Licensed under the Apache License, Version 2.0.
 */
import 'dart:convert';

class Redactor {
  static const String mask = '<hidden>';

  /// Header names that are always hidden.
  static const _headerNames = {
    'authorization',
    'proxy-authorization',
    'cookie',
    'set-cookie',
    'x-api-key',
    'api-key',
    'apikey',
    'x-auth-token',
    'x-access-token',
    'x-csrf-token',
    'x-xsrf-token',
    'x-amz-security-token',
  };

  /// Key names (headers, query, json, form) that look sensitive.
  static final RegExp _keyRe = RegExp(
      r'(pass(word|wd)?|pwd|secret|token|^auth$|^auth[-_]|authorization|session|sessid|cookie|api[-_]?key|apikey|private[-_]?key|credential|otp|'
      r'code_verifier|client_secret|signature|^sig$|^sign$|phone|mobile|msisdn|email|card[-_]?(no|number)|cvv|iban|ssn|user[-_]?id|username|^user$|^login$|device[-_]?id)',
      caseSensitive: false);

  /// Values that look sensitive whatever their key is.
  static final RegExp _jwtRe = RegExp(r'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}');
  static final RegExp _bearerRe = RegExp(r'(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{8,}', caseSensitive: false);
  static final RegExp _emailRe = RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}');

  static bool isSensitiveKey(String key) => _headerNames.contains(key.toLowerCase()) || _keyRe.hasMatch(key);

  /// Hide tokens/emails that appear anywhere inside a string.
  static String scrubText(String s) {
    if (s.isEmpty) return s;
    return s
        .replaceAll(_jwtRe, mask)
        .replaceAllMapped(_bearerRe, (m) => '${m.group(1)} $mask')
        .replaceAll(_emailRe, mask);
  }

  /// Hide sensitive query parameters in a URL.
  static String url(String url) {
    final q = url.indexOf('?');
    if (q < 0) return scrubText(url);
    final base = url.substring(0, q);
    final query = url.substring(q + 1);
    return '${scrubText(base)}?${_form(query)}';
  }

  /// a=1&password=2  ->  a=1&password=<hidden>
  static String _form(String query) {
    return query.split('&').map((pair) {
      final i = pair.indexOf('=');
      if (i <= 0) return pair;
      final key = Uri.decodeQueryComponent(pair.substring(0, i));
      if (isSensitiveKey(key)) return '${pair.substring(0, i)}=$mask';
      return '${pair.substring(0, i)}=${scrubText(pair.substring(i + 1))}';
    }).join('&');
  }

  /// A body given as text: JSON, form or anything else.
  static String body(String text, {String contentType = ''}) {
    if (text.isEmpty || text.startsWith('<binary')) return text;
    final t = text.trimLeft();
    if (t.startsWith('{') || t.startsWith('[')) {
      try {
        return jsonEncode(value(jsonDecode(text)));
      } catch (_) {}
    }
    if (contentType.contains('x-www-form-urlencoded') ||
        RegExp(r'^[^=&\s]+=[^&]*(&[^=&\s]+=[^&]*)*$').hasMatch(t)) {
      return _form(text);
    }
    return scrubText(text);
  }

  /// Any decoded JSON value.
  static dynamic value(dynamic v, {String? key}) {
    if (key != null && isSensitiveKey(key) && (v is String || v is num)) return mask;
    if (v is Map) {
      return v.map((k, val) => MapEntry(k, value(val, key: k.toString())));
    }
    if (v is List) return v.map((e) => value(e)).toList();
    if (v is String) {
      final t = v.trimLeft();
      if (t.startsWith('{') || t.startsWith('[')) return body(v);
      return scrubText(v);
    }
    return v;
  }

  /// Header map {name: value}.
  static Map<String, String> headerMap(Map<String, String> headers) =>
      headers.map((k, v) => MapEntry(k, isSensitiveKey(k) ? mask : scrubText(v)));

  /// HAR style header list [{name, value}].
  static List harHeaders(List? headers) => (headers ?? const [])
      .map((h) => h is Map
          ? {...h, 'value': isSensitiveKey('${h['name']}') ? mask : scrubText('${h['value'] ?? ''}')}
          : h)
      .toList();

  /// One HAR entry (request + response).
  static Map harEntry(Map entry) {
    final e = Map<String, dynamic>.from(entry);
    final req = e['request'];
    if (req is Map) {
      final r = Map<String, dynamic>.from(req);
      r['url'] = url('${r['url'] ?? ''}');
      r['headers'] = harHeaders(r['headers'] as List?);
      r['cookies'] = [];
      r['queryString'] = harHeaders(r['queryString'] as List?);
      final post = r['postData'];
      if (post is Map && post['text'] != null) {
        r['postData'] = {...post, 'text': body('${post['text']}', contentType: '${post['mimeType'] ?? ''}')};
      }
      e['request'] = r;
    }
    final res = e['response'];
    if (res is Map) {
      final r = Map<String, dynamic>.from(res);
      r['headers'] = harHeaders(r['headers'] as List?);
      r['cookies'] = [];
      final content = r['content'];
      if (content is Map && content['text'] != null) {
        r['content'] = {...content, 'text': body('${content['text']}', contentType: '${content['mimeType'] ?? ''}')};
      }
      e['response'] = r;
    }
    return e;
  }
}
