import ReplayKit
import CoreMedia
import CoreVideo
import Network
import Foundation

/// 屏幕广播扩展：采集整屏 → VideoToolbox 硬编 H.264 → 自己监听 9200 推给电脑
/// 【关键】监听放在扩展里，不再依赖宿主 App，所以这个包可以直接和 WDA 驱动包合并成一个 App
final class SampleHandler: RPBroadcastSampleHandler {
    private var encoder: H264Encoder!
    private let server = ExtStreamServer()
    private var frameCount = 0

    override func broadcastStarted(withSetupInfo: [String: NSObject]?) {
        NSLog("[SM] broadcastStarted")
        frameCount = 0
        server.start(port: 9200)
        encoder = H264Encoder(onConfig: { [weak self] sps, pps in self?.server.sendConfig(sps: sps, pps: pps) }, onFrame: { [weak self] data, pts, key in self?.server.sendFrame(data, ptsMs: pts, key: key) })
    }

    override func broadcastPaused() {}
    override func broadcastResumed() {}

    override func broadcastFinished() {
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
        if encoder == nil { encoder = H264Encoder(onConfig: { [weak self] sps, pps in self?.server.sendConfig(sps: sps, pps: pps) }, onFrame: { [weak self] data, pts, key in self?.server.sendFrame(data, ptsMs: pts, key: key) }) }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        frameCount += 1
        encoder?.encode(pixelBuffer, presentationTime: pts)
    }
}

/// 扩展内的 TCP 服务：监听 9200，把 H.264（SMH1 协议）推给所有连上来的电脑
final class ExtStreamServer {
    private var listener: NWListener?
    private var clients: [NWConnection] = []
    private let queue = DispatchQueue(label: "ext.stream")
    private(set) var prologue = Data()
    private var hasConfig = false

    func start(port: UInt16) {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            guard let p = NWEndpoint.Port(rawValue: port) else { return }
            let l = try NWListener(using: params, on: p)
            l.newConnectionHandler = { [weak self] conn in
                guard let self = self else { return }
                conn.start(queue: self.queue)
                self.clients.append(conn)
                // 电脑中途连上来：先补发魔数 + 配置包
                if !self.prologue.isEmpty {
                    conn.send(content: self.prologue, completion: .contentProcessed { _ in })
                }
                self.watch(conn)
            }
            l.start(queue: queue)
            listener = l
        } catch {
        }
    }

    private func watch(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, isDone, err in
            guard let self = self else { return }
            if isDone || err != nil {
                self.clients.removeAll { $0 === conn }
                conn.cancel()
                return
            }
            self.watch(conn)
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
        broadcast(packet)
    }

    func sendFrame(_ avcc: Data, ptsMs: UInt32, key: Bool) {
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
        broadcast(packet)
    }

    private func broadcast(_ data: Data) {
        for c in clients {
            c.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    func stop() {
        for c in clients { c.cancel() }
        clients.removeAll()
        listener?.cancel()
        listener = nil
    }
}
