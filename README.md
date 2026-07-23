# pEp for jailbroken iOS 16

This repository builds the GPLv3 `pEpForiOS` client from the official pEp
Codeberg sources. It produces an arm64 IPA fakesigned with the app-group
entitlement required by pEp, ready for installation with TrollStore.

The upstream application is currently unavailable from the App Store. Its
public build also references a private configuration-only framework. This
repository supplies a clean-room replacement containing public bundle and app
group identifiers, and deliberately leaves commercial OAuth credentials empty.

The build is pinned through upstream's own `.submodules.json` manifests. No
mail credentials, signing certificates, Apple accounts, or device secrets are
stored here.

## Build

Run the `Build TrollStore IPA` GitHub Actions workflow. Successful builds upload
`pEp-iOS16-trollstore.ipa` and
`software.pep.notifier_1.1.12_iphoneos-arm64.deb` as artifacts.

## Native jailbreak background engine

The pEp application executable has a headless startup mode that uses the same
`MessageModel`, Pantomime, and pEp engine code as its GUI mode. The Debian
package installs one launchd wrapper that starts that exact executable with the
headless mode enabled. It contains no second executable, no second IMAP client,
and never exports pEp's account passwords.

pEp's GUI and headless host serialize ownership of the shared app-group store.
Launching the GUI makes the daemon commit and exit before the app initializes;
terminating the GUI releases ownership back to launchd. New messages are parsed,
stored, decrypted, and synchronized by pEp's normal model stack.

The headless process does not call `UNUserNotificationCenter` directly. It
atomically queues sender and subject in pEp's app-group container, then sends a
real UIKit background-fetch action through FrontBoard to
`software.pEp.mail`. The system-managed background launch submits the local
notification and answers the fetch action without initializing the mail model
or UI. This preserves pEp's own notification identity without fabricating a
notification tap response, which can corrupt SpringBoard's notification-list
reconciliation on lock and unlock.

Upstream pEp has its broken IMAP IDLE path disabled and currently polls using
its own replication service, normally every ten seconds.

## Notification persistence baseline

The final `preserve-delivered-notifications.patch` overlay keeps notification
testing free of app-initiated removal:

- pEp's badge reset is a logged no-op. This covers both launch and
  `applicationDidBecomeActive`, which can run while opening or closing
  Notification Center.
- The obsolete headless migration no longer removes pending or delivered
  requests.
- Automatic launch canaries are suppressed; use **Settings → Test
  Notifications** for one controlled foreground request.
- Foreground and headless requests use unique identifiers, and successful
  submission/presentation logs include the identifier.

Restart SpringBoard before interpreting a test from this build. Deleting the
old injected bridge from disk does not unload it from the existing SpringBoard
process. The baseline package deliberately leaves `software.pep.notifier`
unloaded after installation for the foreground test. Enable it only after
foreground persistence is confirmed.

Version 1.1.4 also addresses the `0xdead10cc` RunningBoard termination found
during the foreground test. pEp previously started asynchronous cleanup while
entering the background and was suspended with a Core Data/SQLite lock. It now
stops mail services, commits the session, and exits the GUI process cleanly
before iOS can suspend it. This deterministically releases the database lock;
launchd can then transfer mail ownership to the headless mode. Notification
requests use a one-second nonrepeating timer so iOS 16 archives an explicit
`UNNotificationTriggerType`, and they do not mutate or present a badge.

Version 1.1.5 replaces daemon-side notification submission with the
system-managed delivery launch described above. Sender and subject remain in
the notification, queued messages are retried, and the daemon still uses pEp's
single built-in mail engine.

Version 1.1.6 exits the short-lived delivery launch synchronously after
acknowledging the notification response. This prevents RunningBoard from
suspending it before cleanup and ensures later messages start a fresh delivery
cycle.

Version 1.1.7 removes the unnecessary post-submission grace period. Once
`UNUserNotificationCenter` accepts a local request, iOS owns its timer and the
delivery process can acknowledge the launch and exit immediately.

Version 1.1.8 retains the old system notification launcher for the lifetime of
the headless engine. Its internal cleanup queue could outlive a launch
completion, so releasing a per-message launcher risked a dangling Objective-C
callback.

Version 1.1.9 keeps the messages currently shown by a filter in the detail
carousel. Opening an unread message can therefore mark it read without
immediately replacing its content with the next unread message.

Version 1.1.10 replaces the fabricated notification-response launch with the
real `UIFetchContentInBackgroundAction` payload used by UIKit on iOS 16.3.
The pEp app handles that request through
`application(_:performFetchWithCompletionHandler:)`; no fake notification or
notification-center action is created.

Version 1.1.11 removes `platform-application` and unlimited-background
entitlements from the pEp GUI. The headless mode retains only the narrow
FrontBoard launch entitlement. On iOS 16.3, SpringBoard's lock reconciliation
discarded the entire visible notification list whenever it encountered a local
notification owned by the platform-signed GUI, even though usernotificationsd
kept the delivered request intact. A one-time pEp-only migration removes those
stale platform-owner requests before the first non-platform delivery.

Version 1.1.12 submits queued mail notifications as immediate local requests
with a `nil` trigger. This removes the one-second timer's `RequestDate` and
`TimeInterval` trigger metadata while retaining the real UIKit background-fetch
launch, non-platform app identity, notification content, and destinations.

## License

The build glue in this repository is GPL-3.0-or-later. Upstream components keep
their respective licenses.
