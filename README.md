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
`software.pep.notifier_1.0.4_iphoneos-arm64.deb` as artifacts.

## Native jailbreak background engine

The IPA contains a small headless executable linked to the same
`MessageModel.framework`, `PantomimeFramework.framework`, and pEp engine
frameworks as the GUI. The Debian package installs only a launchd wrapper and a
SpringBoard bulletin bridge. The sandboxed pEp host writes parsed notification
payloads to its existing app-group container, which the bridge drains through a
package-managed link. It contains no second IMAP client and never exports pEp's
account passwords.

pEp's GUI and headless host serialize ownership of the shared app-group store.
Launching the GUI makes the daemon commit and exit before the app initializes;
terminating the GUI releases ownership back to launchd. New messages are parsed,
stored, decrypted, and synchronized by pEp's normal model stack, then the bridge
shows sender and subject through Limneos `libbulletin`.

The native package depends only on `net.limneos.libbulletin`. Upstream pEp has
its broken IMAP IDLE path disabled and currently polls using its own replication
service, normally every ten seconds.

## License

The build glue in this repository is GPL-3.0-or-later. Upstream components keep
their respective licenses.
