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
`software.pep.notifier_1.1.1_iphoneos-arm64.deb` as artifacts.

## Native jailbreak background engine

The pEp application executable has a headless startup mode that uses the same
`MessageModel`, Pantomime, and pEp engine code as its GUI mode. The Debian
package installs one launchd wrapper that starts that exact executable with the
headless mode enabled. It contains no second executable, no second IMAP client,
and never exports pEp's account passwords.

pEp's GUI and headless host serialize ownership of the shared app-group store.
Launching the GUI makes the daemon commit and exit before the app initializes;
terminating the GUI releases ownership back to launchd. New messages are parsed,
stored, decrypted, and synchronized by pEp's normal model stack. Because the
headless engine is the real `software.pEp.mail` application executable, it
submits sender and subject through `UNUserNotificationCenter.current()` using
pEp's normal notification authorization and identity. It does not impersonate
the app or inject into SpringBoard.

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
process. The 1.1.1 package deliberately leaves `software.pep.notifier`
unloaded after installation for the foreground test. Enable it only after
foreground persistence is confirmed.

## License

The build glue in this repository is GPL-3.0-or-later. Upstream components keep
their respective licenses.
