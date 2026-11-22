/*
 * proxypin_mod: API Lab — collections with folders, test runner with assertions,
 * JSONPath and JSON Schema tools, and session comparison.
 *
 * Licensed under the Apache License, Version 2.0.
 */
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_toastr/flutter_toastr.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/storage/api_collections.dart';
import 'package:proxypin/storage/histories.dart';
import 'package:proxypin/utils/api_formats.dart';
import 'package:proxypin/utils/json_tools.dart';

Widget _rtl(Widget child) => Directionality(textDirection: TextDirection.rtl, child: child);

/// Entry: "إضافة إلى مجموعة API" from a captured request.
Future<void> addToApiCollection(BuildContext context, HttpRequest request) async {
  final store = await ApiCollections.instance;
  if (!context.mounted) return;
  final newCtl = TextEditingController();
  var generate = true;
  int? selected = store.collections.isEmpty ? null : 0;

  final ok = await showDialog<bool>(
      context: context,
      builder: (context) => _rtl(StatefulBuilder(
          builder: (context, setState) => AlertDialog(
                title: const Text('إضافة إلى مجموعة API'),
                content: SingleChildScrollView(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    ...store.collections.asMap().entries.map((e) => RadioListTile<int>(
                          dense: true,
                          value: e.key,
                          groupValue: selected,
                          title: Text(e.value.name),
                          onChanged: (v) => setState(() => selected = v),
                        )),
                    TextField(
                      controller: newCtl,
                      decoration: const InputDecoration(labelText: 'أو مجموعة جديدة', isDense: true),
                      onChanged: (_) => setState(() => selected = null),
                    ),
                    CheckboxListTile(
                      dense: true,
                      value: generate,
                      onChanged: (v) => setState(() => generate = v ?? true),
                      title: const Text('توليد اختبارات تلقائياً من الاستجابة'),
                    ),
                  ]),
                ),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
                  TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('إضافة')),
                ],
              ))));
  if (ok != true) return;

  ApiCollection col;
  if (selected != null) {
    col = store.collections[selected!];
  } else {
    final name = newCtl.text.trim().isEmpty ? 'مجموعتي' : newCtl.text.trim();
    col = ApiCollection(name: name);
    store.collections.add(col);
  }
  col.items.add(SavedRequest.fromCaptured(request, generateTests: generate));
  await store.save();
  if (context.mounted) FlutterToastr.show('أُضيف إلى "${col.name}"', context);
}

class ApiLabPage extends StatefulWidget {
  const ApiLabPage({super.key});

  @override
  State<ApiLabPage> createState() => _ApiLabPageState();
}

class _ApiLabPageState extends State<ApiLabPage> {
  ApiCollections? store;

  @override
  void initState() {
    super.initState();
    ApiCollections.instance.then((s) => setState(() => store = s));
  }

  @override
  Widget build(BuildContext context) {
    return _rtl(DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('مختبر API'),
          bottom: const TabBar(tabs: [Tab(text: 'المجموعات'), Tab(text: 'JSONPath'), Tab(text: 'JSON Schema')]),
        ),
        body: TabBarView(children: [
          store == null ? const Center(child: CircularProgressIndicator()) : _collections(),
          const _JsonPathTool(),
          const _SchemaTool(),
        ]),
      ),
    ));
  }

  Widget _collections() {
    final s = store!;
    return Scaffold(
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          final name = await _ask(context, 'اسم المجموعة', '');
          if (name == null || name.trim().isEmpty) return;
          s.collections.add(ApiCollection(name: name.trim()));
          await s.save();
          setState(() {});
        },
        child: const Icon(Icons.add),
      ),
      body: s.collections.isEmpty
          ? const Padding(
              padding: EdgeInsets.all(24),
              child: Center(
                  child: Text('لا توجد مجموعات.\nاضغط مطولاً على أي طلب ← "إضافة إلى مجموعة API"، أو اضغط +',
                      textAlign: TextAlign.center)),
            )
          : ListView(
              children: s.collections.asMap().entries.map((e) {
              final c = e.value;
              return ListTile(
                leading: const Icon(Icons.folder_copy_outlined),
                title: Text(c.name),
                subtitle: Text('${c.items.length} طلب · ${c.folders.length} مجلد'),
                onTap: () => Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => _CollectionPage(store: s, collection: c)))
                    .then((_) => setState(() {})),
                trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      if (!await _confirm(context, 'حذف "${c.name}"؟')) return;
                      s.collections.removeAt(e.key);
                      await s.save();
                      setState(() {});
                    }),
              );
            }).toList()),
    );
  }
}

