import Foundation

/// 纯 POSIX socket 实现（iOS 2+ 可用），替代 Network.framework，
/// 让整个 App 的 deployment target 可以降到 iOS 11。
/// 用法：
///   let srv = PSListener()
///   srv.start(port: 9300, onAccept: { client in
///       client.onData = { data in ... }
///       client.onClose = { ... }
///   })
final class PSClient {
    private(set) var fd: Int32
    private let queue: DispatchQueue
    private var src: DispatchSourceRead?
    var onData: ((Data) -> Void)?
    var onClose: (() -> Void)?
    private var closed = false

    init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
        let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        s.setEventHandler { [weak self] in self?.drain() }
        s.setCancelHandler { [weak self] in
            guard let self = self else { return }
            if self.fd >= 0 { close(self.fd); self.fd = -1 }
        }
        self.src = s
        s.resume()
    }

    private func drain() {
        var buf = [UInt8](repeating: 0, count: 32768)
        let n = read(fd, &buf, buf.count)
        if n > 0 {
            onData?(Data(bytes: buf, count: n))
        } else if n == 0 {
            closeSelf()
        } else {
            if errno != EAGAIN && errno != EWOULDBLOCK { closeSelf() }
        }
    }

    func send(_ data: Data) {
        guard fd >= 0 else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var off = 0
            let total = data.count
            while off < total {
                let n = write(fd, base + off, total - off)
                if n > 0 { off += n; continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    // 简单退避：稍后再试（本场景数据量小，阻塞式重试可接受）
                    usleep(2000)
                    continue
                }
                break
            }
        }
    }

    func closeSelf() {
        guard !closed else { return }
        closed = true
        src?.cancel()
        src = nil
        onClose?()
    }
}

final class PSListener {
    private var fd: Int32 = -1
    private var src: DispatchSourceRead?
    private let queue: DispatchQueue
    private var clients: [PSClient] = []
    private(set) var isRunning = false
    var onStatus: ((String) -> Void)?

    init(label: String = "ps.listener") {
        queue = DispatchQueue(label: label)
    }

    func start(port: UInt16, onAccept: @escaping (PSClient) -> Void) {
        guard !isRunning else { return }
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { onStatus?("socket() 失败"); return }
        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let rc = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                bind(s, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else {
            onStatus?("bind \(port) 失败 errno=\(errno)"); close(s); return
        }
        guard listen(s, 16) == 0 else {
            onStatus?("listen \(port) 失败 errno=\(errno)"); close(s); return
        }
        // 非阻塞
        let flags = fcntl(s, F_GETFL, 0)
        _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)

        fd = s
        isRunning = true
        onStatus?("监听 \(port) 就绪")

        let dsrc = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        dsrc.setEventHandler { [weak self] in
            guard let self = self else { return }
            while true {
                var cfd = accept(s, nil, nil)
                if cfd < 0 { break }
                let flags2 = fcntl(cfd, F_GETFL, 0)
                _ = fcntl(cfd, F_SETFL, flags2 | O_NONBLOCK)
                let c = PSClient(fd: cfd, queue: self.queue)
                self.clients.append(c)
                c.onClose = { [weak self, weak c] in
                    guard let self = self, let c = c else { return }
                    self.clients.removeAll { $0 === c }
                }
                onAccept(c)
                if self.clients.count > 16 { break }
            }
        }
        dsrc.setCancelHandler { [weak self] in
            guard let self = self else { return }
            if self.fd >= 0 { close(self.fd); self.fd = -1 }
        }
        src = dsrc
        dsrc.resume()
    }

    func broadcast(_ data: Data, except sender: PSClient?) {
        for c in clients where c !== sender {
            c.send(data)
        }
    }

    var allClients: [PSClient] { clients }

    func stop() {
        for c in clients { c.closeSelf() }
        clients.removeAll()
        src?.cancel()
        src = nil
        isRunning = false
    }
}
