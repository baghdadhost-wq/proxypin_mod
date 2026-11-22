/*
 * proxypin_mod: UI for advanced capture filters (sets, rules, exceptions, presets, tester).
 *
 * Licensed under the Apache License, Version 2.0.
 */
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_toastr/flutter_toastr.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/components/advanced_filter.dart';
import 'package:proxypin/network/components/host_filter.dart';

class AdvancedFilterPage extends StatefulWidget {
  final Configuration configuration;

  const AdvancedFilterPage({super.key, required this.configuration});

  @override
  State<AdvancedFilterPage> createState() => _AdvancedFilterPageState();
}

class _AdvancedFilterPageState extends State<AdvancedFilterPage> {
  final testCtl = TextEditingController(text: 'tv.almanasa.tv:443');
  String testResult = '';

  Future<void> save() async {
    await widget.configuration.flushConfig();
    if (mounted) setState(() {});
  }

  static List<FilterSet> presets() => [
        FilterSet(name: 'المنصة فقط', enabled: false, rules: [
          FilterRule(type: FilterRuleType.domain, value: 'almanasa.tv', action: FilterAction.include),
        ]),
        FilterSet(name: 'تجاهل خدمات النظام', enabled: false, rules: [
          FilterRule(
              type: FilterRuleType.domain,
              value: '*.apple.com, *.icloud.com, *.mzstatic.com, *.googleapis.com, *.gstatic.com, *.crashlytics.com',
              action: FilterAction.exclude),
        ]),
        FilterSet(name: 'بدون عناوين IP المحلية', enabled: false, rules: [
          FilterRule(
              type: FilterRuleType.ip,
              value: '10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 127.0.0.0/8, fc00::/7',
              action: FilterAction.exclude),
        ]),
        FilterSet(name: 'HTTPS فقط', enabled: false, rules: [
          FilterRule(type: FilterRuleType.protocol, value: 'https', action: FilterAction.include),
        ]),
        FilterSet(name: 'WebSocket فقط', enabled: false, rules: [
          FilterRule(type: FilterRuleType.protocol, value: 'ws', action: FilterAction.include),
        ]),
      ];

  void test() {
    final text = testCtl.text.trim();
    if (text.isEmpty) return;
    var uri = Uri.tryParse(text.contains('://') ? text : 'https://$text');
    final host = uri?.host ?? text;
    final secure = uri?.scheme != 'http';
    final port = uri?.hasPort == true ? uri!.port : (secure ? 443 : 80);
    final adv = AdvancedFilter.decide(FilterTarget(host, port: port, secure: secure, websocket: false));
    final filtered = HostFilter.filter(host, port: port, secure: secure, websocket: false);
    setState(() {
      testResult = '${filtered ? '⛔ لن يُلتقط' : '✅ سيُلتقط'}  '
          '(${adv == null ? 'حسب القائمة البيضاء/السوداء' : 'حسب الفلاتر المتقدمة'})';
    });
  }

  Future<void> exportSets() async {
    await Clipboard.setData(ClipboardData(text: const JsonEncoder.withIndent(' ').convert(AdvancedFilter.toJson())));
    if (mounted) FlutterToastr.show('تم نسخ الفلاتر إلى الحافظة', context);
  }