class _CollectionPage extends StatefulWidget {
  final ApiCollections store;
  final ApiCollection collection;

  const _CollectionPage({required this.store, required this.collection});

  @override
  State<_CollectionPage> createState() => _CollectionPageState();
}

class _CollectionPageState extends State<_CollectionPage> {
  @override
  Widget build(BuildContext context) {
    final c = widget.collection;
    return _rtl(Scaffold(
      appBar: AppBar(title: Text(c.name), actions: [
        IconButton(
            tooltip: 'تشغيل الكل',
            icon: const Icon(Icons.play_arrow),
            onPressed: c.items.isEmpty
                ? null
                : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => _RunnerPage(items: c.items)))),
        PopupMenuButton<String>(
          onSelected: (v) async {
            if (v == 'rename') {
              final name = await _ask(context, 'اسم المجموعة', c.name);
              if (name == null || name.trim().isEmpty) return;
              c.name = name.trim();
            } else if (v == 'postman') {
              final list = c.items.map((e) => e.toHttpRequest()).toList();
              final json = const JsonEncoder.withIndent(' ').convert(PostmanBuilder.build(list, name: c.name, redact: false));
              await Clipboard.setData(ClipboardData(text: json));
              if (context.mounted) FlutterToastr.show('نُسخت كمجموعة Postman', context);
            }
            await widget.store.save();
            setState(() {});
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'rename', child: Text('إعادة تسمية')),
            PopupMenuItem(value: 'postman', child: Text('نسخ كـ Postman Collection')),
          ],
        ),
      ]),
      body: c.items.isEmpty
          ? const Center(child: Text('المجموعة فارغة'))
          : ListView(
              children: c.folders.map((folder) {
              final items = c.items.where((e) => e.folder == folder).toList();
              return ExpansionTile(
                initiallyExpanded: true,
                leading: const Icon(Icons.folder_outlined),
                title: Text(folder.isEmpty ? 'بدون مجلد' : folder),
                trailing: IconButton(
                    tooltip: 'تشغيل المجلد',
                    icon: const Icon(Icons.play_circle_outline),
                    onPressed: () =>
                        Navigator.of(context).push(MaterialPageRoute(builder: (_) => _RunnerPage(items: items)))),
                children: items
                    .map((item) => ListTile(
                          dense: true,
                          title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text('${item.assertions.length} اختبار'),
                          onTap: () => Navigator.of(context)
                              .push(MaterialPageRoute(builder: (_) => _ItemPage(store: widget.store, item: item)))
                              .then((_) => setState(() {})),
                          trailing: IconButton(
                              icon: const Icon(Icons.delete_outline, size: 20),
                              onPressed: () async {
                                c.items.remove(item);
                                await widget.store.save();
                                setState(() {});
                              }),
                        ))
                    .toList(),
              );
            }).toList()),
    ));
  }
}

class _ItemPage extends StatefulWidget {
  final ApiCollections store;
  final SavedRequest item;

  const _ItemPage({required this.store, required this.item});

  @override
  State<_ItemPage> createState() => _ItemPageState();
}

class _ItemPageState extends State<_ItemPage> {
  RunResult? result;
  bool running = false;

  Future<void> run() async {
    setState(() => running = true);
    final r = await ApiCollections.run(widget.item);
    if (mounted) {
      setState(() {
        result = r;
        running = false;
      });
    }
  }

