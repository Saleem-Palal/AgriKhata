import 'package:flutter/material.dart';
import '../models/sale_models.dart';
import '../theme/app_theme.dart';

// Sale-domain aliases → design-system tokens
class SaleColors {
  static const darkGreen = AppColors.primary;
  static const midGreen = AppColors.mediumGreen;
  static const accentGreen = AppColors.accentGreen;
  static const lightGreenBg = Color(0xFFEAF3DE);
  static const canvasBg = AppColors.surface;
  static const cardBg = AppColors.cardSurface;
  static const borderLight = AppColors.border;
  static const borderMid = AppColors.inputBorder;
  static const textDark = AppColors.textPrimary;
  static const textMuted = AppColors.textMuted;
  static const textLight = AppColors.textHint;
  static const paleGreen = Color(0xFFD8F3DC);
  static const lightGreen = Color(0xFFB7E4C7);
  static const recBoxBg = Color(0xFFEAF3DE);
  static const recBoxBorder = Color(0xFF97C459);
  static const recText = Color(0xFF27500A);
  static const recBadgeBg = Color(0xFF2D6A4F);
  static const recBadgeText = Color(0xFFB7E4C7);
  static const addRecBtn = Color(0xFFC0DD97);
  static const addRecBtnText = Color(0xFF3B6D11);

  // Badge colors
  static const fertBg = Color(0xFFD8F3DC);
  static const fertText = Color(0xFF2D6A4F);
  static const pestBg = Color(0xFFFCEBEB);
  static const pestText = Color(0xFF791F1F);
  static const seedBg = Color(0xFFE6F1FB);
  static const seedText = Color(0xFF0C447C);

  // Over limit badge
  static const limitBg = Color(0xFFF7C1C1);
  static const limitText = Color(0xFF791F1F);

  // Delete button
  static const deleteBtnColor = Color(0xFFA32D2D);
}

// Step header with numbered dot
class StepHeader extends StatelessWidget {
  final int stepNumber;
  final String title;

  const StepHeader({super.key, required this.stepNumber, required this.title});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: SaleColors.borderLight, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 19,
            height: 19,
            decoration: const BoxDecoration(
              color: SaleColors.midGreen,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                '$stepNumber',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
          const SizedBox(width: 7),
          Text(
            title,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: SaleColors.textDark,
            ),
          ),
        ],
      ),
    );
  }
}

// Zamindar profile pill display
class ZamindarPill extends StatelessWidget {
  final Zamindar zamindar;

