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
`software.pep.notifier_1.1.14_iphoneos-arm64.deb` as artifacts.

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
or UI. No notification-response object or user interaction is synthesized.

Upstream pEp has its broken IMAP IDLE path disabled and currently polls using
its own replication service, normally every ten seconds.

## Production notification behavior

The production path deliberately retains the queue and native background-fetch
bridge described above. Queued messages are retried, and the short UIKit launch
drains the queue through
`application(_:performFetchWithCompletionHandler:)`. Each mail notification is
submitted as an immediate local request with a `nil` trigger and a unique
identifier.

The application does not perform a migration or mass removal of pending or
delivered notifications. Successful submission and foreground presentation are
logged with their request identifiers. Automatic notification canaries are not
posted; **Settings → Test Notifications** provides one explicit foreground
test instead.

Badge resets remain temporarily suppressed so notification regression tests do
not mix badge changes with list-state changes. This is a controlled baseline,
not a claimed fix for Notification Center persistence.

The GUI is non-platform and does not have the unlimited-background entitlement.
It retains its app group and the narrow application-launch entitlement needed
by the delivery bridge. The GUI also stops mail services, commits its session,
and exits cleanly when transferring ownership to the headless process, avoiding
suspension while holding the shared Core Data/SQLite store.

## Confirmed Notification Center conflict

On the tested iPhone running iOS 16.3, the missing-history failure was caused by
Reo 3.1.2, a SpringBoard tweak that hooks the shared
`NCNotificationListView`. During a failure, pEp's request remained in
`DeliveredNotifications.plist` while SpringBoard removed its group, and
sometimes other applications' groups, from
`NotificationListPersistentState.json`. Disabling Reo made the same production
build survive real physical lock/unlock and Notification Center history checks.

This result does not attribute SpringBoard list corruption to pEp's local
request, its trigger metadata, its entitlements, or the delivery bridge.
Notification tweaks that modify the shared list should be disabled when
validating this build.

## Validation

The delivery path can be exercised without sending mail by placing a unique
payload in the app-group queue and invoking the native fetch launcher. A valid
run receives the FrontBoard response, drains the queue, and records the request
in pEp's delivered archive and SpringBoard's incoming list.

Automated lock commands do not reproduce the complete user interaction.
Notification changes must also pass repeated physical lock/unlock, reveal,
and dismissal cycles before they are considered validated.

## License

The build glue in this repository is GPL-3.0-or-later. Upstream components keep
their respective licenses.