  Future<void> regenerate() async {
    setState(() => running = true);
    final r = await ApiCollections.run(widget.item);
    widget.item.assertions = SavedRequest.generateAssertions(r.response);
    await widget.store.save();
    if (mounted) {
      setState(() {
        result = null;
        running = false;
      });
      FlutterToastr.show('تم توليد ${widget.item.assertions.length} اختبار', context);
    }
  }

  Future<void> editAssertion([Assertion? a]) async {
    final res = await showDialog<Assertion>(context: context, builder: (_) => _AssertionDialog(assertion: a));
    if (res == null) return;
    if (a == null) {
      widget.item.assertions.add(res);
    } else {
      a
        ..type = res.type
        ..target = res.target
        ..op = res.op
        ..value = res.value;
    }
    await widget.store.save();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final results = {for (final r in result?.results ?? const <AssertionResult>[]) r.assertion: r};
    return _rtl(Scaffold(
      appBar: AppBar(title: Text(item.name, overflow: TextOverflow.ellipsis), actions: [
        IconButton(
            tooltip: 'تعديل الاسم والمجلد',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () async {
              final name = await _ask(context, 'الاسم', item.name);
              if (name == null) return;
              if (!context.mounted) return;
              final folder = await _ask(context, 'المجلد / التصنيف', item.folder);
              item.name = name.trim().isEmpty ? item.name : name.trim();
              if (folder != null) item.folder = folder.trim();
              await widget.store.save();
              setState(() {});
            }),
        IconButton(tooltip: 'توليد الاختبارات من جديد', icon: const Icon(Icons.auto_fix_high), onPressed: running ? null : regenerate),
      ]),
      floatingActionButton: FloatingActionButton.extended(
          onPressed: running ? null : run,
          icon: running
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.play_arrow),
          label: const Text('تشغيل')),
      body: ListView(padding: const EdgeInsets.only(bottom: 90), children: [
        ListTile(
          title: Text('${item.method}  ${item.url}', textDirection: TextDirection.ltr, style: const TextStyle(fontSize: 13)),
          subtitle: Text(item.folder.isEmpty ? 'بدون مجلد' : 'المجلد: ${item.folder}'),
        ),
        if (result != null)
          ListTile(
            tileColor: result!.passed ? Colors.green.withValues(alpha: 0.12) : Colors.red.withValues(alpha: 0.12),
            title: Text(result!.error != null
                ? 'فشل الطلب: ${result!.error}'
                : 'الحالة ${result!.response?.status.code} · ${result!.elapsedMs} ms · '
                    '${result!.results.where((r) => r.passed).length}/${result!.results.length} ناجح'),
            onTap: result!.response == null
                ? null
                : () => _showText(context, 'الاستجابة', result!.response!.bodyAsString),
          ),
        const Divider(),
        Row(children: [
          const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('الاختبارات (Assertions)')),
          const Spacer(),
          TextButton.icon(onPressed: () => editAssertion(), icon: const Icon(Icons.add), label: const Text('إضافة')),
        ]),
        ...item.assertions.map((a) {
          final r = results[a];
          return ListTile(
            dense: true,
            leading: Icon(
                r == null ? Icons.radio_button_unchecked : (r.passed ? Icons.check_circle : Icons.cancel),
                color: r == null ? null : (r.passed ? Colors.green : Colors.red)),
            title: Text(a.describe, textDirection: TextDirection.ltr),
            subtitle: r == null ? null : Text(r.message, maxLines: 4, overflow: TextOverflow.ellipsis),
            onTap: () => editAssertion(a),
            trailing: IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                onPressed: () async {
                  item.assertions.remove(a);
                  await widget.store.save();
                  setState(() {});
                }),
          );
        }),
      ]),
    ));
  }
}

class _AssertionDialog extends StatefulWidget {
  final Assertion? assertion;

  const _AssertionDialog({this.assertion});