  const ZamindarPill({super.key, required this.zamindar});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: SaleColors.lightGreenBg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: const BoxDecoration(
              color: SaleColors.midGreen,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                zamindar.initials,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: SaleColors.lightGreen,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  zamindar.name,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: SaleColors.textDark,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  '${zamindar.location} · ${zamindar.kisaanCount} Kisaans',
                  style: const TextStyle(
                    fontSize: 11,
                    color: SaleColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          if (zamindar.isOverLimit)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: SaleColors.limitBg,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text(
                'Over limit',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: SaleColors.limitText,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// Kisaan card for grid
class KisaanCard extends StatelessWidget {
  final Kisaan kisaan;
  final bool isSelected;
  final VoidCallback onTap;

  const KisaanCard({
    super.key,
    required this.kisaan,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
          decoration: BoxDecoration(
            color: isSelected ? SaleColors.lightGreenBg : SaleColors.cardBg,
            border: Border.all(
              color: isSelected ? SaleColors.accentGreen : SaleColors.borderMid,
              width: isSelected ? 1.5 : 0.5,
            ),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      kisaan.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: isSelected
                            ? SaleColors.darkGreen
                            : SaleColors.textDark,
                      ),
                    ),
                  ),
                  if (isSelected)
                    const Icon(
                      Icons.push_pin,
                      size: 14,
                      color: SaleColors.darkGreen,
                    ),
                ],
              ),
              const SizedBox(height: 1),
              Text(
                kisaan.village,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11,
                  color: SaleColors.textLight,
                ),
              ),
              const SizedBox(height: 5),
              Row(
                children: [
                  Flexible(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: SaleColors.paleGreen,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        kisaan.crop,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                          color: SaleColors.midGreen,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    '${kisaan.acres.toStringAsFixed(0)} acres',
                    style: const TextStyle(
                      fontSize: 10,
                      color: SaleColors.textMuted,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Smart recommendations box
class SmartRecommendationsBox extends StatelessWidget {
  final Kisaan? selectedKisaan;
  final List<Recommendation> recommendations;
  final Function(Recommendation) onAddRecommendation;
  final bool isLoading;
  final String? stageLabel;

  const SmartRecommendationsBox({
    super.key,
    required this.selectedKisaan,
    required this.recommendations,
    required this.onAddRecommendation,
    this.isLoading = false,
    this.stageLabel,
  });

  @override
  Widget build(BuildContext context) {
    if (selectedKisaan == null) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
        child: const Text(
          'Select a Kisaan to see recommendations',
          style: TextStyle(fontSize: 12, color: SaleColors.textMuted),
        ),
      );
    }

    if (isLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 14),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: SaleColors.recBoxBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: SaleColors.recBoxBorder, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.stars, size: 12, color: SaleColors.recText),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${selectedKisaan!.name} · ${selectedKisaan!.acres.toStringAsFixed(0)} acres ${selectedKisaan!.crop}',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: SaleColors.recText,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: SaleColors.recBadgeBg,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  stageLabel?.isNotEmpty == true
                      ? stageLabel!
                      : 'Auto-calculated',
                  style: const TextStyle(
                    fontSize: 10,
                    color: SaleColors.recBadgeText,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (recommendations.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 4),
              child: Text(
                "✨ All recommended inputs for this Kisaan's acreage are currently up to date for this stage of the season.",
                style: TextStyle(
                  fontSize: 12,
                  height: 1.35,
                  color: SaleColors.recText,
                ),
              ),
            )
          else
            ...recommendations.map((rec) => _buildRecommendationRow(rec)),
        ],
      ),
    );
  }

  Widget _buildRecommendationRow(Recommendation rec) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 5),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: SaleColors.addRecBtn, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              rec.product.name,
              style: const TextStyle(fontSize: 12, color: SaleColors.textDark),
            ),
          ),
          Text(
            rec.displayQuantity,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: SaleColors.addRecBtnText,
            ),
          ),
          const SizedBox(width: 8),
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => onAddRecommendation(rec),
              borderRadius: BorderRadius.circular(6),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(
                  color: SaleColors.addRecBtn,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  '+ Add',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: SaleColors.addRecBtnText,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Product type badge
class ProductTypeBadge extends StatelessWidget {
  final ProductType type;

  const ProductTypeBadge({super.key, required this.type});

  @override
  Widget build(BuildContext context) {
    Color bgColor;
    Color textColor;

    switch (type) {
      case ProductType.fertilizer:
        bgColor = SaleColors.fertBg;
        textColor = SaleColors.fertText;
        break;
      case ProductType.pesticide:
        bgColor = SaleColors.pestBg;
        textColor = SaleColors.pestText;
        break;
      case ProductType.seed:
        bgColor = SaleColors.seedBg;
        textColor = SaleColors.seedText;
        break;
      case ProductType.other:
        bgColor = SaleColors.paleGreen;
        textColor = SaleColors.textMuted;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        type.displayName,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w500,
          color: textColor,
        ),
      ),
    );
  }
}

// Quantity control with +/- buttons
class QuantityControl extends StatelessWidget {
  final int quantity;
  final VoidCallback onIncrement;
  final VoidCallback onDecrement;

