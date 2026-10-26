import Flutter
import UIKit
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate {
    private let dsp = DSPManager.shared
    private var visualizerTimer: CADisplayLink?
    private var visualizerChannel: FlutterMethodChannel?
    private var projectMRenderer: ProjectMRenderer?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)

        // Configure audio session for playback
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            print("AVAudioSession setup failed: \(error)")
        }

        // Initialize DSP engine
        let sampleRate = Int(session.sampleRate)
        dsp.initialize(sampleRate: sampleRate > 0 ? sampleRate : 48000)

        // Pass DSP handle to audio tap
        if let handle = dsp.handle {
            HypeAudioTap.shared().setDspHandle(handle)
        }

        // Set up MethodChannel
        if let controller = window?.rootViewController as? FlutterViewController {
            let channel = FlutterMethodChannel(name: "eq_app",
                                                binaryMessenger: controller.binaryMessenger)
            channel.setMethodCallHandler { [weak self] call, result in
                self?.handleMethodCall(call, result: result)
            }

            // Separate channel for visualizer data (matches Android pattern)
            visualizerChannel = channel

            // Live stems: engine init + status events (HypeDSP/src/stems)
            StemsBridge.shared.attach(messenger: controller.binaryMessenger)

            // Screen brightness, for the swipe gesture on the video screen.
            //
            // iOS has no per-window override, so this is the device brightness
            // and it persists after the app is closed — the same bargain every
            // iOS video player makes, and the reason the value is restored when
            // the full-screen route is left rather than on app exit.
            let brightnessChannel = FlutterMethodChannel(
                name: "eq_app/screen_brightness",
                binaryMessenger: controller.binaryMessenger)
            brightnessChannel.setMethodCallHandler { call, result in
                switch call.method {
                case "get":
                    result(Double(UIScreen.main.brightness))
                case "set":
                    let value = (call.arguments as? [String: Any])?["value"] as? Double
                    if let value = value {
                        UIScreen.main.brightness = CGFloat(min(max(value, 0.01), 1.0))
                    }
                    result(nil)
                case "keepAwake":
                    // The idle timer is the iOS equivalent of FLAG_KEEP_SCREEN_ON.
                    // Set only while a picture is on screen; audio-only playback
                    // leaves it alone, so locking the phone during a song still
                    // works as it should.
                    let on = (call.arguments as? [String: Any])?["on"] as? Bool ?? false
                    UIApplication.shared.isIdleTimerDisabled = on
                    result(nil)
                default:
                    result(FlutterMethodNotImplemented)
                }
            }
        }

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    // MARK: - Open audio files from other apps (Safari, Files, AirDrop, etc.)

    override func application(_ app: UIApplication, open url: URL,
                              options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        // Check if this is an audio file
        let ext = url.pathExtension.lowercased()
        let audioExts: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "ogg", "wma", "aiff", "alac"]
        if audioExts.contains(ext) {
            copyToMusicFolder(url)
            return true
        }
        return super.application(app, open: url, options: options)
    }

    private func copyToMusicFolder(_ url: URL) {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let musicDir = docs.appendingPathComponent("Music")

        // Create Music directory if needed
        if !fm.fileExists(atPath: musicDir.path) {
            try? fm.createDirectory(at: musicDir, withIntermediateDirectories: true)
        }

        let destURL = musicDir.appendingPathComponent(url.lastPathComponent)

        // Access security-scoped resource (for files from other apps)
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        do {
            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            try fm.copyItem(at: url, to: destURL)
            print("Hype: Imported \(url.lastPathComponent) to Music folder")

            // Notify Dart side that a new file was imported
            if let channel = visualizerChannel {
                DispatchQueue.main.async {
                    channel.invokeMethod("onFileImported", arguments: [
                        "path": destURL.path,
                        "name": url.lastPathComponent,
                    ])
                }
            }
        } catch {
            print("Hype: Failed to import \(url.lastPathComponent): \(error)")
        }
    }

    // MARK: - Visualizer Timer

    private func startVisualizerTimer() {
        guard visualizerTimer == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(sendVisualizerData))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        visualizerTimer = link
    }

    private func stopVisualizerTimer() {
        visualizerTimer?.invalidate()
        visualizerTimer = nil
    }

    @objc private func sendVisualizerData() {
        guard let channel = visualizerChannel else { return }
        let tap = HypeAudioTap.shared()

        // Send waveform as raw bytes (NSData → Uint8List in Dart, matches Android byte[])
        if let waveform = tap.latestWaveformBytes() {
            let args: [String: Any] = [
                "waveform": FlutterStandardTypedData(bytes: waveform),
                "sampleRate": tap.currentSampleRate()
            ]
            channel.invokeMethod("onWaveformVisualization", arguments: args)
        }

        // The bass report rides along with the FFT (see BeatFrame in Dart).
        let beat = tap.takeBeatFrame()
        let fft = tap.latestFftBytes()
        if fft != nil || beat != nil {
            var args: [String: Any] = [:]
            if let fft = fft { args["fft"] = FlutterStandardTypedData(bytes: fft) }
            if let beat = beat { args["beat"] = FlutterStandardTypedData(float32: beat) }
            channel.invokeMethod("onFftVisualization", arguments: args)
        }
    }

    // MARK: - MethodChannel Handler

    private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]

        switch call.method {

        // ==================== EQ ====================
        case "init":
            result(nil)

        case "enableEq":
            let enable = args?["enable"] as? Bool ?? false
            dsp.setEqEnabled(enable)
            result(nil)

        case "isEnabled":
            result(true)

        case "setPreamp":
            let gain = floatArg(args, "gain")
            dsp.setPreampGain(gain)
            result(nil)

        case "getPreamp":
            result(Double(dsp.cachedPreampGain))

        case "enableMbc":
            let enable = args?["enable"] as? Bool ?? false
            dsp.setMbcEnabled(enable)
            result(nil)

        case "isMbcEnabled":
            result(dsp.cachedMbcEnabled)

        // ==================== Legacy EQ (safe defaults) ====================
        case "getPresetNames":
            result(["Flat", "Rock", "Pop", "Jazz", "Classical", "Bass Boost", "Treble Boost"])

        case "setPreset":
            result(nil)

        case "setBandLevel":
            result(nil)

        case "getBandLevelRange":
            result([-1500, 1500])

        case "getBandLevel":
            result(0)

        case "getSettings":
            result("")

        case "setSettings":
            result(nil)

        case "getBandFreq":
            result([60, 230, 910, 3600, 14000])

        // ==================== Bass Boost (legacy — handled by DSP pipeline) ====================
        case "initBassBoost":
            result(nil)

        case "enableBassBoost":
            result(nil)

        case "isBassEnabled":
            result(false)

        case "bassBoostStrength":
            result(0)

        case "setBassBoostStrength":
            result(nil)

        // ==================== Loudness Enhancer ====================
        case "initLoudnessEnhancer":
            result(nil)

        case "enableLoudnessEnhancer":
            result(nil)

        case "loudnessEnhancerEnabled":
            result(false)

        case "loudnessEnhancerStrength":
            result(0.0)

        case "setLoudnessEnhancerStrength":
            result(nil)

        // ==================== DVC (Limited on iOS) ====================
        case "enableDvc":
            result(nil)

        case "disableDvc":
            result(nil)

        case "setDvcGain":
            result(nil)

        case "getDvcGain":
            result(0.0)

        case "isDvcActive":
            result(false)

        case "getSystemVolume":
            let vol = AVAudioSession.sharedInstance().outputVolume
            result(Int(vol * 16))

        case "getSystemMaxVolume":
            result(16)

        // ==================== MBC Compressor ====================
        case "setDspNoiseThreshold":
            dsp.setMbcNoiseGate(floatArg(args, "noiseThreshold"))
            result(nil)

        case "setPreGain":
            dsp.setMbcPreGain(floatArg(args, "preGain"))
            result(nil)

        case "expandRatio":
            dsp.setMbcExpanderRatio(floatArg(args, "expandRatio"))
            result(nil)

        case "kneeWidth":
            dsp.setMbcKneeWidth(floatArg(args, "kneeWidth"))
            result(nil)

        // ==================== Tone Controls ====================
        case "dspSetToneEnabled":
            dsp.setToneEnabled(args?["enabled"] as? Bool ?? false)
            result(nil)

        case "dspSetBassGain":
            dsp.setBassGain(floatArg(args, "value"))
            result(nil)

        case "dspSetBassFreq":
            dsp.setBassFreq(floatArg(args, "value"))
            result(nil)

        case "dspSetBassQ":
            dsp.setBassQ(floatArg(args, "value"))
            result(nil)

        case "dspSetTrebleGain":
            dsp.setTrebleGain(floatArg(args, "value"))
            result(nil)

        case "dspSetTrebleFreq":
            dsp.setTrebleFreq(floatArg(args, "value"))
            result(nil)

        case "dspSetTrebleQ":
            dsp.setTrebleQ(floatArg(args, "value"))
            result(nil)

        // ==================== Output Limiter ====================
        case "dspSetLimiterEnabled":
            dsp.setLimiterEnabled(args?["enabled"] as? Bool ?? true)
            result(nil)

        case "dspSetLimiterCeiling":
            dsp.setLimiterCeiling(floatArg(args, "value"))
            result(nil)

        case "dspSetLimiterRelease":
            dsp.setLimiterRelease(floatArg(args, "value"))
            result(nil)

        case "dspSetLimiterKnee":
            dsp.setLimiterKnee(floatArg(args, "value"))
            result(nil)

        // ==================== 32-Band Graphic EQ ====================
        case "setGraphicBandGain":
            let band = args?["band"] as? Int ?? 0
            let gain = floatArg(args, "gain")
            dsp.setGraphicBandGain(band: band, dB: gain)
            result(nil)

        case "getGraphicBandGain":
            result(0.0)

        case "setGraphicAllBands":
            if let gains = args?["gains"] as? [Double] {
                dsp.setGraphicAllBands(gains.map { Float($0) })
            }
            result(nil)

        case "getGraphicAllBands":
            result([Double]())

        // ==================== 32-Band Parametric EQ ====================
        case "setParametricBand":
            let band = args?["band"] as? Int ?? 0
            let freq = floatArg(args, "freq")
            let gain = floatArg(args, "gain")
            let q = args?["q"] != nil ? floatArg(args, "q") : 1.4
            let filterType = args?["filterType"] as? Int ?? 0
            let enabled = args?["enabled"] as? Bool ?? true
            dsp.setParametricBand(band: band, freq: freq, gain: gain, q: q,
                                   filterType: filterType, enabled: enabled)
            result(nil)

        case "setParametricAllBands":
            if let freqs = args?["freqs"] as? [Double],
               let gains = args?["gains"] as? [Double] {
                let qs = (args?["qs"] as? [Double]) ?? Array(repeating: 1.4, count: freqs.count)
                dsp.setParametricAllBands(freqs: freqs.map { Float($0) },
                                           gains: gains.map { Float($0) },
                                           qs: qs.map { Float($0) })
            }
            result(nil)

        // ==================== Speaker Correction EQ ====================
        case "setSpeakerEqEnabled":
            dsp.setSpeakerEqEnabled(args?["enabled"] as? Bool ?? false)
            result(nil)

        case "setSpeakerEqBands":
            if let freqs = args?["freqs"] as? [Double],
               let gains = args?["gains"] as? [Double],
               let qs = args?["qs"] as? [Double],
               let types = args?["types"] as? [Int] {
                for i in 0..<min(freqs.count, gains.count, qs.count, types.count) {
                    dsp.setSpeakerEqBand(band: i, freq: Float(freqs[i]),
                                          gain: Float(gains[i]), q: Float(qs[i]),
                                          filterType: types[i], enabled: true)
                }
            }
            result(nil)

        case "clearSpeakerEq":
            dsp.clearSpeakerEq()
            result(nil)

        // ==================== Room Effects ====================
        case "dspSetReverbEnabled":
            dsp.setReverbEnabled(args?["enabled"] as? Bool ?? false)
            result(nil)

        case "dspSetRoomSize":
            dsp.setRoomSize(floatArg(args, "value"))
            result(nil)

        case "dspSetDecay":
            dsp.setDecay(floatArg(args, "value"))
            result(nil)

        case "dspSetDamping":
            dsp.setDamping(floatArg(args, "value"))
            result(nil)

        case "dspSetPreDelay":
            dsp.setPreDelay(floatArg(args, "value"))
            result(nil)

        case "dspSetDiffusion":
            dsp.setDiffusion(floatArg(args, "value"))
            result(nil)

        case "dspSetReverbWetDry":
            dsp.setReverbWetDry(floatArg(args, "value"))
            result(nil)

        case "dspSetStereoExpandEnabled":
            dsp.setStereoExpandEnabled(args?["enabled"] as? Bool ?? false)
            result(nil)

        case "dspSetStereoWidth":
            dsp.setStereoWidth(floatArg(args, "value"))
            result(nil)

        case "dspSetCrossfeedEnabled":
            dsp.setCrossfeedEnabled(args?["enabled"] as? Bool ?? false)
            result(nil)

        case "dspSetCrossfeedParams":
            let cutoff = floatArg(args, "cutoff")
            let feed = floatArg(args, "feed")
            dsp.setCrossfeedParams(cutoff: cutoff, feed: feed)
            result(nil)

        case "dspSetSurround3dEnabled":
            dsp.setSurround3dEnabled(args?["enabled"] as? Bool ?? false)
            result(nil)

        case "dspSetSurround3dParams":
            dsp.setSurround3dParams(intensity: floatArg(args, "intensity"),
                                    subwoofer: floatArg(args, "subwoofer"))
            result(nil)

        case "dspSetSurround3dSpeakers":
            dsp.setSurround3dSpeakers(
                frontL: args?["frontL"] as? Bool ?? true,
                frontR: args?["frontR"] as? Bool ?? true,
                sideL: args?["sideL"] as? Bool ?? true,
                sideR: args?["sideR"] as? Bool ?? true,
                surroundL: args?["surroundL"] as? Bool ?? true,
                surroundR: args?["surroundR"] as? Bool ?? true)
            result(nil)

        // ==================== Live Stems ====================
        case "stemsLoadModel", "stemsUnloadModel", "stemsBenchmark", "stemsSetArmed",
             "stemsSetLevels", "stemsProvideStream", "stemsGetStatus":
            StemsBridge.shared.handle(call, result: result)

        // ==================== Global EQ (Not available on iOS) ====================
        case "enableGlobalEq":
            result(false)

        case "isGlobalEqEnabled":
            result(false)

        case "isGlobalEqAvailable":
            result(false)

        // ==================== Device Detection ====================
        case "isDynamicsProcessingAvailable":
            result(true)

        case "getAudioOutputType":
            result(getAudioOutputType())

        // ==================== Audio Metadata Extraction ====================
        case "extractAudioMetadata":
            if let url = args?["url"] as? String {
                let artPath = args?["artworkPath"] as? String
                let headers = args?["headers"] as? [String: String] ?? [:]
                extractMetadata(url: url, headers: headers, artworkPath: artPath, result: result)
            } else {
                result(nil)
            }
            return // async

        // ==================== Audio Fingerprinting ====================
        case "generateFingerprint":
            result(nil)

        // ==================== Tag Writing ====================
        case "writeTags":
            result(false)

        case "scanMediaFile":
            result(nil)

        // ==================== Sharing ====================
        case "shareText":
            presentShareSheet(items: [args?["text"] as? String ?? ""], result: result)

        case "shareAudio":
            guard let path = args?["filePath"] as? String,
                  FileManager.default.fileExists(atPath: path) else {
                result(false)
                return
            }
            presentShareSheet(items: [URL(fileURLWithPath: path)], result: result)

        // ==================== YouTube downloads ====================
        case "finishYtDownload":
            guard let src = args?["src"] as? String, let dst = args?["dst"] as? String else {
                result(false)
                return
            }
            let tags = args?["tags"] as? [String: Any] ?? [:]
            YtDownloadFinisher.finish(src: src, dst: dst, tags: tags) { error in
                if let error { NSLog("YtDownloadFinisher: \(error)") }
                DispatchQueue.main.async { result(error.map { $0 as Any } ?? true) }
            }

        case "replaceAudioFiles":
            let files = args?["files"] as? [[String: String]] ?? []
            DispatchQueue.global(qos: .utility).async {
                let done = YtDownloadFinisher.replace(files)
                DispatchQueue.main.async { result(done) }
            }

        // ==================== Lyrics ====================
        case "readLyrics":
            if let filePath = args?["filePath"] as? String {
                result(readLyricsFromFile(filePath))
            } else {
                result(nil)
            }

        case "writeLyrics":
            result(false)

        // ==================== Visualizer ====================
        case "activate_visualizer":
            HypeAudioTap.shared().visualizerEnabled = true
            startVisualizerTimer()
            result(nil)

        case "enableVisual":
            let enable = args?["enableVisual"] as? Bool ?? false
            HypeAudioTap.shared().visualizerEnabled = enable
            if enable {
                startVisualizerTimer()
            } else {
                stopVisualizerTimer()
            }
            result(nil)

        case "getEnabled":
            result(HypeAudioTap.shared().visualizerEnabled)

        case "deactivate_visualizer":
            HypeAudioTap.shared().visualizerEnabled = false
            stopVisualizerTimer()
            result(nil)

        case "setScalingMode", "setFrameRate":
            result(nil)

        // ==================== projectM Visualizer ====================
        case "projectm_init":
            let w = args?["width"] as? Int ?? 720
            let h = args?["height"] as? Int ?? 480
            // Idempotent: release any existing renderer before creating a new
            // one. Without this, re-opening the visualizer (or reopening with a
            // new size) overwrote projectMRenderer, leaking the prior EAGL
            // context, FBOs/renderbuffers, CVPixelBuffers and the registered
            // Flutter texture.
            projectMRenderer?.release()
            projectMRenderer = nil
            if let controller = window?.rootViewController as? FlutterViewController {
                let renderer = ProjectMRenderer()
                let texId = renderer.initialize(
                    registrar: controller.engine.textureRegistry,
                    width: w, height: h
                )
                if let texId = texId {
                    projectMRenderer = renderer
                    // Enable visualization tap so projectM gets PCM data
                    HypeAudioTap.shared().visualizerEnabled = true
                    result(texId)
                } else {
                    result(-1)
                }
            } else {
                result(-1)
            }

        case "projectm_start":
            projectMRenderer?.start()
            result(nil)

        case "projectm_stop":
            projectMRenderer?.stop()
            result(nil)

        case "projectm_release":
            projectMRenderer?.release()
            projectMRenderer = nil
            result(nil)

        case "projectm_set_preset":
            if let path = args?["path"] as? String {
                result(projectMRenderer?.loadPresetByIndex(0) ?? "")
            } else {
                result("")
            }

        case "projectm_next_preset":
            result(projectMRenderer?.nextPreset() ?? "")

        case "projectm_prev_preset":
            result(projectMRenderer?.previousPreset() ?? "")

        case "projectm_load_preset_index":
            let index = args?["index"] as? Int ?? 0
            result(projectMRenderer?.loadPresetByIndex(index) ?? "")

        case "projectm_list_presets":
            result(projectMRenderer?.listPresets() ?? [String]())

        case "projectm_current_preset":
            result(projectMRenderer?.getCurrentPresetName() ?? "")

        case "projectm_set_fps":
            let fps = args?["fps"] as? Int ?? 30
            projectMRenderer?.setFps(fps)
            result(nil)

        case "projectm_set_beat_sensitivity":
            let sensitivity = floatArg(args, "sensitivity")
            projectMRenderer?.setBeatSensitivity(sensitivity)
            result(nil)

        case "projectm_set_preset_duration":
            let seconds = args?["seconds"] as? Double ?? 30.0
            projectMRenderer?.setPresetDuration(seconds)
            result(nil)

        case "projectm_set_preset_locked":
            let locked = args?["locked"] as? Bool ?? false
            projectMRenderer?.setPresetLocked(locked)
            result(nil)

        case "projectm_set_size":
            let w = args?["width"] as? Int ?? 720
            let h = args?["height"] as? Int ?? 480
            projectMRenderer?.setSize(w, h)
            result(nil)

        case "projectm_set_mesh_size":
            let w = args?["width"] as? Int ?? 32
            let h = args?["height"] as? Int ?? 24
            projectMRenderer?.setMeshSize(w, h)
            result(nil)

        // ==================== Preset Reverb (legacy) ====================
        case "initPresetReverb", "enablePresetReverb", "setReverbPreset":
            result(nil)

        case "getReverbPreset":
            result(0)

        // ==================== Delete Manager ====================
        case "deleteManager":
            // Reports whether it worked. It used to swallow the error with
            // `try?` and answer nil either way, so a delete that failed — a
            // file outside the sandbox, a path that no longer existed — was
            // indistinguishable from one that succeeded, and the caller
            // cheerfully removed the row from the library.
            if let path = args?["filePath"] as? String {
                do {
                    try FileManager.default.removeItem(atPath: path)
                    result(true)
                } catch {
                    NSLog("deleteManager failed for \(path): \(error)")
                    result(false)
                }
            } else {
                result(false)
            }

        // Deleting ONE track. Separate from the folder case above so the two
        // platforms present the same channel surface — Android needs its own
        // method there because a track and a directory take entirely different
        // routes through scoped storage.
        case "deleteAudio":
            if let path = args?["filePath"] as? String {
                let fm = FileManager.default
                if !fm.fileExists(atPath: path) {
                    // Already gone. The caller wanted it absent, and it is.
                    result(true)
                } else if !fm.isDeletableFile(atPath: path) {
                    // Anything the Music app owns lives outside this sandbox and
                    // cannot be removed by us. Saying so is better than a silent
                    // no-op that leaves the track in the library.
                    NSLog("deleteAudio refused, not deletable: \(path)")
                    result(false)
                } else {
                    do {
                        try fm.removeItem(atPath: path)
                        result(true)
                    } catch {
                        NSLog("deleteAudio failed for \(path): \(error)")
                        result(false)
                    }
                }
            } else {
                result(false)
            }

        case "showNativeMessage":
            result(nil)

        // ==================== Legacy DSP stubs ====================
        case "initDSPEngine", "enableDSP", "disposeDSP", "setDSPSpeakers",
             "setDSPXBass", "setExtraBass", "setDSPPowerBass", "setDSPXTreble",
             "setDSPVolume", "setTunerBass", "setCutOffFreq", "setTrebleFreq",
             "setTunerVocal":
            result(nil)

        case "getVocalLevel":
            result(0.0)

        case "release":
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Helpers

    private func floatArg(_ args: [String: Any]?, _ key: String) -> Float {
        if let v = args?[key] as? Double { return Float(v) }
        if let v = args?[key] as? Int { return Float(v) }
        if let v = args?[key] as? Float { return v }
        return 0.0
    }

    private func getAudioOutputType() -> String {
        let route = AVAudioSession.sharedInstance().currentRoute
        for output in route.outputs {
            switch output.portType {
            case .headphones, .headsetMic:
                return "headset"
            case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP:
                return "bluetooth"
            case .builtInSpeaker:
                return "speaker"
            case .airPlay:
                return "airplay"
            case .carAudio:
                return "car"
            default:
                return "other"
            }
        }
        return "speaker"
    }

    private func extractMetadata(url: String, headers: [String: String],
                                  artworkPath: String?,
                                  result: @escaping FlutterResult) {
        DispatchQueue.global(qos: .userInitiated).async {
            var metadata: [String: Any] = [:]
            var asset: AVAsset?

            if url.hasPrefix("http://") || url.hasPrefix("https://") {
                guard let assetUrl = URL(string: url) else {
                    DispatchQueue.main.async { result(nil) }
                    return
                }
                if headers.isEmpty {
                    asset = AVURLAsset(url: assetUrl)
                } else {
                    asset = AVURLAsset(url: assetUrl, options: [
                        "AVURLAssetHTTPHeaderFieldsKey": headers
                    ])
                }
            } else {
                let fileUrl = URL(fileURLWithPath: url)
                guard FileManager.default.fileExists(atPath: url) else {
                    DispatchQueue.main.async { result(nil) }
                    return
                }
                asset = AVURLAsset(url: fileUrl)
            }

            guard let avAsset = asset else {
                DispatchQueue.main.async { result(nil) }
                return
            }

            for item in avAsset.commonMetadata {
                if let key = item.commonKey {
                    switch key {
                    case .commonKeyTitle:
                        metadata["title"] = item.stringValue
                    case .commonKeyArtist:
                        metadata["artist"] = item.stringValue
                    case .commonKeyAlbumName:
                        metadata["album"] = item.stringValue
                    case .commonKeyArtwork:
                        if let artPath = artworkPath, let data = item.dataValue {
                            try? data.write(to: URL(fileURLWithPath: artPath))
                            metadata["hasArtwork"] = true
                        }
                    default:
                        break
                    }
                }
            }

            let durationMs = Int(CMTimeGetSeconds(avAsset.duration) * 1000)
            if durationMs > 0 {
                metadata["durationMs"] = durationMs
            }

            DispatchQueue.main.async {
                result(metadata)
            }
        }
    }

    private func readLyricsFromFile(_ filePath: String) -> String? {
        let url = URL(fileURLWithPath: filePath)
        let asset = AVURLAsset(url: url)

        for item in asset.metadata {
            if let key = item.identifier,
               key.rawValue.contains("lyrics") || key.rawValue.contains("USLT") {
                return item.stringValue
            }
        }

        if let lyrics = asset.lyrics {
            return lyrics
        }

        return nil
    }

    /// The system share sheet over whatever is showing. On iPad it must be
    /// anchored or UIKit throws; it is pinned to the bottom centre, under the
    /// song's actions it was opened from.
    private func presentShareSheet(items: [Any], result: @escaping FlutterResult) {
        DispatchQueue.main.async {
            guard var top = self.window?.rootViewController else {
                result(false)
                return
            }
            while let presented = top.presentedViewController { top = presented }
            let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
            if let popover = sheet.popoverPresentationController {
                popover.sourceView = top.view
                popover.sourceRect = CGRect(
                    x: top.view.bounds.midX, y: top.view.bounds.maxY - 120,
                    width: 1, height: 1)
                popover.permittedArrowDirections = []
            }
            top.present(sheet, animated: true)
            result(true)
        }
    }
}