  Future<void> importSets() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    try {
      final json = jsonDecode(data?.text ?? '');
      final list = json is Map ? json['sets'] : json;
      final sets = (list as List).whereType<Map>().map(FilterSet.fromJson).toList();
      AdvancedFilter.sets.addAll(sets);
      await save();
      if (mounted) FlutterToastr.show('تم استيراد ${sets.length} مجموعة', context);
    } catch (e) {
      if (mounted) FlutterToastr.show('النص في الحافظة ليس فلاتر صالحة', context);
    }
  }

  Future<void> addSet() async {
    final name = await _askText(context, 'اسم المجموعة', '');
    if (name == null || name.trim().isEmpty) return;
    AdvancedFilter.sets.add(FilterSet(name: name.trim()));
    await save();
    if (mounted) openSet(AdvancedFilter.sets.last);
  }

  Future<void> addPreset() async {
    final picked = await showDialog<FilterSet>(
        context: context,
        builder: (context) => SimpleDialog(
              title: const Text('مجموعات جاهزة'),
              children: presets()
                  .map((p) => SimpleDialogOption(onPressed: () => Navigator.pop(context, p), child: Text(p.name)))
                  .toList(),
            ));
    if (picked == null) return;
    picked.enabled = true;
    AdvancedFilter.sets.add(picked);
    AdvancedFilter.enabled = true;
    await save();
  }

  void openSet(FilterSet set) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => _FilterSetPage(set: set, onChanged: save)))
        .then((_) => setState(() {}));
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('الفلاتر المتقدمة'), actions: [
          IconButton(tooltip: 'مجموعات جاهزة', icon: const Icon(Icons.auto_awesome_outlined), onPressed: addPreset),
          PopupMenuButton<String>(
            onSelected: (v) => v == 'export' ? exportSets() : importSets(),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'export', child: Text('نسخ كل الفلاتر (تصدير)')),
              PopupMenuItem(value: 'import', child: Text('لصق فلاتر من الحافظة (استيراد)')),
            ],
          ),
        ]),
        floatingActionButton: FloatingActionButton(onPressed: addSet, child: const Icon(Icons.add)),
        body: ListView(padding: const EdgeInsets.only(bottom: 80), children: [
          SwitchListTile(
            title: const Text('تفعيل الفلاتر المتقدمة'),
            subtitle: const Text('الاستثناء ← الاستبعاد ← الحصر، ثم القائمة البيضاء/السوداء'),
            value: AdvancedFilter.enabled,
            onChanged: (v) {
              AdvancedFilter.enabled = v;
              save();
            },
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'فلتر IP يعمل فقط عندما يتصل التطبيق بعنوان IP مباشرة. '
              'الفلترة حسب التطبيق غير متاحة على iOS لأن النظام لا يخبر الـ VPN بالتطبيق المرسل.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          const Divider(),
          if (AdvancedFilter.sets.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: Text('لا توجد مجموعات. اضغط + أو ✨ للمجموعات الجاهزة')),
            ),
          ...AdvancedFilter.sets.asMap().entries.map((e) {
            final set = e.value;
            final active = set.rules.where((r) => r.enabled).length;
            return ListTile(
              leading: Switch(
                  value: set.enabled,
                  onChanged: (v) {
                    set.enabled = v;
                    save();
                  }),
              title: Text(set.name),
              subtitle: Text('$active / ${set.rules.length} قاعدة مفعّلة'),
              onTap: () => openSet(set),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  final ok = await _confirm(context, 'حذف مجموعة "${set.name}"؟');
                  if (ok) {
                    AdvancedFilter.sets.removeAt(e.key);
                    save();
                  }
                },
              ),
            );
          }),
          const Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: testCtl,
                  textDirection: TextDirection.ltr,
                  decoration: const InputDecoration(labelText: 'جرّب: host:port أو رابط', isDense: true),
                  onSubmitted: (_) => test(),
                ),
              ),
              TextButton(onPressed: test, child: const Text('اختبار')),
            ]),
          ),
          if (testResult.isNotEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(testResult)),
        ]),
      ),
    );
  }
}

class _FilterSetPage extends StatefulWidget {
  final FilterSet set;
  final Future<void> Function() onChanged;

  const _FilterSetPage({required this.set, required this.onChanged});

  @override
  State<_FilterSetPage> createState() => _FilterSetPageState();
}

class _FilterSetPageState extends State<_FilterSetPage> {
  Future<void> changed() async {
    await widget.onChanged();
    if (mounted) setState(() {});
  }

  Future<void> edit([FilterRule? rule]) async {
    final result = await showDialog<FilterRule>(context: context, builder: (_) => _RuleDialog(rule: rule));
    if (result == null) return;
    if (rule == null) {
      widget.set.rules.add(result);
    } else {
      rule
        ..type = result.type
        ..value = result.value
        ..action = result.action;
    }
    await changed();
  }

