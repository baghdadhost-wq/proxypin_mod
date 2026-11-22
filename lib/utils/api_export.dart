/*
 * Filtered export (proxypin_mod): small JSON files instead of a full HAR.
 * Filters: API, JSON, login/token, video/DRM, errors, all of domain.
 * Drops images, media segments, fonts, css/js, duplicates, binary and oversized bodies.
 *
 * Licensed under the Apache License, Version 2.0.
 */
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_toastr/flutter_toastr.dart';
import 'package:file_picker/file_picker.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/utils/api_formats.dart';
import 'package:proxypin/utils/har.dart';
import 'package:proxypin/utils/redact.dart';
import 'package:proxypin/utils/platform.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ExportFilter {
  api('API فقط', 'طلبات الواجهة البرمجية بدون صور أو فيديو أو ملفات ثابتة'),
  json('JSON فقط', 'الطلبات التي ردّها JSON'),
  auth('الدخول والتوكن', 'login / token / auth / sso / oauth'),
  media('الفيديو و DRM', 'ملفات mpd و m3u8 وطلبات الترخيص والمشغّل، بدون المقاطع'),
  errors('الأخطاء فقط', 'الحالة 400 فما فوق أو بدون رد'),
  all('كل طلبات النطاق', 'كل شيء للنطاق مع تصغير المحتوى');

  final String label;
  final String hint;

  const ExportFilter(this.label, this.hint);
}

enum ExportFormat {
  compact('JSON مختصر', 'json'),
  openapi('OpenAPI 3 (توثيق)', 'openapi.json'),
  postman('Postman Collection', 'postman_collection.json'),
  har('HAR مُفلتر', 'har');

  final String label;
  final String ext;

  const ExportFormat(this.label, this.ext);
}

class ApiExport {
  static const String prefsDomains = 'apiExportDomains';
  static const String prefsFilter = 'apiExportFilter';
  static const String prefsKeyword = 'apiExportKeyword';
  static const String prefsFormat = 'apiExportFormat';
  static const String prefsRedact = 'apiExportRedact';
  static const String defaultDomains = 'almanasa.tv';

  /// Max characters kept from any single body.
  static int maxBodyChars = 64 * 1024;

  static const _staticExt = [
    '.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg', '.ico', '.bmp', '.avif',
    '.css', '.js', '.map', '.woff', '.woff2', '.ttf', '.otf', '.eot', '.html', '.htm',
  ];

  static const _segmentExt = [
    '.mp4', '.m4s', '.m4v', '.m4a', '.ts', '.aac', '.mp3', '.webm', '.vtt', '.srt', '.cmfv', '.cmfa', '.init',
  ];

  static const _staticType = ['image/', 'video/', 'audio/', 'font/', 'text/css', 'javascript', 'text/html'];

  static final _authRe = RegExp(r'(login|logout|token|auth|oauth|openid|sso|session|signin|sign-in|refresh|otp|verify)',
      caseSensitive: false);
  static final _mediaRe =
      RegExp(r'(\.mpd|\.m3u8|license|widevine|playready|fairplay|drm|player|stream|manifest|playback|video)',
          caseSensitive: false);

  /// Headers kept from responses (requests keep all headers).
  static const _keepResHeaders = ['content-type', 'location', 'set-cookie', 'www-authenticate'];

  static Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  static List<String> parseDomains(String value) => value
      .split(RegExp(r'[,\s،]+'))
      .map((e) => e.trim().toLowerCase())
      .where((e) => e.isNotEmpty)
      .toList();

  static bool _hostMatches(String host, List<String> domains) {
    if (domains.isEmpty) return true;
    host = host.toLowerCase();
    return domains.any((d) => host == d || host.endsWith('.$d'));
  }

