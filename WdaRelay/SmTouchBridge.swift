import Foundation
import Network
import UIKit

/// 9300 触控桥：电脑发换行分隔的 JSON，转成 WDA 的 HTTP 触控接口
/// 协议与 H264 宿主 App 一致：
///   连上先回 {"ok":true,"w":..,"h":..,"pw":..,"ph":..,"inject":true}
///   {"t":"tap","x":0.5,"y":0.5}
///   {"t":"long","x":0.5,"y":0.5,"ms":800}
///   {"t":"swipe","x1":0.1,"y1":0.5,"x2":0.9,"y2":0.5,"ms":300}
/// x/y 是 0~1 归一化比例
final class SmTouchBridge {
    static let shared = SmTouchBridge()

    private var listener: NWListener?
    private var conns: [NWConnection] = []
    private let queue = DispatchQueue(label: "sm.touch.bridge")
    private(set) var isRunning = false
    private var cachedSession: String?
    private let wdaBase = "http://127.0.0.1:8100"

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
                    NSLog("[SmTouch] 9300 ready")
                }
                if case .failed(let e) = state {
                    self?.isRunning = false
                    NSLog("[SmTouch] 9300 failed: %@", e.localizedDescription)
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            NSLog("[SmTouch] 9300 listen error: %@", error.localizedDescription)
        }
    }

    // MARK: - 连接管理

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        conns.append(conn)
        sendHello(conn)
        receive(on: conn)
    }

    private func sendHello(_ conn: NWConnection) {
        let s = screenInfo()
        let info: [String: Any] = [
            "ok": true,
            "w": Int(s.0), "h": Int(s.1),
            "pw": Int(s.2), "ph": Int(s.3),
            "inject": true,
            "mode": "wda"
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: info),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        conn.send(content: Data(line.utf8), completion: .contentProcessed { _ in })
    }

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isDone, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                for line in text.split(separator: "\n") where !line.isEmpty {
                    self.handle(String(line), on: conn)
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

    // MARK: - 指令处理

    private func handle(_ line: String, on conn: NWConnection) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["t"] as? String else { return }

        let s = screenInfo()
        let ptW = s.2, ptH = s.3
        func norm(_ v: Any?) -> CGFloat {
            let n = CGFloat((v as? NSNumber)?.doubleValue ?? 0)
            return max(0, min(1, n))
        }

        var action: [String: Any]? = nil
        var directPress: String? = nil

        func dragAct(_ fx: CGFloat, _ fy: CGFloat, _ tx: CGFloat, _ ty: CGFloat, _ dur: Double) -> [String: Any] {
            return ["action": "drag",
                    "options": ["fromX": Double(fx), "fromY": Double(fy),
                                "toX": Double(tx), "toY": Double(ty),
                                "duration": dur]]
        }

        // 坐标边界保护：iOS 合成事件在 0 点经常被丢弃，最少留 1pt
        func clampPt(_ v: CGFloat, _ maxV: CGFloat) -> CGFloat {
            return max(1.0, min(maxV - 1.0, v))
        }

        switch type {
        case "probe", "variant":
            reply(conn, true)
            return

        case "home", "homescreen", "main":
            directPress = "home"

        case "multitask", "appswitcher":
            action = dragAct(ptW * 0.5, ptH - 1, ptW * 0.5, ptH * 0.5, 1.5)

        case "back":
            let y = clampPt(norm(json["y"] ?? 0.5) * ptH, ptH)
            action = dragAct(1.0, y, ptW * 0.72, y, 0.5)

        case "tap":
            action = ["action": "tap",
                      "options": ["x": Double(clampPt(norm(json["x"]) * ptW, ptW)),
                                  "y": Double(clampPt(norm(json["y"]) * ptH, ptH))]]

        case "long":
            let ms = (json["ms"] as? NSNumber)?.doubleValue ?? 800
            action = ["action": "longPress",
                      "options": ["x": Double(clampPt(norm(json["x"]) * ptW, ptW)),
                                  "y": Double(clampPt(norm(json["y"]) * ptH, ptH)),
                                  "duration": ms / 1000.0]]

        case "swipe":
            let ms = (json["ms"] as? NSNumber)?.doubleValue ?? 300
            let x1 = norm(json["x1"]), y1 = norm(json["y1"])
            let x2 = norm(json["x2"]), y2 = norm(json["y2"])

            if y1 >= 0.94 && y2 <= 0.75 {
                // 底部上滑：慢滑=多任务，快滑=回主屏
                if ms >= 600 {
                    action = dragAct(ptW * 0.5, ptH - 1, ptW * 0.5, ptH * 0.5, 1.5)
                } else {
                    directPress = "home"
                }
            } else if x1 <= 0.03 || x2 <= 0.03 {
                // 左边缘右滑：起点必须贴边，且不能太快
                let y = clampPt(y1 * ptH, ptH)
                action = dragAct(1.0, y, clampPt(x2 * ptW, ptW), y, max(0.5, ms / 1000.0))
            } else {
                action = dragAct(clampPt(x1 * ptW, ptW), clampPt(y1 * ptH, ptH),
                                 clampPt(x2 * ptW, ptW), clampPt(y2 * ptH, ptH),
                                 ms / 1000.0)
            }

        default:
            reply(conn, false)
            return
        }

        if let name = directPress {
            reply(conn, pressButton(name))
            return
        }

        guard let act = action else { reply(conn, false); return }
        let ok = perform(act)
        reply(conn, ok)
    }

    /// 调 WDA 的硬件按键（home 等）
    private func pressButton(_ name: String) -> Bool {
        guard let sid = sessionId() else { return false }
        let body = try? JSONSerialization.data(withJSONObject: ["name": name])
        if let (code, _) = wdaRequest("/session/\(sid)/wda/pressButton", method: "POST", body: body), code == 200 {
            return true
        }
        cachedSession = nil
        guard let sid2 = sessionId() else { return false }
        if let (code2, _) = wdaRequest("/session/\(sid2)/wda/pressButton", method: "POST", body: body), code2 == 200 {
            return true
        }
        return false
    }

    private func reply(_ conn: NWConnection, _ ok: Bool) {
        let line = "{\"ok\":\(ok ? "true" : "false")}\n"
        conn.send(content: Data(line.utf8), completion: .contentProcessed { _ in })
    }

    // MARK: - WDA HTTP

    private func wdaRequest(_ path: String, method: String, body: Data?) -> (Int, Data)? {
        guard let url = URL(string: wdaBase + path) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 3
        if let body = body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        var result: (Int, Data)? = nil
        let sem = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: req) { d, r, _ in
            let code = (r as? HTTPURLResponse)?.statusCode ?? 0
            result = (code, d ?? Data())
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 3.5)
        return result
    }

    private func sessionId() -> String? {
        if let s = cachedSession { return s }
        if let (_, d) = wdaRequest("/status", method: "GET", body: nil),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            if let v = obj["value"] as? [String: Any], let sid = v["sessionId"] as? String, !sid.isEmpty {
                cachedSession = sid
                return sid
            }
            if let sid = obj["sessionId"] as? String, !sid.isEmpty {
                cachedSession = sid
                return sid
            }
        }
        // 没有现成会话就建一个空的
        let body = try? JSONSerialization.data(withJSONObject: ["capabilities": [:] as [String: Any]])
        if let (_, d) = wdaRequest("/session", method: "POST", body: body),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            if let v = obj["value"] as? [String: Any] {
                if let sid = v["sessionId"] as? String { cachedSession = sid; return sid }
                if let sid = v["id"] as? String { cachedSession = sid; return sid }
            }
            if let sid = obj["sessionId"] as? String { cachedSession = sid; return sid }
        }
        return nil
    }

    private func perform(_ action: [String: Any]) -> Bool {
        guard let sid = sessionId() else { return false }
        let payload: [String: Any] = ["actions": [action]]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        if let (code, _) = wdaRequest("/session/\(sid)/wda/touch/perform", method: "POST", body: body), code == 200 {
            return true
        }
        // 会话可能过期，清缓存重试一次
        cachedSession = nil
        guard let sid2 = sessionId() else { return false }
        if let (code2, _) = wdaRequest("/session/\(sid2)/wda/touch/perform", method: "POST", body: body), code2 == 200 {
            return true
        }
        return false
    }

    // MARK: - 屏幕尺寸

    private func screenInfo() -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        var r: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        let work: () -> Void = {
            let b = UIScreen.main.bounds
            let sc = UIScreen.main.scale
            r = (b.width * sc, b.height * sc, b.width, b.height)
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
        return r
    }

    func stop() {
        for c in conns { c.cancel() }
        conns.removeAll()
        listener?.cancel()
        listener = nil
        isRunning = false
    }
}
