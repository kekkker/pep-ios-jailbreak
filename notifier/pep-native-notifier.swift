import Darwin
import Foundation
import MessageModel
import UserNotifications

@_silgen_name("notify_register_check")
private func systemNotifyRegisterCheck(
    _ name: UnsafePointer<CChar>,
    _ token: UnsafeMutablePointer<Int32>) -> UInt32

@_silgen_name("notify_check")
private func systemNotifyCheck(
    _ token: Int32,
    _ changed: UnsafeMutablePointer<Int32>) -> UInt32

@_silgen_name("notify_post")
private func systemNotifyPost(_ name: UnsafePointer<CChar>) -> UInt32

private let appGroupIdentifier = "group.software.pEp"
private let newMessageNotification = Notification.Name("pEpNewInboxMessagePersisted")
private let takeoverNotification = "software.pep.native-notifier.takeover"
private let newBulletinNotification = "software.pep.notifier.new-bulletin"

private func log(_ message: String) {
    FileHandle.standardError.write(Data(("pep-native-notifier: \(message)\n").utf8))
}

private func cleaned(_ value: String?, fallback: String, limit: Int) -> String {
    let result = (value ?? "")
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
    return String((result.isEmpty ? fallback : result).prefix(limit))
}

private final class HeadlessProviders:
    CNContactsAccessPermissionProviderProtocol,
    EncryptionErrorDelegate,
    KeySyncStateProvider,
    PassphraseProviderProtocol,
    UsePEPFolderProviderProtocol {

    private let defaults: UserDefaults

    var stateChangeHandler: ((Bool) -> Void)?

    init() {
        defaults = UserDefaults(suiteName: appGroupIdentifier) ?? .standard
        defaults.register(defaults: [
            "keyStartpEpSync": true,
            "keyUsePEPFolderEnabled": true,
            "keyUnencryptedSubjectEnabled": false,
            "keyPassiveMode": false,
            "keyUserHasBeenAskedForContactAccessPermissions": false
        ])
    }

    var isKeySyncEnabled: Bool {
        defaults.bool(forKey: "keyStartpEpSync")
    }

    var usePepFolder: Bool {
        defaults.bool(forKey: "keyUsePEPFolderEnabled")
    }

    var userHasBeenAskedForContactAccessPermissions: Bool {
        defaults.bool(forKey: "keyUserHasBeenAskedForContactAccessPermissions")
    }

    func applyEngineSettings() {
        MessageModelConfig.setUnEncryptedSubjectEnabled(
            defaults.bool(forKey: "keyUnencryptedSubjectEnabled"))
        MessageModelConfig.setPassiveModeEnabled(
            defaults.bool(forKey: "keyPassiveMode"))
    }

    func showEnterPassphrase(triggeredWhilePEPSync: Bool,
                             completion: @escaping (String?) -> Void) {
        completion(nil)
    }

    func showWrongPassphrase(completion: @escaping (String?) -> Void) {
        completion(nil)
    }

    func showPassphraseTooLong(completion: @escaping (String?) -> Void) {
        completion(nil)
    }

    func handleCouldNotEncrypt(completion: @escaping (Bool) -> Void) {
        // Never silently send unencrypted mail from a headless process.
        completion(false)
    }
}

