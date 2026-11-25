import Foundation
import UIKit

/// 触控服务：监听 9300，接收电脑发来的触摸指令（纯 POSIX socket，支持 iOS 11+）
/// 协议：换行分隔的 JSON
///   连上先回一帧：{"ok":true,"w":1179,"h":2556,"pw":393,"ph":852,"inject":true}
///   之后：{"t":"tap","x":0.5,"y":0.5} / {"t":"swipe",...} / {"t":"home"} / {"t":"back"}
final class ControlServer {
    private let listener = PSListener(label: "control.server")
    var onStatus: ((String) -> Void)?
    private(set) var isRunning = false

    func start(port: UInt16 = 9300) {
        guard !isRunning else { return }
        listener.onStatus = { [weak self] msg in
            self?.onStatus?(msg)
            if msg.contains("就绪") { self?.isRunning = true }
        }
        listener.start(port: port) { [weak self] client in
            guard let self = self else { return }
            self.sendHello(client)
            var buf = Data()
            client.onData = { [weak self] data in
                guard let self = self else { return }
                buf.append(data)
                while let idx = buf.firstIndex(of: 0x0A) {
                    let lineData = buf[buf.startIndex..<idx]
                    buf = buf[buf.index(after: idx)...]
                    if let text = String(data: lineData, encoding: .utf8), !text.isEmpty {
                        self.handle(text, on: client)
                    }
                }
            }
        }
    }

    private func sendHello(_ client: PSClient) {
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
        client.send(Data(line.utf8))
    }

    private func handle(_ line: String, on client: PSClient) {
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
            ok = SMTouchInjector.swipe(from: CGPoint(x: pt.width * 0.5, y: pt.height * 0.999),
                                       to: CGPoint(x: pt.width * 0.5, y: pt.height * 0.55),
                                       duration: 0.18, hold: 0)
        case "multitask":
            ok = SMTouchInjector.swipe(from: CGPoint(x: pt.width * 0.5, y: pt.height * 0.999),
                                       to: CGPoint(x: pt.width * 0.5, y: pt.height * 0.5),
                                       duration: 0.28, hold: 0.9)
        case "back":
            ok = SMTouchInjector.swipe(from: CGPoint(x: pt.width * 0.01, y: pt.height * 0.5),
                                       to: CGPoint(x: pt.width * 0.62, y: pt.height * 0.5),
                                       duration: 0.22, hold: 0)
        default:
            ok = false
        }
        client.send(Data("{\"ok\":\(ok ? "true" : "false")}\n".utf8))
    }

    func stop() {
        listener.stop()
        isRunning = false
    }
}