  @override
  State<_AssertionDialog> createState() => _AssertionDialogState();
}

class _AssertionDialogState extends State<_AssertionDialog> {
  late AssertionType type = widget.assertion?.type ?? AssertionType.status;
  late String op = widget.assertion?.op ?? '==';
  late final targetCtl = TextEditingController(text: widget.assertion?.target ?? '');
  late final valueCtl = TextEditingController(text: widget.assertion?.value ?? '');

  bool get needsTarget => type == AssertionType.header || type == AssertionType.jsonPath;

  bool get needsOp => type != AssertionType.bodyContains && type != AssertionType.schema;

  @override
  Widget build(BuildContext context) {
    return _rtl(AlertDialog(
      title: const Text('اختبار'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          DropdownButtonFormField<AssertionType>(
            initialValue: type,
            decoration: const InputDecoration(labelText: 'النوع'),
            items: AssertionType.values.map((t) => DropdownMenuItem(value: t, child: Text(t.label))).toList(),
            onChanged: (v) => setState(() => type = v ?? type),
          ),
          if (needsTarget)
            TextField(
              controller: targetCtl,
              textDirection: TextDirection.ltr,
              decoration: InputDecoration(
                  labelText: type == AssertionType.header ? 'اسم الهيدر' : 'المسار',
                  hintText: type == AssertionType.header ? 'Content-Type' : r'$.data[0].id'),
            ),
          if (needsOp)
            DropdownButtonFormField<String>(
              initialValue: Assertion.ops.contains(op) ? op : '==',
              decoration: const InputDecoration(labelText: 'المقارنة'),
              items: Assertion.ops.map((o) => DropdownMenuItem(value: o, child: Text(o))).toList(),
              onChanged: (v) => setState(() => op = v ?? op),
            ),
          if (op != 'exists' || !needsOp)
            TextField(
              controller: valueCtl,
              textDirection: TextDirection.ltr,
              maxLines: type == AssertionType.schema ? 8 : 1,
              decoration: InputDecoration(
                  labelText: type == AssertionType.schema ? 'JSON Schema' : 'القيمة',
                  hintText: type == AssertionType.status ? '200' : null),
            ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        TextButton(
            onPressed: () {
              if (type == AssertionType.schema) {
                try {
                  jsonDecode(valueCtl.text);
                } catch (_) {
                  FlutterToastr.show('JSON Schema غير صالح', context);
                  return;
                }
              }
              Navigator.pop(
                  context,
                  Assertion(
                      type: type,
                      target: targetCtl.text.trim(),
                      op: needsOp ? op : '==',
                      value: type == AssertionType.schema ? valueCtl.text : valueCtl.text.trim()));
            },
            child: const Text('حفظ')),
      ],
    ));
  }
}

class _RunnerPage extends StatefulWidget {
  final List<SavedRequest> items;

  const _RunnerPage({required this.items});

  @override
  State<_RunnerPage> createState() => _RunnerPageState();
}

class _RunnerPageState extends State<_RunnerPage> {
  final results = <RunResult>[];
  bool done = false;
  bool cancelled = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    cancelled = true;
    super.dispose();
  }

  Future<void> _run() async {
    for (final item in widget.items) {
      if (cancelled) return;
      final r = await ApiCollections.run(item);
      if (!mounted) return;
      setState(() => results.add(r));
    }
    if (mounted) setState(() => done = true);
  }

