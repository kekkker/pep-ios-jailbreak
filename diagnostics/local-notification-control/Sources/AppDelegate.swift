import UIKit
import UserNotifications

@main
final class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = self

        let viewController = NotificationControlViewController(notificationCenter: notificationCenter)
        let navigationController = UINavigationController(rootViewController: viewController)

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = navigationController
        window.makeKeyAndVisible()
        self.window = window

        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
private final class NotificationControlViewController: UIViewController {
    private enum DeliveryMode {
        case immediate
        case oneSecondTimer

        var buttonTitle: String {
            switch self {
            case .immediate:
                return "Immediate — trigger: nil"
            case .oneSecondTimer:
                return "1-second Timer — time interval"
            }
        }

        var identifierComponent: String {
            switch self {
            case .immediate:
                return "immediate"
            case .oneSecondTimer:
                return "timer-1s"
            }
        }

        var notificationLabel: String {
            switch self {
            case .immediate:
                return "Immediate (trigger: nil)"
            case .oneSecondTimer:
                return "1-second timer"
            }
        }

        var trigger: UNNotificationTrigger? {
            switch self {
            case .immediate:
                return nil
            case .oneSecondTimer:
                return UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            }
        }
    }

    private let notificationCenter: UNUserNotificationCenter

    private let authorizationLabel = NotificationControlViewController.makeBodyLabel()
    private let submissionLabel = NotificationControlViewController.makeBodyLabel()
    private let identifierLabel = NotificationControlViewController.makeIdentifierLabel()
    private lazy var immediateButton = makeButton(
        title: DeliveryMode.immediate.buttonTitle,
        color: .systemBlue,
        action: #selector(sendImmediateNotification)
    )
    private lazy var timerButton = makeButton(
        title: DeliveryMode.oneSecondTimer.buttonTitle,
        color: .systemOrange,
        action: #selector(sendTimerNotification)
    )

    init(notificationCenter: UNUserNotificationCenter) {
        self.notificationCenter = notificationCenter
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "Notification Control"
        view.backgroundColor = .systemBackground
        configureInterface()
        setNotificationButtonsEnabled(false)
        requestAuthorization()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        refreshAuthorizationStatus()
    }

    @objc
    private func sendImmediateNotification() {
        submitNotification(mode: .immediate)
    }

    @objc
    private func sendTimerNotification() {
        submitNotification(mode: .oneSecondTimer)
    }

    private func configureInterface() {
        let heading = UILabel()
        heading.font = .preferredFont(forTextStyle: .title2)
        heading.adjustsFontForContentSizeCategory = true
        heading.numberOfLines = 0
        heading.text = "Compare two normal local notifications"

        let explanation = Self.makeBodyLabel()
        explanation.textColor = .secondaryLabel
        explanation.text = """
        Both buttons use this app identity, active interruption level, default sound, and a unique request identifier. Only the trigger mechanism changes.
        """

        authorizationLabel.text = "Authorization: checking…"
        submissionLabel.text = "Submission: none yet"
        identifierLabel.text = "Identifier: —"

        let stack = UIStackView(arrangedSubviews: [
            heading,
            explanation,
            authorizationLabel,
            immediateButton,
            timerButton,
            submissionLabel,
            identifierLabel
        ])
        stack.axis = .vertical
        stack.spacing = 16
        stack.setCustomSpacing(24, after: authorizationLabel)
        stack.setCustomSpacing(24, after: timerButton)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = UIScrollView()
        scrollView.alwaysBounceVertical = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -40),

            immediateButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 54),
            timerButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 54)
        ])
    }

    private func requestAuthorization() {
        authorizationLabel.text = "Authorization: requesting alerts and sounds…"

        notificationCenter.requestAuthorization(options: [.alert, .sound]) { [weak self] _, error in
            DispatchQueue.main.async {
                if let error {
                    self?.authorizationLabel.text = "Authorization request failed: \(error.localizedDescription)"
                    self?.setNotificationButtonsEnabled(false)
                } else {
                    self?.refreshAuthorizationStatus()
                }
            }
        }
    }

    private func refreshAuthorizationStatus() {
        notificationCenter.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }

                switch settings.authorizationStatus {
                case .authorized:
                    self.authorizationLabel.text = "Authorization: allowed"
                    self.setNotificationButtonsEnabled(true)
                case .provisional:
                    self.authorizationLabel.text = "Authorization: provisional"
                    self.setNotificationButtonsEnabled(true)
                case .ephemeral:
                    self.authorizationLabel.text = "Authorization: ephemeral"
                    self.setNotificationButtonsEnabled(true)
                case .denied:
                    self.authorizationLabel.text = "Authorization: denied — enable notifications in Settings"
                    self.setNotificationButtonsEnabled(false)
                case .notDetermined:
                    self.authorizationLabel.text = "Authorization: waiting for a decision…"
                    self.setNotificationButtonsEnabled(false)
                @unknown default:
                    self.authorizationLabel.text = "Authorization: unknown"
                    self.setNotificationButtonsEnabled(false)
                }
            }
        }
    }

    private func submitNotification(mode: DeliveryMode) {
        let milliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        let identifier = [
            "local-notification-control",
            mode.identifierComponent,
            String(milliseconds),
            UUID().uuidString.lowercased()
        ].joined(separator: ".")

        let content = UNMutableNotificationContent()
        content.title = "Local notification control"
        content.subtitle = mode.notificationLabel
        content.body = "Request \(identifier)"
        content.sound = .default
        content.interruptionLevel = .active
        content.userInfo = [
            "controlMode": mode.identifierComponent,
            "requestIdentifier": identifier
        ]

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: mode.trigger
        )

        submissionLabel.text = "Submission: sending \(mode.notificationLabel)…"
        identifierLabel.text = "Identifier: \(identifier)"

        notificationCenter.add(request) { [weak self] error in
            DispatchQueue.main.async {
                if let error {
                    self?.submissionLabel.text = "Submission: failed — \(error.localizedDescription)"
                } else {
                    self?.submissionLabel.text = "Submission: accepted — \(mode.notificationLabel)"
                }
            }
        }
    }

    private func setNotificationButtonsEnabled(_ enabled: Bool) {
        immediateButton.isEnabled = enabled
        timerButton.isEnabled = enabled
    }

    private func makeButton(title: String, color: UIColor, action: Selector) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.baseBackgroundColor = color
        configuration.cornerStyle = .medium

        let button = UIButton(configuration: configuration)
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private static func makeBodyLabel() -> UILabel {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        return label
    }

    private static func makeIdentifierLabel() -> UILabel {
        let label = UILabel()
        label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.lineBreakMode = .byCharWrapping
        label.textColor = .secondaryLabel
        return label
    }
}
