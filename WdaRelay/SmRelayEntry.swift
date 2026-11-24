import Foundation
import AVFoundation

private var keepAliveEngine: AVAudioEngine?
private var keepAlivePlayer: AVAudioPlayerNode?

/// 由 ObjC 的 constructor 调用：dylib 一被 dyld 加载就进来
@_cdecl("sm_relay_entry")
public func sm_relay_entry() {
    // 等 UIKit / 主队列就绪再起服务
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        SmRelayServer.shared.start(port: 9200)
        SmTouchBridge.shared.start(port: 9300)
        startKeepAlive()
        NSLog("[SmRelay] started 9200/9300")
    }
}

/// 静音循环播放，降低 WDA 进程切后台被挂起的概率
private func startKeepAlive() {
    guard keepAliveEngine == nil else { return }
    do {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1) else { return }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.start()

        let frames: AVAudioFrameCount = 4096
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buf.frameLength = frames
        player.scheduleBuffer(buf, at: nil, options: [.loops], completionHandler: nil)
        player.play()

        keepAliveEngine = engine
        keepAlivePlayer = player
    } catch {
        NSLog("[SmRelay] keepalive failed: %@", error.localizedDescription)
    }
}
