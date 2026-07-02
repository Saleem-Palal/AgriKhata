import 'package:agrikhata/Core/Themes/app_colors.dart';
import 'package:agrikhata/Database/database_helper.dart';
import 'package:agrikhata/Widgets/season_selector.dart';
import 'package:agrikhata/screens/zamindar_profile_screen.dart';
import 'package:flutter/material.dart';

class AddZamindarScreen extends StatefulWidget {
  final VoidCallback? onCancel;
  final VoidCallback? onSaved;
  final Zamindar?
  zamindar; // Uses the typed Zamindar model from database_helper.dart
  final void Function(Zamindar zamindar)? onSaveZamindar;

  const AddZamindarScreen({
    super.key,
    this.onCancel,
    this.onSaved,
    this.zamindar,
    this.onSaveZamindar,
  });

  @override
  State<AddZamindarScreen> createState() => _AddZamindarScreenState();
}

class _AddZamindarScreenState extends State<AddZamindarScreen> {
  final TextEditingController _villageController = TextEditingController();
  final TextEditingController _landController = TextEditingController();
  String _selectedLandUnit = 'Acre';

  final List<String> _paymentTerms = [
    "Seasonal",
    "Monthly",
    "Advance Payment",
    "Custom",
  ];

  String _selectedTerm = "Seasonal";

  final TextEditingController _udhaarController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();

  // New controllers connected to database schema fields
  final TextEditingController _fatherNameController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();

  final TextEditingController _paymentTermsController = TextEditingController();
  final TextEditingController _seasonController = TextEditingController();
  final TextEditingController _cropSelectionController =
      TextEditingController();

  List<String> selectedSeasons = [];
  List<String> selectedCrops = [];

  final Map<String, List<String>> seasonCrops = {
    'Rabi': ['Wheat', 'Mustard', 'Potato', 'Onion'],
    'Kharif': [
      'Rice',
      'Cotton',
      'Sugarcane',
      'Maize',
      'Sunflower',
      'Chili',
      'Tomato',
      'Mango',
    ],
  };

  bool get _minimalFieldsFilled =>
      _nameController.text.isNotEmpty && _phoneController.text.length >= 10;

  bool get _allFieldsFilled =>
      _nameController.text.isNotEmpty &&
      _phoneController.text.length >= 10 &&
      (_selectedTerm == 'Advance Payment' ||
          _udhaarController.text.isNotEmpty) &&
      _landController.text.isNotEmpty &&
      selectedSeasons.isNotEmpty &&
      selectedCrops.isNotEmpty;

  @override
  void initState() {
    super.initState();

    // If a Zamindar model exists (Edit flow), prepopulate all database fields safely
    if (widget.zamindar != null) {
      final z = widget.zamindar!;
      _nameController.text = z.name;
      _fatherNameController.text = z.fathersName ?? '';
      _phoneController.text = z.whatsappNumber;
      _villageController.text = z.village ?? '';
      _descriptionController.text = z.description ?? '';
      _udhaarController.text = z.creditLimit.toString();
      _landController.text = z.landArea.toString();
      _selectedLandUnit = z.landUnit;
      _selectedTerm = z.paymentTerms;
      selectedSeasons = z.activeSeasons;
    }

    _nameController.addListener(updateUI);
    _fatherNameController.addListener(updateUI);
    _phoneController.addListener(updateUI);
    _villageController.addListener(updateUI);
    _descriptionController.addListener(updateUI);
    _udhaarController.addListener(updateUI);
    _landController.addListener(updateUI);
    _paymentTermsController.addListener(updateUI);
    _seasonController.addListener(updateUI);
    _cropSelectionController.addListener(updateUI);
  }

