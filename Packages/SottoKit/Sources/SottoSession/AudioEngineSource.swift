#if canImport(AVFAudio)
import SottoAudio

/// The AVAudioEngine controller is the production `AudioSource`.
extension AudioEngineController: AudioSource {}
#endif
