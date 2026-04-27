import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';
import 'package:collection/collection.dart';

/// Full-screen page for managing Anki export profiles.
/// Replaces the old dialog-based ProfilesDialogPage.
class ProfilesManagementPage extends BasePage {
  const ProfilesManagementPage({
    required this.models,
    required this.initialModel,
    super.key,
  });

  final List<String> models;
  final String initialModel;

  @override
  BasePageState createState() => _ProfilesManagementPageState();
}

class _ProfilesManagementPageState
    extends BasePageState<ProfilesManagementPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await appModel.validateSelectedMapping(
        context: context,
        mapping: appModel.lastSelectedMapping,
      );
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final mappings = appModel.mappings;

    return Scaffold(
      appBar: AppBar(
        title: Text(t.anki_manage_profiles),
        actions: [
          IconButton(
            icon: const Icon(Icons.auto_awesome),
            tooltip: t.use_recommended_template,
            onPressed: _createRecommended,
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: t.dialog_create,
            onPressed: _createNew,
          ),
        ],
      ),
      body: mappings.isEmpty
          ? Center(child: Text(t.field_label_empty))
          : ReorderableListView.builder(
              padding: const EdgeInsets.only(bottom: 80),
              itemCount: mappings.length,
              onReorder: _onReorder,
              itemBuilder: (context, index) {
                final mapping = mappings[index];
                final isSelected =
                    appModel.lastSelectedMapping.label == mapping.label;

                return ListTile(
                  key: ValueKey(mapping.label),
                  leading: Icon(
                    Icons.account_box,
                    color: isSelected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  title: Text(
                    mapping.label,
                    style: isSelected
                        ? TextStyle(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.bold)
                        : null,
                  ),
                  subtitle: Text(mapping.model),
                  trailing: PopupMenuButton<String>(
                    onSelected: (action) =>
                        _onMenuAction(action, mapping),
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'edit',
                        child: ListTile(
                          leading: const Icon(Icons.edit, size: 20),
                          title: Text(t.options_edit),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      PopupMenuItem(
                        value: 'copy',
                        child: ListTile(
                          leading: const Icon(Icons.copy, size: 20),
                          title: Text(t.options_copy),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      if (mapping.label !=
                          AnkiMapping.standardProfileName)
                        PopupMenuItem(
                          value: 'delete',
                          child: ListTile(
                            leading: Icon(Icons.delete,
                                size: 20,
                                color: theme.colorScheme.error),
                            title: Text(t.options_delete,
                                style: TextStyle(
                                    color: theme.colorScheme.error)),
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                    ],
                  ),
                  onTap: () async {
                    await appModel.setLastSelectedMapping(mapping);
                    await appModel.validateSelectedMapping(
                      context: context,
                      mapping: mapping,
                    );
                    if (mounted) setState(() {});
                  },
                );
              },
            ),
    );
  }

  void _onReorder(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex -= 1;
    final mappings = appModel.mappings.toList();
    final item = mappings.removeAt(oldIndex);
    mappings.insert(newIndex, item);
    mappings.forEachIndexed((i, m) => m.order = i);
    appModel.updateMappingsOrder(mappings);
    setState(() {});
  }

  void _onMenuAction(String action, AnkiMapping mapping) {
    switch (action) {
      case 'edit':
        _openEditPage(mapping);
      case 'copy':
        final clone =
            mapping.copyWith(label: t.copy_of_mapping(name: mapping.label));
        clone.id = null;
        _openEditPage(clone);
      case 'delete':
        _confirmDelete(mapping);
    }
  }

  Future<void> _createRecommended() async {
    try {
      await appModel.addDefaultModelIfMissing();
      if (appModel.getMappingFromLabel(AnkiMapping.standardProfileName) !=
          null) {
        Fluttertoast.showToast(msg: t.recommended_template_exists);
        return;
      }

      final modelName = AnkiMapping.standardModelName;
      final models = widget.models;
      if (!models.contains(modelName)) {
        Fluttertoast.showToast(msg: '${t.error_profile_name}: $modelName');
        return;
      }

      final fields = await appModel.getFieldList(modelName);
      final fieldMappings = AnkiHandlebar.autoMapFields(fields, modelName: modelName);

      final defaultMapping = AnkiMapping(
        label: AnkiMapping.standardProfileName,
        model: modelName,
        fieldMappings: fieldMappings,
        creatorFieldKeys: AnkiMapping.defaultCreatorFieldKeys,
        creatorCollapsedFieldKeys:
            AnkiMapping.defaultCreatorCollapsedFieldKeys,
        order: appModel.nextMappingOrder,
        tags: [modelName],
        enhancements: AnkiMapping.defaultEnhancementsByLanguage[
            appModel.targetLanguage.languageCountryCode],
        actions: AnkiMapping.defaultActionsByLanguage[
            appModel.targetLanguage.languageCountryCode],
        exportMediaTags: true,
        useBrTags: true,
        prependDictionaryNames: true,
      );

      appModel.addMapping(defaultMapping);
      await appModel.setLastSelectedMapping(defaultMapping);
      Fluttertoast.showToast(msg: t.recommended_template_created);
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Failed to create recommended template: $e');
    }
  }

  Future<void> _createNew() async {
    String model = appModel.lastSelectedModel ?? widget.initialModel;
    List<String> modelFields = await appModel.getFieldList(model);
    Map<String, String> fieldMappings = AnkiHandlebar.autoMapFields(modelFields, modelName: model);

    final newMapping = AnkiMapping(
      label: '',
      model: model,
      fieldMappings: fieldMappings,
      creatorFieldKeys: AnkiMapping.defaultCreatorFieldKeys,
      creatorCollapsedFieldKeys: AnkiMapping.defaultCreatorCollapsedFieldKeys,
      tags: [],
      order: 0,
      enhancements: AnkiMapping.defaultEnhancementsByLanguage[
          appModel.targetLanguage.languageCountryCode],
      actions: AnkiMapping.defaultActionsByLanguage[
          appModel.targetLanguage.languageCountryCode],
      exportMediaTags: true,
      useBrTags: true,
      prependDictionaryNames: true,
    );

    _openEditPage(newMapping);
  }

  void _openEditPage(AnkiMapping mapping) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _ProfileEditPage(
          mapping: mapping,
          models: widget.models,
        ),
      ),
    ).then((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _confirmDelete(AnkiMapping mapping) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(mapping.label),
        content: Text(t.mappings_delete_confirmation),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.dialog_cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.errorContainer,
              foregroundColor: theme.colorScheme.onErrorContainer,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.dialog_delete),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      appModel.deleteMapping(mapping);
      if (mounted) setState(() {});
    }
  }
}