  @override
  Widget build(BuildContext context) {
    final passed = results.where((r) => r.passed).length;
    final checks = results.fold<int>(0, (n, r) => n + r.results.length);
    final okChecks = results.fold<int>(0, (n, r) => n + r.results.where((a) => a.passed).length);
    return _rtl(Scaffold(
      appBar: AppBar(title: Text(done ? 'النتيجة: $passed/${results.length} طلب ناجح' : 'جاري التشغيل ${results.length}/${widget.items.length}')),
      body: Column(children: [
        if (!done) LinearProgressIndicator(value: widget.items.isEmpty ? null : results.length / widget.items.length),
        ListTile(title: Text('الاختبارات: $okChecks/$checks ناجح')),
        const Divider(height: 1),
        Expanded(
          child: ListView(
              children: results
                  .map((r) => ExpansionTile(
                        leading: Icon(r.passed ? Icons.check_circle : Icons.cancel, color: r.passed ? Colors.green : Colors.red),
                        title: Text(r.item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(r.error ?? 'الحالة ${r.response?.status.code} · ${r.elapsedMs} ms'),
                        children: r.results
                            .map((a) => ListTile(
                                  dense: true,
                                  leading: Icon(a.passed ? Icons.check : Icons.close,
                                      size: 18, color: a.passed ? Colors.green : Colors.red),
                                  title: Text(a.assertion.describe, textDirection: TextDirection.ltr),
                                  subtitle: Text(a.message, maxLines: 4, overflow: TextOverflow.ellipsis),
                                ))
                            .toList(),
                      ))
                  .toList()),
        ),
      ]),
    ));
  }
}

class _JsonPathTool extends StatefulWidget {
  const _JsonPathTool();

  @override
  State<_JsonPathTool> createState() => _JsonPathToolState();
}

class _JsonPathToolState extends State<_JsonPathTool> {
  final jsonCtl = TextEditingController();
  final pathCtl = TextEditingController(text: r'$..id');
  String out = '';

  void run() {
    try {
      final data = jsonDecode(jsonCtl.text);
      final res = JsonPath.query(data, pathCtl.text);
      setState(() => out = '${res.length} نتيجة\n${const JsonEncoder.withIndent(' ').convert(res)}');
    } catch (e) {
      setState(() => out = 'خطأ: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.all(12), children: [
      TextField(
          controller: pathCtl,
          textDirection: TextDirection.ltr,
          decoration: InputDecoration(
              labelText: 'JSONPath',
              hintText: r"$.data[*].name  |  $..id  |  $.items[?(@.price>10)]",
              suffixIcon: IconButton(icon: const Icon(Icons.play_arrow), onPressed: run)),
          onSubmitted: (_) => run()),
      const SizedBox(height: 8),
      TextField(
          controller: jsonCtl,
          textDirection: TextDirection.ltr,
          maxLines: 10,
          decoration: const InputDecoration(labelText: 'JSON (الصق الاستجابة هنا)', border: OutlineInputBorder())),
      const SizedBox(height: 8),
      SelectableText(out, textDirection: TextDirection.ltr, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
    ]);
  }
}

class _SchemaTool extends StatefulWidget {
  const _SchemaTool();

  @override
  State<_SchemaTool> createState() => _SchemaToolState();
}

class _SchemaToolState extends State<_SchemaTool> {
  final jsonCtl = TextEditingController();
  final schemaCtl = TextEditingController();
  String out = '';

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.all(12), children: [
      TextField(
          controller: jsonCtl,
          textDirection: TextDirection.ltr,
          maxLines: 8,
          decoration: const InputDecoration(labelText: 'JSON', border: OutlineInputBorder())),
      const SizedBox(height: 8),
      TextField(
          controller: schemaCtl,
          textDirection: TextDirection.ltr,
          maxLines: 8,
          decoration: const InputDecoration(labelText: 'JSON Schema', border: OutlineInputBorder())),
      Row(children: [
        TextButton(
            onPressed: () {
              try {
                schemaCtl.text =
                    const JsonEncoder.withIndent(' ').convert(ApiShape.schemaOf(jsonDecode(jsonCtl.text)));
              } catch (e) {
                setState(() => out = 'خطأ: $e');
              }
            },
            child: const Text('توليد Schema من JSON')),
        const Spacer(),
        FilledButton(
            onPressed: () {
              try {
                final errors = JsonSchema.validate(jsonDecode(jsonCtl.text), jsonDecode(schemaCtl.text));
                setState(() => out = errors.isEmpty ? '✅ مطابق' : '❌ ${errors.length} خطأ\n${errors.join('\n')}');
              } catch (e) {
                setState(() => out = 'خطأ: $e');
              }
            },
            child: const Text('تحقق')),
      ]),
      SelectableText(out, textDirection: TextDirection.ltr),
    ]);
  }
}

