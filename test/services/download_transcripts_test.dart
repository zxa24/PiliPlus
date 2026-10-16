import 'package:PiliPlus/services/download/download_transcripts.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the download list says of a download's transcript.
void main() {
  test('nothing for a download with no transcript', () {
    expect(transcriptLabel(null), '');
    expect(transcriptLabel(null, pending: true), '');
  });

  test('waiting, going, part of it, all of it', () {
    expect(
      transcriptLabel((fraction: 0, running: false), pending: true),
      '  等待转录',
    );
    expect(
      transcriptLabel((fraction: 0.456, running: true), pending: true),
      '  转录中 45%',
    );
    expect(
      transcriptLabel((fraction: 0.456, running: false), pending: true),
      '  转录 45%',
    );
    // made while watching, not to be finished here (the setting off)
    expect(transcriptLabel((fraction: 0.2, running: false)), '  转录 20%');
    expect(transcriptLabel((fraction: 1, running: false)), '  已转录');
    // never 100% before it is all there
    expect(
      transcriptLabel((fraction: 0.999, running: true), pending: true),
      '  转录中 99%',
    );
  });
}