private final class NativeNotifier {
    private let providers = HeadlessProviders()
    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "software.pep.native-notifier.bulletins")
    private let notificationCenter = UNUserNotificationCenter.current()
    private var bulletinQueueURL: URL?
    private var lockFileDescriptor: Int32 = -1
    private var takeoverToken: Int32 = 0
    private var takeoverTimer: Timer?
    private var newMailObserver: NSObjectProtocol?
    private var service: MessageModelService?
    private var isStopping = false

    func run() -> Never {
        setenv("PEP_HEADLESS_NOTIFIER", "1", 1)
        registerForTakeover()
        acquireMailEngineOwnership()

        providers.applyEngineSettings()
        newMailObserver = NotificationCenter.default.addObserver(
            forName: newMessageNotification,
            object: nil,
            queue: nil) { [weak self] notification in
                let sender = notification.userInfo?["sender"] as? String
                let subject = notification.userInfo?["subject"] as? String
                self?.queueBulletin(sender: sender, subject: subject)
            }

        let modelService = MessageModelService(
            cnContactsAccessPermissionProvider: providers,
            keySyncStateProvider: providers,
            usePEPFolderProvider: providers,
            passphraseProvider: providers,
            encryptionErrorDelegate: providers)
        service = modelService
        modelService.start()
        startTakeoverTimer()
        notificationCenter.getNotificationSettings { settings in
            log("native notification authorization status \(settings.authorizationStatus.rawValue)")
        }
        log("pEp MessageModel started")

        RunLoop.main.run()
        fatalError("main run loop unexpectedly returned")
    }

    private func registerForTakeover() {
        let status = takeoverNotification.withCString {
            systemNotifyRegisterCheck($0, &takeoverToken)
        }
        guard status == 0 else {
            log("failed to register GUI takeover notification")
            exit(70)
        }
        var ignored: Int32 = 0
        systemNotifyCheck(takeoverToken, &ignored)
    }

    private func acquireMailEngineOwnership() {
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            log("app-group container unavailable")
            exit(71)
        }

        let queueURL = container
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("software.pep.notifier", isDirectory: true)
            .appendingPathComponent("queue", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: queueURL,
                withIntermediateDirectories: true)
            bulletinQueueURL = queueURL
        } catch {
            log("unable to create app-group bulletin queue: \(error.localizedDescription)")
            exit(74)
        }

        let lockURL = container.appendingPathComponent("pep-mail-engine.lock")
        lockFileDescriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockFileDescriptor >= 0 else {
            log("unable to open ownership lock (errno \(errno))")
            exit(72)
        }

        while flock(lockFileDescriptor, LOCK_EX | LOCK_NB) != 0 {
            if errno != EWOULDBLOCK && errno != EAGAIN && errno != EINTR {
                log("unable to acquire ownership lock (errno \(errno))")
                exit(73)
            }
            if takeoverWasRequested() {
                log("GUI owns mail engine; waiting for next launchd restart")
                exit(0)
            }
            usleep(250_000)
        }

        if takeoverWasRequested() {
            log("GUI requested ownership during startup")
            exit(0)
        }
    }

    private func startTakeoverTimer() {
        takeoverTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) {
            [weak self] _ in
            guard let self = self, self.takeoverWasRequested() else {
                return
            }
            self.stopForGUI()
        }
    }

    private func takeoverWasRequested() -> Bool {
        var changed: Int32 = 0
        guard systemNotifyCheck(takeoverToken, &changed) == 0 else {
            return false
        }
        return changed != 0
    }

    private func stopForGUI() {
        guard !isStopping else {
            return
        }
        isStopping = true
        log("handing pEp MessageModel ownership to GUI")
        takeoverTimer?.invalidate()
        service?.stop()
        Session.main.commit()
        usleep(250_000)
        exit(0)
    }

    private func queueBulletin(sender: String?, subject: String?) {
        let title = cleaned(sender, fallback: "New email", limit: 180)
        let message = cleaned(subject, fallback: "(No subject)", limit: 500)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = .default
        content.interruptionLevel = .active
        let request = UNNotificationRequest(
            identifier: "pep-mail-\(UUID().uuidString)",
            content: content,
            trigger: nil)

        notificationCenter.add(request) { [weak self] error in
            if let error {
                log("native notification failed: \(error.localizedDescription); using bridge")
                self?.queueBridgeBulletin(title: title, message: message)
            } else {
                log("posted persistent native iOS notification")
            }
        }
    }

    private func queueBridgeBulletin(title: String, message: String) {
        queue.async { [weak self] in
            do {
                guard let self, let queueURL = self.bulletinQueueURL else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let payload: [String: String] = [
                    "title": title,
                    "message": message,
                    "bundle_id": "software.pEp.mail"
                ]
                let payloadData = try PropertyListSerialization.data(
                    fromPropertyList: payload,
                    format: .binary,
                    options: 0)
                let bulletinURL = queueURL
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("plist")
                try payloadData.write(to: bulletinURL, options: .atomic)
                let status = newBulletinNotification.withCString {
                    systemNotifyPost($0)
                }
                guard status == 0 else {
                    throw CocoaError(.fileWriteUnknown)
                }
                log("queued bulletin from pEp MessageModel")
            } catch {
                log("unable to queue bulletin: \(error.localizedDescription)")
            }
        }
    }
}

NativeNotifier().run()
