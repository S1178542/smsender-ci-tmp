import Foundation
import Network

/// 9200 中继：一端是 ReplayKit 广播扩展（推 H.264），另一端是电脑（拉流）
/// 对称转发，谁先连都行；缓存开头魔数 + SPS/PPS 给后连的客户端补发
final class SmRelayServer {
    static let shared = SmRelayServer()

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let queue = DispatchQueue(label: "sm.relay.server")
    private(set) var isRunning = false

    private var prologue = Data()
    private var prologueDone = false

    func start(port: UInt16 = 9200) {
        guard !isRunning else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            guard let p = NWEndpoint.Port(rawValue: port) else { return }
            let l = try NWListener(using: params, on: p)
            l.newConnectionHandler = { [weak self] conn in
                self?.accept(conn)
            }
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.isRunning = true
                    NSLog("[SmRelay] 9200 ready")
                case .failed(let err):
                    self?.isRunning = false
                    NSLog("[SmRelay] 9200 failed: %@", err.localizedDescription)
                default:
                    break
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            NSLog("[SmRelay] 9200 listen error: %@", error.localizedDescription)
        }
    }

    private func accept(_ conn: NWConnection) {
        conn.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.remove(conn) }
            if case .cancelled = state { self?.remove(conn) }
        }
        conn.start(queue: queue)
        connections.append(conn)
        if !prologue.isEmpty {
            conn.send(content: prologue, completion: .contentProcessed { _ in })
        }
        receive(on: conn)
    }

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

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isDone, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.broadcast(data, from: conn)
            }
            if isDone || error != nil {
                self.remove(conn)
                return
            }
            self.receive(on: conn)
        }
    }

    private func broadcast(_ data: Data, from sender: NWConnection) {
        rememberPrologue(data)
        for c in connections where c !== sender {
            c.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    private func remove(_ conn: NWConnection) {
        connections.removeAll { $0 === conn }
        conn.cancel()
    }

    func stop() {
        for c in connections { c.cancel() }
        connections.removeAll()
        listener?.cancel()
        listener = nil
        isRunning = false
    }
}
