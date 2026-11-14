import Foundation
import AVFoundation
import VideoToolbox
import CoreMedia
import CoreGraphics
import CoreImage
#if DEBUG
import AppKit
#endif

/// Hardware-accelerated H.264 renderer built on AVSampleBufferDisplayLayer.
/// All methods must be called from the same serial queue.
public final class H264VideoDecoder {
    public let displayLayer: AVSampleBufferDisplayLayer

    #if DEBUG
    public var debugLabel = "?"
    private var debugEnqueueCount = 0
    #endif

    public var onFrameDecoded: (() -> Void)?
    public var onError: ((String) -> Void)?
    public var onSizeChanged: ((CGSize) -> Void)?
    /// Called (on the decode queue) when the decoder is waiting for an IDR
    /// frame and the session should ask the device for one. Without this a
    /// static screen can stay frozen indefinitely, because scrcpy only sends
    /// keyframes on demand or when the picture changes.
    public var onNeedsKeyframe: (() -> Void)?

    private var sps: Data?
    private var pps: [Data] = []
    private var formatDescription: CMVideoFormatDescription?
    private var currentSize: CGSize = .zero
    private var needsKeyframe = false
    private var failed = false
    private let visibilityLock = NSLock()
    private let layerLock = NSLock()
    private var displayAttached = true
    private var keyframeGate = true
    #if DEBUG
    private var decodeCount = 0
    #endif

    public init() {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer.isOpaque = true
        layer.allowsGroupOpacity = false
        self.displayLayer = layer
    }

    public func handleSession(width: Int, height: Int) {
        let newSize = CGSize(width: width, height: height)
        if currentSize != .zero, currentSize != newSize {
            resetDecoder(clearParameterSets: true)
        }
        currentSize = newSize
        onSizeChanged?(newSize)
    }

    public func handleConfig(_ data: Data) {
        let units = decodedNALUnits(from: data)
        guard !units.isEmpty else { return }
        var changed = false
        for unit in units {
            guard !unit.isEmpty else { continue }
            switch unit[0] & 0x1F {
            case 7:
                if sps != unit {
                    sps = unit
                    changed = true
                }
            case 8:
                if !pps.contains(unit) {
                    pps.append(unit)
                    changed = true
                }
            default:
                break
            }
        }
        if changed || formatDescription == nil {
            rebuildFormatDescription()
        }
        #if DEBUG
        print("[decoder \(debugLabel)] config nals=\(units.count) sps=\(sps?.count ?? 0) pps=\(pps.count) format=\(formatDescription != nil)")
        #endif
    }

    /// Thread-safe: called by the AppKit layer when the surface appears or
    /// leaves the window.
    public func setDisplayAttached(_ attached: Bool) {
        visibilityLock.lock()
        let changed = displayAttached != attached
        displayAttached = attached
        if attached, changed {
            keyframeGate = true
        }
        visibilityLock.unlock()
    }

