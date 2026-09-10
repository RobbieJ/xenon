# ADR-0005: LiveCommunicationKit for the session lifecycle, CallKit as fallback

**Status:** Proposed, pending a lock-screen test in phase 3. **Date:** 2026-09-10.

## Context

See `docs/research/04-ios27-platform.md` §4 and §5. The app must keep capturing and playing audio with the screen locked and the phone in a pocket for 90 minutes. The `audio` background mode does that as long as the engine keeps running. Reporting the session to the system as a call adds the lock-screen call UI, Dynamic Island, Recents, AirPods stem-press to mute or end, Focus handling, and a system-activated audio session with call priority. A locally signalled call needs no VoIP push. WWDC26 session 226 names LiveCommunicationKit as the modern replacement for CallKit's CXProvider, with full lock-screen and Dynamic Island integration, and it is permitted in China where CallKit's UI is not. Apple's PushToTalk framework is half-duplex and needs a push server, so it does not fit.

## Decision

- Use LiveCommunicationKit: `ConversationManager`, `StartConversationAction` on the initiating phone, `JoinConversationAction` on the phone that receives the invite over the link. The audio engine is started from the framework's audio-session activation callback.
- Declare `UIBackgroundModes`: `audio`, `bluetooth-central`, `bluetooth-peripheral`.
- The engine never stops for silence during a session.
- If phase 3 shows LiveCommunicationKit's lock-screen behaviour falls short of what session 226 describes, swap in CallKit `CXProvider` with the same audio-session pattern and disable it for the China storefront.

## Consequences

- One code path gives background survival, system UI and headset controls.
- Describe the product as a local voice call, not VoIP, in App Store metadata, since there is no IP network path.
- The orange microphone indicator is always on during a session. That is unavoidable and should be explained in onboarding.
