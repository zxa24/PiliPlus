/// LibrePili: when a growing transcript is worth handing to the player again.
///
/// A transcript arrives in pieces, and each time it does the whole track is
/// rebuilt and handed to mpv as a fresh `memory://` URI. That is a *reload*:
/// whatever line is on screen at that moment vanishes and comes back. Doing
/// it on a timer means a subtitle can blink every few seconds, which looks
/// exactly like "the subtitle only stayed up for a moment" — and no amount
/// of inspecting the cue timings would show it, because the timings are
/// fine.
///
/// Recognition runs far ahead of playback once the audio is arriving, so
/// most of those reloads buy nothing: the track already covers minutes the
/// viewer has not reached. Republish only when the viewer is close to
/// running out of subtitle, or when this is the first or last word on the
/// subject.
library;

/// How far ahead of the playhead the published transcript must reach before
/// a refresh is skipped.
///
/// Generous on purpose: being a minute ahead and reloading anyway is a
/// visible cost for no benefit, while being a few seconds ahead and *not*
/// reloading would strand the viewer with no subtitle.
const asrPublishLead = Duration(seconds: 30);

/// Whether to hand the player a rebuilt subtitle track.
///
/// [publishedTo] is where the published cues end, [position] where playback
/// is; both measured from the start of the media. [isFirst] covers the cue
/// that has never been shown, [isFinal] the end of the run, and both always
/// publish — the first because there is nothing on screen to disturb, the
/// last because it is the only chance to deliver the tail.
bool shouldPublishAsr({
  required Duration publishedTo,
  required Duration position,
  required bool isFirst,
  required bool isFinal,
}) {
  if (isFirst || isFinal) return true;
  return publishedTo - position < asrPublishLead;
}
