# Vibez - Complete App Store Connect submission copy

Every field App Store Connect asks for, with paste-ready text and character
counts. Limits confirmed for 2026. Fields marked **[you]** need your personal
info or a hosted URL.

---

## 1. App Name  (max 30)

Recommended (puts your two strongest search terms in the highest-weighted field):
```
Vibez: Focus & App Blocker
```
`26/30`

Alternatives:
- `Vibez` (clean brand only - weakest for search)
- `Vibez - Focus Mode` (18/30)

## 2. Subtitle  (max 30)

Recommended (adds "screen time" + "deep work" - terms NOT in the name, so no
wasted overlap):
```
Screen time for deep work
```
`25/30`

Alternatives:
- `Stay focused while AI works` (27/30)
- `Block apps, stay in flow` (24/30)

## 3. Promotional Text  (max 170, editable anytime without re-review)

```
Your AI coding agent just finished - instead of doomscrolling while it works, Vibez shields your distracting apps until you're back in the loop.
```
`144/170`

## 4. Description  (max 4000)

```
Vibez turns the dead time around your AI coding agent into focus time.

When Claude Code or Codex finishes a task - or stops to ask you something - it's
the exact moment you reach for Instagram, TikTok, or X "just for a second." Vibez
catches that moment. The instant your agent pings, it shields the apps you've
chosen, so the pause becomes a beat of focus instead of a 20-minute detour.

You're always in control. You pick which of your own apps to block using Apple's
Screen Time system, you decide how long the shield stays up, and you can turn it
on or off yourself anytime with a single toggle. Vibez never sees your browsing
history or how you use your apps - it only puts up (and takes down) the shield.

HOW IT WORKS
- Choose the apps you want out of your way during focus sessions.
- Pair your Mac and iPhone once with a simple four-word code.
- Install the lightweight Claude Code or Codex plugin on your Mac.
- When your agent finishes or needs input, your distracting apps lock behind a
  friendly shield screen - and lift automatically when the session resolves.

WHY IT'S DIFFERENT
- Built for the way developers actually work with AI agents.
- Block on autopilot (triggered by your agent) or manually whenever you want.
- A custom shield screen that tells you what your agent is waiting on.
- Your app selections stay private on your device - always.

NO ACCOUNT NEEDED
There's no sign-up and no password. Pairing is a four-word code, and that's it.

Vibez uses Apple's Family Controls / Screen Time APIs to shield the apps you
choose, on your own device, for your own focus. It is not a parental-controls or
device-management product.
```

## 5. Keywords  (max 100, comma-separated, NO spaces)

Deliberately avoids words already in the name/subtitle (focus, app, blocker,
screen, time, deep, work) so you don't waste the field:
```
distraction,productivity,flow,concentration,willpower,coding,claude,codex,study,habit,doomscroll
```
`96/100`

## 6. What's New in This Version  (for 1.0; optional on first release)

```
First release. Pair your Mac, pick your apps, and let Vibez keep you focused whenever your AI coding agent finishes a task or asks for input.
```

## 7. Categories
- **Primary:** Productivity  _(matches your Info.plist LSApplicationCategoryType)_
- **Secondary:** Utilities  _(or Health & Fitness if you want to lean into the digital-wellbeing angle)_

## 8. Copyright  **[you]**
```
2026 <your legal name or company>
```
_(Apple prepends the © automatically. Your Apple account shows "Jinhe" - use the
matching legal name or entity.)_

## 9. URLs  **[you]**
- **Privacy Policy URL** (required): host `docs/privacy-policy.md` publicly (GitHub
  Pages renders Markdown) and paste the URL.
- **Support URL** (required): a one-page site or public gist with a contact method.
- **Marketing URL** (optional): leave blank or link a landing page.

