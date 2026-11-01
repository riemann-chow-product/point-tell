import Cocoa
import AVFoundation
import Speech

/// 按住 ⌥ 说话：实时把语音变成面板里的指令文本。
/// 隐私优先：优先走设备端识别（requiresOnDeviceRecognition）。
final class SpeechRecognizer {

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let engine = AVAudioEngine()

    private(set) var isRunning = false
    private var startTime = Date()

    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onError: ((String) -> Void)?

    // MARK: 权限

    static func requestPermissions(_ completion: @escaping (Bool, String?) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                DispatchQueue.main.async {
                    completion(false, "语音识别未授权（系统设置 › 隐私与安全性 › 语音识别）")
                }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted {
                        completion(true, nil)
                    } else {
                        completion(false, "麦克风未授权（系统设置 › 隐私与安全性 › 麦克风）")
                    }
                }
            }
        }
    }

    // MARK: 开始 / 停止

    func start() {
        guard !isRunning else { return }
        let locale = Locale(identifier: Settings.shared.speechLocale)
        guard let rec = SFSpeechRecognizer(locale: locale), rec.isAvailable else {
            onError?("当前语言不可用的语音识别：\(locale.identifier)")
            return
        }
        recognizer = rec

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if Settings.shared.preferOnDeviceSpeech, rec.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }
        request = req

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        if format.sampleRate <= 0 || format.channelCount == 0 {
            onError?("找不到可用的麦克风输入")
            return
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak req] buffer, _ in
            req?.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            onError?("麦克风启动失败：\(error.localizedDescription)")
            return
        }

        startTime = Date()
        isRunning = true

        task = rec.recognitionTask(with: req) { [weak self] result, error in
            guard let self = self else { return }
            if let r = result {
                let text = r.bestTranscription.formattedString
                DispatchQueue.main.async {
                    if r.isFinal {
                        self.onFinal?(text)
                    } else {
                        self.onPartial?(text)
                    }
                }
            }
            if error != nil && self.isRunning {
                // 静音超时之类的错误：直接收尾，不要把错误糊到用户脸上
                DispatchQueue.main.async {
                    self.stop()
                }
            }
        }
        PTLog.write("speech start locale=\(locale.identifier)")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
        PTLog.write("speech stop after \(Int(Date().timeIntervalSince(startTime)))s")
    }
}