/// Compare two captured sessions.
class SessionDiffPage extends StatelessWidget {
  final String nameA, nameB;
  final List<HttpRequest> a, b;

  const SessionDiffPage({super.key, required this.nameA, required this.nameB, required this.a, required this.b});

  @override
  Widget build(BuildContext context) {
    final diff = SessionDiff.compare(a, b);
    int n(DiffKind k) => diff.where((e) => e.kind == k).length;
    const labels = {
      DiffKind.added: ('جديد', Colors.green, Icons.add_circle_outline),
      DiffKind.removed: ('محذوف', Colors.red, Icons.remove_circle_outline),
      DiffKind.changed: ('متغيّر', Colors.orange, Icons.change_circle_outlined),
      DiffKind.same: ('بدون تغيير', Colors.grey, Icons.check_circle_outline),
    };
    return _rtl(Scaffold(
      appBar: AppBar(title: const Text('مقارنة الجلسات')),
      body: ListView(children: [
        ListTile(
          title: Text('أ: $nameA\nب: $nameB'),
          subtitle: Text('جديد ${n(DiffKind.added)} · محذوف ${n(DiffKind.removed)} · '
              'متغيّر ${n(DiffKind.changed)} · بدون تغيير ${n(DiffKind.same)}'),
        ),
        const Divider(),
        ...diff.map((e) {
          final l = labels[e.kind]!;
          return ListTile(
            dense: true,
            leading: Icon(l.$3, color: l.$2),
            title: Text(e.endpoint, textDirection: TextDirection.ltr, style: const TextStyle(fontSize: 13)),
            subtitle: Text([l.$1, ...e.details].join('\n')),
          );
        }),
      ]),
    ));
  }
}

Future<String?> _ask(BuildContext context, String title, String initial) {
  final ctl = TextEditingController(text: initial);
  return showDialog<String>(
      context: context,
      builder: (context) => _rtl(AlertDialog(
            title: Text(title),
            content: TextField(controller: ctl, autofocus: true),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
              TextButton(onPressed: () => Navigator.pop(context, ctl.text), child: const Text('حفظ')),
            ],
          )));
}

Future<bool> _confirm(BuildContext context, String text) async {
  final ok = await showDialog<bool>(
      context: context,
      builder: (context) => _rtl(AlertDialog(content: Text(text), actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('حذف')),
          ])));
  return ok == true;
}

Future<void> _showText(BuildContext context, String title, String text) {
  return showDialog(
      context: context,
      builder: (context) => _rtl(AlertDialog(
            title: Text(title),
            content: SingleChildScrollView(child: SelectableText(text, textDirection: TextDirection.ltr)),
            actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('إغلاق'))],
          )));
}

/// Pick another saved session and compare it with [a].
Future<void> compareSessionWith(BuildContext context, HistoryStorage storage, HistoryItem a) async {
  final others = storage.histories.where((h) => h != a).toList();
  if (others.isEmpty) {
    FlutterToastr.show('لا توجد جلسة أخرى للمقارنة', context);
    return;
  }
  final b = await showDialog<HistoryItem>(
      context: context,
      builder: (context) => _rtl(SimpleDialog(
            title: Text('قارن "${a.name}" مع:'),
            children: others
                .map((h) => SimpleDialogOption(
                    onPressed: () => Navigator.pop(context, h), child: Text('${h.name}  (${h.requestLength})')))
                .toList(),
          )));
  if (b == null) return;
  final ra = await storage.getRequests(a);
  final rb = await storage.getRequests(b);
  if (!context.mounted) return;
  Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => SessionDiffPage(nameA: a.name, nameB: b.name, a: ra, b: rb)));
}
