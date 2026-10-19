import Flutter
import UIKit
import Firebase
import FirebaseMessaging
import home_widget
import workmanager

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    FirebaseApp.configure()

    // Enregistrer pour les notifications push
    UNUserNotificationCenter.current().delegate = self
    application.registerForRemoteNotifications()

    GeneratedPluginRegistrant.register(with: self)

    // Le moteur d'arrière-plan qui exécute l'appui sur un bouton de widget est
    // distinct de celui de l'app : sans ceci il démarrerait sans plugins, et le
    // rappel Dart échouerait au premier appel de canal.
    if #available(iOS 17, *) {
      HomeWidgetBackgroundWorker.setPluginRegistrantCallback { registry in
        GeneratedPluginRegistrant.register(with: registry)
      }
    }

    // Relevé périodique de Workmanager. iOS n'accepte l'enregistrement qu'avant
    // la fin du lancement, et sous un identifiant listé dans Info.plist.
    WorkmanagerPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    WorkmanagerPlugin.registerPeriodicTask(
      withIdentifier: "com.lixee.assist.deviceCheck",
      frequency: NSNumber(value: 15 * 60)
    )

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // Transmettre le token APNs à Firebase
  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    Messaging.messaging().apnsToken = deviceToken
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }
}
