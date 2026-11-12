# Waypoint prototype

An iPhone accessibility prototype for completing a short pedestrian walk with spoken directions and AirPods head-tracked corrective sound. The optional Watch app requests a repeat through the paired iPhone.

## Try it in Xcode 27

1. Open `Waypoint.xcodeproj`. Select the **Waypoint** scheme and an iPhone. For a physical build, select your development team in Signing & Capabilities for both targets.
2. For a hands-free walk, say **“Siri, start a walk with Waypoint.”** Speak a destination, then confirm the place Siri reads back. Say **“Siri, repeat directions with Waypoint”** or **“Siri, stop my Waypoint walk”** during the walk. For the simulated route, select **Practice → Start practice**. The route has three legs. Turn with the buttons, wait for alignment, and choose **Walk this leg**. Repeat until the route completes.
3. Pair and wear your AirPods 3. Check **Audio output** and run **Test left and right audio**. Choose **Enable AirPods motion**, allow motion access if prompted, then face forward and choose **Align AirPods** once motion is received. Walk the first simulated leg. Turn toward the next cue and hold briefly. Try **Repeat direction**, then remove and reconnect an earbud and recalibrate. Compare **Speech only** with **Spatial sound**.
4. Select **Open route camera** and allow camera access. Point the rear camera along the first leg and tap **Align camera**. The live preview shows a route arrow that updates as the phone turns. Camera orientation can drive audio guidance when AirPods motion is unavailable.
5. For a live test, choose **Live walk**, search for a nearby destination, select the result, and tap **Start walk**. Apple Maps computes the walking route over the network. You can also import a GPX track or download it from an HTTPS link. Waypoint saves the route geometry for offline use. Use a short, familiar pedestrian route without crossings for the first test.
6. For AirPods-only guidance, leave the camera off. Hold the iPhone flat with its top edge pointing where you’re facing. Tap **Align AirPods** if you want to calibrate while standing still. Waypoint also starts tracking connected AirPods automatically and can align after it detects a steady walking direction. When prompted, look straight ahead while walking. The left cue falls in pitch and pans left. The right cue rises in pitch and pans right.
7. For camera guidance, hold the iPhone upright, tap **Open route camera**, and turn until the arrow points up and turns green. Tap **Use camera for audio guidance** to hear the correction as you turn the phone.
8. Open Waypoint on a paired Apple Watch while an iPhone session is active. Tap **Repeat direction**. Supported Watch models can invoke the on-screen button with Double Tap.

## Scope and hardware checks

- Practice explicitly simulates walking progress. It can use AirPods motion, camera orientation, or accessible turn buttons.
- The route line and GPS progress remain available offline after saving. Destination search, route generation, and uncached street map imagery use the network.
- An active live walk uses background location and audio when you lock the phone or switch apps. Spoken directions continue without head tracking. The camera closes when the app enters the background. Waypoint retries motion when iOS makes your paired AirPods available again.
- Alignment compares head or camera orientation with the route's next leg. It cannot establish that the path is clear. If location or head tracking is lost, the prototype stops the directional cue. To recover calibration in live mode, align AirPods again using the compass or the route camera.
- Verify Siri start, repeat, and stop, spoken directions with the screen locked, and AirPods recovery on physical hardware. Check that clockwise and counterclockwise movements move the cue correctly, motion remains fresh, the Watch relays repeat, and weak location fixes do not advance the route. Use VoiceOver to test setup, repeat, recovery, and completion.
- Save a real walking route chosen with a blind or low-vision traveller or orientation and mobility instructor before user testing. Compare speech-only and spatial guidance on comparable turns.

## Attribution

The directional correction that stops when aligned was inspired by [Navig-AI-tion](https://arxiv.org/html/2603.13200v2#S3.SS3). The prototype uses Apple's Core Motion, AVFoundation, Core Location, SwiftUI, and Watch Connectivity APIs. Cue audio is generated in code.

This prototype was generated with Codex assistance. Keep a record of what you independently design, implement, and verify before preparing a challenge entry, and disclose AI assistance under the challenge rules.
