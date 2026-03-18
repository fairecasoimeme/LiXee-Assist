# WorkManager
-keep class androidx.work.** { *; }
-keep class * extends androidx.work.Worker
-keep class * extends androidx.work.ListenableWorker {
    public <init>(android.content.Context, androidx.work.WorkerParameters);
}

# Flutter WorkManager plugin
-keep class be.tramckrijte.workmanager.** { *; }

# Firebase Core
-keep class com.google.firebase.** { *; }
-dontwarn com.google.firebase.**

# Firebase Messaging (FCM)
-keep class com.google.firebase.messaging.** { *; }
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.android.gms.**

# Flutter Local Notifications
-keep class com.dexterous.** { *; }

# Flutter Firebase plugins
-keep class io.flutter.plugins.firebase.** { *; }
