import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// ReplayKit 送来的 CMSampleBuffer → VideoToolbox 低延迟 H.264 → 交给下游（扩展内 TCP 服务）
final class H264Encoder {
    typealias ConfigSink = (Data, Data) -> Void
    typealias FrameSink = (Data, UInt32, Bool) -> Void

    private var session: VTCompressionSession?
    private var width: Int32 = 0
    private var height: Int32 = 0
    private var sentParams = false
    private var loggedFirst = false
    private let onConfig: ConfigSink
    private let onFrame: FrameSink
    private let bitrate: Int = 6_000_000
    private let fps: Int = 60

    init(onConfig: @escaping ConfigSink, onFrame: @escaping FrameSink) {
        self.onConfig = onConfig
        self.onFrame = onFrame
    }

    convenience init(sink: AnyObject) {
        // 兼容旧调用（不使用）
        self.init(onConfig: { _, _ in }, onFrame: { _, _, _ in })
    }

    deinit {
        if let s = session { VTCompressionSessionInvalidate(s) }
    }

    private func makeSession(width: Int32, height: Int32) {
        if let s = session { VTCompressionSessionInvalidate(s) }
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &s
        )
        NSLog("[SM-ENC] create session \(width)x\(height) status=\(status)")
        guard status == noErr, let session = s else { return }
        self.session = session
        self.width = width
        self.height = height
        self.sentParams = false

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: fps))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrate))
        if #available(iOS 14.0, *) {
            VTSessionSetProperty(session, key: "EnableLowLatencyRateControl" as CFString, value: kCFBooleanTrue)
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        let w = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let h = Int32(CVPixelBufferGetHeight(pixelBuffer))
        if session == nil || w != width || h != height {
            makeSession(width: w, height: h)
        }
        guard let session = session else { return }
        let ptsMs = UInt32((CMTimeGetSeconds(presentationTime) * 1000.0).rounded())
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: .invalid,
            frameProperties: nil,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard let self = self, status == noErr, let sb = sampleBuffer else { return }
            let isKey = !sampleBufferIsDelta(sb)
            self.handle(sb, ptsMs: ptsMs, isKey: isKey)
        }
    }

    private func handle(_ sb: CMSampleBuffer, ptsMs: UInt32, isKey: Bool) {
        if !loggedFirst { loggedFirst = true; NSLog("[SM-ENC] first output key=\(isKey)") }
        if !sentParams, let fmt = CMSampleBufferGetFormatDescription(sb) {
            var sps = Data(), pps = Data()
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0,
                                                              parameterSetPointerOut: nil,
                                                              parameterSetSizeOut: nil,
                                                              parameterSetCountOut: &count,
                                                              nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                let st = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i,
                                                                           parameterSetPointerOut: &ptr,
                                                                           parameterSetSizeOut: &size,
                                                                           parameterSetCountOut: nil,
                                                                           nalUnitHeaderLengthOut: nil)
                guard st == noErr, let p = ptr, size > 0 else { continue }
                let d = Data(bytes: p, count: size)
                if d.first.map({ ($0 & 0x1f) == 7 }) == true { sps = d } else { pps = d }
            }
            if !sps.isEmpty && !pps.isEmpty {
                onConfig(sps, pps)
                sentParams = true
            }
        }
        guard let block = CMSampleBufferGetDataBuffer(sb) else { return }
        let len = CMBlockBufferGetDataLength(block)
        guard len > 0 else { return }
        var data = Data(count: len)
        let ok = data.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: base)
        }
        guard ok == kCMBlockBufferNoErr else { return }
        onFrame(data, ptsMs, isKey)
    }
}

/// 判断这一帧是不是关键帧（AVCC 里第一个 NAL 的类型 5 = IDR）
private func sampleBufferIsDelta(_ sb: CMSampleBuffer) -> Bool {
    guard let block = CMSampleBufferGetDataBuffer(sb) else { return true }
    let len = CMBlockBufferGetDataLength(block)
    guard len > 5 else { return true }
    var head = [UInt8](repeating: 0, count: 5)
    let ok = head.withUnsafeMutableBytes { raw -> OSStatus in
        guard let base = raw.baseAddress else { return -1 }
        return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 5, destination: base)
    }
    guard ok == kCMBlockBufferNoErr else { return true }
    let nalType = head[4] & 0x1f
    return nalType != 5 && nalType != 7
}
