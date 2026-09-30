import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[Locale('en')];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'openphon'**
  String get appTitle;

  /// No description provided for @startupFailed.
  ///
  /// In en, this message translates to:
  /// **'openphon could not start. Please retry.'**
  String get startupFailed;

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// No description provided for @record.
  ///
  /// In en, this message translates to:
  /// **'Record'**
  String get record;

  /// Recording was paused by a native audio interruption; Stop saves the captured portion.
  ///
  /// In en, this message translates to:
  /// **'Paused · Stop'**
  String get recordingPaused;

  /// No description provided for @clippingWarning.
  ///
  /// In en, this message translates to:
  /// **'{elapsed} · clipping!'**
  String clippingWarning(String elapsed);

  /// No description provided for @stop.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get stop;

  /// No description provided for @stopElapsed.
  ///
  /// In en, this message translates to:
  /// **'Stop  {elapsed}'**
  String stopElapsed(String elapsed);

  /// No description provided for @defaultRecordingName.
  ///
  /// In en, this message translates to:
  /// **'Recording {stamp}'**
  String defaultRecordingName(String stamp);

  /// No description provided for @recordingFailed.
  ///
  /// In en, this message translates to:
  /// **'Recording failed: {error}'**
  String recordingFailed(String error);

  /// No description provided for @microphonePermissionDenied.
  ///
  /// In en, this message translates to:
  /// **'Microphone permission denied'**
  String get microphonePermissionDenied;

  /// No description provided for @noRecordingsYet.
  ///
  /// In en, this message translates to:
  /// **'No recordings yet'**
  String get noRecordingsYet;

  /// No description provided for @tapRecordHint.
  ///
  /// In en, this message translates to:
  /// **'Tap Record to capture audio for analysis.'**
  String get tapRecordHint;

  /// No description provided for @selectRecordingHint.
  ///
  /// In en, this message translates to:
  /// **'Select a recording to analyze'**
  String get selectRecordingHint;

  /// No description provided for @coreVersion.
  ///
  /// In en, this message translates to:
  /// **'core {version}'**
  String coreVersion(String version);

  /// No description provided for @rescanTooltip.
  ///
  /// In en, this message translates to:
  /// **'Rescan recordings folder'**
  String get rescanTooltip;

  /// No description provided for @rescanResult.
  ///
  /// In en, this message translates to:
  /// **'Rescan: {count} file(s) added'**
  String rescanResult(int count);

  /// No description provided for @importAudioTooltip.
  ///
  /// In en, this message translates to:
  /// **'Import audio'**
  String get importAudioTooltip;

  /// No description provided for @textGridBadge.
  ///
  /// In en, this message translates to:
  /// **'Has TextGrid'**
  String get textGridBadge;

  /// No description provided for @importResultOk.
  ///
  /// In en, this message translates to:
  /// **'Imported {count} file(s)'**
  String importResultOk(int count);

  /// No description provided for @importResultSkipped.
  ///
  /// In en, this message translates to:
  /// **'Imported {count}, skipped {skipped}. Supported formats: 16-, 24- or 32-bit PCM WAV and 32-bit float WAV.'**
  String importResultSkipped(int count, int skipped);

  /// No description provided for @recordingActions.
  ///
  /// In en, this message translates to:
  /// **'Recording actions'**
  String get recordingActions;

  /// No description provided for @exportPairMenu.
  ///
  /// In en, this message translates to:
  /// **'Export WAV + TextGrid…'**
  String get exportPairMenu;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @rename.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get rename;

  /// No description provided for @renameRecordingTitle.
  ///
  /// In en, this message translates to:
  /// **'Rename recording'**
  String get renameRecordingTitle;

  /// No description provided for @deleteRecordingTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete \"{name}\"?'**
  String deleteRecordingTitle(String name);

  /// No description provided for @deleteRecordingBody.
  ///
  /// In en, this message translates to:
  /// **'The audio file and its TextGrid annotations are removed permanently.'**
  String get deleteRecordingBody;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @discard.
  ///
  /// In en, this message translates to:
  /// **'Discard'**
  String get discard;

  /// No description provided for @unsavedAnnotationsTitle.
  ///
  /// In en, this message translates to:
  /// **'Save annotation changes?'**
  String get unsavedAnnotationsTitle;

  /// No description provided for @unsavedAnnotationsBody.
  ///
  /// In en, this message translates to:
  /// **'This recording has unsaved TextGrid edits. Save them before leaving, or discard the changes.'**
  String get unsavedAnnotationsBody;

  /// No description provided for @overwriteTitle.
  ///
  /// In en, this message translates to:
  /// **'Overwrite existing files?'**
  String get overwriteTitle;

  /// No description provided for @overwriteBody.
  ///
  /// In en, this message translates to:
  /// **'\"{stem}\" already exists in that folder.'**
  String overwriteBody(String stem);

  /// No description provided for @overwrite.
  ///
  /// In en, this message translates to:
  /// **'Overwrite'**
  String get overwrite;

  /// No description provided for @exportedPair.
  ///
  /// In en, this message translates to:
  /// **'Exported {stem}.wav + {stem}.TextGrid'**
  String exportedPair(String stem);

  /// No description provided for @exportedWavOnly.
  ///
  /// In en, this message translates to:
  /// **'Exported {stem}.wav (no TextGrid)'**
  String exportedWavOnly(String stem);

  /// No description provided for @exportFailed.
  ///
  /// In en, this message translates to:
  /// **'Export failed: {error}'**
  String exportFailed(String error);

  /// No description provided for @couldNotOpenRecording.
  ///
  /// In en, this message translates to:
  /// **'Could not open recording:\n{error}'**
  String couldNotOpenRecording(String error);

  /// No description provided for @play.
  ///
  /// In en, this message translates to:
  /// **'Play'**
  String get play;

  /// No description provided for @pause.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get pause;

  /// No description provided for @playSelection.
  ///
  /// In en, this message translates to:
  /// **'Play selection'**
  String get playSelection;

  /// No description provided for @selectionSpan.
  ///
  /// In en, this message translates to:
  /// **'sel {span} s'**
  String selectionSpan(String span);

  /// No description provided for @zoomToSelection.
  ///
  /// In en, this message translates to:
  /// **'Zoom to selection'**
  String get zoomToSelection;

  /// No description provided for @zoomToFit.
  ///
  /// In en, this message translates to:
  /// **'Zoom to fit'**
  String get zoomToFit;

  /// No description provided for @analysisSettingsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Analysis settings'**
  String get analysisSettingsTooltip;

  /// No description provided for @clearSelection.
  ///
  /// In en, this message translates to:
  /// **'Clear selection'**
  String get clearSelection;

  /// No description provided for @undoTooltip.
  ///
  /// In en, this message translates to:
  /// **'Undo (Ctrl+Z)'**
  String get undoTooltip;

  /// No description provided for @redoTooltip.
  ///
  /// In en, this message translates to:
  /// **'Redo (Ctrl+Y)'**
  String get redoTooltip;

  /// No description provided for @insertBoundaryTooltip.
  ///
  /// In en, this message translates to:
  /// **'Insert boundary at cursor (Enter)'**
  String get insertBoundaryTooltip;

  /// No description provided for @deleteBoundaryTooltip.
  ///
  /// In en, this message translates to:
  /// **'Delete selected boundary (Del)'**
  String get deleteBoundaryTooltip;

  /// No description provided for @textGridMenu.
  ///
  /// In en, this message translates to:
  /// **'TextGrid'**
  String get textGridMenu;

  /// No description provided for @saveTextGridMenu.
  ///
  /// In en, this message translates to:
  /// **'Save TextGrid (Ctrl+S)'**
  String get saveTextGridMenu;

  /// No description provided for @exportTextGridMenu.
  ///
  /// In en, this message translates to:
  /// **'Export TextGrid…'**
  String get exportTextGridMenu;

  /// No description provided for @newTextGridMenu.
  ///
  /// In en, this message translates to:
  /// **'New TextGrid'**
  String get newTextGridMenu;

  /// No description provided for @exportMeasurementsMenu.
  ///
  /// In en, this message translates to:
  /// **'Export measurements…'**
  String get exportMeasurementsMenu;

  /// No description provided for @noIntervalTier.
  ///
  /// In en, this message translates to:
  /// **'No interval tier to measure'**
  String get noIntervalTier;

  /// No description provided for @noLabelledIntervals.
  ///
  /// In en, this message translates to:
  /// **'No labelled intervals on the tier'**
  String get noLabelledIntervals;

  /// No description provided for @measurementsExported.
  ///
  /// In en, this message translates to:
  /// **'Exported measurements for {count} interval(s)'**
  String measurementsExported(int count);

  /// No description provided for @exportLibraryMeasurements.
  ///
  /// In en, this message translates to:
  /// **'Export measurements (library)'**
  String get exportLibraryMeasurements;

  /// No description provided for @measuringProgress.
  ///
  /// In en, this message translates to:
  /// **'Measuring {done}/{total}…'**
  String measuringProgress(int done, int total);

  /// No description provided for @noAnnotatedRecordings.
  ///
  /// In en, this message translates to:
  /// **'No recordings with labelled interval tiers in the library'**
  String get noAnnotatedRecordings;

  /// No description provided for @libraryMeasurementsExported.
  ///
  /// In en, this message translates to:
  /// **'Exported {count} row(s) from {files} recording(s)'**
  String libraryMeasurementsExported(int count, int files);

  /// No description provided for @importTextGridMenu.
  ///
  /// In en, this message translates to:
  /// **'Import TextGrid…'**
  String get importTextGridMenu;

  /// No description provided for @textGridSaved.
  ///
  /// In en, this message translates to:
  /// **'TextGrid saved'**
  String get textGridSaved;

  /// No description provided for @textGridExported.
  ///
  /// In en, this message translates to:
  /// **'TextGrid exported'**
  String get textGridExported;

  /// No description provided for @textGridImported.
  ///
  /// In en, this message translates to:
  /// **'TextGrid imported'**
  String get textGridImported;

  /// No description provided for @saveFailed.
  ///
  /// In en, this message translates to:
  /// **'Save failed: {error}'**
  String saveFailed(String error);

  /// No description provided for @importFailed.
  ///
  /// In en, this message translates to:
  /// **'Import failed: {error}'**
  String importFailed(String error);

  /// No description provided for @replaceTextGridTitle.
  ///
  /// In en, this message translates to:
  /// **'Replace current TextGrid?'**
  String get replaceTextGridTitle;

  /// No description provided for @replaceOnImportBody.
  ///
  /// In en, this message translates to:
  /// **'This recording already has annotations; importing replaces them (the previous file is overwritten).'**
  String get replaceOnImportBody;

  /// No description provided for @replaceOnNewBody.
  ///
  /// In en, this message translates to:
  /// **'This discards the current annotations (the file on disk is only overwritten when you save).'**
  String get replaceOnNewBody;

  /// No description provided for @replace.
  ///
  /// In en, this message translates to:
  /// **'Replace'**
  String get replace;

  /// No description provided for @tapSpectrogramHint.
  ///
  /// In en, this message translates to:
  /// **'Tap the spectrogram to read values'**
  String get tapSpectrogramHint;

  /// No description provided for @unvoiced.
  ///
  /// In en, this message translates to:
  /// **'unvoiced'**
  String get unvoiced;

  /// No description provided for @waveformSemantics.
  ///
  /// In en, this message translates to:
  /// **'Waveform'**
  String get waveformSemantics;

  /// No description provided for @spectrogramSemantics.
  ///
  /// In en, this message translates to:
  /// **'Spectrogram. Tap to read values at a point.'**
  String get spectrogramSemantics;

  /// No description provided for @tierStripSemantics.
  ///
  /// In en, this message translates to:
  /// **'Annotation tiers: {tierNames}. Active tier: {activeName}. Tap a tier to select; double-tap a label to edit.'**
  String tierStripSemantics(String tierNames, String activeName);

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @appearance.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get appearance;

  /// No description provided for @themeSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get themeSystem;

  /// No description provided for @themeLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get themeLight;

  /// No description provided for @themeDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get themeDark;

  /// No description provided for @analysisSection.
  ///
  /// In en, this message translates to:
  /// **'Analysis'**
  String get analysisSection;

  /// No description provided for @defaultAnalysisSettings.
  ///
  /// In en, this message translates to:
  /// **'Default analysis settings'**
  String get defaultAnalysisSettings;

  /// No description provided for @usingBuiltInDefaults.
  ///
  /// In en, this message translates to:
  /// **'Using built-in defaults'**
  String get usingBuiltInDefaults;

  /// No description provided for @customizedDefaults.
  ///
  /// In en, this message translates to:
  /// **'Customized; applied to recordings without their own'**
  String get customizedDefaults;

  /// No description provided for @resetAnalysisDefaults.
  ///
  /// In en, this message translates to:
  /// **'Reset analysis defaults'**
  String get resetAnalysisDefaults;

  /// No description provided for @aboutOpenphon.
  ///
  /// In en, this message translates to:
  /// **'About openphon'**
  String get aboutOpenphon;

  /// No description provided for @aboutVersion.
  ///
  /// In en, this message translates to:
  /// **'0.1.0 (pre-release)'**
  String get aboutVersion;

  /// No description provided for @aboutLegalese.
  ///
  /// In en, this message translates to:
  /// **'Apache-2.0. Analysis runs on this device. Recordings are shared only when you export them.'**
  String get aboutLegalese;

  /// No description provided for @sheetSpectrogram.
  ///
  /// In en, this message translates to:
  /// **'Spectrogram'**
  String get sheetSpectrogram;

  /// No description provided for @sheetPitch.
  ///
  /// In en, this message translates to:
  /// **'Pitch'**
  String get sheetPitch;

  /// No description provided for @sheetFormants.
  ///
  /// In en, this message translates to:
  /// **'Formants'**
  String get sheetFormants;

  /// No description provided for @sheetIntensity.
  ///
  /// In en, this message translates to:
  /// **'Intensity'**
  String get sheetIntensity;

  /// No description provided for @sheetTracks.
  ///
  /// In en, this message translates to:
  /// **'Tracks'**
  String get sheetTracks;

  /// No description provided for @layersTooltip.
  ///
  /// In en, this message translates to:
  /// **'Layers'**
  String get layersTooltip;

  /// No description provided for @recordingSection.
  ///
  /// In en, this message translates to:
  /// **'Recording'**
  String get recordingSection;

  /// No description provided for @recordingSampleRate.
  ///
  /// In en, this message translates to:
  /// **'Sample rate'**
  String get recordingSampleRate;

  /// No description provided for @autoGain.
  ///
  /// In en, this message translates to:
  /// **'Automatic gain control'**
  String get autoGain;

  /// No description provided for @echoCancel.
  ///
  /// In en, this message translates to:
  /// **'Echo cancellation'**
  String get echoCancel;

  /// No description provided for @noiseSuppress.
  ///
  /// In en, this message translates to:
  /// **'Noise suppression'**
  String get noiseSuppress;

  /// No description provided for @recordingDspHint.
  ///
  /// In en, this message translates to:
  /// **'Leave off for acoustic measurement'**
  String get recordingDspHint;

  /// No description provided for @presetAdultMale.
  ///
  /// In en, this message translates to:
  /// **'Adult male'**
  String get presetAdultMale;

  /// No description provided for @presetAdultFemale.
  ///
  /// In en, this message translates to:
  /// **'Adult female'**
  String get presetAdultFemale;

  /// No description provided for @presetChild.
  ///
  /// In en, this message translates to:
  /// **'Child'**
  String get presetChild;

  /// No description provided for @presetClassic.
  ///
  /// In en, this message translates to:
  /// **'Classic'**
  String get presetClassic;

  /// No description provided for @presetOkabeIto.
  ///
  /// In en, this message translates to:
  /// **'Okabe-Ito'**
  String get presetOkabeIto;

  /// No description provided for @presetHighVisibility.
  ///
  /// In en, this message translates to:
  /// **'High visibility'**
  String get presetHighVisibility;

  /// No description provided for @markSize.
  ///
  /// In en, this message translates to:
  /// **'Mark size'**
  String get markSize;

  /// No description provided for @colorOptionSemantics.
  ///
  /// In en, this message translates to:
  /// **'Color option for {track}'**
  String colorOptionSemantics(String track);

  /// No description provided for @minTimeStep.
  ///
  /// In en, this message translates to:
  /// **'Min time step'**
  String get minTimeStep;

  /// No description provided for @trackTimeStep.
  ///
  /// In en, this message translates to:
  /// **'Time step'**
  String get trackTimeStep;

  /// No description provided for @windowLength.
  ///
  /// In en, this message translates to:
  /// **'Window length'**
  String get windowLength;

  /// No description provided for @maxFrequency.
  ///
  /// In en, this message translates to:
  /// **'Max frequency'**
  String get maxFrequency;

  /// No description provided for @preEmphasisFrom.
  ///
  /// In en, this message translates to:
  /// **'Pre-emphasis from'**
  String get preEmphasisFrom;

  /// No description provided for @dynamicRange.
  ///
  /// In en, this message translates to:
  /// **'Dynamic range'**
  String get dynamicRange;

  /// No description provided for @floor.
  ///
  /// In en, this message translates to:
  /// **'Floor'**
  String get floor;

  /// No description provided for @ceiling.
  ///
  /// In en, this message translates to:
  /// **'Ceiling'**
  String get ceiling;

  /// No description provided for @count.
  ///
  /// In en, this message translates to:
  /// **'Count'**
  String get count;

  /// No description provided for @minimumPitch.
  ///
  /// In en, this message translates to:
  /// **'Minimum pitch'**
  String get minimumPitch;

  /// No description provided for @resetToDefaults.
  ///
  /// In en, this message translates to:
  /// **'Reset to defaults'**
  String get resetToDefaults;

  /// No description provided for @apply.
  ///
  /// In en, this message translates to:
  /// **'Apply'**
  String get apply;

  /// No description provided for @voiceReportTitle.
  ///
  /// In en, this message translates to:
  /// **'Voice report'**
  String get voiceReportTitle;

  /// No description provided for @voiceReportSelectionRange.
  ///
  /// In en, this message translates to:
  /// **'Selection {t0}–{t1} s'**
  String voiceReportSelectionRange(String t0, String t1);

  /// No description provided for @voiceReportWholeRange.
  ///
  /// In en, this message translates to:
  /// **'Whole recording, 0–{t1} s'**
  String voiceReportWholeRange(String t1);

  /// No description provided for @voiceReportPitchRange.
  ///
  /// In en, this message translates to:
  /// **'Pitch range {floor}–{ceiling} Hz'**
  String voiceReportPitchRange(String floor, String ceiling);

  /// No description provided for @medianF0Label.
  ///
  /// In en, this message translates to:
  /// **'Median F0'**
  String get medianF0Label;

  /// No description provided for @meanF0Label.
  ///
  /// In en, this message translates to:
  /// **'Mean F0'**
  String get meanF0Label;

  /// No description provided for @sdF0Label.
  ///
  /// In en, this message translates to:
  /// **'F0 SD'**
  String get sdF0Label;

  /// No description provided for @meanHnrLabel.
  ///
  /// In en, this message translates to:
  /// **'Mean HNR'**
  String get meanHnrLabel;

  /// No description provided for @jitterLocalLabel.
  ///
  /// In en, this message translates to:
  /// **'Jitter (local)'**
  String get jitterLocalLabel;

  /// No description provided for @shimmerLocalLabel.
  ///
  /// In en, this message translates to:
  /// **'Shimmer (local)'**
  String get shimmerLocalLabel;

  /// No description provided for @pulsePeriodsLabel.
  ///
  /// In en, this message translates to:
  /// **'Glottal periods'**
  String get pulsePeriodsLabel;

  /// No description provided for @voiceReportSparseHint.
  ///
  /// In en, this message translates to:
  /// **'Little steadily voiced material in this stretch; voice measures need a sustained voiced sound.'**
  String get voiceReportSparseHint;

  /// No description provided for @voiceReportFailed.
  ///
  /// In en, this message translates to:
  /// **'Voice report failed: {error}'**
  String voiceReportFailed(String error);

  /// No description provided for @reportCopied.
  ///
  /// In en, this message translates to:
  /// **'Report copied to clipboard'**
  String get reportCopied;

  /// No description provided for @saveSelectionWavTooltip.
  ///
  /// In en, this message translates to:
  /// **'Save selection as WAV'**
  String get saveSelectionWavTooltip;

  /// No description provided for @loopSelectionTooltip.
  ///
  /// In en, this message translates to:
  /// **'Loop selection'**
  String get loopSelectionTooltip;

  /// No description provided for @playbackRateTooltip.
  ///
  /// In en, this message translates to:
  /// **'Playback speed'**
  String get playbackRateTooltip;

  /// No description provided for @backupLibraryMenu.
  ///
  /// In en, this message translates to:
  /// **'Back up library…'**
  String get backupLibraryMenu;

  /// No description provided for @backupDone.
  ///
  /// In en, this message translates to:
  /// **'Backed up {count} recording(s) with manifest.csv'**
  String backupDone(int count);

  /// No description provided for @libraryEmpty.
  ///
  /// In en, this message translates to:
  /// **'Library is empty'**
  String get libraryEmpty;

  /// No description provided for @selectionSaved.
  ///
  /// In en, this message translates to:
  /// **'Selection saved'**
  String get selectionSaved;

  /// No description provided for @copy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copy;

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// No description provided for @editPitchTooltip.
  ///
  /// In en, this message translates to:
  /// **'Edit pitch'**
  String get editPitchTooltip;

  /// No description provided for @pitchEditHint.
  ///
  /// In en, this message translates to:
  /// **'Tap a candidate to choose it, or select a stretch.'**
  String get pitchEditHint;

  /// No description provided for @pitchEditedFrames.
  ///
  /// In en, this message translates to:
  /// **'{count} edited frame(s)'**
  String pitchEditedFrames(int count);

  /// No description provided for @octaveDownTooltip.
  ///
  /// In en, this message translates to:
  /// **'Octave down (selection)'**
  String get octaveDownTooltip;

  /// No description provided for @octaveUpTooltip.
  ///
  /// In en, this message translates to:
  /// **'Octave up (selection)'**
  String get octaveUpTooltip;

  /// No description provided for @unvoiceTooltip.
  ///
  /// In en, this message translates to:
  /// **'Set unvoiced (selection)'**
  String get unvoiceTooltip;

  /// No description provided for @voiceTooltip.
  ///
  /// In en, this message translates to:
  /// **'Set voiced (selection)'**
  String get voiceTooltip;

  /// No description provided for @revertPitchTooltip.
  ///
  /// In en, this message translates to:
  /// **'Revert to automatic (selection)'**
  String get revertPitchTooltip;

  /// No description provided for @exitPitchEditTooltip.
  ///
  /// In en, this message translates to:
  /// **'Stop editing pitch'**
  String get exitPitchEditTooltip;

  /// No description provided for @pitchEditsOtherSettings.
  ///
  /// In en, this message translates to:
  /// **'Pitch edits were made at time step {step} s, floor {floor} Hz, ceiling {ceiling} Hz. Restore those settings to use them, or discard them.'**
  String pitchEditsOtherSettings(String step, String floor, String ceiling);

  /// No description provided for @pitchEditsUnreadable.
  ///
  /// In en, this message translates to:
  /// **'The pitch edits file could not be read: {error}'**
  String pitchEditsUnreadable(String error);

  /// No description provided for @pitchEditsSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Pitch edits could not be saved: {error}'**
  String pitchEditsSaveFailed(String error);

  /// No description provided for @discardPitchEdits.
  ///
  /// In en, this message translates to:
  /// **'Discard edits'**
  String get discardPitchEdits;

  /// No description provided for @discardPitchEditsTitle.
  ///
  /// In en, this message translates to:
  /// **'Discard pitch edits?'**
  String get discardPitchEditsTitle;

  /// No description provided for @discardPitchEditsBody.
  ///
  /// In en, this message translates to:
  /// **'The stored corrections for this recording will be deleted.'**
  String get discardPitchEditsBody;

  /// No description provided for @skippedPitchEditMismatch.
  ///
  /// In en, this message translates to:
  /// **'{count} recording(s) skipped: their pitch edits were made at non-default pitch settings'**
  String skippedPitchEditMismatch(int count);
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