// ─────────────────────────────────────────────────────────────────────
// Profile Edit Page — iOS Hoshi AnkiView-style field mapping
// ─────────────────────────────────────────────────────────────────────

class _ProfileEditPage extends BasePage {
  const _ProfileEditPage({
    required this.mapping,
    required this.models,
  });

  final AnkiMapping mapping;
  final List<String> models;

  @override
  BasePageState createState() => _ProfileEditPageState();
}

class _ProfileEditPageState extends BasePageState<_ProfileEditPage> {
  late AnkiMapping _clone;
  late TextEditingController _nameController;
  List<String> _modelFields = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _clone = widget.mapping.copyWith();
    _nameController = TextEditingController(text: _clone.label);
    _loadFields();
  }

  Future<void> _loadFields() async {
    final fields = await appModel.getFieldList(_clone.model);
    if (mounted) {
      setState(() {
        _modelFields = fields;
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_clone.id != null ? t.options_edit : t.dialog_create),
        actions: [
          TextButton(
            onPressed: _save,
            child: Text(t.dialog_save),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                // ── Profile Name ──
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: TextField(
                    controller: _nameController,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.account_box),
                      labelText: t.mapping_name,
                      hintText: t.mapping_name_hint,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                const Divider(),

                // ── Card Type (Model) ──
                _SectionLabel(t.model_to_map),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: DropdownButtonFormField<String>(
                    initialValue: widget.models.contains(_clone.model)
                        ? _clone.model
                        : widget.models.firstOrNull,
                    decoration:
                        const InputDecoration(border: OutlineInputBorder()),
                    items: widget.models
                        .map((m) =>
                            DropdownMenuItem(value: m, child: Text(m)))
                        .toList(),
                    onChanged: (v) async {
                      if (v == null || v == _clone.model) return;
                      setState(() => _loading = true);
                      final fields = await appModel.getFieldList(v);
                      _clone = _clone.copyWith(
                        model: v,
                        fieldMappings: AnkiHandlebar.autoMapFields(fields, modelName: v),
                      );
                      if (mounted) {
                        setState(() {
                          _modelFields = fields;
                          _loading = false;
                        });
                      }
                    },
                  ),
                ),
                const Divider(height: 24),

                // ── Field Mappings ──
                _SectionLabel('Fields'),
                ..._modelFields.map((field) => _FieldMappingRow(
                      fieldName: field,
                      value: _clone.fieldMappings[field] ?? '',
                      onChanged: (v) {
                        setState(() {
                          _clone.fieldMappings[field] = v;
                        });
                      },
                    )),
                const Divider(height: 24),

                // ── Settings ──
                _SectionLabel(t.show_options),
                SwitchListTile(
                  title: Text(t.wrap_image_audio),
                  value: _clone.exportMediaTags ?? false,
                  onChanged: (v) =>
                      setState(() => _clone.exportMediaTags = v),
                ),
                SwitchListTile(
                  title: Text(t.use_br_tags),
                  value: _clone.useBrTags ?? false,
                  onChanged: (v) => setState(() => _clone.useBrTags = v),
                ),
                SwitchListTile(
                  title: Text(t.prepend_dictionary_names),
                  value: _clone.prependDictionaryNames ?? false,
                  onChanged: (v) =>
                      setState(() => _clone.prependDictionaryNames = v),
                ),
              ],
            ),
    );
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();

    if (_clone.label == AnkiMapping.standardProfileName &&
        name != AnkiMapping.standardProfileName) {
      _showError(t.error_standard_profile_name,
          t.error_standard_profile_name_content);
      return;
    }

    AnkiMapping newMapping = _clone.copyWith(
      label: name,
      tags: [_clone.model],
    );

    if (_clone.id == null) {
      newMapping = newMapping.copyWith(order: appModel.nextMappingOrder);
      if (name.isEmpty ||
          name.contains('%mappingName%') ||
          appModel.mappingNameHasDuplicate(newMapping)) {
        _showError(t.error_profile_name, t.error_profile_name_content);
        return;
      }
    }

    appModel.addMapping(newMapping);
    if (mounted) Navigator.pop(context);
  }

  void _showError(String title, String content) {
    showAppDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t.dialog_close),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Shared widgets
// ─────────────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }
}

class _FieldMappingRow extends StatelessWidget {
  const _FieldMappingRow({
    required this.fieldName,
    required this.value,
    required this.onChanged,
  });

  final String fieldName;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final handlebars = ['', ...AnkiHandlebar.all];
    final isKnownValue = handlebars.contains(value);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 120,
            child: Text(
              fieldName,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: isKnownValue ? value : value,
              isDense: true,
              isExpanded: true,
              decoration: const InputDecoration(
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                border: OutlineInputBorder(),
              ),
              items: [
                if (!isKnownValue && value.isNotEmpty)
                  DropdownMenuItem(
                    value: value,
                    child: Text('[$value]'),
                  ),
                ...handlebars.map((hb) {
                  final label = hb.isEmpty
                      ? t.field_label_empty
                      : AnkiHandlebar.displayName(hb);
                  return DropdownMenuItem(value: hb, child: Text(label));
                }),
              ],
              onChanged: (v) => onChanged(v ?? ''),
            ),
          ),
        ],
      ),
    );
  }
}

/// Keep the old class name as an alias for backward compat references.
typedef ProfilesDialogPage = ProfilesManagementPage;