  @override
  Widget build(BuildContext context) {
    final set = widget.set;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: Text(set.name), actions: [
          IconButton(
              tooltip: 'إعادة تسمية',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () async {
                final name = await _askText(context, 'اسم المجموعة', set.name);
                if (name != null && name.trim().isNotEmpty) {
                  set.name = name.trim();
                  changed();
                }
              }),
        ]),
        floatingActionButton: FloatingActionButton(onPressed: () => edit(), child: const Icon(Icons.add)),
        body: set.rules.isEmpty
            ? const Center(child: Text('لا توجد قواعد. اضغط + لإضافة قاعدة'))
            : ListView(
                children: set.rules.asMap().entries.map((e) {
                  final r = e.value;
                  return ListTile(
                    leading: Switch(
                        value: r.enabled,
                        onChanged: (v) {
                          r.enabled = v;
                          changed();
                        }),
                    title: Text('${r.type.label}: ${r.value}', textDirection: TextDirection.ltr),
                    subtitle: Text(r.action.label),
                    onTap: () => edit(r),
                    trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () {
                          set.rules.removeAt(e.key);
                          changed();
                        }),
                  );
                }).toList(),
              ),
      ),
    );
  }
}

class _RuleDialog extends StatefulWidget {
  final FilterRule? rule;

  const _RuleDialog({this.rule});

  @override
  State<_RuleDialog> createState() => _RuleDialogState();
}

class _RuleDialogState extends State<_RuleDialog> {
  late FilterRuleType type = widget.rule?.type ?? FilterRuleType.domain;
  late FilterAction action = widget.rule?.action ?? FilterAction.exclude;
  late final valueCtl = TextEditingController(text: widget.rule?.value ?? '');

  static const hints = {
    FilterRuleType.domain: 'almanasa.tv, *.cdn.example.com',
    FilterRuleType.ip: '1.2.3.4, 10.0.0.0/8, 1.1.1.1-1.1.1.9',
    FilterRuleType.port: '443, 8000-9000',
    FilterRuleType.protocol: 'http, https, ws, wss',
  };

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: Text(widget.rule == null ? 'قاعدة جديدة' : 'تعديل القاعدة'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          DropdownButtonFormField<FilterRuleType>(
            initialValue: type,
            decoration: const InputDecoration(labelText: 'النوع'),
            items: FilterRuleType.values.map((t) => DropdownMenuItem(value: t, child: Text(t.label))).toList(),
            onChanged: (v) => setState(() => type = v ?? type),
          ),
          TextField(
            controller: valueCtl,
            textDirection: TextDirection.ltr,
            decoration: InputDecoration(labelText: 'القيمة (افصل بفاصلة)', hintText: hints[type]),
          ),
          DropdownButtonFormField<FilterAction>(
            initialValue: action,
            decoration: const InputDecoration(labelText: 'الإجراء'),
            items: FilterAction.values.map((a) => DropdownMenuItem(value: a, child: Text(a.label))).toList(),
            onChanged: (v) => setState(() => action = v ?? action),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
          TextButton(
              onPressed: () {
                if (valueCtl.text.trim().isEmpty) return;
                Navigator.pop(context, FilterRule(type: type, value: valueCtl.text.trim(), action: action));
              },
              child: const Text('حفظ')),
        ],
      ),
    );
  }
}

Future<String?> _askText(BuildContext context, String title, String initial) {
  final ctl = TextEditingController(text: initial);
  return showDialog<String>(
      context: context,
      builder: (context) => Directionality(
            textDirection: TextDirection.rtl,
            child: AlertDialog(
              title: Text(title),
              content: TextField(controller: ctl, autofocus: true),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
                TextButton(onPressed: () => Navigator.pop(context, ctl.text), child: const Text('حفظ')),
              ],
            ),
          ));
}

Future<bool> _confirm(BuildContext context, String text) async {
  final ok = await showDialog<bool>(
      context: context,
      builder: (context) => Directionality(
            textDirection: TextDirection.rtl,
            child: AlertDialog(content: Text(text), actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
              TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('حذف')),
            ]),
          ));
  return ok == true;
}
