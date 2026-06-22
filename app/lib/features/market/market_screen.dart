import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class MarketScreen extends ConsumerWidget {
  const MarketScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Marktpreise')),
      body: const Center(
        child: Text('Cardmarket / eBay Aggregation folgt.'),
      ),
    );
  }
}
