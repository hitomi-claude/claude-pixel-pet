// Packs clip frames into the pet's clip videos: every SRC/<clip>/ folder of frames (NN.png or NN.webp, all one size, the
// feet at the bottom centre) becomes DEST/<clip>.mov, HEVC with alpha at `fps` frames a second (main.swift's Clip.fps must match).
// Needs only macOS.
//   swiftc -O -o /tmp/pack_clips tools/pack_clips.swift && /tmp/pack_clips SRC DEST [quality 0.7]
import AVFoundation
import AppKit

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: pack_clips SRC DEST [quality]"); exit(1) }
let src = URL(fileURLWithPath: args[1]), dest = URL(fileURLWithPath: args[2]), quality = args.count > 3 ? Double(args[3])! : 0.7
let fm = FileManager.default, fps: CMTimeScale = 10
try fm.createDirectory(at: dest, withIntermediateDirectories: true)
for dir in try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil).map({ $0.resolvingSymlinksInPath() }).filter(\.hasDirectoryPath).sorted(by: { $0.path < $1.path }) {
    let frames = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { ["png", "webp"].contains($0.pathExtension) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { NSImage(contentsOf: $0)?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
    guard let first = frames.first else { continue }
    let w = (first.width + 1) / 2 * 2, h = (first.height + 1) / 2 * 2   // HEVC wants even sizes: a spare column on the right, a row on top
    let out = dest.appendingPathComponent(dir.lastPathComponent + ".mov"); try? fm.removeItem(at: out)
    let writer = try AVAssetWriter(outputURL: out, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha, AVVideoWidthKey: w, AVVideoHeightKey: h,
        AVVideoCompressionPropertiesKey: [AVVideoQualityKey: quality, "TargetQualityForAlpha": quality]])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
    writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
    guard let pool = adaptor.pixelBufferPool else { print("can't write \(out.path): \(writer.error as Any)"); exit(1) }
    for (i, im) in frames.enumerated() {
        while !input.isReadyForMoreMediaData { usleep(1000) }
        var buffer: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let pb = buffer else { print("out of pixel buffers"); exit(1) }
        CVPixelBufferLockBaseAddress(pb, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h)); ctx.draw(im, in: CGRect(x: 0, y: 0, width: im.width, height: im.height))
        CVPixelBufferUnlockBaseAddress(pb, [])
        adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0); writer.finishWriting { done.signal() }; done.wait()
    guard writer.status == .completed else { print("can't write \(out.path): \(writer.error as Any)"); exit(1) }
    print("\(out.path): \(frames.count) frames, \((try fm.attributesOfItem(atPath: out.path)[.size] as! Int) / 1024) KB")
}
