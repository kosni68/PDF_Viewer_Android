import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:signature/signature.dart';

class SignatureCaptureService {
  const SignatureCaptureService();

  Future<Uint8List?> captureSignature(BuildContext context) {
    return showModalBottomSheet<Uint8List>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => const _SignatureCaptureSheet(),
    );
  }
}

class _SignatureCaptureSheet extends StatefulWidget {
  const _SignatureCaptureSheet();

  @override
  State<_SignatureCaptureSheet> createState() => _SignatureCaptureSheetState();
}

class _SignatureCaptureSheetState extends State<_SignatureCaptureSheet> {
  late final SignatureController _controller;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _controller = SignatureController(
      penStrokeWidth: 3.6,
      penColor: Colors.black,
      exportBackgroundColor: Colors.transparent,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_controller.isEmpty || _isSaving) {
      return;
    }

    setState(() => _isSaving = true);
    final bytes = await _controller.toPngBytes();
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop(bytes);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: 20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Ajouter une signature',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Dessinez votre signature, puis enregistrez-la dans la page.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          Container(
            height: 260,
            width: double.infinity,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Signature(
              controller: _controller,
              backgroundColor: Colors.transparent,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              OutlinedButton.icon(
                onPressed: () {
                  _controller.clear();
                  setState(() {});
                },
                icon: const Icon(Icons.restart_alt_rounded),
                label: const Text('Effacer'),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: _isSaving ? null : _submit,
                icon: _isSaving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check_rounded),
                label: const Text('Inserer'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
