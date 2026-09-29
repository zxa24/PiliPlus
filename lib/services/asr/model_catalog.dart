/// LibrePili: what the on-device recogniser needs, where to get it, and the
/// hash it must have once it is here.
///
/// Nothing in this file is downloaded at build time and nothing is bundled in
/// the app: the binaries are ~240 MB and most users never turn transcription
/// on. [AsrModelStore] fetches them into the app's *data* directory on demand.
///
/// **The hash is the contract.** Every pin below is the SHA-256 of the file as
/// published by the upstream k2-fsa release — for files that upstream only
/// ships inside a tarball, of the *unpacked* file. A mirror therefore cannot
/// substitute anything: whatever the source, the bytes that land on disk must
/// hash to the same value or they are deleted.
library;

enum AsrArchive {
  /// The URL is the file itself.
  none,

  /// The URL is a `.tar.bz2` and [AsrSource.entry] names the member to keep.
  tarBz2,
}

class AsrSource {
  const AsrSource({
    required this.url,
    this.archive = AsrArchive.none,
    this.entry,
    this.archiveSize,
  }) : assert(
         archive == AsrArchive.none || entry != null,
         'an archive source must name the entry to extract',
       );

  final String url;
  final AsrArchive archive;

  /// Path of the wanted member inside the archive.
  final String? entry;

  /// Size of the download itself (not of the extracted file), when known — the
  /// progress bar needs it before any byte arrives.
  final int? archiveSize;
}

class AsrModelFile {
  const AsrModelFile({
    required this.name,
    required this.size,
    required this.sha256,
    required this.sources,
  });

  /// Filename on disk, inside the model's own directory.
  final String name;

  /// Size of the file once unpacked.
  final int size;

  /// Lowercase hex SHA-256 of the unpacked file.
  final String sha256;

  /// Tried in order; the first one that yields matching bytes wins.
  final List<AsrSource> sources;

  /// Bytes actually transferred by [source], for progress reporting.
  int transferSize(AsrSource source) => source.archiveSize ?? size;
}

/// Terms a model comes under that the app has to pass on: the licence text
/// itself and a notice that goes with every copy.
class AsrModelLicence {
  const AsrModelLicence({
    required this.name,
    required this.url,
    required this.asset,
    required this.notice,
  });

  /// As the licence calls itself.
  final String name;

  /// Where the licence is published.
  final String url;

  /// The full text, shipped with the app (pubspec assets).
  final String asset;

  /// The attribution the licence requires, word for word.
  final String notice;
}

class AsrModel {
  const AsrModel({
    required this.id,
    required this.label,
    required this.files,
    required this.languages,
    this.licence,
  });

  /// Directory name under `<support>/asr/`, and the key stored in prefs.
  final String id;
  final String label;
  final List<AsrModelFile> files;

  /// BCP-47-ish tags the model recognises; empty for language-agnostic pieces.
  final List<String> languages;

  /// Terms to pass on with it, where there are any beyond a permissive
  /// licence's (see [AsrModelLicence]).
  final AsrModelLicence? licence;

  int get totalSize => files.fold(0, (sum, file) => sum + file.size);
}

abstract final class AsrModelCatalog {
  /// Our own release. It holds the *unpacked* files, so a phone never has to
  /// bzip2-decompress 163 MB into 239 MB — which is why it is tried first.
  /// [_upstream] is the fallback, and the pinned hash is the same either way.
  static const _mirror =
      'https://github.com/zxa24/PiliPlus/releases/download/asr-models';

  static const _upstream =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models';

  /// The 2024-07-17 build, deliberately. The same release directory holds a
  /// 2025-09-09 file one character different in the name whose language ID is
  /// pinned to `<|yue|>` — confirmed on two phones. Never resolve "the newest
  /// sense-voice asset".
  static const _senseVoiceDir =
      'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17';

  static const senseVoice = AsrModel(
    id: 'sense-voice-2024-07-17',
    label: 'SenseVoice（中英日韩粤）',
    languages: ['zh', 'en', 'ja', 'ko', 'yue'],
    files: [
      AsrModelFile(
        name: 'model.int8.onnx',
        size: 239233841,
        sha256:
            'c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51',
        sources: [
          AsrSource(url: '$_mirror/$_senseVoiceDir.model.int8.onnx'),
          AsrSource(
            url: '$_upstream/$_senseVoiceDir.tar.bz2',
            archive: AsrArchive.tarBz2,
            entry: '$_senseVoiceDir/model.int8.onnx',
            archiveSize: 163002883,
          ),
        ],
      ),
      AsrModelFile(
        name: 'tokens.txt',
        size: 315894,
        sha256:
            'f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc',
        sources: [
          AsrSource(url: '$_mirror/$_senseVoiceDir.tokens.txt'),
          AsrSource(
            url: '$_upstream/$_senseVoiceDir.tar.bz2',
            archive: AsrArchive.tarBz2,
            entry: '$_senseVoiceDir/tokens.txt',
            archiveSize: 163002883,
          ),
        ],
      ),
    ],
  );