  const QuantityControl({
    super.key,
    required this.quantity,
    required this.onIncrement,
    required this.onDecrement,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildButton('−', onDecrement),
        const SizedBox(width: 5),
        SizedBox(
          width: 28,
          child: Text(
            '$quantity',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: SaleColors.textDark,
            ),
          ),
        ),
        const SizedBox(width: 5),
        _buildButton('+', onIncrement),
      ],
    );
  }

  Widget _buildButton(String label, VoidCallback onPressed) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(5),
        child: Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: SaleColors.cardBg,
            border: Border.all(color: SaleColors.borderMid, width: 0.5),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Center(
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: SaleColors.textDark,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Inline editable currency field for table
class InlineEditableField extends StatefulWidget {
  final double value;
  final Function(double) onChanged;
  final double width;

  const InlineEditableField({
    super.key,
    required this.value,
    required this.onChanged,
    this.width = 70,
  });

  @override
  State<InlineEditableField> createState() => _InlineEditableFieldState();
}

class _InlineEditableFieldState extends State<InlineEditableField> {
  late final TextEditingController _controller;
  final FocusNode _focusNode = FocusNode();

  static String _format(double value) => value.toStringAsFixed(0);

  static double _parse(String raw) {
    final cleaned = raw.replaceAll(',', '').trim();
    if (cleaned.isEmpty) return 0.0;
    return double.tryParse(cleaned) ?? 0.0;
  }

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _format(widget.value));
    _focusNode.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    if (_focusNode.hasFocus) return;
    final parsed = _parse(_controller.text);
    final text = _format(parsed);
    if (_controller.text != text) {
      _controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
  }

  @override
  void didUpdateWidget(InlineEditableField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // While focused, leave the raw text alone so clearing "" can stay empty
    // while cart state already treats it as 0.0.
    if (_focusNode.hasFocus || oldWidget.value == widget.value) return;
    final text = _format(widget.value);
    if (_controller.text != text) {
      _controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.width,
      child: TextField(
        controller: _controller,
        focusNode: _focusNode,
        textAlign: TextAlign.right,
        keyboardType: TextInputType.number,
        style: const TextStyle(fontSize: 11, color: SaleColors.textDark),
        decoration: InputDecoration(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 4,
            vertical: 2,
          ),
          isDense: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(
              color: SaleColors.borderMid,
              width: 0.5,
            ),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(
              color: SaleColors.borderMid,
              width: 0.5,
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(
              color: SaleColors.accentGreen,
              width: 1,
            ),
          ),
          filled: true,
          fillColor: SaleColors.cardBg,
        ),
        onChanged: (val) {
          // Empty / invalid input → 0.0 so subtotals update immediately.
          widget.onChanged(_parse(val));
        },
      ),
    );
  }
}

// Currency formatter helper
class CurrencyFormatter {
  static String format(double amount) {
    return '₨ ${amount.toStringAsFixed(0).replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (Match m) => '${m[1]},')}';
  }
}

// Payment method toggle
class PaymentMethodToggle extends StatelessWidget {
  final PaymentMethod selectedMethod;
  final Function(PaymentMethod) onChanged;
  final bool compact;

  const PaymentMethodToggle({
    super.key,
    required this.selectedMethod,
    required this.onChanged,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.15),
            width: 0.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildCompactChip(PaymentMethod.credit),
            const SizedBox(width: 3),
            _buildCompactChip(PaymentMethod.cash),
          ],
        ),
      );
    }

    return Row(
      children: [
        Expanded(child: _buildButton(PaymentMethod.credit)),
        const SizedBox(width: 8),
        Expanded(child: _buildButton(PaymentMethod.cash)),
      ],
    );
  }

  Widget _buildCompactChip(PaymentMethod method) {
    final isActive = selectedMethod == method;
    final label = method == PaymentMethod.credit ? 'Credit' : 'Cash';
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => onChanged(method),
        borderRadius: BorderRadius.circular(7),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: isActive ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: isActive ? SaleColors.textDark : SaleColors.textLight,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildButton(PaymentMethod method) {
    final isActive = selectedMethod == method;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => onChanged(method),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 7),
          decoration: BoxDecoration(
            color: isActive ? Colors.white : Colors.white.withOpacity(0.1),
            border: Border.all(
              color: isActive ? Colors.white : Colors.white.withOpacity(0.15),
              width: 1.25,
            ),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Text(
            method.displayName,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: isActive ? SaleColors.textDark : SaleColors.textLight,
            ),
          ),
        ),
      ),
    );
  }
}

// Custom input field matching the design
class SaleInputField extends StatelessWidget {
  final String label;
  final String? placeholder;
  final TextEditingController? controller;
  final bool isRequired;
  final TextInputType keyboardType;
  final Function(String)? onChanged;

