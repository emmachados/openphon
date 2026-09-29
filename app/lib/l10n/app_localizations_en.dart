// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'openphon';

  @override
  String get startupFailed => 'openphon could not start. Please retry.';

  @override
  String get retry => 'Retry';

  @override
  String get record => 'Record';

  @override
  String get recordingPaused => 'Paused · Stop';

  @override
  String clippingWarning(String elapsed) {
    return '$elapsed · clipping!';
  }

  @override
  String get stop => 'Stop';

  @override
  String stopElapsed(String elapsed) {
    return 'Stop  $elapsed';
  }

  @override
  String defaultRecordingName(String stamp) {
    return 'Recording $stamp';
  }

  @override
  String recordingFailed(String error) {
    return 'Recording failed: $error';
  }

  @override
  String get microphonePermissionDenied => 'Microphone permission denied';

  @override
  String get noRecordingsYet => 'No recordings yet';

  @override
  String get tapRecordHint => 'Tap Record to capture audio for analysis.';

  @override
  String get selectRecordingHint => 'Select a recording to analyze';

  @override
  String coreVersion(String version) {
    return 'core $version';
  }

  @override
  String get rescanTooltip => 'Rescan recordings folder';

  @override
  String rescanResult(int count) {
    return 'Rescan: $count file(s) added';
  }

  @override
  String get importAudioTooltip => 'Import audio';

  @override
  String get textGridBadge => 'Has TextGrid';

  @override
  String importResultOk(int count) {
    return 'Imported $count file(s)';
  }

  @override
  String importResultSkipped(int count, int skipped) {
    return 'Imported $count, skipped $skipped. Supported formats: 16-, 24- or 32-bit PCM WAV and 32-bit float WAV.';
  }

  @override
  String get recordingActions => 'Recording actions';

  @override
  String get exportPairMenu => 'Export WAV + TextGrid…';

  @override
  String get delete => 'Delete';

  @override
  String get rename => 'Rename';

  @override
  String get renameRecordingTitle => 'Rename recording';

  @override
  String deleteRecordingTitle(String name) {
    return 'Delete \"$name\"?';
  }

  @override
  String get deleteRecordingBody =>
      'The audio file and its TextGrid annotations are removed permanently.';

  @override
  String get cancel => 'Cancel';

  @override
  String get save => 'Save';

  @override
  String get discard => 'Discard';

  @override
  String get unsavedAnnotationsTitle => 'Save annotation changes?';

  @override
  String get unsavedAnnotationsBody =>
      'This recording has unsaved TextGrid edits. Save them before leaving, or discard the changes.';

  @override
  String get overwriteTitle => 'Overwrite existing files?';

  @override
  String overwriteBody(String stem) {
    return '\"$stem\" already exists in that folder.';
  }

  @override
  String get overwrite => 'Overwrite';

  @override
  String exportedPair(String stem) {
    return 'Exported $stem.wav + $stem.TextGrid';
  }

  @override
  String exportedWavOnly(String stem) {
    return 'Exported $stem.wav (no TextGrid)';
  }

  @override
  String exportFailed(String error) {
    return 'Export failed: $error';
  }

  @override
  String couldNotOpenRecording(String error) {
    return 'Could not open recording:\n$error';
  }

  @override
  String get play => 'Play';

  @override
  String get pause => 'Pause';

  @override
  String get playSelection => 'Play selection';

  @override
  String selectionSpan(String span) {
    return 'sel $span s';
  }

  @override
  String get zoomToSelection => 'Zoom to selection';

  @override
  String get zoomToFit => 'Zoom to fit';

  @override
  String get analysisSettingsTooltip => 'Analysis settings';

  @override
  String get clearSelection => 'Clear selection';

  @override
  String get undoTooltip => 'Undo (Ctrl+Z)';

  @override
  String get redoTooltip => 'Redo (Ctrl+Y)';

  @override
  String get insertBoundaryTooltip => 'Insert boundary at cursor (Enter)';

  @override
  String get deleteBoundaryTooltip => 'Delete selected boundary (Del)';

  @override
  String get textGridMenu => 'TextGrid';

  @override
  String get saveTextGridMenu => 'Save TextGrid (Ctrl+S)';

  @override
  String get exportTextGridMenu => 'Export TextGrid…';

  @override
  String get newTextGridMenu => 'New TextGrid';

  @override
  String get exportMeasurementsMenu => 'Export measurements…';

  @override
  String get noIntervalTier => 'No interval tier to measure';

  @override
  String get noLabelledIntervals => 'No labelled intervals on the tier';

  @override
  String measurementsExported(int count) {
    return 'Exported measurements for $count interval(s)';
  }

  @override
  String get exportLibraryMeasurements => 'Export measurements (library)';

  @override
  String measuringProgress(int done, int total) {
    return 'Measuring $done/$total…';
  }

  @override
  String get noAnnotatedRecordings =>
      'No recordings with labelled interval tiers in the library';

  @override
  String libraryMeasurementsExported(int count, int files) {
    return 'Exported $count row(s) from $files recording(s)';
  }

  @override
  String get importTextGridMenu => 'Import TextGrid…';

  @override
  String get textGridSaved => 'TextGrid saved';

  @override
  String get textGridExported => 'TextGrid exported';

  @override
  String get textGridImported => 'TextGrid imported';

  @override
  String saveFailed(String error) {
    return 'Save failed: $error';
  }

  @override
  String importFailed(String error) {
    return 'Import failed: $error';
  }

  @override
  String get replaceTextGridTitle => 'Replace current TextGrid?';

  @override
  String get replaceOnImportBody =>
      'This recording already has annotations; importing replaces them (the previous file is overwritten).';

  @override
  String get replaceOnNewBody =>
      'This discards the current annotations (the file on disk is only overwritten when you save).';

  @override
  String get replace => 'Replace';

  @override
  String get tapSpectrogramHint => 'Tap the spectrogram to read values';

  @override
  String get unvoiced => 'unvoiced';

  @override
  String get waveformSemantics => 'Waveform';

  @override
  String get spectrogramSemantics =>
      'Spectrogram. Tap to read values at a point.';

  @override
  String tierStripSemantics(String tierNames, String activeName) {
    return 'Annotation tiers: $tierNames. Active tier: $activeName. Tap a tier to select; double-tap a label to edit.';
  }

  @override
  String get settings => 'Settings';

  @override
  String get appearance => 'Appearance';

  @override
  String get themeSystem => 'System';

  @override
  String get themeLight => 'Light';

  @override
  String get themeDark => 'Dark';

  @override
  String get analysisSection => 'Analysis';

  @override
  String get defaultAnalysisSettings => 'Default analysis settings';

  @override
  String get usingBuiltInDefaults => 'Using built-in defaults';

  @override
  String get customizedDefaults =>
      'Customized; applied to recordings without their own';

  @override
  String get resetAnalysisDefaults => 'Reset analysis defaults';

  @override
  String get aboutOpenphon => 'About openphon';

  @override
  String get aboutVersion => '0.1.0 (pre-release)';

  @override
  String get aboutLegalese =>
      'Apache-2.0. Analysis runs on this device. Recordings are shared only when you export them.';

  @override
  String get sheetSpectrogram => 'Spectrogram';

  @override
  String get sheetPitch => 'Pitch';

  @override
  String get sheetFormants => 'Formants';

  @override
  String get sheetIntensity => 'Intensity';

  @override
  String get sheetTracks => 'Tracks';

  @override
  String get layersTooltip => 'Layers';

  @override
  String get recordingSection => 'Recording';

  @override
  String get recordingSampleRate => 'Sample rate';

  @override
  String get autoGain => 'Automatic gain control';

  @override
  String get echoCancel => 'Echo cancellation';

  @override
  String get noiseSuppress => 'Noise suppression';

  @override
  String get recordingDspHint => 'Leave off for acoustic measurement';

  @override
  String get presetAdultMale => 'Adult male';

  @override
  String get presetAdultFemale => 'Adult female';

  @override
  String get presetChild => 'Child';

  @override
  String get presetClassic => 'Classic';

  @override
  String get presetOkabeIto => 'Okabe-Ito';

  @override
  String get presetHighVisibility => 'High visibility';

  @override
  String get markSize => 'Mark size';

  @override
  String colorOptionSemantics(String track) {
    return 'Color option for $track';
  }

  @override
  String get minTimeStep => 'Min time step';

  @override
  String get trackTimeStep => 'Time step';

  @override
  String get windowLength => 'Window length';

  @override
  String get maxFrequency => 'Max frequency';

  @override
  String get preEmphasisFrom => 'Pre-emphasis from';

  @override
  String get dynamicRange => 'Dynamic range';

  @override
  String get floor => 'Floor';

  @override
  String get ceiling => 'Ceiling';

  @override
  String get count => 'Count';

  @override
  String get minimumPitch => 'Minimum pitch';

  @override
  String get resetToDefaults => 'Reset to defaults';

  @override
  String get apply => 'Apply';

  @override
  String get voiceReportTitle => 'Voice report';

  @override
  String voiceReportSelectionRange(String t0, String t1) {
    return 'Selection $t0–$t1 s';
  }

  @override
  String voiceReportWholeRange(String t1) {
    return 'Whole recording, 0–$t1 s';
  }

  @override
  String voiceReportPitchRange(String floor, String ceiling) {
    return 'Pitch range $floor–$ceiling Hz';
  }

  @override
  String get medianF0Label => 'Median F0';

  @override
  String get meanF0Label => 'Mean F0';

  @override
  String get sdF0Label => 'F0 SD';

  @override
  String get meanHnrLabel => 'Mean HNR';

  @override
  String get jitterLocalLabel => 'Jitter (local)';

  @override
  String get shimmerLocalLabel => 'Shimmer (local)';

  @override
  String get pulsePeriodsLabel => 'Glottal periods';

  @override
  String get voiceReportSparseHint =>
      'Little steadily voiced material in this stretch; voice measures need a sustained voiced sound.';

  @override
  String voiceReportFailed(String error) {
    return 'Voice report failed: $error';
  }

  @override
  String get reportCopied => 'Report copied to clipboard';

  @override
  String get saveSelectionWavTooltip => 'Save selection as WAV';

  @override
  String get loopSelectionTooltip => 'Loop selection';

  @override
  String get playbackRateTooltip => 'Playback speed';

  @override
  String get backupLibraryMenu => 'Back up library…';

  @override
  String backupDone(int count) {
    return 'Backed up $count recording(s) with manifest.csv';
  }

  @override
  String get libraryEmpty => 'Library is empty';

  @override
  String get selectionSaved => 'Selection saved';

  @override
  String get copy => 'Copy';

  @override
  String get close => 'Close';
}
