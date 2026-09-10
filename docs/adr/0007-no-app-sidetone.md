# ADR-0007: No synthesised sidetone

**Status:** Accepted. **Date:** 2026-09-10.

## Context

With ANC on and sealed ear tips, people hear their own voice as muffled and tend to raise it. Hearing-aid literature puts the threshold at which own-voice delay becomes noticeable at 3 to 5 ms, objectionable above 10 ms, and disruptive to speech production above 30 ms. Any path through the iPhone and back to the AirPods is at least 40 to 80 ms. HeardThat users describe exactly this "distracting echo of my own voice".

## Decision

The app never mixes the local microphone into the local output. Own-voice perception is left to the AirPods' own occlusion handling. Onboarding tells users that a slightly muffled own voice is normal and that they do not need to raise it.

## Consequences

- Removes an entire class of complaints and a processing path.
- Whether iOS itself injects sidetone during a third-party call on AirPods, and whether that can be suppressed, is open question 4 in `docs/PLAN.md` §9.
