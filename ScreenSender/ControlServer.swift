import Foundation
import Network
import UIKit

/// 触控服务：监听 9300，接收电脑发来的触摸指令
/// 协议：换行分隔的 JSON
///   连上先回一帧设备信息：
///     {"ok":true,"w":1179,"h":2556,"pw":393,"ph":852,"inject":true}
///   之后每行一条指令：
///     {"t":"tap","x":0.5,"y":0.5}
///     {"t":"long","x":0.5,"y":0.5,"ms":800}
///     {"t":"swipe","x1":0.1,"y1":0.5,"x2":0.9,"y2":0.5,"ms":300}
///   x/y 都是 0~1 的归一化比例（相对整屏点尺寸），电脑端不用知道机型尺寸
final class ControlServer {
    private var listener: NWListener?
    private var conns: [NWConnection] = []
    private let queue = DispatchQueue(label: "control.server")
    var onStatus: ((String) -> Void)?
    private(set) var isRunning = false

    func start(port: UInt16 = 9300) {
        guard !isRunning else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            guard let p = NWEndpoint.Port(rawValue: port) else { return }
            let l = try NWListener(using: params, on: p)
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.stateUpdateHandler = { [weak self] state in
                if case .ready = state {
                    self?.isRunning = true
                    self?.onStatus?("触控端口 9300 就绪")
                }
                if case .failed(let e) = state {
                    self?.isRunning = false
                    self?.onStatus?("触控端口失败：\(e.localizedDescription)")
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            onStatus?("触控端口启动失败：\(error.localizedDescription)")
        }
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        conns.append(conn)
        sendHello(conn)
        receive(on: conn)
    }

    private func sendHello(_ conn: NWConnection) {
        let px = SMTouchInjector.screenSizeInPixels()
        let pt = SMTouchInjector.screenSizeInPoints()
        let inject = SMTouchInjector.isAvailable()
        let info: [String: Any] = [
            "ok": true,
            "w": Int(px.width), "h": Int(px.height),
            "pw": Int(pt.width), "ph": Int(pt.height),
            "inject": inject
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: info),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        conn.send(content: Data(line.utf8), completion: .contentProcessed { _ in })
    }

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isDone, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                if let text = String(data: data, encoding: .utf8) {
                    for line in text.split(separator: "\n") where !line.isEmpty {
                        self.handle(String(line), on: conn)
                    }
                }
            }
            if isDone || error != nil {
                self.conns.removeAll { $0 === conn }
                conn.cancel()
                return
            }
            self.receive(on: conn)
        }
    }

    private func handle(_ line: String, on conn: NWConnection) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["t"] as? String else { return }
        let pt = SMTouchInjector.screenSizeInPoints()
        func px(_ v: Any?) -> CGFloat {
            let n = CGFloat((v as? NSNumber)?.doubleValue ?? 0)
            return max(0, min(1, n))
        }
        var ok = false
        let x = px(json["x"]) * pt.width
        let y = px(json["y"]) * pt.height
        switch type {
        case "probe":
            // 参数自检：用第 v 种注入组合点一下，PC 端看画面有没有变化
            let v = (json["v"] as? NSNumber)?.intValue ?? 0
            SMTouchInjector.setVariant(v)
            ok = SMTouchInjector.tap(at: CGPoint(x: x, y: y))
        case "variant":
            let v = (json["v"] as? NSNumber)?.intValue ?? 0
            SMTouchInjector.setVariant(v)
            ok = true
        case "tap":
            ok = SMTouchInjector.tap(at: CGPoint(x: x, y: y))
        case "long":
            let ms = (json["ms"] as? NSNumber)?.doubleValue ?? 800
            ok = SMTouchInjector.longPress(at: CGPoint(x: x, y: y), duration: ms / 1000.0)
        case "swipe":
            let x2 = px(json["x2"]) * pt.width
            let y2 = px(json["y2"]) * pt.height
            let ms = (json["ms"] as? NSNumber)?.doubleValue ?? 300
            let hold = (json["hold"] as? NSNumber)?.doubleValue ?? 0
            ok = SMTouchInjector.swipe(from: CGPoint(x: x, y: y),
                                       to: CGPoint(x: x2, y: y2),
                                       duration: ms / 1000.0,
                                       hold: hold / 1000.0)
        case "home":
            // 从底部上滑 = 回主屏
            ok = SMTouchInjector.swipe(from: CGPoint(x: pt.width * 0.5, y: pt.height * 0.999),
                                       to: CGPoint(x: pt.width * 0.5, y: pt.height * 0.55),
                                       duration: 0.18, hold: 0)
        case "multitask":
            // 底部上滑到中间并按住 = 多任务
            ok = SMTouchInjector.swipe(from: CGPoint(x: pt.width * 0.5, y: pt.height * 0.999),
                                       to: CGPoint(x: pt.width * 0.5, y: pt.height * 0.5),
                                       duration: 0.28, hold: 0.9)
        case "back":
            // 左边缘右滑 = 返回
            ok = SMTouchInjector.swipe(from: CGPoint(x: pt.width * 0.01, y: pt.height * 0.5),
                                       to: CGPoint(x: pt.width * 0.62, y: pt.height * 0.5),
                                       duration: 0.22, hold: 0)
        default:
            ok = false
        }
        let reply = "{\"ok\":\(ok ? "true" : "false")}\n"
        conn.send(content: Data(reply.utf8), completion: .contentProcessed { _ in })
    }

    func stop() {
        for c in conns { c.cancel() }
        conns.removeAll()
        listener?.cancel()
        listener = nil
        isRunning = false
    }
}