  /// Speech detection: without it the recogniser would be fed silence and
  /// music, and SenseVoice hallucinates on both.
  static const vad = AsrModel(
    id: 'silero-vad',
    label: '语音活动检测',
    languages: [],
    files: [
      AsrModelFile(
        name: 'silero_vad.onnx',
        size: 643854,
        sha256:
            '9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6',
        sources: [
          AsrSource(url: '$_mirror/silero_vad.onnx'),
          AsrSource(url: '$_upstream/silero_vad.onnx'),
        ],
      ),
    ],
  );

  /// Everything transcription needs, in the order it should be fetched (the
  /// small one first, so a failure shows up before 240 MB of traffic).
  static const required = <AsrModel>[vad, senseVoice];

  static const _parakeetDir =
      'sherpa-onnx-nemo-parakeet-unified-en-0.6b-int8-non-streaming';

  /// The upstream tarball the Parakeet files come in (500 MB).
  static const _parakeetArchive = 501350460;

  static AsrModelFile _parakeetFile(String name, int size, String sha256) =>
      AsrModelFile(
        name: name,
        size: size,
        sha256: sha256,
        sources: [
          AsrSource(url: '$_mirror/$_parakeetDir.$name'),
          AsrSource(
            url: '$_upstream/$_parakeetDir.tar.bz2',
            archive: AsrArchive.tarBz2,
            entry: '$_parakeetDir/$name',
            archiveSize: _parakeetArchive,
          ),
        ],
      );

  /// NVIDIA's licence for Parakeet: redistribution is allowed if every copy
  /// comes with the agreement and this notice (section 3.1).
  static const nvidiaOpenModelLicence = AsrModelLicence(
    name: 'NVIDIA Open Model License',
    url:
        'https://www.nvidia.com/en-us/agreements/enterprise-software/'
        'nvidia-open-model-license/',
    asset: 'assets/licenses/nvidia-open-model-license.txt',
    notice:
        'Licensed by NVIDIA Corporation under the NVIDIA Open Model License',
  );

  /// English only, optional: once a session's speech is settled as English,
  /// its later segments are recognised with this instead of SenseVoice.
  /// On a Pixel 4 XL it runs at RTF 0.07–0.11 (SenseVoice 0.03) and takes
  /// 1.2 GB (0.4); on the app's segments it is clearly more accurate on
  /// English street vlogs (research/noisy-speech-design-2026-09-26.md,
  /// 11–12). An RNN-T, sherpa-onnx `nemo_transducer`.
  static final parakeet = AsrModel(
    id: 'parakeet-unified-en-0.6b-int8',
    label: 'Parakeet（英语）',
    languages: const ['en'],
    licence: nvidiaOpenModelLicence,
    files: [
      _parakeetFile(
        'encoder.int8.onnx',
        654040552,
        '6716910b7a0833997fec7a410494c995d70124001a0e9b66d6370d6aced577e0',
      ),
      _parakeetFile(
        'decoder.int8.onnx',
        7257753,
        'a5e223392c90e75f8144cdb5eb95af7625db389e39edef2bd1a9c872b3298fe6',
      ),
      _parakeetFile(
        'joiner.int8.onnx',
        1735860,
        '869f43f7d24595c55581ad3bf249a935fb8a71389fbdaa7504b9f46f93140f8a',
      ),
      _parakeetFile(
        'tokens.txt',
        8952,
        'dc0b4584ab2e4ddbf888425c076c61b736e7356a015250db7d307e6f1a8188ff',
      ),
    ],
  );

  /// Models transcription can do without; each is downloaded only when the
  /// user asks for it.
  static final optional = <AsrModel>[parakeet];

  /// [required] and [optional].
  static List<AsrModel> get all => [...required, ...optional];

  static int get totalSize =>
      required.fold(0, (sum, model) => sum + model.totalSize);

  static AsrModel? byId(String id) =>
      all.where((model) => model.id == id).firstOrNull;
}
