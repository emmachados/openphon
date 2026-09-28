/// Byte length of the canonical RIFF/WAVE header written by the recorder.
const int kWavHeaderBytes = 44;

/// Duration of a PCM WAV file computed from its byte length.
///
/// Returns null when the file is too short to contain audio payload.
int? wavDurationMs({
  required int fileBytes,
  required int sampleRate,
  int channels = 1,
  int bitsPerSample = 16,
}) {
  final payload = fileBytes - kWavHeaderBytes;
  if (payload <= 0) return null;
  final bytesPerSecond = sampleRate * channels * (bitsPerSample ~/ 8);
  return (payload / bytesPerSecond * 1000).round();
}