  void updateUI() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _landController.dispose();
    _nameController.dispose();
    _fatherNameController.dispose();
    _phoneController.dispose();
    _villageController.dispose();
    _descriptionController.dispose();
    _udhaarController.dispose();
    _paymentTermsController.dispose();
    _seasonController.dispose();
    _cropSelectionController.dispose();
    super.dispose();
  }

  Future<void> _handleSaveDraft() async {
    if (!_minimalFieldsFilled) return;

    final zamindarData = _buildZamindarFromForm(isDraft: true);

    if (widget.zamindar != null) {
      await DatabaseHelper.instance.updateZamindar(zamindarData);
    } else {
      await DatabaseHelper.instance.insertZamindar(zamindarData);
    }

    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Draft saved successfully')));
    }

    if (widget.onSaveZamindar != null) {
      widget.onSaveZamindar!(zamindarData);
    } else {
      widget.onSaved?.call();
    }
  }

  Future<void> _handleSaveAndGoToProfile() async {
    if (!_allFieldsFilled) return;

    final zamindarData = _buildZamindarFromForm(isDraft: false);

    int? savedId;
    if (widget.zamindar != null) {
      await DatabaseHelper.instance.updateZamindar(zamindarData);
      savedId = zamindarData.id;
    } else {
      savedId = await DatabaseHelper.instance.insertZamindar(zamindarData);
    }

    if (!mounted) return;

    final enrichedZamindar = await DatabaseHelper.instance.enrichZamindar(
      zamindarData.copyWith(id: savedId),
    );

    if (!mounted) return;

    // If onSaveZamindar callback is provided (shell context), use it
    // This keeps the navigation within the shell and maintains the sidebar
    if (widget.onSaveZamindar != null) {
      widget.onSaveZamindar!(enrichedZamindar);
      return;
    }

    // If onSaved callback is provided (simple pop scenario)
    if (widget.onSaved != null) {
      widget.onSaved!();
      return;
    }

    // Fallback: Direct navigation (only when no callbacks provided)
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (ctx) => ZamindarProfileScreen(
          zamindar: enrichedZamindar,
          initialTabIndex: 1,
          onBack: () => Navigator.of(ctx).pop(),
        ),
      ),
    );
  }

  Zamindar _buildZamindarFromForm({bool isDraft = false}) {
    final rawLimit = _udhaarController.text.replaceAll(RegExp(r'[^0-9]'), '');
    final int creditLimitInt = int.tryParse(rawLimit) ?? 0;
    final double landAreaDouble = double.tryParse(_landController.text) ?? 0.0;

    return Zamindar(
      id: widget.zamindar?.id,
      name: _nameController.text.trim(),
      fathersName: _fatherNameController.text.trim().isEmpty
          ? null
          : _fatherNameController.text.trim(),
      whatsappNumber: _phoneController.text.trim(),
      locationGoth: null,
      village: _villageController.text.trim().isEmpty
          ? null
          : _villageController.text.trim(),
      description: _descriptionController.text.trim().isEmpty
          ? null
          : _descriptionController.text.trim(),
      creditLimit: creditLimitInt,
      landArea: landAreaDouble,
      landUnit: _selectedLandUnit,
      paymentTerms: _selectedTerm,
      activeSeasons: selectedSeasons,
      activeCrops: selectedCrops,
      isDraft: isDraft,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _buildHeader(context),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(0.0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 2,
                    child: Column(
                    children: [
                      Column(
                        children: [
                          _buildFormSection(
                            title: "Personal information",
                            dotColor: Colors.teal,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8.0,
                                vertical: 4,
                              ),
                              child: Column(
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: _buildTextField(
                                          "Full name",
                                          "e.g. Atta Muhammad",
                                          isRequired: true,
                                          prefixIcon:
                                              Icons.person_outline_rounded,
                                          controller: _nameController,
                                        ),
                                      ),
                                      const SizedBox(width: 20),
                                      Expanded(
                                        child: _buildTextField(
                                          "Father's name",
                                          "e.g. Abdul Ghani",
                                          prefixIcon: Icons.family_restroom,
                                          controller: _fatherNameController,
                                        ),
                                      ),
                                    ],
                                  ),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: _buildTextField(
                                          "Whatsapp number",
                                          "e.g. 03001234567",
                                          isRequired: true,
                                          prefixText: "+92",
                                          controller: _phoneController,
                                        ),
                                      ),
                                      const SizedBox(width: 20),
                                      Expanded(
                                        child: _buildTextField(
                                          "Village",
                                          "e.g. Shahan Palal",
                                          prefixIcon:
                                              Icons.location_on_outlined,
                                          controller: _villageController,
                                        ),
                                      ),
                                    ],
                                  ),
                                  _buildTextField(
                                    "Description (optional)",
                                    "Additional notes",
                                    prefixIcon: Icons.description_outlined,
                                    controller: _descriptionController,
                                  ),
                                ],
                              ),
                            ),
                          ),
                          _buildFormSection(
                            title: "Credit Limit & Land Details",
                            dotColor: Colors.redAccent,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8.0,
                                vertical: 4,
                              ),
                              child: Column(
                                children: [
                                  _buildDropdownField(
                                    "Payment terms",
                                    _selectedTerm,
                                    _paymentTerms,
                                    (newValue) {
                                      setState(() {
                                        _selectedTerm = newValue!;
                                      });
                                    },
                                  ),
                                  if (_selectedTerm != 'Advance Payment') ...[
                                    const SizedBox(height: 10),
                                    _buildTextField(
                                      controller: _udhaarController,
                                      "Udhaar Limit (Rs)",
                                      "e.g. 10000",
                                      isRequired: true,
                                      prefixText: "Rs",
                                    ),
                                    const SizedBox(height: 10),
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.start,
                                      children: [
                                        _buildAmountPill(
                                          "Rs 50,000",
                                          _udhaarController,
                                        ),
                                        _buildAmountPill(
                                          "Rs 1,00,000",
                                          _udhaarController,
                                        ),
                                        _buildAmountPill(
                                          "Rs 1,50,000",
                                          _udhaarController,
                                        ),
                                        _buildAmountPill(
                                          "Rs 2,00,000",
                                          _udhaarController,
                                        ),
                                        _buildAmountPill(
                                          "Rs 2,50,000",
                                          _udhaarController,
                                        ),
                                        _buildAmountPill(
                                          "Rs 3,00,000",
                                          _udhaarController,
                                        ),
                                      ],
                                    ),
                                  ],
                                  const SizedBox(height: 10),
                                  Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: const [
                                          Text(
                                            'Land Area',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: AppColors.textMuted,
                                            ),
                                          ),
                                          Text(
                                            ' *',
                                            style: TextStyle(
                                              color: Colors.red,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      Row(
                                        children: [
                                          Expanded(
                                            flex: 2,
                                            child: SizedBox(
                                              height: 35,
                                              child: TextField(
                                                controller: _landController,
                                                keyboardType:
                                                    const TextInputType.numberWithOptions(
                                                      decimal: true,
                                                    ),
                                                style: const TextStyle(
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w500,
                                                  color: AppColors.darkGreen,
                                                ),
                                                textAlignVertical:
                                                    TextAlignVertical.center,
                                                decoration: InputDecoration(
                                                  isDense: true,
                                                  contentPadding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 12,
                                                        vertical: 10,
                                                      ),
                                                  border: OutlineInputBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          9,
                                                        ),
                                                    borderSide:
                                                        const BorderSide(
                                                          color: AppColors
                                                              .sidebarBg,
                                                          width: 0.5,
                                                        ),
                                                  ),
                                                  enabledBorder:
                                                      OutlineInputBorder(
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              9,
                                                            ),
                                                        borderSide:
                                                            const BorderSide(
                                                              color: AppColors
                                                                  .sidebarBg,
                                                              width: 0.5,
                                                            ),
                                                      ),
                                                  focusedBorder:
                                                      OutlineInputBorder(
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              9,
                                                            ),
                                                        borderSide:
                                                            const BorderSide(
                                                              color: AppColors
                                                                  .darkGreen,
                                                              width: 1,
                                                            ),
                                                      ),
                                                  hintText: 'e.g. 12',
                                                  hintStyle: const TextStyle(
                                                    color: AppColors.sidebarBg,
                                                    fontWeight: FontWeight.w400,
                                                  ),
                                                ),
                                                onChanged: (_) =>
                                                    setState(() {}),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          ...['Acre', 'Athaas'].map((unit) {
                                            final isActive =
                                                unit == _selectedLandUnit;
                                            return Padding(
                                              padding: const EdgeInsets.only(
                                                right: 8,
                                              ),
                                              child: GestureDetector(
                                                onTap: () => setState(
                                                  () =>
                                                      _selectedLandUnit = unit,
                                                ),
                                                child: Container(
                                                  height: 35,
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 16,
                                                      ),
                                                  decoration: BoxDecoration(
                                                    color: isActive
                                                        ? AppColors.lightGreen
                                                              .withValues(
                                                                alpha: 0.15,
                                                              )
                                                        : Colors.white,
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          9,
                                                        ),
                                                    border: Border.all(
                                                      color: isActive
                                                          ? AppColors.darkGreen
                                                          : AppColors.sidebarBg,
                                                      width: isActive ? 1 : 0.5,
                                                    ),
                                                  ),
                                                  alignment: Alignment.center,
                                                  child: Text(
                                                    unit,
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                      fontWeight:
                                                          FontWeight.w500,
                                                      color: isActive
                                                          ? AppColors.darkGreen
                                                          : AppColors.textMuted,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            );
                                          }).toList(),
                                        ],
                                      ),
                                      const SizedBox(height: 5),
                                      if (_landController.text.isNotEmpty)
                                        Builder(
                                          builder: (_) {
                                            final val =
                                                double.tryParse(
                                                  _landController.text,
                                                ) ??
                                                0;
                                            final converted =
                                                _selectedLandUnit == 'Acre'
                                                ? '= ${(val / 4).toStringAsFixed(2)} Athaas'
                                                : '= ${(val * 4).toStringAsFixed(0)} Acres';
                                            return Text(
                                              converted,
                                              style: const TextStyle(
                                                fontSize: 11,
                                                color: AppColors.accentGreen,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            );
                                          },
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                          _buildFormSection(
                            title: "Seasons & crops",
                            dotColor: AppColors.cropDotColor,
                            child: SeasonSelector(
                              onSeasonsChanged: (seasons) {
                                setState(() {
                                  selectedSeasons = seasons;
                                });
                              },
                              onCropsChanged: (crops) {
                                setState(() {
                                  selectedCrops = crops;
                                });
                              },
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 240,
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(
                          right: 16.0,
                          top: 8,
                          bottom: 5,
                        ),
                        child: _buildPreviewCard(),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(right: 16.0, bottom: 5),
                        child: _buildChecklistCard(),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(
                          right: 16.0,
                          top: 8,
                          bottom: 5,
                        ),
                        child: _buildInfoCard(
                          _nameController.text.isEmpty
                              ? "Zamindar"
                              : _nameController.text,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          decoration: const BoxDecoration(
            color: AppColors.cardSurface,
            border: Border(
              top: BorderSide(color: Color.fromARGB(255, 65, 113, 54)),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: _allFieldsFilled
                    ? Row(
                        children: const [
                          Icon(
                            Icons.check_circle,
                            size: 14,
                            color: AppColors.accentGreen,
                          ),
                          SizedBox(width: 6),
                          Text(
                            "All required fields filled — ready to save",
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w400,
                              color: AppColors.accentGreen,
                            ),
                          ),
                        ],
                      )
                    : const Text(
                        "Fill name & phone to save draft, or all fields to complete",
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w300,
                          color: AppColors.textMuted,
                        ),
                      ),
              ),
              OutlinedButton(
                onPressed: _minimalFieldsFilled ? _handleSaveDraft : null,
                child: const Text("Save as Draft"),
              ),
              const SizedBox(width: 12),
              ElevatedButton.icon(
                onPressed: _allFieldsFilled ? _handleSaveAndGoToProfile : null,
                icon: const Icon(Icons.arrow_forward, size: 16),
                label: const Text("Save & go to profile"),
              ),
            ],
          ),
        ),
      ],
      ),
    );
  }

  Widget _buildChecklistCard() {
    bool nameFilled = _nameController.text.isNotEmpty;
    bool phoneFilled = _phoneController.text.length >= 10;
    bool udhaarFilled =
        _selectedTerm == 'Advance Payment' || _udhaarController.text.isNotEmpty;
    bool landFilled = _landController.text.isNotEmpty;
    bool paymentTermsFilled = _selectedTerm.isNotEmpty;
    bool seasonFilled = selectedSeasons.isNotEmpty;
    bool cropsFilled = selectedCrops.isNotEmpty;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.sidebarBg, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Checklist",
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
          ),
          const Divider(height: 15, color: AppColors.sidebarBg),
          _buildChecklistItem("Full name", isCompleted: nameFilled),
          _buildChecklistItem("WhatsApp number", isCompleted: phoneFilled),
          _buildChecklistItem("Credit limit set", isCompleted: udhaarFilled),
          _buildChecklistItem("Land area", isCompleted: landFilled),
          _buildChecklistItem("Payment terms", isCompleted: paymentTermsFilled),
          _buildChecklistItem("Seasons selected", isCompleted: seasonFilled),
          _buildChecklistItem("Crops selected", isCompleted: cropsFilled),
          _buildChecklistItem("Kisaans (add after saving)", isCompleted: false),
        ],
      ),
    );
  }

  Widget _buildChecklistItem(String title, {required bool isCompleted}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          Icon(
            isCompleted ? Icons.check_circle : Icons.circle_outlined,
            size: 14,
            color: isCompleted
                ? AppColors.darkGreen.withValues(alpha: 0.7)
                : AppColors.sidebarBg,
          ),
          const SizedBox(width: 5),
          Text(
            title,
            style: TextStyle(
              fontSize: 12,
              color: isCompleted
                  ? Colors.black87
                  : AppColors.textMuted.withValues(alpha: 0.8),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoCard(String zamindarName) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F8E9),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.darkGreen.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "After saving",
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: Color(0xFF2E7D32),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            "You'll be taken to $zamindarName's profile to add Kisaans and start recording sales.",
            style: const TextStyle(
              fontSize: 12,
              color: Color(0xFF1B5E20),
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: const BoxDecoration(
        color: AppColors.cardSurface,
        border: Border(
          bottom: BorderSide(color: Color.fromARGB(255, 65, 113, 54)),
        ),
      ),
      child: Row(
        children: [
          const Text(
            "Zamindars",
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w200,
              color: AppColors.textMuted,
            ),
          ),
          const Text(
            "  ›  Add new Zamindar",
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w200),
          ),
          const Spacer(),
          OutlinedButton(
            onPressed: widget.onCancel,
            child: const Text("Cancel"),
          ),
          const SizedBox(width: 12),
          ElevatedButton.icon(
            onPressed: _allFieldsFilled ? _handleSaveAndGoToProfile : null,
            icon: const Icon(Icons.check, size: 16),
            label: const Text("Save Zamindar"),
          ),
        ],
      ),
    );
  }

  Widget _buildFormSection({
    required String title,
    required Color dotColor,
    required Widget child,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 6),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: AppColors.cardSurface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12.0,
                    vertical: 8.0,
                  ),
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: dotColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
            const Divider(height: 24, color: AppColors.darkGreen),
            child,
          ],
        ),
      ),
    );
  }

  Widget _buildTextField(
    String label,
    String hint, {
    bool isRequired = false,
    String? prefixText,
    IconData? prefixIcon,
    TextEditingController? controller,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
            if (isRequired)
              const Text(
                " *",
                style: TextStyle(color: Colors.red, fontSize: 12),
              ),
          ],
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 35,
          child: TextField(
            controller: controller,
            style: const TextStyle(fontSize: 13),
            textAlignVertical: TextAlignVertical.center,
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              hintText: hint,
              prefixIcon: (prefixIcon != null || prefixText != null)
                  ? Container(
                      margin: const EdgeInsets.only(right: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: AppColors.sidebarText.withValues(alpha: 0.1),
                        border: Border(
                          right: BorderSide(
                            color: AppColors.sidebarBg,
                            width: 0.5,
                          ),
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (prefixIcon != null)
                            Icon(
                              prefixIcon,
                              size: 16,
                              color: AppColors.textMuted,
                            )
                          else if (prefixText != null)
                            Text(
                              prefixText,
                              style: const TextStyle(
                                fontSize: 13,
                                color: AppColors.textMuted,
                              ),
                            ),
                        ],
                      ),
                    )
                  : null,
              prefixIconConstraints: const BoxConstraints(
                minWidth: 0,
                minHeight: 0,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(9),
                borderSide: const BorderSide(
                  color: AppColors.sidebarBg,
                  width: 0.5,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(9),
                borderSide: const BorderSide(
                  color: AppColors.darkGreen,
                  width: 1,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPreviewCard() {
    String displayName = _nameController.text.isEmpty
        ? "New Zamindar"
        : _nameController.text;
    String udharText = _udhaarController.text.isEmpty
        ? "0"
        : _udhaarController.text;

    String initials = displayName
        .split(' ')
        .where((element) => element.isNotEmpty)
        .map((e) => e[0].toUpperCase())
        .take(2)
        .join();

    String landDisplay = _landController.text.isEmpty
        ? "Not set"
        : "${_landController.text} $_selectedLandUnit";

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.darkGreen,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "PROFILE PREVIEW",
            style: TextStyle(
              color: Colors.white70,
              fontSize: 10,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 5),
          CircleAvatar(
            radius: 23,
            backgroundColor: AppColors.border,
            child: CircleAvatar(
              radius: 22,
              backgroundColor: AppColors.sidebarActive,
              child: Text(
                initials,
                style: const TextStyle(color: Colors.white, fontSize: 20),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            displayName,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            _phoneController.text.isEmpty
                ? "+92 300-0000000"
                : "+92 ${_phoneController.text}",
            style: TextStyle(color: AppColors.sidebarText, fontSize: 12),
          ),
          if (_villageController.text.isNotEmpty)
            Text(
              _villageController.text,
              style: TextStyle(color: AppColors.sidebarText, fontSize: 11),
            ),
          SizedBox(
            width: 210,
            child: Divider(
              height: 22,
              color: Colors.white.withValues(alpha: 0.2),
              thickness: 0.5,
            ),
          ),
          _previewRow("Land Area", landDisplay),
          _previewRow("Credit limit", "Rs $udharText"),
          _previewRow("Payment Terms", _selectedTerm),
          _previewRow("Seasons", selectedSeasons.join(" · ")),
          _buildPreviewPillRow("Crops", selectedCrops),
          const SizedBox(height: 10),
          _previewRow("Kissans", "Add after saving"),
        ],
      ),
    );
  }

  Widget _previewRow(String label, String value) {
    return SizedBox(
      width: 180,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              "$label:",
              style: const TextStyle(
                color: AppColors.sidebarText,
                fontSize: 12,
              ),
            ),
            Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreviewPillRow(String label, List<String> items) {
    return SizedBox(
      width: 180,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4.0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.sidebarText,
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              width: 120,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Wrap(
                    spacing: 4.0,
                    runSpacing: 2.0,
                    children: items
                        .map((item) => _buildSmallPreviewPill(item))
                        .toList(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSmallPreviewPill(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.mediumDarkGreen,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.normal,
          color: AppColors.lightGreenAccent,
        ),
      ),
    );
  }

  Widget _buildAmountPill(String amount, TextEditingController controller) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        onTap: () {
          controller.text = amount.replaceAll("Rs ", "").replaceAll(",", "");
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppColors.sidebarBg, width: 0.5),
          ),
          child: Text(
            amount,
            style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
          ),
        ),
      ),
    );
  }

  Widget _buildDropdownField(
    String label,
    String value,
    List<String> options,
    ValueChanged<String?> onChanged,
  ) {
    double customHeight = 45;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
        ),
        const SizedBox(height: 2),
        SizedBox(
          height: customHeight,
          child: DropdownButtonFormField<String>(
            initialValue: value,
            isExpanded: true,
            icon: const Icon(
              Icons.keyboard_arrow_down,
              size: 20,
              color: AppColors.textMuted,
            ),
            style: const TextStyle(fontSize: 13, color: Colors.black),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(9),
                borderSide: const BorderSide(
                  color: AppColors.sidebarBg,
                  width: 0.5,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(9),
                borderSide: const BorderSide(
                  color: AppColors.darkGreen,
                  width: 1,
                ),
              ),
            ),
            items: options.map((String val) {
              return DropdownMenuItem<String>(value: val, child: Text(val));
            }).toList(),
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}
