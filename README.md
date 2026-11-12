# Waypoint prototype

An iPhone accessibility prototype for completing a short pedestrian walk with spoken directions and AirPods head-tracked corrective sound. The optional Watch app requests a repeat through the paired iPhone.

## Try it in Xcode 27

1. Open `Waypoint.xcodeproj`. Select the **Waypoint** scheme and an iPhone. For a physical build, select your development team in Signing & Capabilities for both targets.
2. Select **Practice → Start practice**. The route has three legs. Turn with the buttons, wait for alignment, and choose **Walk this leg**. Repeat until the route completes.
3. Pair and wear your AirPods 3. Check **Audio output** and run **Test left and right audio**. Choose **Enable AirPods motion**, allow motion access if prompted, then face forward and choose **Align AirPods** once motion is received. Walk the first simulated leg. Turn toward the next cue and hold briefly. Try **Repeat direction**, then remove and reconnect an earbud and recalibrate. Compare **Speech only** with **Spatial sound**.
4. Select **Open route camera** and allow camera access. Point the rear camera along the first leg and tap **Align camera**. The live preview shows a route arrow that updates as the phone turns. Camera orientation can drive audio guidance when AirPods motion is unavailable.
5. For a live test, choose **Live walk** and import a single continuous GPX track/route from Files or download one from a direct HTTPS GPX link. The route and its schematic are saved to the iPhone. Start at the first point, face along the first leg, and align. Use a short, familiar pedestrian route with widely spaced waypoints and no crossings for supervised testing. No account or internet is required after saving the route.
6. Open Waypoint on a paired Apple Watch while an iPhone session is active. Tap **Repeat direction**. Supported Watch models can invoke the on-screen button with Double Tap.

## Scope and hardware checks

- Practice explicitly simulates walking progress. It can use AirPods motion, camera orientation, or accessible turn buttons.
- The offline map shows the saved route and current location. It does not include street basemap tiles, address search, or automatic rerouting.
- This first build pauses when the iPhone app enters the background. During the supervised live test, keep Waypoint open and the screen awake, including when putting the phone in a pocket.
- Alignment compares head or camera orientation with the route's next leg. It cannot establish that the path is clear. If location or head tracking is lost, the prototype stops the directional cue. To recover calibration in live mode, return to the start of the active leg and face the direction of that leg.
- Verify on physical hardware that clockwise and counterclockwise movements move the cue correctly, motion remains fresh, the Watch relays repeat, and weak location fixes do not advance the route. Use VoiceOver to test setup, repeat, recovery, and completion.
- Save a real walking route chosen with a blind or low-vision traveller or orientation and mobility instructor before user testing. Compare speech-only and spatial guidance on comparable turns.

## Attribution

The directional correction that stops when aligned was inspired by [Navig-AI-tion](https://arxiv.org/html/2603.13200v2#S3.SS3). The prototype uses Apple's Core Motion, AVFoundation, Core Location, SwiftUI, and Watch Connectivity APIs. Cue audio is generated in code.

This prototype was generated with Codex assistance. Keep a record of what you independently design, implement, and verify before preparing a challenge entry, and disclose AI assistance under the challenge rules.