  static bool matches(HttpRequest r, List<String> domains, ExportFilter filter, String keyword) {
    final uri = r.requestUri;
    final host = uri?.host ?? r.hostAndPort?.host ?? '';
    if (!_hostMatches(host, domains)) return false;

    final method = r.method.name.toUpperCase();
    if (method == 'CONNECT') return false;

    final url = r.requestUrl;
    if (keyword.isNotEmpty && !url.toLowerCase().contains(keyword.toLowerCase())) return false;

    final path = (uri?.path ?? '').toLowerCase();
    final resType = (r.response?.headers.contentType ?? '').toLowerCase();
    final isStatic = _staticExt.any(path.endsWith);
    final isSegment = _segmentExt.any(path.endsWith);

    switch (filter) {
      case ExportFilter.api:
        if (method == 'OPTIONS' || isStatic || isSegment) return false;
        return !_staticType.any(resType.contains);
      case ExportFilter.json:
        return method != 'OPTIONS' && resType.contains('json');
      case ExportFilter.auth:
        return method != 'OPTIONS' && !isStatic && _authRe.hasMatch(url);
      case ExportFilter.media:
        return method != 'OPTIONS' && !isSegment && !isStatic && _mediaRe.hasMatch(url);
      case ExportFilter.errors:
        final code = r.response?.status.code;
        return method != 'OPTIONS' && (code == null || code >= 400);
      case ExportFilter.all:
        return true;
    }
  }

  static String _text(HttpMessage? message) {
    if (message == null) return '';
    final body = message.body;
    if (body == null || body.isEmpty) return '';
    final type = message.headers.contentType.toLowerCase();
    final textual = type.isEmpty ||
        type.contains('json') ||
        type.contains('text') ||
        type.contains('xml') ||
        type.contains('x-www-form-urlencoded') ||
        type.contains('dash') ||
        type.contains('mpegurl') ||
        type.contains('graphql');
    if (!textual) return '<binary ${body.length} bytes>';
    var s = message.bodyAsString;
    if (s.length > maxBodyChars) {
      s = '${s.substring(0, maxBodyChars)}...<truncated, total ${s.length} chars>';
    }
    return s;
  }

  static dynamic _maybeJson(String s) {
    final t = s.trimLeft();
    if (t.startsWith('{') || t.startsWith('[')) {
      try {
        return jsonDecode(s);
      } catch (_) {}
    }
    return s;
  }

  static Map<String, String> _headers(HttpMessage? message, {List<String>? only}) {
    final out = <String, String>{};
    message?.headers.forEach((name, values) {
      if (only != null && !only.contains(name.toLowerCase())) return;
      out[name] = values.join(', ');
    });
    return out;
  }

  /// Replace ids in a path with {id} so endpoints can be grouped.
  static String _template(String path) => path.split('/').map((seg) {
        if (seg.isEmpty) return seg;
        if (RegExp(r'^\d+$').hasMatch(seg)) return '{id}';
        if (RegExp(r'^[0-9a-fA-F-]{16,}$').hasMatch(seg)) return '{id}';
        return seg;
      }).join('/');

  static Map<String, dynamic> build(List<HttpRequest> all, List<String> domains,
      {ExportFilter filter = ExportFilter.api, String keyword = '', bool redact = false}) {
    final list = select(all, domains, filter, keyword);

    final seen = <String, Map<String, dynamic>>{};
    final calls = <Map<String, dynamic>>[];
    final endpoints = <String, Map<String, dynamic>>{};

    for (final r in list) {
      final reqBody = _text(r);
      final key = '${r.method.name} ${r.requestUrl} $reqBody';
      final previous = seen[key];
      if (previous != null) {
        previous['repeated'] = ((previous['repeated'] as int?) ?? 1) + 1;
        continue;
      }

      final uri = r.requestUri;
      final resBody = _text(r.response);
      final call = <String, dynamic>{
        'time': r.requestTime.toIso8601String(),
        'method': r.method.name,
        'url': redact ? Redactor.url(r.requestUrl) : r.requestUrl,
        'requestHeaders': redact ? Redactor.headerMap(_headers(r)) : _headers(r),
        if (reqBody.isNotEmpty)
          'requestBody': _maybeJson(redact ? Redactor.body(reqBody, contentType: r.headers.contentType) : reqBody),
        'status': r.response?.status.code,
        'responseHeaders': redact
            ? Redactor.headerMap(_headers(r.response, only: _keepResHeaders))
            : _headers(r.response, only: _keepResHeaders),
        'responseBody':
            _maybeJson(redact ? Redactor.body(resBody, contentType: r.response?.headers.contentType ?? '') : resBody),
      };
      seen[key] = call;
      calls.add(call);

      final ep = '${r.method.name} ${uri?.host ?? ''}${_template(uri?.path ?? '')}';
      final e = endpoints.putIfAbsent(
          ep, () => <String, dynamic>{'endpoint': ep, 'count': 0, 'statuses': <int>{}, 'query': <String>{}});
      e['count'] = (e['count'] as int) + 1;
      final code = r.response?.status.code;
      if (code != null) (e['statuses'] as Set<int>).add(code);
      (e['query'] as Set<String>).addAll(uri?.queryParameters.keys ?? const <String>[]);
    }

    final endpointList = endpoints.values.map((e) {
      final statuses = (e['statuses'] as Set<int>).toList();
      statuses.sort();
      final query = (e['query'] as Set<String>).toList();
      query.sort();
      return <String, dynamic>{'endpoint': e['endpoint'], 'count': e['count'], 'statuses': statuses, 'queryParams': query};
    }).toList();
    endpointList.sort((a, b) => (a['endpoint'] as String).compareTo(b['endpoint'] as String));

    return {
      'tool': 'proxypin_mod filtered export',
      'filter': filter.name,
      'keyword': keyword,
      'redacted': redact,
      'domains': domains,
      'exportedAt': DateTime.now().toIso8601String(),
      'totalCaptured': all.length,
      'exportedCalls': calls.length,
      'endpoints': endpointList,
      'calls': calls,
    };
  }

