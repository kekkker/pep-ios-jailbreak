# Local Notification Control

This is a standalone UIKit control app for comparing two ordinary local
notification requests on iOS 16:

- **Immediate** submits an `UNNotificationRequest` with `trigger: nil`.
- **1-second Timer** submits the same notification configuration with a
  non-repeating one-second `UNTimeIntervalNotificationTrigger`.

Both paths use a unique request identifier, active interruption level, and the
default sound. The screen reports notification authorization, submission
result, and the full identifier. Foreground presentation includes banner, list,
and sound so either path can be exercised without first leaving the app.

The app has bundle identifier `software.pEp.LocalNotificationControl`. It has
no entitlements, provisioning profile, app groups, background modes, or private
API use, so TrollStore can give it its normal non-platform identity.

## Build

Run on a Mac with Xcode:

```sh
./build.sh
```

The output location is:

```text
build/LocalNotificationControl-unsigned.ipa
```

The script targets arm64 iOS 16.0, uses the active Xcode iPhoneOS SDK, removes
any linker-generated ad-hoc signature, and packages a deliberately unsigned
IPA. Archive timestamps are normalized (and can be overridden with
`SOURCE_DATE_EPOCH`) so repeated builds with identical inputs and the same
Xcode toolchain are byte-for-byte reproducible. The IPA can then be signed with
plain `ldid -S` or passed through the usual TrollStore signing/install workflow.

## Comparison procedure

Grant alert and sound authorization, then submit one notification with each
button. The mode is visible in the notification subtitle and encoded in the
request identifier. Use real physical lock/unlock and Notification Center
interaction when evaluating whether either request survives SpringBoard
history reconciliation.