## 10. App Review Information  **[you]**
- First name / Last name / Phone / Email: your contact info (not shown publicly).
- **Sign-in required?** No - check "Sign-in not required" (there's no account).
- **Notes** (paste this):
```
Vibez is a personal focus app. You pick your own apps and Vibez shields them
during focus sessions using Apple's Family Controls / Screen Time APIs
(FamilyControls + ManagedSettings). It is NOT a parental-controls or MDM product:
authorization is requested in individual mode (AuthorizationCenter .individual),
there is no second user, no child, and no remote management. We do NOT use
DeviceActivity and never read app-usage history. No account or login is required.

PLEASE TEST ON A PHYSICAL DEVICE. Screen Time shields are a no-op in the iOS
Simulator, so blocking will appear to do nothing there.

STEP-BY-STEP TEST (no Mac or desktop app required):
1. Launch Vibez and tap Allow on the permission prompts (notifications, then
   Screen Time access).
2. On the home screen you'll see a setup/pairing card. Type this code into it
   exactly:  moss-pine-fox-jazz  and submit. This is only a pairing code - you do
   NOT need the companion Mac app, and any code of this form unlocks the app.
   Wait a few seconds for it to confirm (the large toggle becomes active). If it
   stays on "registering," confirm the device has internet, then tap retry.
3. Tap the gear (Settings) icon in the top bar, choose one or more apps to block
   (e.g., Safari) in the system picker, then close Settings.
4. Turn the large toggle ON. Your selected apps are now shielded.
5. Leave Vibez and open one of the blocked apps - instead of the app you'll see
   the Vibez shield screen. Return to Vibez and turn the toggle OFF to unblock.

OPTIONAL (not needed to review): Vibez can also raise the shield automatically
when a paired Mac running Claude Code or Codex finishes a task, via push
notification (Firebase Cloud Messaging). This needs the desktop tool and is not
required to evaluate the app; the manual toggle above performs identical blocking.

PRIVACY: the only data leaving the device is the push token (used to route
notifications). No analytics, no crash reporting, and we never transmit the apps
you select or any usage data.
```

## 11. Age Rating  (questionnaire -> results in 4+)
Answer **None / No** to every content question (violence, sexual content,
profanity, drugs, horror, gambling, contests, mature themes). Specifically:
- Unrestricted Web Access: **No** (the app blocks apps/sites; it doesn't browse)
- Uses the Advertising Identifier (IDFA): **No** (all ad SDKs removed)
- Third-party content: **No**
Expected result: **4+**.

## 12. App Privacy ("nutrition label")
Build links only Firebase Cloud Messaging + Cloud Functions, so declare exactly
one item under **Data Collected**:
- **Identifiers -> Device ID** = your push token. Used for: **App Functionality**.
  Linked to identity: **No**. Used for tracking: **No**.

Declare nothing else (no Usage Data, Diagnostics, or Location). No App Tracking
Transparency prompt needed.

## 13. Pricing  **[you]**
- Price: **Free** (assumed). Set availability to all territories or as desired.

## 14. App Icon
- 1024 x 1024 px, PNG, no alpha/transparency, no rounded corners (Apple rounds it).
  You already ship an AppIcon asset; ASC pulls the 1024 from the build.

## 15. Screenshots  (REQUIRED - the most likely thing to block you)
- **iPhone 6.9":** 1320 x 2868 px (portrait). Minimum 1, up to 10. This size is
  required.
- **iPad 13":** 2064 x 2752 px. **Required ONLY because your app is currently
  Universal** (`TARGETED_DEVICE_FAMILY = "1,2"`). See the decision note below.

Suggested 5-shot sequence (with caption ideas):
1. Hero - mascot + "Focus the moment your agent pauses"
2. Home screen with the big toggle - "One tap to shield your distractions"
3. App picker - "You choose what gets blocked"
4. The shield screen in a blocked app - "A friendly wall, not a black hole"
5. Focus stats - "Watch your focus time add up"

---

## DECISION: iPhone-only vs Universal

Your project targets iPhone **and** iPad (`TARGETED_DEVICE_FAMILY = "1,2"`). That
means App Store Connect will **require iPad screenshots** and reviewers will test
on iPad. Since Vibez is an iPhone-first focus tool, the simplest path is to make
it **iPhone-only** (`TARGETED_DEVICE_FAMILY = "1"`), which drops the iPad
screenshot requirement and iPad review surface. Tell me and I'll make that change.
