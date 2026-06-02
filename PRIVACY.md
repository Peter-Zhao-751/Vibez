# Vibez - Privacy Policy

_Last updated: June 2, 2026_

Vibez is a personal focus app. You choose which of your own apps to shield, and
Vibez blocks them during focus sessions - including, optionally, when an AI
coding agent on your paired Mac finishes a task. This policy explains what data
the app handles and what stays on your device.

We collect as little as possible. The short version: **the apps you choose to
block never leave your device, we never read your Screen Time or app-usage
history, and the only thing stored on our side is a push token so notifications
can reach you.**

## What stays on your device (never sent to us)

- **The apps, categories, and websites you select to block.** These are stored
  by Apple's Screen Time system as opaque tokens. They are saved only on your
  device (and shared with the Vibez app extensions on the same device). We
  cannot see which apps you picked, and they are never transmitted off the
  device.
- **Your Screen Time / app-usage history.** Vibez does **not** use Apple's
  DeviceActivity framework and does not read, collect, or transmit how much you
  use any app. It only applies and removes the shield.
- **Your focus statistics** (focus time, number of triggers, most-blocked apps).
  These are computed and stored locally and are not sent to us.

## What is processed off your device

To deliver notifications, the following is processed by our service provider,
Google Firebase:

- **Push notification token.** Apple/Firebase issue a token that identifies your
  device for push delivery. We store it with your pairing ID so notifications
  reach the right phone.
- **Your Vibez pairing ID.** The four-word code (e.g. `moss-pine-fox-jazz`) you
  enter to link your Mac and phone. It is a random, user-chosen code and is not
  derived from your identity.
- **Notification content.** When your paired Mac sends a focus trigger, the
  notification it generates (such as a short task title) is relayed through
  Firebase and Apple Push Notification service to your device. It is delivered,
  not stored by us. Do not include sensitive information in content you ask the
  agent to surface.

We do **not** use analytics or crash-reporting SDKs, we do not show ads, we do
not track you across other apps or websites, and we do not sell your data.

## Service providers

- **Google Firebase** (Cloud Messaging, Cloud Functions) - push delivery and the
  backend that routes it. See Google's privacy policy:
  https://policies.google.com/privacy and Firebase's data handling:
  https://firebase.google.com/support/privacy
- **Apple Push Notification service** - delivery of notifications to your device.

## Data retention and deletion

We retain your push token and pairing ID only to route notifications. You can
remove this data at any time by unpairing in the app (which deletes the stored
token) or by emailing us at the address below to request deletion.

## Children

Vibez is a general-audience productivity app intended for the person using the
device to manage their own focus. It is not directed to children, and it is not
a parental-controls product for monitoring another person.

## Changes

We may update this policy as the app evolves. Material changes will be reflected
by the "Last updated" date above.

## Contact

Questions or deletion requests: **pzhaoothermail@gmail.com**