    public func handleFrame(_ data: Data, pts: UInt64, isKeyFrame: Bool) {
        guard !data.isEmpty else { return }
        visibilityLock.lock()
        let attached = displayAttached
        let forceKeyframe = keyframeGate
        if forceKeyframe { keyframeGate = false }
        visibilityLock.unlock()
        guard attached else {
            // A background device keeps its control channel, but should not
            // decode and enqueue frames until its surface is on screen again.
            needsKeyframe = true
            return
        }
        if forceKeyframe { needsKeyframe = true }

        let units = decodedNALUnits(from: data)
        var collectedParameterSet = false
        for unit in units where !unit.isEmpty {
            switch unit[0] & 0x1F {
            case 7:
                if sps != unit {
                    sps = unit
                    collectedParameterSet = true
                }
            case 8:
                if !pps.contains(unit) {
                    pps.append(unit)
                    collectedParameterSet = true
                }
            default:
                break
            }
        }
        if collectedParameterSet || formatDescription == nil {
            rebuildFormatDescription()
        }
        guard let formatDescription else {
            needsKeyframe = true
            return
        }

        if failed || displayLayer.status == .failed || displayLayer.requiresFlushToResumeDecoding {
            // The layer can silently stop decoding after a display sleep,
            // screen lock, GPU switch or window-server hiccup. It then needs a
            // flush and a fresh IDR frame; otherwise the tile stays frozen.
            #if DEBUG
            print("[decoder \(debugLabel)] recovering layer status=\(displayLayer.status.rawValue) requiresFlush=\(displayLayer.requiresFlushToResumeDecoding) error=\(displayLayer.error?.localizedDescription ?? "none")")
            #endif
            layerLock.lock()
            displayLayer.flush()
            layerLock.unlock()
            failed = false
            self.formatDescription = nil
            rebuildFormatDescription()
            needsKeyframe = true
            guard self.formatDescription != nil else { return }
            if !isKeyFrame {
                onNeedsKeyframe?()
                return
            }
        }

        if needsKeyframe, !isKeyFrame {
            onNeedsKeyframe?()
            return
        }
        needsKeyframe = false
        // isReadyForMoreMediaData is a queue-occupancy hint for non-real-time
        // producers. Our source is real-time, so we must not drop P-frames just
        // because the layer briefly reports a full queue: doing so freezes the
        // picture until the next IDR frame.

        let avcc = H264NALParser.avccSample(from: units)
        guard let sampleBuffer = makeSampleBuffer(
            avcc: avcc,
            formatDescription: formatDescription,
            pts: pts
        ) else {
            #if DEBUG
            print("[decoder \(debugLabel)] sample buffer creation failed key=\(isKeyFrame) bytes=\(avcc.count)")
            #endif
            return
        }

        // kCMSampleAttachmentKey_* attachments must be set on the sample
        // attachment dictionary, not with CMSetAttachment. Without the
        // DisplayImmediately flag the layer schedules frames against the host
        // clock; scrcpy PTS values are not host-clock aligned, so its queue can
        // stall while the picture stays frozen.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
            let array = attachments as NSArray
            if let dictionary = array.firstObject as? NSMutableDictionary {
                dictionary[kCMSampleAttachmentKey_DisplayImmediately as String] = kCFBooleanTrue
            }
        }
        layerLock.lock()
        displayLayer.enqueue(sampleBuffer)
        layerLock.unlock()
        #if DEBUG
        decodeCount += 1
        debugEnqueueCount = decodeCount
        if decodeCount <= 4 || decodeCount % 120 == 0 {
            print(
                "[decoder \(debugLabel)] enqueue #\(decodeCount) key=\(isKeyFrame) bytes=\(avcc.count) " +
                "status=\(displayLayer.status.rawValue) ready=\(displayLayer.isReadyForMoreMediaData) " +
                "superlayer=\(displayLayer.superlayer != nil) bounds=\(displayLayer.bounds) " +
                "error=\(displayLayer.error?.localizedDescription ?? "none")"
            )
        }
        #endif
        onFrameDecoded?()
    }

    public func reset() {
        resetDecoder(clearParameterSets: true)
        currentSize = .zero
    }

    private func resetDecoder(clearParameterSets: Bool) {
        layerLock.lock()
        displayLayer.flushAndRemoveImage()
        layerLock.unlock()
        formatDescription = nil
        needsKeyframe = true
        failed = false
        if clearParameterSets {
            sps = nil
            pps.removeAll()
        }
    }

    private func rebuildFormatDescription() {
        guard let sps, !pps.isEmpty else {
            formatDescription = nil
            return
        }
        let parameterSets = [sps] + pps
        var description: CMVideoFormatDescription?
        // The pointers must stay valid for the whole VideoToolbox call. Data's
        // withUnsafeBytes pointer cannot safely escape its closure, so copy the
        // parameter sets into stable native buffers for the call.
        var buffers: [UnsafeMutablePointer<UInt8>] = []
        defer { buffers.forEach { $0.deallocate() } }
        var sizes: [Int] = []
        for set in parameterSets {
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(set.count, 1))
            set.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    buffer.initialize(from: base.assumingMemoryBound(to: UInt8.self), count: set.count)
                }
            }
            buffers.append(buffer)
            sizes.append(set.count)
        }
        let pointers = buffers.map { UnsafePointer($0) }
        let status: OSStatus = pointers.withUnsafeBufferPointer { pointerBuffer in
            sizes.withUnsafeBufferPointer { sizeBuffer in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: parameterSets.count,
                    parameterSetPointers: pointerBuffer.baseAddress!,
                    parameterSetSizes: sizeBuffer.baseAddress!,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            }
        }
        guard status == noErr, let description else {
            formatDescription = nil
            #if DEBUG
            print("[decoder \(debugLabel)] format creation failed status=\(status) sizes=\(sizes)")
            #endif
            onError?("VideoToolbox could not read this device's H.264 profile (\(status))")
            return
        }
        formatDescription = description
        needsKeyframe = true
        #if DEBUG
        print("[decoder \(debugLabel)] format ready sizes=\(sizes)")
        #endif
    }

    private func makeSampleBuffer(
        avcc: Data,
        formatDescription: CMVideoFormatDescription,
        pts: UInt64
    ) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard createStatus == kCMBlockBufferNoErr, let blockBuffer else {
            return nil
        }

        let copyStatus: OSStatus = avcc.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: avcc.count
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: Int64(pts), timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = avcc.count
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr else { return nil }
        return sampleBuffer
    }

    /// Forces the current display layer back to a clean state after a window
    /// transition (notably macOS fullscreen). The caller should also request a
    /// fresh keyframe from the device.
    public func flushForDisplayRefresh() {
        visibilityLock.lock()
        keyframeGate = true
        displayAttached = true
        visibilityLock.unlock()
        layerLock.lock()
        displayLayer.flushAndRemoveImage()
        layerLock.unlock()
    }

    #if DEBUG
    public func debugStatus() -> String {
        var pixelHash: UInt64 = 0
        var pixelSize = "none"
        if #available(macOS 14.4, *) {
            if let pixelBuffer = displayLayer.sampleBufferRenderer.displayedPixelBuffer() {
                CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
                if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                    let width = CVPixelBufferGetWidth(pixelBuffer)
                    let height = CVPixelBufferGetHeight(pixelBuffer)
                    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
                    let pointer = base.assumingMemoryBound(to: UInt8.self)
                    pixelHash = 1469598103934665603
                    for y in stride(from: 0, to: height, by: 12) {
                        for x in stride(from: 0, to: min(bytesPerRow, width * 4), by: 97) {
                            pixelHash = (pixelHash ^ UInt64(pointer[y * bytesPerRow + x])) &* 1099511628211
                        }
                    }
                    pixelSize = "\(width)x\(height)"
                }
                CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            }
        }
        visibilityLock.lock()
        let attached = displayAttached
        visibilityLock.unlock()
        return "enq=\(debugEnqueueCount) status=\(displayLayer.status.rawValue) ready=\(displayLayer.isReadyForMoreMediaData) attached=\(attached) hash=\(String(pixelHash, radix: 16)) pixels=\(pixelSize)"
    }
    #endif

    #if DEBUG
    private func captureDisplayedFrame(suffix: String = "") {
        if #available(macOS 14.4, *) {
            let renderer = displayLayer.sampleBufferRenderer
            let readyForDisplay = displayLayer.isReadyForDisplay
            let rate = renderer.timebase.rate
            print("[decoder] display ready=\(readyForDisplay) timebaseRate=\(rate)")
            guard let pixelBuffer = renderer.displayedPixelBuffer() else {
                print("[decoder] no displayed pixel buffer")
                return
            }
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            let context = CIContext(options: [.useSoftwareRenderer: false])
            guard let cgImage = context.createCGImage(image, from: image.extent) else {
                print("[decoder] could not convert displayed frame")
                return
            }
            let rep = NSBitmapImageRep(cgImage: cgImage)
            guard let data = rep.representation(using: .png, properties: [:]) else { return }
            let basePath = ProcessInfo.processInfo.environment["UU_DEBUG_FRAME_PATH"]
                ?? NSTemporaryDirectory() + "remotedroid-decoder-frame.png"
            let baseURL = URL(fileURLWithPath: basePath)
            let url = suffix.isEmpty
                ? baseURL
                : baseURL.deletingPathExtension().appendingPathExtension("\(suffix.dropFirst())").appendingPathExtension(baseURL.pathExtension)
            try? data.write(to: url)
            print("[decoder] displayed frame saved \(url.path) \(cgImage.width)x\(cgImage.height)")
        }
    }
    #endif

    private func decodedNALUnits(from data: Data) -> [Data] {
        let annexB = H264NALParser.nals(from: data)
        if annexB.count == 1, annexB[0].count == data.count {
            if let lengthPrefixed = H264NALParser.lengthPrefixedNALs(from: data) {
                return lengthPrefixed
            }
        }
        return annexB
    }
}
