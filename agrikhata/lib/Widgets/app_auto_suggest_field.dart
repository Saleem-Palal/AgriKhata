import 'package:agrikhata/Core/Themes/app_colors.dart';
import 'package:flutter/material.dart';

/// Reusable name auto-suggest field for AgriKhata forms.
///
/// Calls [fetchSuggestions] as the user types and shows a compact floating
/// list. When there are no matches, the overlay is hidden entirely.
class AppAutoSuggestField extends StatefulWidget {
  const AppAutoSuggestField({
    super.key,
    required this.controller,
    required this.labelText,
    required this.fetchSuggestions,
    this.hintText,
    this.onSelected,
    this.validator,
    this.isRequired = false,
    this.autofocus = false,
    this.textInputAction,
    this.prefixIcon,
    this.suggestionIcon = Icons.person_outline_rounded,
  });

  final TextEditingController controller;
  final String labelText;
  final String? hintText;
  final Future<List<String>> Function(String text) fetchSuggestions;
  final ValueChanged<String>? onSelected;
  final FormFieldValidator<String>? validator;
  final bool isRequired;
  final bool autofocus;
  final TextInputAction? textInputAction;
  final IconData? prefixIcon;
  /// Icon shown beside each suggestion row (name → person, village → location).
  final IconData suggestionIcon;

  @override
  State<AppAutoSuggestField> createState() => _AppAutoSuggestFieldState();
}

class _AppAutoSuggestFieldState extends State<AppAutoSuggestField> {
  late final FocusNode _focusNode;
  int _requestId = 0;
  List<String> _cachedOptions = const [];

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  Future<Iterable<String>> _optionsBuilder(TextEditingValue value) async {
    final query = value.text.trim();
    if (query.isEmpty) {
      _cachedOptions = const [];
      return const Iterable<String>.empty();
    }

    final id = ++_requestId;
    // Light debounce so rapid typing does not flood SQLite.
    await Future<void>.delayed(const Duration(milliseconds: 160));
    if (!mounted || id != _requestId) return _cachedOptions;

    final results = await widget.fetchSuggestions(value.text);
    if (!mounted || id != _requestId) return _cachedOptions;

    _cachedOptions = results;
    return results;
  }

  InputDecoration _decoration() {
    final prefix = widget.prefixIcon == null
        ? null
        : Container(
            margin: const EdgeInsets.only(right: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: AppColors.sidebarText.withValues(alpha: 0.1),
              border: const Border(
                right: BorderSide(color: AppColors.sidebarBg, width: 0.5),
              ),
            ),
            child: Icon(
              widget.prefixIcon,
              size: 16,
              color: AppColors.textMuted,
            ),
          );

    return InputDecoration(
      isDense: true,
      hintText: widget.hintText,
      hintStyle: const TextStyle(fontSize: 12.5, color: AppColors.textHint),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      prefixIcon: prefix,
      prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.darkGreen, width: 0.5),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.darkGreen, width: 1.2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.dangerText, width: 1),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.dangerText, width: 1.2),
      ),
      errorStyle: const TextStyle(fontSize: 10),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Text(
              widget.labelText,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: AppColors.textMuted,
              ),
            ),
            if (widget.isRequired)
              const Text(
                ' *',
                style: TextStyle(color: Colors.red, fontSize: 11),
              ),
          ],
        ),
        const SizedBox(height: 5),
        RawAutocomplete<String>(
          textEditingController: widget.controller,
          focusNode: _focusNode,
          optionsBuilder: _optionsBuilder,
          displayStringForOption: (option) => option,
          onSelected: (selection) {
            widget.controller
              ..text = selection
              ..selection = TextSelection.collapsed(offset: selection.length);
            widget.onSelected?.call(selection);
            // Drop focus so the overlay closes cleanly (avoids overlay overflow).
            _focusNode.unfocus();
          },
          fieldViewBuilder:
              (context, textEditingController, focusNode, onFieldSubmitted) {
                return TextFormField(
                  controller: textEditingController,
                  focusNode: focusNode,
                  autofocus: widget.autofocus,
                  textInputAction: widget.textInputAction,
                  validator: widget.validator,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: AppColors.textPrimary,
                  ),
                  decoration: _decoration(),
                  onFieldSubmitted: (_) => onFieldSubmitted(),
                );
              },
          optionsViewBuilder: (context, onSelected, options) {
            // Hide overlay completely when there are no matches.
            if (options.isEmpty) return const SizedBox.shrink();

            final optionList = options.toList(growable: false);
            return Align(
              alignment: Alignment.topLeft,
              child: Material(
                elevation: 6,
                color: Colors.white,
                shadowColor: AppColors.darkGreen.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(10),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxHeight: 180,
                    minWidth: 220,
                  ),
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    shrinkWrap: true,
                    itemCount: optionList.length,
                    separatorBuilder: (_, _) => const Divider(
                      height: 1,
                      thickness: 0.5,
                      color: AppColors.border,
                    ),
                    itemBuilder: (context, index) {
                      final option = optionList[index];
                      return InkWell(
                        onTap: () => onSelected(option),
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                widget.suggestionIcon,
                                size: 15,
                                color: AppColors.textMuted,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  option,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w500,
                                    color: AppColors.darkGreen,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}
