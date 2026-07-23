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
`software.pep.notifier_1.0.8_iphoneos-arm64.deb` as artifacts.

## Native jailbreak background engine

The IPA contains a small headless executable linked to the same
`MessageModel.framework`, `PantomimeFramework.framework`, and pEp engine
frameworks as the GUI. The Debian package installs launchd wrappers for that
mail engine and a tiny notification poster linked only to system frameworks. It
contains no second IMAP client and never exports pEp's account passwords.

pEp's GUI and headless host serialize ownership of the shared app-group store.
Launching the GUI makes the daemon commit and exit before the app initializes;
terminating the GUI releases ownership back to launchd. New messages are parsed,
stored, decrypted, and synchronized by pEp's normal model stack. The
headless host queues sender and subject in the pEp app group. A separately
entitled poster creates a user-notification connection explicitly scoped to
`software.pEp.mail`, then submits unique requests to `usernotificationsd`.
Failed requests remain queued. This uses pEp's existing notification
authorization and does not inject into SpringBoard.

Upstream pEp has its broken IMAP IDLE path disabled and currently polls using
its own replication service, normally every ten seconds.

## License

The build glue in this repository is GPL-3.0-or-later. Upstream components keep
their respective licenses.