  const SaleInputField({
    super.key,
    required this.label,
    this.placeholder,
    this.controller,
    this.isRequired = false,
    this.keyboardType = TextInputType.text,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: SaleColors.textMuted,
              ),
            ),
            if (isRequired) ...[
              const SizedBox(width: 2),
              const Text(
                '*',
                style: TextStyle(fontSize: 11, color: Color(0xFFE24B4A)),
              ),
            ],
          ],
        ),
        const SizedBox(height: 5),
        TextFormField(
          controller: controller,
          keyboardType: keyboardType,
          style: const TextStyle(fontSize: 13, color: SaleColors.textDark),
          decoration: InputDecoration(
            hintText: placeholder,
            hintStyle: const TextStyle(
              fontSize: 13,
              color: SaleColors.textLight,
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 11,
              vertical: 8,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(9),
              borderSide: const BorderSide(
                color: SaleColors.borderMid,
                width: 0.5,
              ),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(9),
              borderSide: const BorderSide(
                color: SaleColors.borderMid,
                width: 0.5,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(9),
              borderSide: const BorderSide(
                color: SaleColors.accentGreen,
                width: 1,
              ),
            ),
            filled: true,
            fillColor: SaleColors.cardBg,
          ),
          onChanged: onChanged,
        ),
      ],
    );
  }
}

/// Compact numeric field with a vertical up/down stepper in the suffix.
///
/// Used on the New Sale screen for Qty (step 1) and Price / Seasonal Inc (step 20).
class CustomStepperTextField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final double stepValue;
  final double minValue;
  final bool integerOnly;
  final String? hintText;
  final ValueChanged<String>? onChanged;

  const CustomStepperTextField({
    super.key,
    required this.label,
    required this.controller,
    required this.stepValue,
    this.minValue = 0,
    this.integerOnly = false,
    this.hintText,
    this.onChanged,
  });

  void _step(bool increment) {
    final raw = controller.text.replaceAll(RegExp(r'[^0-9.]'), '');
    final current = double.tryParse(raw) ?? 0;
    final next = increment
        ? current + stepValue
        : (current - stepValue).clamp(minValue, double.infinity);
    final text = integerOnly
        ? next.round().toString()
        : (next == next.roundToDouble()
              ? next.toStringAsFixed(0)
              : next.toStringAsFixed(0));
    controller.text = text;
    controller.selection = TextSelection.collapsed(offset: text.length);
    onChanged?.call(text);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: SaleColors.textMuted,
          ),
        ),
        const SizedBox(height: 4),
        TextFormField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: SaleColors.textDark,
          ),
          onChanged: onChanged,
          decoration: InputDecoration(
            hintText: hintText,
            hintStyle: const TextStyle(
              fontSize: 11,
              color: SaleColors.textLight,
              fontWeight: FontWeight.w500,
            ),
            contentPadding: const EdgeInsets.fromLTRB(8, 8, 0, 8),
            isDense: true,
            suffixIconConstraints: const BoxConstraints(
              minWidth: 28,
              minHeight: 36,
            ),
            suffixIcon: Padding(
              padding: const EdgeInsets.only(right: 2, top: 2, bottom: 2),
              child: Material(
                color: SaleColors.darkGreen,
                borderRadius: BorderRadius.circular(7),
                child: SizedBox(
                  width: 26,
                  height: 32,
                  child: Column(
                    children: [
                      SizedBox(
                        height: 15,
                        width: 26,
                        child: InkWell(
                          onTap: () => _step(true),
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(7),
                          ),
                          child: const Center(
                            child: Icon(
                              Icons.arrow_drop_up,
                              size: 18,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                      Container(
                        height: 1,
                        width: 26,
                        color: Colors.white.withValues(alpha: 0.25),
                      ),
                      SizedBox(
                        height: 16,
                        width: 26,
                        child: InkWell(
                          onTap: () => _step(false),
                          borderRadius: const BorderRadius.vertical(
                            bottom: Radius.circular(7),
                          ),
                          child: const Center(
                            child: Icon(
                              Icons.arrow_drop_down,
                              size: 18,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(9),
              borderSide: const BorderSide(
                color: SaleColors.borderMid,
                width: 0.5,
              ),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(9),
              borderSide: const BorderSide(
                color: SaleColors.borderMid,
                width: 0.5,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(9),
              borderSide: const BorderSide(
                color: SaleColors.accentGreen,
                width: 1,
              ),
            ),
            filled: true,
            fillColor: SaleColors.cardBg,
          ),
        ),
      ],
    );
  }
}