  static List<HttpRequest> select(List<HttpRequest> all, List<String> domains, ExportFilter filter, String keyword) =>
      all.where((r) => matches(r, domains, filter, keyword)).toList()
        ..sort((a, b) => a.requestTime.compareTo(b.requestTime));

  /// Builds the file content; returns (content, count).
  static (String, int) render(List<HttpRequest> all, List<String> domains,
      {required ExportFilter filter, required ExportFormat format, String keyword = '', bool redact = true, String name = 'proxypin_mod'}) {
    const encoder = JsonEncoder.withIndent(' ');
    switch (format) {
      case ExportFormat.compact:
        final data = build(all, domains, filter: filter, keyword: keyword, redact: redact);
        return (encoder.convert(data), data['exportedCalls'] as int);
      case ExportFormat.openapi:
        final list = select(all, domains, filter, keyword);
        return (encoder.convert(OpenApiBuilder.build(list, title: name, redact: redact)), list.length);
      case ExportFormat.postman:
        final list = select(all, domains, filter, keyword);
        return (encoder.convert(PostmanBuilder.build(list, name: name, redact: redact)), list.length);
      case ExportFormat.har:
        final list = select(all, domains, filter, keyword);
        final entries = list.map((r) {
          final e = Har.toHar(r);
          return redact ? Redactor.harEntry(e) : e;
        }).toList();
        final har = {
          'log': {
            'version': '1.2',
            'creator': {'name': 'proxypin_mod', 'version': '1'},
            'pages': [
              {'title': name, 'id': 'ProxyPin', 'startedDateTime': list.firstOrNull?.requestTime.toUtc().toIso8601String()}
            ],
            'entries': entries,
          }
        };
        return (jsonEncode(har), list.length);
    }
  }

