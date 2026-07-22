# pEp for jailbroken iOS 16

This repository builds the GPLv3 `pEpForiOS` client from the official pEp
Codeberg sources. It is intended to produce an unsigned arm64 IPA for devices
where the owner supplies their own signing or jailbreak installation method.

The upstream application is currently unavailable from the App Store. Its
public build also references a private configuration-only framework. This
repository supplies a clean-room replacement containing public bundle and app
group identifiers, and deliberately leaves commercial OAuth credentials empty.

The build is pinned through upstream's own `.submodules.json` manifests. No
mail credentials, signing certificates, Apple accounts, or device secrets are
stored here.

## Build

Run the `Build unsigned IPA` GitHub Actions workflow. Successful builds upload
`pEp-iOS16-unsigned.ipa` as an artifact.

## License

The build glue in this repository is GPL-3.0-or-later. Upstream components keep
their respective licenses.
