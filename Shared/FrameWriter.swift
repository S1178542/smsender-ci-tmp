import Foundation
import Network

/// 与电脑之间的帧协议（和 Windows 端 h264-stream.js 一致）
///   "SMH1" + [type(1) + len(4,BE) + payload]…
///   type 0 配置：spsLen(2) + SPS + ppsLen(2) + PPS
///   type 1 帧  ：flags(1, bit0=关键帧) + ptsMs(4) + AVCC 数据
final class FrameWriter {
    private var conn: NWConnection?
    private let queue = DispatchQueue(label: "frame.writer")
    private var helloed = false
    private var pending: [Data] = []
    private var retryTimer: DispatchSourceTimer?

    func start(port: UInt16 = 9200) {
        connect(port: port)
    }

    private func connect(port: UInt16) {
        guard let p = NWEndpoint.Port(rawValue: port) else { return }
        let conn = NWConnection(host: "127.0.0.1", port: p, using: .tcp)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.helloed = false
                self.sendHello()
                self.flush()
            case .failed, .cancelled:
                self.conn = nil
                self.scheduleRetry(port: port)
            default:
                break
            }
        }
        conn.start(queue: queue)
        self.conn = conn
    }

    private func scheduleRetry(port: UInt16) {
        retryTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.8)
        t.setEventHandler { [weak self] in self?.connect(port: port) }
        t.resume()
        retryTimer = t
    }

    private func sendHello() {
        guard !helloed else { return }
        helloed = true
        sendRaw(Data("SMH1".utf8))
    }

    func sendConfig(sps: Data, pps: Data) {
        var payload = Data()
        payload.append(UInt8((sps.count >> 8) & 0xff))
        payload.append(UInt8(sps.count & 0xff))
        payload.append(sps)
        payload.append(UInt8((pps.count >> 8) & 0xff))
        payload.append(UInt8(pps.count & 0xff))
        payload.append(pps)
        sendPacket(type: 0, payload: payload)
    }

    func sendFrame(_ avcc: Data, ptsMs: UInt32, key: Bool) {
        var payload = Data(capacity: avcc.count + 5)
        payload.append(key ? 1 : 0)
        payload.append(UInt8((ptsMs >> 24) & 0xff))
        payload.append(UInt8((ptsMs >> 16) & 0xff))
        payload.append(UInt8((ptsMs >> 8) & 0xff))
        payload.append(UInt8(ptsMs & 0xff))
        payload.append(avcc)
        sendPacket(type: 1, payload: payload)
    }

    private func sendPacket(type: UInt8, payload: Data) {
        var d = Data(capacity: payload.count + 5)
        d.append(type)
        let n = UInt32(payload.count)
        d.append(UInt8((n >> 24) & 0xff))
        d.append(UInt8((n >> 16) & 0xff))
        d.append(UInt8((n >> 8) & 0xff))
        d.append(UInt8(n & 0xff))
        d.append(payload)
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.helloed, let c = self.conn, c.state == .ready {
                self.sendRaw(d)
            } else {
                // 还没连上宿主 App：先缓存最近的（只留 60 帧，防止爆内存）
                self.pending.append(d)
                if self.pending.count > 60 { self.pending.removeFirst(self.pending.count - 60) }
            }
        }
    }

    private func sendRaw(_ data: Data) {
        conn?.send(content: data, completion: .contentProcessed { _ in })
    }

    private func flush() {
        guard helloed else { return }
        for d in pending { sendRaw(d) }
        pending.removeAll()
    }

    func stop() {
        conn?.cancel()
        conn = nil
        retryTimer?.cancel()
        retryTimer = nil
    }
}