  /// Asks for filter + domains + keyword (remembered), then saves/shares the file.
  static Future<void> showDialogAndExport(BuildContext ctx, List<HttpRequest> requests, String name,
      {VoidCallback? onSuccess}) async {
    final prefs = await _prefs;
    final domainCtl = TextEditingController(text: prefs.getString(prefsDomains) ?? defaultDomains);
    final keywordCtl = TextEditingController(text: prefs.getString(prefsKeyword) ?? '');
    var filter = ExportFilter.values.firstWhere((f) => f.name == prefs.getString(prefsFilter),
        orElse: () => ExportFilter.api);
    var format = ExportFormat.values.firstWhere((f) => f.name == prefs.getString(prefsFormat),
        orElse: () => ExportFormat.compact);
    var redact = prefs.getBool(prefsRedact) ?? true;
    if (!ctx.mounted) return;

    final ok = await showDialog<bool>(
        context: ctx,
        builder: (context) => Directionality(
              textDirection: TextDirection.rtl,
              child: StatefulBuilder(
                  builder: (context, setState) => AlertDialog(
                        title: const Text('تصدير مُفلتر'),
                        content: SingleChildScrollView(
                          child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SwitchListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  value: redact,
                                  onChanged: (v) => setState(() => redact = v),
                                  title: const Text('إخفاء البيانات الحساسة',
                                      style: TextStyle(fontWeight: FontWeight.bold)),
                                  subtitle: const Text('التوكن، كلمات المرور، الكوكيز، الإيميل، رقم الهاتف، معرف المستخدم',
                                      style: TextStyle(fontSize: 11)),
                                ),
                                Row(children: [
                                  const Text('الصيغة: ', style: TextStyle(fontSize: 13)),
                                  Expanded(
                                    child: DropdownButton<ExportFormat>(
                                      isExpanded: true,
                                      value: format,
                                      items: ExportFormat.values
                                          .map((f) => DropdownMenuItem(value: f, child: Text(f.label)))
                                          .toList(),
                                      onChanged: (v) => setState(() => format = v ?? format),
                                    ),
                                  ),
                                ]),
                                const Divider(),
                                const Text('الفلتر', style: TextStyle(fontSize: 13)),
                                ...ExportFilter.values.map((f) => RadioListTile<ExportFilter>(
                                      dense: true,
                                      contentPadding: EdgeInsets.zero,
                                      value: f,
                                      groupValue: filter,
                                      title: Text(f.label),
                                      subtitle: Text(f.hint, style: const TextStyle(fontSize: 11)),
                                      onChanged: (v) => setState(() => filter = v ?? filter),
                                    )),
                                const Divider(),
                                const Text('النطاقات (افصل بفاصلة، فارغ = الكل)', style: TextStyle(fontSize: 12)),
                                TextField(
                                    controller: domainCtl,
                                    textDirection: TextDirection.ltr,
                                    decoration: const InputDecoration(isDense: true, hintText: 'almanasa.tv')),
                                const SizedBox(height: 8),
                                const Text('كلمة في الرابط (اختياري)', style: TextStyle(fontSize: 12)),
                                TextField(
                                    controller: keywordCtl,
                                    textDirection: TextDirection.ltr,
                                    decoration: const InputDecoration(isDense: true, hintText: '/api/')),
                              ]),
                        ),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
                          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('تصدير')),
                        ],
                      )),
            ));
    if (ok != true) return;

    await prefs.setString(prefsDomains, domainCtl.text.trim());
    await prefs.setString(prefsKeyword, keywordCtl.text.trim());
    await prefs.setString(prefsFilter, filter.name);
    await prefs.setString(prefsFormat, format.name);
    await prefs.setBool(prefsRedact, redact);

    final (json, count) = render(requests, parseDomains(domainCtl.text),
        filter: filter, format: format, keyword: keywordCtl.text.trim(), redact: redact, name: name);
    if (count == 0) {
      if (ctx.mounted) FlutterToastr.show('لا توجد طلبات تطابق الفلتر', ctx);
      return;
    }

    final fileName =
        '${name.replaceAll(RegExp(r'[\s:/]'), '_')}_${filter.name}${redact ? '_safe' : ''}.${format.ext}';
    final bytes = utf8.encode(json);
    try {
      if (Platforms.isDesktop() || Platform.isAndroid) {
        await FilePicker.saveFile(fileName: fileName, bytes: bytes);
      } else {
        RenderBox? box;
        if (await Platforms.isIpad() && ctx.mounted) box = ctx.findRenderObject() as RenderBox?;
        await SharePlus.instance.share(ShareParams(
            sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
            fileNameOverrides: [fileName],
            files: [XFile.fromData(bytes, name: fileName, mimeType: 'application/json')]));
      }
      onSuccess?.call();
      if (ctx.mounted) {
        FlutterToastr.show('تم: $count طلب (${(bytes.length / 1024).toStringAsFixed(0)} KB)', ctx);
      }
    } catch (e) {
      if (ctx.mounted) FlutterToastr.show('فشل التصدير: $e', ctx);
    }
  }
}
