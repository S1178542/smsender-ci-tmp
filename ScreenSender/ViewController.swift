import UIKit
import AVFoundation

/// 宿主 App：监听 9200 做中转 + 用静音音频保持后台存活
final class ViewController: UIViewController {
    private let server = RelayServer()
    private let control = ControlServer()
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let stepsLabel = UILabel()

    private var audioEngine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var audioFormat: AVAudioFormat?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        titleLabel.text = "神目投屏"
        titleLabel.textColor = .white
        titleLabel.font = .boldSystemFont(ofSize: 26)
        titleLabel.textAlignment = .center

        statusLabel.text = "正在启动…"
        statusLabel.textColor = .systemGreen
        statusLabel.font = .systemFont(ofSize: 15)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0

        stepsLabel.text = """
        使用方法
        1. 保持本 App 在后台运行（不要上滑杀掉）
        2. 打开「控制中心」→ 长按「屏幕录制」
        3. 选择「神目投屏」→ 开始直播（触控走 9300，无需其它 App）
        4. 回到电脑，点连接

        说明：本 App 只负责把画面编码后经 USB 交给电脑，
        不采集麦克风，不上传任何数据。
        """
        stepsLabel.textColor = .lightGray
        stepsLabel.font = .systemFont(ofSize: 14)
        stepsLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [titleLabel, statusLabel, stepsLabel])
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        server.onStatus = { [weak self] text in
            DispatchQueue.main.async {
                self?.statusLabel.text = text + "\n等待电脑连接…"
            }
        }
        server.start(port: 9200)
        control.onStatus = { [weak self] text in
            DispatchQueue.main.async { self?.statusLabel.text = text }
        }
        control.start(port: 9300)
        keepAliveInBackground()
    }

    // MARK: - 后台保活：播静音，声明 audio 后台模式
    private func keepAliveInBackground() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            statusLabel.text = "音频会话失败：\(error.localizedDescription)"
        }

        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2) else { return }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            statusLabel.text = "保活音频启动失败：\(error.localizedDescription)"
            return
        }
        node.play()
        audioEngine = engine
        player = node
        audioFormat = format
        scheduleSilence()
    }

    private func scheduleSilence() {
        guard let node = player, let format = audioFormat else { return }
        let frames = AVAudioFrameCount(44100)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        if let channels = buffer.floatChannelData {
            for i in 0..<Int(format.channelCount) {
                memset(channels[i], 0, Int(frames) * MemoryLayout<Float>.size)
            }
        }
        node.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            self?.scheduleSilence()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // 不要停 server：回后台还要继续中转
    }
}
