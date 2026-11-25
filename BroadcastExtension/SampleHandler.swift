import ReplayKit
import CoreMedia
import CoreVideo
import Foundation

/// 屏幕广播扩展：采集整屏 → VideoToolbox 硬编 H.264 → 自己监听 9200 推给电脑
/// 网络层用 POSIX socket（PSListener），不依赖 Network.framework → 支持 iOS 11+
final class SampleHandler: RPBroadcastSampleHandler {
    private var encoder: H264Encoder!
    private let server = ExtStreamServer()
    private var frameCount = 0

    override func broadcastStarted(withSetupInfo: [String: NSObject]?) {
        NSLog("[SM] broadcastStarted")
        frameCount = 0
        server.start(port: 9200)
        encoder = H264Encoder(onConfig: { [weak self] sps, pps in self?.server.sendConfig(sps: sps, pps: pps) },
                              onFrame: { [weak self] data, pts, key in self?.server.sendFrame(data, ptsMs: pts, key: key) })
    }

    override func broadcastPaused() {}
    override func broadcastResumed() {}

    override func broadcastFinished() {
        NSLog("[SM] broadcastFinished")
        encoder = nil
        server.stop()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        if sampleBufferType == .video && frameCount < 3 {
            let pb = CMSampleBufferGetImageBuffer(sampleBuffer)
            let w = pb.map { CVPixelBufferGetWidth($0) } ?? 0
            let h = pb.map { CVPixelBufferGetHeight($0) } ?? 0
            NSLog("[SM] video sample #\(frameCount) \(w)x\(h)")
        }
        guard sampleBufferType == .video else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if encoder == nil {
            encoder = H264Encoder(onConfig: { [weak self] sps, pps in self?.server.sendConfig(sps: sps, pps: pps) },
                                  onFrame: { [weak self] data, pts, key in self?.server.sendFrame(data, ptsMs: pts, key: key) })
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        frameCount += 1
        encoder?.encode(pixelBuffer, presentationTime: pts)
    }
}

/// 扩展内的 TCP 服务：监听 9200，把 H.264（SMH1 协议）推给所有连上来的电脑
final class ExtStreamServer {
    private let listener = PSListener(label: "ext.stream")
    private(set) var prologue = Data()
    private var hasConfig = false

    func start(port: UInt16) {
        listener.start(port: port) { [weak self] client in
            guard let self = self else { return }
            // 电脑中途连上来：先补发魔数 + 配置包
            if !self.prologue.isEmpty { client.send(self.prologue) }
        }
    }

    func sendConfig(sps: Data, pps: Data) {
        var payload = Data()
        payload.append(UInt8((sps.count >> 8) & 0xff)); payload.append(UInt8(sps.count & 0xff)); payload.append(sps)
        payload.append(UInt8((pps.count >> 8) & 0xff)); payload.append(UInt8(pps.count & 0xff)); payload.append(pps)
        var packet = Data("SMH1".utf8)
        packet.append(0)
        var n = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &n) { packet.append(contentsOf: $0) }
        packet.append(payload)
        hasConfig = true
        prologue = packet
        listener.broadcast(packet, except: nil)
    }

    func sendFrame(_ avcc: Data, ptsMs: UInt32, key: Bool) {
        if !hasConfig && prologue.isEmpty {
            // 还没拿到 SPS/PPS：先不发帧，避免客户端解不出来
        }
        var payload = Data(capacity: avcc.count + 5)
        payload.append(key ? 1 : 0)
        payload.append(UInt8((ptsMs >> 24) & 0xff))
        payload.append(UInt8((ptsMs >> 16) & 0xff))
        payload.append(UInt8((ptsMs >> 8) & 0xff))
        payload.append(UInt8(ptsMs & 0xff))
        payload.append(avcc)
        var packet = Data()
        packet.append(1)
        var n = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &n) { packet.append(contentsOf: $0) }
        packet.append(payload)
        listener.broadcast(packet, except: nil)
    }

    func stop() {
        listener.stop()
    }
}
