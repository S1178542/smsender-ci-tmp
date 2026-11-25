import Foundation

/// 手机内的中继：监听 9200
/// 一端是 ReplayKit 广播扩展（推 H.264），另一端是电脑经 usbmux 连进来（拉流）
/// 纯 POSIX socket 实现，支持 iOS 11+
final class RelayServer {
    private let listener = PSListener(label: "relay.server")
    var onStatus: ((String) -> Void)?
    private(set) var isRunning = false
    // 缓存开头（"SMH1" + 配置包 SPS/PPS），新连进来的电脑先把它补发过去
    private var prologue = Data()
    private var prologueDone = false

    func start(port: UInt16 = 9200) {
        guard !isRunning else { return }
        listener.onStatus = { [weak self] msg in
            self?.onStatus?(msg)
            if msg.contains("就绪") { self?.isRunning = true }
        }
        listener.start(port: port) { [weak self] client in
            guard let self = self else { return }
            if !self.prologue.isEmpty { client.send(self.prologue) }
            client.onData = { [weak self, weak client] data in
                guard let self = self, let client = client else { return }
                self.rememberPrologue(data)
                self.listener.broadcast(data, except: client)
            }
        }
    }

    /// 从数据流里截出 "SMH1" + 第一个配置包
    private func rememberPrologue(_ data: Data) {
        guard !prologueDone else { return }
        prologue.append(data)
        if prologue.count < 9 { return }
        let bytes = [UInt8](prologue)
        guard bytes[0] == 0x53, bytes[1] == 0x4D, bytes[2] == 0x48, bytes[3] == 0x31 else {
            prologueDone = true
            prologue.removeAll()
            return
        }
        let len = (UInt32(bytes[5]) << 24) | (UInt32(bytes[6]) << 16) | (UInt32(bytes[7]) << 8) | UInt32(bytes[8])
        let total = 9 + Int(len)
        if prologue.count < total {
            if prologue.count > 65536 { prologueDone = true }
            return
        }
        prologue = prologue.prefix(total)
        prologueDone = true
    }

    func stop() {
        listener.stop()
        isRunning = false
    }
}
