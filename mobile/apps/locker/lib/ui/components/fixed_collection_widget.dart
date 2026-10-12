import 'package:ente_components/ente_components.dart';
import 'package:ente_strings/ente_strings.dart';
import 'package:flutter/material.dart';
import 'package:hugeicons/hugeicons.dart';
import 'package:locker/extensions/collection_extension.dart';
import 'package:locker/services/collections/models/collection.dart';

class FixedCollectionWidget extends StatelessWidget {
  const FixedCollectionWidget({super.key, required this.collection});

  final Collection collection;

  @override
  Widget build(BuildContext context) => MenuGroupComponent(
    items: [
      MenuComponent(
        title: collection.displayName ?? context.strings.unnamedCollection,
        titleMaxLines: 2,
        leading: const HugeIcon(icon: HugeIcons.strokeRoundedFolder01),
      ),
    ],
  );
}
