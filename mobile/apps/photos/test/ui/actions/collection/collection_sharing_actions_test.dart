import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:photos/gateways/collections/models/create_request.dart';
import 'package:photos/models/api/collection/user.dart';
import 'package:photos/models/collection/collection.dart';
import 'package:photos/models/file/file.dart';
import 'package:photos/gateways/collections/models/public_url.dart';
import 'package:photos/services/collections_service.dart';
import 'package:photos/ui/actions/collection/collection_sharing_actions.dart';

enum _ShareUrlOutcome { error, missingUrl, created }

void main() {
  for (final outcome in _ShareUrlOutcome.values) {
    testWidgets(
      switch (outcome) {
        _ShareUrlOutcome.error =>
          'failed quick-link creation removes the album',
        _ShareUrlOutcome.missingUrl =>
          'quick link without a URL removes the album',
        _ShareUrlOutcome.created => 'created quick link keeps the album',
      },
      (tester) async {
        final collection = Collection(
          42,
          User(id: 1, email: 'owner@example.com'),
          '',
          null,
          'Quick link',
          null,
          null,
          CollectionType.album,
          CollectionAttributes(),
          [],
          [],
          1,
        );
        final collectionsService = _FakeCollectionsService(
          collection,
          outcome: outcome,
        );
        final actions = _RecordingCollectionActions(
          collectionsService,
          createRequest: (_, {required visibility, required subType}) async =>
              CreateRequest(
                encryptedKey: '',
                keyDecryptionNonce: '',
                encryptedName: '',
                nameDecryptionNonce: '',
                type: CollectionType.album,
              ),
        );
        late BuildContext context;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (value) {
                context = value;
                return const SizedBox.shrink();
              },
            ),
          ),
        );

        final resultFuture = actions.createSharedCollectionLink(context, [
          EnteFile()..creationTime = 1700000000000000,
        ]);
        await tester.pumpWidget(const SizedBox.shrink());
        collectionsService.allowCreation.complete();
        final result = await resultFuture;

        expect(
          result,
          outcome == _ShareUrlOutcome.created ? same(collection) : isNull,
        );
        expect(
          actions.removedCollection,
          outcome == _ShareUrlOutcome.created ? isNull : same(collection),
        );
      },
    );
  }
}

class _RecordingCollectionActions extends CollectionActions {
  _RecordingCollectionActions(
    super.collectionsService, {
    required super.createRequest,
  });

  Collection? removedCollection;

  @override
  Future<void> trashCollectionKeepingPhotos(Collection collection) async {
    removedCollection = collection;
  }
}

class _FakeCollectionsService extends Mock implements CollectionsService {
  _FakeCollectionsService(this.collection, {required this.outcome});

  final Collection collection;
  final _ShareUrlOutcome outcome;
  final allowCreation = Completer<void>();

  @override
  Future<Collection> createAndCacheCollection(CreateRequest request) async {
    await allowCreation.future;
    return collection;
  }

  @override
  Future<void> addOrCopyToCollection(
    int collectionID,
    List<EnteFile> files, {
    bool toCopy = true,
  }) async {}

  @override
  Future<void> createShareUrl(
    Collection collection, {
    bool enableCollect = false,
    bool enableJoin = false,
  }) async {
    if (outcome == _ShareUrlOutcome.error) {
      throw StateError('URL creation failed');
    }
    if (outcome == _ShareUrlOutcome.created) {
      collection.publicURLs.add(
        PublicURL(
          url: 'https://albums.ente.com/?t=test',
          deviceLimit: 0,
          validTill: 0,
        ),
      );
    }
  }
}
