import "dart:async";

// ignore: depend_on_referenced_packages
import "package:firebase_core_platform_interface/firebase_core_platform_interface.dart";
import "package:firebase_messaging/firebase_messaging.dart";
import "package:flutter_test/flutter_test.dart";
import "package:photos/services/push_service.dart";
import "package:photos/utils/bg_task_utils.dart";
import "package:workmanager/workmanager.dart";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Firebase firebase;
  late _Workmanager workmanager;

  setUp(() {
    firebase = _Firebase();
    workmanager = _Workmanager();
    FirebasePlatform.instance = firebase;
    WorkmanagerPlatform.instance = workmanager;
  });

  test("push uses the normal Android background refresh behavior", () {
    const pushTask = "io.ente.photos.androidPushRefresh";
    expect(BgTaskUtils.isRefreshTask(pushTask), isTrue);
    expect(BgTaskUtils.allowsImageIndexing(pushTask), isTrue);
    expect(
      BgTaskUtils.taskTimeoutFor(pushTask),
      BgTaskUtils.taskTimeoutFor(BgTaskUtils.androidPeriodicTask),
    );
  });

  test("ignores background messages without a sync action", () async {
    await handleAndroidBackgroundPush(const RemoteMessage());
    await handleAndroidBackgroundPush(
      const RemoteMessage(data: {"action": "unknown"}),
    );
    expect(firebase.initializations, 0);
    expect(workmanager.jobs, isEmpty);
  });

  test(
    "awaits a connected one-off refresh with the keep policy",
    () async {
      final scheduled = Completer<void>();
      workmanager.scheduled = scheduled;
      var completed = false;
      final handling = handleAndroidBackgroundPush(
        const RemoteMessage(data: {"action": "sync"}),
      ).then((_) => completed = true);
      await pumpEventQueue();
      expect(firebase.initializations, 1);
      expect(workmanager.initialized, isTrue);
      expect(workmanager.jobs, ["io.ente.photos.androidPushRefresh"]);
      expect(workmanager.constraints!.networkType, NetworkType.connected);
      expect(workmanager.policy, ExistingWorkPolicy.keep);
      expect(completed, isFalse);
      scheduled.complete();
      await handling;
      expect(completed, isTrue);
    },
  );

  test(
    "propagates scheduling failure instead of reporting completion",
    () async {
      workmanager.error = StateError("scheduler unavailable");
      await expectLater(
        handleAndroidBackgroundPush(
          const RemoteMessage(data: {"action": "sync"}),
        ),
        throwsStateError,
      );
    },
  );
}

class _Firebase extends FirebasePlatform {
  int initializations = 0;

  @override
  Future<FirebaseAppPlatform> initializeApp({
    String? name,
    FirebaseOptions? options,
  }) async {
    initializations++;
    return FirebaseAppPlatform(
      "[DEFAULT]",
      const FirebaseOptions(
        apiKey: "test",
        appId: "test",
        messagingSenderId: "test",
        projectId: "test",
      ),
    );
  }
}

class _Workmanager extends WorkmanagerPlatform {
  bool initialized = false;
  final jobs = <String>[];
  Constraints? constraints;
  ExistingWorkPolicy? policy;
  Completer<void>? scheduled;
  Object? error;

  @override
  Future<void> initialize(
    Function callbackDispatcher, {
    bool isInDebugMode = false,
  }) async {
    initialized = true;
  }

  @override
  Future<void> registerOneOffTask(
    String uniqueName,
    String taskName, {
    Map<String, dynamic>? inputData,
    Duration? initialDelay,
    Constraints? constraints,
    ExistingWorkPolicy? existingWorkPolicy,
    BackoffPolicy? backoffPolicy,
    Duration? backoffPolicyDelay,
    String? tag,
    OutOfQuotaPolicy? outOfQuotaPolicy,
  }) async {
    jobs.add(taskName);
    this.constraints = constraints;
    policy = existingWorkPolicy;
    if (error != null) throw error!;
    await scheduled?.future;
  }
}
