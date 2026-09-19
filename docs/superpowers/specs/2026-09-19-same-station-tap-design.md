# Same-station tap guard

**Problem.** Tapping the station that is already current restarts playback from
scratch (`RadioSession.play` bumps the session, stops the ICY reader, finalizes
any recording, calls `setUrl` again). Impatient double/triple clicks therefore
*delay* the music instead of speeding it up.

**Behaviour.**
- Tapping the current station while it is loading or playing is a no-op.
- Tapping the current station while it is **paused** (media notification /
  Bluetooth) resumes it.
- Tapping the current station after a **stream error** re-tunes, as today, so the
  "tap the station to reconnect" hint stays true.
- Tapping a different station, and Stop then tap, are unchanged.

**Implementation.**
- A pure helper `sameStationTapAction(...)` in `lib/radio_session.dart` returns
  `ignore` / `resume` / `retune`; unit-tested in `test/radio_session_test.dart`.
- `RadioSession.play` calls it first and returns / resumes accordingly.
- Stations compare by URL (how the tiles identify them).
- One-line note in `doc/implementation-notes.md`.

**Not doing.** No timer, no UI change.
