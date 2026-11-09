// Claude desktop pet: the chibi character floating on the macOS desktop.
// Click to chat or drive a Claude Code session, drag to move. Shows what Claude Code sessions are doing
// (read from the local transcripts) and today's token usage in the menu-bar icon. Transparent pixels are click-through.
import AppKit
import AVFoundation
import CryptoKit

let home = FileManager.default.homeDirectoryForCurrentUser
let appSupport = home.appendingPathComponent("Library/Application Support/ClaudePet")   // hook events
let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("claude-pixel-pet")   // resume scripts, unpacked clips
// Claude Code config dirs whose transcripts are watched; the first one is also used for chat.
// Default ~/.claude; override for several accounts:
//   defaults write io.github.kirigirihitomi.claude-pixel-pet configDirs -array ~/.claude-work ~/.claude
let accounts: [(label: String, dir: URL)] = ((UserDefaults.standard.array(forKey: "configDirs") as? [String]) ?? ["~/.claude"])
    .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("projects").path) }
    .map { ($0.lastPathComponent, $0) }

let persona = """
You are Claude, living on the user's Mac desktop as a small chibi desktop pet (orange hair, white dress, holding a book). \
The user clicked you to chat. Reply like a calm, dry-humoured friend: short, usually one to three sentences, plain text, \
no markdown, no lists. Match the user's language.
"""

/// CLAUDE_CONFIG_DIR value for a config dir. The default ~/.claude must stay unset: setting it explicitly makes
/// Claude Code look up a different stored login, and it asks you to log in again.
func configEnv(_ dir: URL) -> String? {
    dir.standardizedFileURL.path == home.appendingPathComponent(".claude").standardizedFileURL.path ? nil : dir.path
}

/// "Bash · Run tests"; `full` keeps the whole command / path (for permission cards).
func describeTool(_ tool: String, _ input: [String: Any], full: Bool = false) -> String {
    let path = input["file_path"] as? String
    let detail: String?
    if full { detail = (input["command"] as? String) ?? path ?? (input["description"] as? String) }
    else { detail = (input["description"] as? String) ?? (input["command"] as? String) ?? path.map { ($0 as NSString).lastPathComponent } }
    let d = detail ?? (input["pattern"] as? String) ?? (input["url"] as? String) ?? ""
    return String((d.isEmpty ? tool : "\(tool) · \(d)").prefix(full ? 300 : 70))
}

/// Splits complete lines off `buffer` (keeping a trailing partial line) and parses each as a JSON object.
/// `keep` can reject a raw line before the (expensive) JSON parse.
func takeJSONLines(_ buffer: inout Data, keep: (Data) -> Bool = { _ in true }) -> [[String: Any]] {
    guard let last = buffer.lastIndex(of: 0x0A) else { return [] }
    let lines = buffer[buffer.startIndex..<last].split(separator: 0x0A)
    buffer.removeSubrange(buffer.startIndex...last)
    return lines.compactMap { keep($0) ? (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] : nil }
}

/// Every transcript (*.jsonl) under the watched accounts modified after `since`.
func transcripts(since: Date, subagents: Bool) -> [(label: String, dir: URL, url: URL, size: UInt64)] {
    let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
    var out: [(String, URL, URL, UInt64)] = []
    for (label, dir) in accounts {
        guard let e = FileManager.default.enumerator(at: dir.appendingPathComponent("projects"), includingPropertiesForKeys: keys,
                                                    options: [.skipsHiddenFiles]) else { continue }
        for case let url as URL in e where url.pathExtension == "jsonl" && (subagents || !url.path.contains("/subagents/")) {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), (v.contentModificationDate ?? .distantPast) > since else { continue }
            out.append((label, dir, url, UInt64(v.fileSize ?? 0)))
        }
    }
    return out
}

let isoFrac: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
let isoPlain = ISO8601DateFormatter()
func shortCount(_ n: Int) -> String { n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? "\(n / 1000)k" : "\(n)" }

// MARK: voice: short blips rendered once into in-memory WAVs

/// One blip, 44.1 kHz mono. Soft: a sine, 4 ms attack then a straight fade over 50 ms. 8-bit: a 25% pulse (the NES
/// square), 1 ms attack then an exponential fade (time constant 15 ms) over 55 ms.
func blipSound(_ f: Double, pulse: Bool = false) -> NSSound {
    let rate = 44100.0, n = Int(rate * (pulse ? 0.055 : 0.05)), attack = rate * (pulse ? 0.001 : 0.004)
    let samples: [Int16] = (0..<n).map { i in
        let x = Double(i)
        let wave = pulse ? ((x * f / rate).truncatingRemainder(dividingBy: 1) < 0.25 ? 1.0 : -1.0) : sin(2 * .pi * f * x / rate)
        let env = pulse ? min(1, x / attack) * exp(-x / (rate * 0.015)) : min(x / attack, (Double(n) - x) / (Double(n) - attack))
        return Int16(wave * env * (pulse ? 0.13 : 0.3) * 32767)
    }
    var d = Data()
    func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    d.append(contentsOf: "RIFF".utf8); put(UInt32(36 + samples.count * 2)); d.append(contentsOf: "WAVEfmt ".utf8)
    put(UInt32(16)); put(UInt16(1)); put(UInt16(1)); put(UInt32(rate)); put(UInt32(rate * 2)); put(UInt16(2)); put(UInt16(16))
    d.append(contentsOf: "data".utf8); put(UInt32(samples.count * 2)); samples.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }   // Int16 is little-endian on every Mac
    return NSSound(data: d)!
}

/// The talking voice, picked in the menu.
enum Voice: String, CaseIterable {
    case off, soft, chip
    var title: String {
        switch self {
        case .off: return "Off"
        case .soft: return "Soft"
        case .chip: return "8-bit"
        }
    }
    var gap: Double { self == .chip ? 0 : 0.18 }   // least time between two blips
    static func saved() -> Voice {   // read once at launch; "sound" = false is the old Sound effects switch
        Voice(rawValue: UserDefaults.standard.string(forKey: "voice") ?? "")
            ?? (UserDefaults.standard.object(forKey: "sound") as? Bool == false ? .off : .soft)
    }
}
enum Sfx {
    /// Soft: C5 D5 E5 F5 G5 A5, each repeated by how often it's picked (C, D, G, A most). 8-bit: G5, detuned ±4%.
    static let soft = [(523.25, 3), (587.33, 4), (659.25, 1), (698.46, 1), (783.99, 3), (880.0, 3)]
        .flatMap { f, w in Array(repeating: blipSound(f), count: w) }
    static let chip = [0.96, 0.98, 0.99, 1.0, 1.01, 1.02, 1.04].map { blipSound(783.99 * $0, pulse: true) }
    static func blip(_ v: Voice, _ tune: inout Tune) {
        (v == .chip ? chip : v == .soft ? soft : []).randomElement(using: &tune).map { $0.stop(); $0.play() }
    }
}
/// Which notes a line gets: a SplitMix64 stream seeded by an FNV-1a hash of the text, so the same line always sounds the
/// same (Swift's Hasher is reseeded every launch).
struct Tune: RandomNumberGenerator {
    var state: UInt64
    init(_ text: String) { state = text.utf8.reduce(0xcbf29ce484222325) { ($0 ^ UInt64($1)) &* 0x100000001b3 } }
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = (state ^ (state >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}

// MARK: sprite

/// A frame of a clip, or a pose she rests in (standing, writing, reading or asleep), which shows a clip's frame (hold).
struct Pose: Hashable {
    let rawValue: String, clip: Clip?, index: Int
    init(_ name: String) { rawValue = name; clip = nil; index = 0 }
    init(_ c: Clip, _ i: Int) { rawValue = "\(c.rawValue)/\(i)"; clip = c; index = i }
    static let closed = Pose("closed"), read = Pose("read"), sleep = Pose("sleep"), work = Pose("work")
}

/// Motion between and around the poses, from a video model: <character>/clips/<clip>.mov, HEVC with alpha made by
/// tools/pack_clips.swift, each frame at idle_loop's scale with the feet at the bottom centre. A character needs idle_loop. Every frame shows for `frame`
/// seconds: a loop (which starts and ends on its pose) is sampled to play in real time, the rest at twice the speed.
enum Clip: String, CaseIterable {
    case closed_to_work, work_loop, closed_to_read, closed_to_sleep, sleep_loop, sleep_to_closed, surprise, yawn, idle_loop, talk
    /// The poses she rests in: the loop she plays there, and the clips into it from standing and out of it back to standing.
    /// Without a clip out (or a character without that clip), the one in plays backwards: she puts the book and quill away as she took them out.
    static let rests: [Pose: (loop: Clip, enter: Clip?, exit: Clip?)] = [
        .closed: (.idle_loop, nil, nil), .work: (.work_loop, .closed_to_work, nil), .sleep: (.sleep_loop, .closed_to_sleep, .sleep_to_closed)]
    var loops: Bool { Clip.rests.values.contains { $0.loop == self } || self == .talk }
    static let frame = 0.11
    static let fps = 10   // the timescale tools/pack_clips.swift writes; frames show for `frame` (sampled from 24 fps video, not 10)
    private static func frames(_ url: URL, _ frames: [Int]) -> AVAssetImageGenerator.Images {   // exact frames, in whatever order they come
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url)); g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
        return g.images(for: frames.map { CMTime(value: CMTimeValue($0), timescale: CMTimeScale(fps)) })
    }
    static func decode(_ url: URL, _ frames: [Int]) async -> [NSImage] {   // those frames in order; all 40 of a loop take about a quarter of a second
        var images: [Int: NSImage] = [:]
        for await r in Clip.frames(url, frames) {
            if let cg = try? r.image { images[Int(r.requestedTime.value)] = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) }
        }
        return frames.compactMap { images[$0] }
    }
    /// Where a clip is unpacked: one HEIC per frame under Caches, named by a hash of the movie, so a changed movie gets a new one.
    static func cache(_ url: URL) -> URL? {
        (try? Data(contentsOf: url)).map { cacheDir.appendingPathComponent("clips/" + sha256Hex($0).prefix(16)) }
    }
    /// Unpacks a clip into its cache, a frame at a time as they decode, written aside and moved in whole; nil if that fails.
    static func unpack(_ url: URL, _ n: Int, to dir: URL) async -> URL? {
        let fm = FileManager.default, part = dir.appendingPathExtension("part"); try? fm.removeItem(at: part)
        guard (try? fm.createDirectory(at: part, withIntermediateDirectories: true)) != nil else { return nil }
        var written = 0
        for await r in Clip.frames(url, Array(0..<n)) {
            guard let cg = try? r.image, let d = CGImageDestinationCreateWithURL(part.appendingPathComponent("\(r.requestedTime.value).heic") as CFURL, "public.heic" as CFString, 1, nil)
            else { return nil }
            CGImageDestinationAddImage(d, cg, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            guard CGImageDestinationFinalize(d) else { return nil }
            written += 1
        }
        return written == n && (try? fm.moveItem(at: part, to: dir)) != nil ? dir : nil
    }
    static func pruneCache() {   // unpacked clips nobody used for a month, and unfinished ones; a used folder gets its date touched
        let fm = FileManager.default, old = Date().addingTimeInterval(-30 * 86400), dir = cacheDir.appendingPathComponent("clips")
        for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where f.pathExtension == "part" || ((try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) < old {
            try? fm.removeItem(at: f)
        }
    }
}

func isCharacter(_ dir: URL) -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent("clips/idle_loop.mov").path) }

/// Characters, each named Claude (<name>), in the order of `characterGroups` (the models, then the outfits): Claude (Opus) is
/// Resources/ in the app, the others Resources/Characters/<name>.
let defaultCharacter = "Claude (Opus)"
let characterGroups = [["Haiku", "Sonnet", "Opus", "Fable", "Mythos"], ["Spring", "Summer", "Autumn", "Winter"]]
func characters() -> [(name: String, dir: URL, group: Int)] {
    let res = Bundle.main.resourceURL!
    return characterGroups.enumerated().flatMap { g, ns in ns.map { n in
        (name: "Claude (\(n))", dir: n == "Opus" ? res : res.appendingPathComponent("Characters/\(n)"), group: g) } }
        .filter { isCharacter($0.dir) }
}
/// The characters into a menu, a separator between groups, each item holding its folder.
func addCharacters(to menu: NSMenu, action: Selector, target: AnyObject) {
    var last: Int?
    for c in characters() {
        if let l = last, l != c.group { menu.addItem(.separator()) }
        last = c.group
        let it = menu.addItem(withTitle: c.name, action: action, keyEquivalent: ""); it.target = target; it.representedObject = c.dir
    }
}

final class Sprite {
    let dir: URL
    private var clipFiles: [Clip: URL] = [:], clipSize: [Clip: CGSize] = [:]
    private var decoded: [Clip: [NSImage]] = [:], decoding: Set<Clip> = [], recent: [Clip] = []   // until unpacked, a clip is decoded to play it; the last three stay
    private var held: [Pose: NSImage] = [:]   // the clip frames she rests on, kept
    private var unpacked: [Clip: URL] = [:], read: [Pose: NSImage] = [:], reading: Set<Pose> = [], shown: Pose?   // unpacked clips: frames read a few ahead, off the main thread
    private(set) var clips: [Clip: [Pose]] = [:]   // the frames of each clip the character has, known a moment after loading
    private(set) var settled = false   // the frames she rests on are decoded: until then she isn't drawn at all
    var onSettled: (() -> Void)?
    private(set) var aspect: CGFloat = 1   // of idle_loop, which every size is relative to; known once settled
    private(set) var scale: CGFloat = 1   // idle_loop's height over the shipped 600 px, so a taller or shorter character keeps the same head size; far off it, 1
    typealias Mask = (w: Int, h: Int, alpha: [UInt8])
    private var mask: Mask?   // of the frame she stands on, for click-through
    private var edges: [Clip: (CGFloat, CGFloat)] = [:]   // sideways at a clip's first and last frame, in idle_loop widths (shifts)
    func shift(_ p: Pose) -> CGFloat {   // so her head doesn't jump where one clip hands over to the next
        guard let c = p.clip, let (a, b) = edges[c], let n = clips[c]?.count, n > 1 else { return 0 }
        return a + (b - a) * CGFloat(p.index) / CGFloat(n - 1)
    }
    init?(_ dir: URL) {
        guard isCharacter(dir) else { return nil }
        self.dir = dir
        Task { [weak self] in   // each clip's frame count and size from its track, without decoding it; then the frames she rests on; then unpacking
            var found: [(Clip, URL, Int, CGSize, URL?)] = []
            for c in Clip.allCases {
                let f = dir.appendingPathComponent("clips/\(c.rawValue).mov")
                guard FileManager.default.fileExists(atPath: f.path), let track = try? await AVURLAsset(url: f).loadTracks(withMediaType: .video).first,
                      let (range, size) = try? await track.load(.timeRange, .naturalSize) else { continue }
                let n = Int((range.duration.seconds * Double(Clip.fps)).rounded())
                if n > 0 { found.append((c, f, n, size, Clip.cache(f))) }
            }
            guard let px = found.first(where: { $0.0 == .idle_loop })?.3 else { return }
            for (_, _, _, _, d) in found { if let d { try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: d.path) } }
            let holds = await MainActor.run { [found, weak self] () -> [(Pose, Pose)] in
                guard let self else { return [] }
                aspect = px.width / px.height
                let k = px.height / 600; scale = (0.8...1.25).contains(k) ? k : 1
                for (c, f, n, size, d) in found {
                    clipFiles[c] = f; clipSize[c] = CGSize(width: size.width / px.width, height: size.height / px.height); clips[c] = (0..<n).map { Pose(c, $0) }
                    if let d, FileManager.default.fileExists(atPath: d.path) { unpacked[c] = d }
                }
                return [Pose.closed, .work, .sleep, .read].map { ($0, self.hold($0)) }.filter { $0.1.clip != nil }
            }
            for (pose, p) in holds {
                guard let c = p.clip, let f = found.first(where: { $0.0 == c }) else { continue }
                let im = await Sprite.frame(f, p.index)
                let mask = pose == .closed ? im?.cgImage(forProposedRect: nil, context: nil, hints: nil).map(Sprite.alpha) : nil
                await MainActor.run { [weak self, im] in self?.held[p] = im; if let mask { self?.mask = mask } }   // her outline, for clicks
            }
            await MainActor.run { [weak self] in self?.settle() }
            let edges = await Sprite.shifts(found, px.width)
            await MainActor.run { [weak self] in self?.edges = edges }
            for (c, f, n, _, d) in found.sorted(by: { $0.0.loops && !$1.0.loops }) {   // the loops first: they play most
                guard self != nil, let d, !FileManager.default.fileExists(atPath: d.path), let done = await Clip.unpack(f, n, to: d) else { continue }
                await MainActor.run { [weak self] in self?.unpacked[c] = done; self?.decoded[c] = nil; self?.recent.removeAll { $0 == c } }
            }
        }
    }
    private static func frame(_ f: (Clip, URL, Int, CGSize, URL?), _ i: Int) async -> NSImage? {   // from the cache when it's there (every launch but the first), else from the movie
        if let im = f.4.flatMap({ NSImage(contentsOf: $0.appendingPathComponent("\(i).heic")) }) { return im }
        return await Clip.decode(f.1, [i]).first
    }
    /// Each clip lined up with the ones it plays between, by the outline of her head: its first frame with the frame before it and,
    /// back to standing, its last with idle_loop's first, sliding from one to the other. The video model doesn't keep her in one place.
    private static func shifts(_ found: [(Clip, URL, Int, CGSize, URL?)], _ width: CGFloat) async -> [Clip: (CGFloat, CGFloat)] {
        let idle = (Clip.idle_loop, 0), links: [(Clip, (Clip, Int), (Clip, Int)?)] = [(.closed_to_work, idle, nil), (.closed_to_sleep, idle, nil),
            (.closed_to_read, idle, nil), (.work_loop, (.closed_to_work, -1), nil), (.sleep_loop, (.closed_to_sleep, -1), nil),
            (.sleep_to_closed, (.sleep_loop, -1), idle),
            (.yawn, idle, idle), (.surprise, idle, idle), (.talk, idle, idle)]
        var masks: [Pose: Mask] = [:]
        func mask(_ c: Clip, _ i: Int) async -> Mask? {
            guard let f = found.first(where: { $0.0 == c }) else { return nil }
            let p = Pose(c, i < 0 ? f.2 + i : i)
            if masks[p] == nil { masks[p] = await frame(f, p.index)?.cgImage(forProposedRect: nil, context: nil, hints: nil).map(Sprite.alpha) }
            return masks[p]
        }
        var px: [Clip: (Int, Int)] = [.idle_loop: (0, 0)]   // at the first frame and the last
        func align(_ c: Clip, _ i: Int, _ to: (Clip, Int)) async -> Int? {
            guard let r = px[to.0], let a = await mask(c, i), let b = await mask(to.0, to.1) else { return nil }
            return (to.1 < 0 ? r.1 : r.0) - offset(a, b)   // from the end it lands on: its first frame's or its last's
        }
        for (c, from, to) in links {
            guard let s = await align(c, 0, from) else { continue }
            px[c] = (s, to == nil ? s : await align(c, -1, to!) ?? s)
        }
        return px.mapValues { (CGFloat($0.0) / width, CGFloat($0.1) / width) }
    }
    /// How far right `a` sits from `b`, both standing on the bottom centre: the columns of her head (the top third of `b`) matched up.
    private static func offset(_ a: Mask, _ b: Mask) -> Int {
        guard let top = (0..<b.h).first(where: { y in (0..<b.w).contains { b.alpha[y * b.w + $0] > 128 } }) else { return 0 }
        let reach = 40, tall = b.h - top, rise = tall * 2 / 3...tall, half = max(a.w, b.w) / 2 + reach + 1   // heights above the bottom
        func cols(_ m: Mask) -> [Int] {   // opaque count per column, the centre at `half`
            var s = [Int](repeating: 0, count: 2 * half + 1)
            for r in rise where r <= m.h { let y = m.h - r; for x in 0..<m.w where m.alpha[y * m.w + x] > 128 { s[x - m.w / 2 + half] += 1 } }
            return s
        }
        let ca = cols(a), cb = cols(b)
        func cost(_ s: Int) -> Int { (reach + 1..<2 * half - reach).reduce(0) { $0 + abs(ca[$1 + s] - cb[$1]) } }
        return (-reach...reach).map { ($0, cost($0)) }.min { $0.1 < $1.1 }?.0 ?? 0
    }
    func size(_ p: Pose) -> CGSize { p.clip.flatMap { clipSize[$0] } ?? CGSize(width: 1, height: 1) }   // relative to idle_loop
    /// The frame she rests on in a pose.
    func hold(_ p: Pose) -> Pose {
        (p == .read ? clips[.closed_to_read]?.last : Clip.rests[p].flatMap { clips[$0.loop]?.first }) ?? p
    }
    private func settle() { settled = true; onSettled?() }
    /// Whether a frame can be drawn now. A clip frame needs reading from the cache, or before that its clip decoded; asking starts that.
    func ready(_ p: Pose) -> Bool {
        guard let c = p.clip, held[p] == nil else { return true }
        if let dir = unpacked[c] { readAhead(p, dir); if read[p] == nil { return false }; shown = p; return true }
        if decoded[c] == nil { prepare(c); return false }
        if recent.last != c { touch(c) }
        return true
    }
    private func touch(_ c: Clip) {   // most recently used last; only the last three stay decoded
        recent.removeAll { $0 == c }; recent.append(c)
        for old in recent.dropLast(3) { decoded[old] = nil }
        recent = Array(recent.suffix(3))
    }
    private func readAhead(_ p: Pose, _ dir: URL) {   // this frame and the next three, each a few ms; the rest are let go
        guard let c = p.clip, let all = clips[c] else { return }
        let want = (0..<4).map { all[(p.index + $0) % all.count] }
        for q in read.keys where !want.contains(q) && q != shown { read[q] = nil }   // what's on screen stays while the next one reads
        for q in want where read[q] == nil && reading.insert(q).inserted {
            DispatchQueue.global(qos: .userInitiated).async {
                let im = CGImageSourceCreateWithURL(dir.appendingPathComponent("\(q.index).heic") as CFURL, nil)
                    .flatMap { CGImageSourceCreateImageAtIndex($0, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) }
                DispatchQueue.main.async { self.reading.remove(q); self.read[q] = im.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) } }
            }
        }
    }
    func prepare(_ c: Clip) {   // ahead of time: decode a clip not unpacked yet, or read an unpacked one's first frames
        if let dir = unpacked[c], let first = clips[c]?.first { return readAhead(first, dir) }
        guard let f = clipFiles[c], let n = clips[c]?.count, decoding.insert(c).inserted else { return }
        Task {
            let images = await Clip.decode(f, Array(0..<n))
            await MainActor.run { decoding.remove(c); if unpacked[c] == nil { decoded[c] = images; touch(c) } }
        }
    }
    func image(_ p: Pose) -> NSImage? {
        if let f = held[p] ?? read[p] { return f }
        if let c = p.clip, let d = decoded[c], p.index < d.count { return d[p.index] }
        return nil
    }
    func drawable(_ p: Pose) -> Pose { image(p) == nil ? hold(.closed) : p }   // a frame not in yet shows her standing
    static func alpha(_ cg: CGImage) -> Mask {   // drawn into an alpha-only buffer: one pass, no per-pixel objects
        let w = cg.width, h = cg.height
        var alpha = [UInt8](repeating: 0, count: w * h)
        CGContext(data: &alpha, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)!.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (w, h, alpha)
    }
    func opaque(atUnit p: CGPoint) -> Bool {   // on the frame she stands on; p in 0...1, origin bottom-left
        guard let m = mask else { return false }
        let x = Int(p.x * CGFloat(m.w)), y = Int((1 - p.y) * CGFloat(m.h))
        return x >= 0 && y >= 0 && x < m.w && y < m.h && m.alpha[y * m.w + x] > 25
    }
}

final class PetWindow: NSWindow {
    override var canBecomeKey: Bool { true }   // borderless windows can't take typing otherwise
}

final class PetView: NSView {
    var sprite: Sprite { didSet { needsDisplay = true } }   // a new one comes settled (loadSprite)
    var spriteHeight: CGFloat = 240
    var pose = Pose.closed { didSet { if pose != oldValue { needsDisplay = true } } }
    var fade: CGFloat = 1 { didSet { if fade != oldValue { needsDisplay = true } } }  // sprite opacity
    var onClick: (() -> Void)?
    var onMoved: (() -> Void)?
    var onRightClick: (() -> Void)?
    var onTouch: (() -> Void)?   // any click or drag
    private var dragStart: NSPoint?, moved = false

    init(sprite: Sprite) { self.sprite = sprite; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    var spriteRect: NSRect {
        let w = spriteHeight * sprite.aspect
        return NSRect(x: (bounds.width - w) / 2, y: 0, width: w, height: spriteHeight)
    }
    /// The frame drawn and where: the same scale and bottom centre as idle_loop.
    var shown: (pose: Pose, rect: NSRect) {
        let r = spriteRect, p = sprite.drawable(pose), k = sprite.size(p), w = r.width * k.width
        return (p, NSRect(x: r.midX - w / 2 + sprite.shift(p) * r.width, y: r.minY, width: w, height: r.height * k.height))
    }
    override func draw(_ dirtyRect: NSRect) {
        guard sprite.settled else { return }
        NSGraphicsContext.current?.imageInterpolation = .high
        let (p, r) = shown
        sprite.image(p)?.draw(in: r, from: .zero, operation: .sourceOver, fraction: fade)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        for v in subviews.reversed() where !v.isHidden && v.frame.contains(p) { return v.hitTest(point) }
        let r = spriteRect
        guard r.contains(p) else { return nil }
        return sprite.opaque(atUnit: CGPoint(x: (p.x - r.minX) / r.width, y: (p.y - r.minY) / r.height)) ? self : nil
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) { onTouch?(); dragStart = e.locationInWindow; moved = false }
    override func mouseDragged(with e: NSEvent) {
        guard let start = dragStart, let w = window else { return }
        let p = NSEvent.mouseLocation
        w.setFrameOrigin(NSPoint(x: p.x - start.x, y: p.y - start.y)); moved = true
    }
    override func mouseUp(with e: NSEvent) {
        if moved { onMoved?() } else { onClick?() }
        dragStart = nil
    }
    override func rightMouseDown(with e: NSEvent) { onTouch?(); onRightClick?() }
}

// MARK: Claude Code activity + usage, read from ~/.claude*/projects/**/*.jsonl

struct Activity { var working = false, interrupted = false; var detail = ""; var project = ""; var last = Date.distantPast; var since = Date.distantPast; var context = 0 }
struct Usage: Equatable { var input = 0, output = 0, sessions = 0 }

final class Monitor {
    private struct FileState { var offset: UInt64 = 0; var rest = Data(); var act = Activity(); var lastUser = Date.distantPast }
    private var files: [String: FileState] = [:]
    private var seen = Set<String>()                    // message ids already counted (one message spans several lines)
    private var dayStart = Date.distantPast
    private var usage: [String: (input: Int, output: Int, sessions: Set<String>)] = [:]
    var ignoreSession: () -> String? = { nil }          // the session the pet itself is attached to
    // only user/assistant lines matter; skip everything else (huge tool results, snapshots…) before parsing
    private let wanted = [Data(#""type":"user""#.utf8), Data(#""type":"assistant""#.utf8)]

    func poll() -> (Activity?, [(label: String, usage: Usage)]) {
        let start = Calendar.current.startOfDay(for: Date())
        if start != dayStart {   // new day: restart the counts, keep read offsets (yesterday's lines don't count anyway)
            dayStart = start; usage = [:]; seen = []
            files = files.filter { $0.value.act.last >= start.addingTimeInterval(-3600) }
        }
        for t in transcripts(since: start, subagents: true) where files[t.url.path]?.offset != t.size {
            read(t.url, label: t.label, size: t.size)
        }
        let mine = ignoreSession()
        let latest = files.filter { mine == nil || !$0.key.contains(mine!) }.values.map(\.act).max { $0.last < $1.last }
        let rows = usage.sorted { $0.key < $1.key }.map { ($0.key, Usage(input: $0.value.input, output: $0.value.output, sessions: $0.value.sessions.count)) }
        return (latest, rows)
    }

    /// JSON lines appended to `url` since `st.offset` (from the start again if the file shrank).
    private func newLines(_ url: URL, _ st: inout FileState, size: UInt64, keep: (Data) -> Bool = { _ in true }) -> [[String: Any]] {
        if size < st.offset { st = FileState() }
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        try? h.seek(toOffset: st.offset)
        st.rest += (try? h.read(upToCount: Int(size - st.offset))) ?? Data()
        st.offset = size
        return takeJSONLines(&st.rest, keep: keep)
    }

    /// Where the Claude Code PermissionRequest hook appends its input, one JSON object per line (see README).
    static let hookFile = appSupport.appendingPathComponent("events.jsonl")
    private var hookState: FileState?   // nil until the first call, which skips what was there before launch
    private var ask: (session: String, at: Date)?   // the prompt the bubble shows, until its session moves on
    enum AskChange { case show(project: String, tool: String), hide }
    /// The newest permission prompt from a Claude Code session; or `.hide` once the shown one is answered, which its
    /// transcript shows as a user line after the prompt (the tool result, a denial or an interrupt).
    func askChange() -> AskChange? {
        let url = Self.hookFile
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        var st = hookState ?? FileState(offset: size)
        let mine = ignoreSession()
        let asks = size == st.offset ? [] : newLines(url, &st, size: size).filter {
            $0["hook_event_name"] as? String == "PermissionRequest" && $0["session_id"] as? String != mine
        }
        hookState = st
        if let j = asks.last, let session = j["session_id"] as? String {
            ask = (session, Date())
            return .show(project: ((j["cwd"] as? String ?? "") as NSString).lastPathComponent,
                         tool: describeTool(j["tool_name"] as? String ?? "a tool", j["tool_input"] as? [String: Any] ?? [:]))
        }
        if let a = ask, files.contains(where: { $0.key.contains(a.session) && $0.value.lastUser > a.at }) { ask = nil; return .hide }
        return nil
    }

    private func read(_ url: URL, label: String, size: UInt64) {
        var st = files[url.path] ?? FileState()
        let session = url.deletingPathExtension().lastPathComponent
        for j in newLines(url, &st, size: size, keep: { line in self.wanted.contains { line.range(of: $0) != nil } }) {
            guard let type = j["type"] as? String, type == "user" || type == "assistant",
                  let ts = (j["timestamp"] as? String).flatMap(isoFrac.date) else { continue }
            let msg = j["message"] as? [String: Any] ?? [:]
            let content = msg["content"] as? [[String: Any]] ?? []
            if let cwd = j["cwd"] as? String { st.act.project = (cwd as NSString).lastPathComponent }
            if type == "user" {
                st.lastUser = max(st.lastUser, ts)
                let text = (msg["content"] as? String) ?? content.last(where: { $0["type"] as? String == "text" })?["text"] as? String
                // Esc in Claude Code leaves "[Request interrupted by user…]" as the last text: the turn is over
                st.act.interrupted = text?.hasPrefix("[Request interrupted by user") == true
                if st.act.interrupted { st.act.working = false } else {
                    if text != nil { if !st.act.working { st.act.since = ts }; st.act.detail = "thinking" }
                    st.act.working = true
                }
            } else {
                if let u = msg["usage"] as? [String: Any], let id = msg["id"] as? String {
                    let inp = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"].reduce(0) { $0 + (u[$1] as? Int ?? 0) }
                    st.act.context = inp
                    if ts >= dayStart, seen.insert(id).inserted {
                        var row = usage[label] ?? (0, 0, [])
                        row.input += inp; row.output += u["output_tokens"] as? Int ?? 0; row.sessions.insert(session)
                        usage[label] = row
                    }
                }
                if let tool = content.first(where: { $0["type"] as? String == "tool_use" }) {
                    st.act.detail = describeTool(tool["name"] as? String ?? "tool", tool["input"] as? [String: Any] ?? [:])
                    st.act.working = true
                } else if msg["stop_reason"] as? String == "end_turn" {
                    st.act.working = false; st.act.detail = "done"
                }
            }
            st.act.last = ts
        }
        files[url.path] = st
    }
}

// MARK: recent sessions (reads only the tail of each transcript)

struct Session {
    let id: String, dir: URL, cwd: String, title: String, modified: Date
    var label: String { "\((cwd as NSString).lastPathComponent) — \(title)" }
}

func recentSessions(days: Double = 7, limit: Int = 12) -> [Session] {
    var found: [Session] = []
    let fields = [Data(#""cwd""#.utf8), Data(#"Title""#.utf8), Data(#""lastPrompt""#.utf8)]
    for t in transcripts(since: Date().addingTimeInterval(-days * 86400), subagents: false) {
        guard let h = try? FileHandle(forReadingFrom: t.url) else { continue }
        try? h.seek(toOffset: t.size > 262_144 ? t.size - 262_144 : 0)
        var tail = ((try? h.readToEnd()) ?? Data()) + Data([0x0A]); try? h.close()
        var cwd = "", title = "", prompt = ""
        for j in takeJSONLines(&tail, keep: { line in fields.contains { line.range(of: $0) != nil } }) {
            if let c = j["cwd"] as? String { cwd = c }
            if let s = (j["customTitle"] ?? j["aiTitle"]) as? String { title = s }
            if let s = j["lastPrompt"] as? String { prompt = s }
        }
        guard !cwd.isEmpty else { continue }
        let id = t.url.deletingPathExtension().lastPathComponent
        let shown = String((title.isEmpty ? (prompt.isEmpty ? String(id.prefix(8)) : prompt) : title).prefix(40))
        let mod = (try? t.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        found.append(Session(id: id, dir: t.dir, cwd: cwd, title: shown, modified: mod))
    }
    return Array(found.sorted { $0.modified > $1.modified }.prefix(limit))
}

/// Opens Terminal in the session's directory and runs `claude --resume` there (a .command file needs no extra permissions).
func resumeInTerminal(_ t: Target) {
    guard let id = t.id else { return }
    let q = { (x: String) in "'" + x.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    let env = t.dir.flatMap(configEnv).map { "CLAUDE_CONFIG_DIR=\(q($0)) " } ?? "unset CLAUDE_CONFIG_DIR; "
    let script = "#!/bin/zsh -l\ncd \(q(t.cwd)) && \(env)exec claude --resume \(id)\n"
    try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    let file = cacheDir.appendingPathComponent("resume-\(id.prefix(8)).command")
    try? script.write(to: file, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    NSWorkspace.shared.open(file)
}

// MARK: talking to Claude Code: one long-lived `claude -p` process per attached session, stream-json both ways
// (the same protocol the IDE extensions use; tool permission requests arrive as control_request can_use_tool)

/// `claude`'s path and the PATH it needs, as the user's interactive shell sees them (resolved once; GUI apps get a bare PATH).
/// Runs `exe` and returns its exit status and stdout (stderr is dropped), or nil if it can't start. Blocks.
func runTool(_ exe: String, _ args: [String]) -> (status: Int32, out: Data)? {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()   // read first: a full pipe blocks the exit
    return (p.terminationStatus, data)
}

let claudeLaunch: (exe: String, path: String)? = {
    guard let r = runTool("/bin/zsh", ["-ilc", "print -r -- \"$PATH\"; command -v claude"]) else { return nil }
    let lines = String(decoding: r.out, as: UTF8.self).split(separator: "\n").map(String.init)
    guard lines.count >= 2, let exe = lines.last, exe.hasPrefix("/") else { return nil }
    return (exe, lines[lines.count - 2])
}()

/// A `claude` process with the PATH it needs, on an account's config dir; nil if claude isn't found.
func claudeProcess(_ args: [String], dir: URL?) -> Process? {
    guard let launch = claudeLaunch else { return nil }
    let p = Process(); p.executableURL = URL(fileURLWithPath: launch.exe); p.arguments = args
    var env = ProcessInfo.processInfo.environment
    env["CLAUDE_CONFIG_DIR"] = dir.flatMap(configEnv); env["PATH"] = launch.path
    p.environment = env
    return p
}

struct Target {
    var id: String?            // session id; nil = start a new one
    var cwd: String
    var dir: URL?              // Claude Code config dir
    var tools: Bool            // false = plain chat with the pet (no tools, pet persona)
    var name: String
}

final class Agent {
    enum Event { case text(String), step(String), permission(id: String, title: String, input: [String: Any]), done(String), failed(String) }
    var target: Target
    var onEvent: (Event) -> Void = { _ in }
    var onSession: (String) -> Void = { _ in }
    private(set) var busy = false
    private var proc: Process?, stdin: FileHandle?, buffer = Data()

    init(target: Target) { self.target = target }

    func attach(_ t: Target) { stop(); target = t }

    func send(_ text: String) {
        if proc?.isRunning != true { start() }
        busy = true
        write(["type": "user", "message": ["role": "user", "content": text]])
    }

    func answer(permission id: String, allow: Bool, input: [String: Any]) {
        let r: [String: Any] = allow ? ["behavior": "allow", "updatedInput": input] : ["behavior": "deny", "message": "The user declined this from the desktop pet."]
        write(["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": r]])
    }

    func interrupt() {
        guard busy else { return }
        write(["type": "control_request", "request_id": UUID().uuidString, "request": ["subtype": "interrupt"]])
    }

    func stop() { try? stdin?.close(); proc?.terminate(); proc = nil; stdin = nil; busy = false; buffer = Data() }

    private func write(_ o: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: o) else { return }
        try? stdin?.write(contentsOf: d + Data([0x0A]))
    }

    private func start() {
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--permission-prompt-tool", "stdio"]
        if let id = target.id { args += ["--resume", id] }
        else { let id = UUID().uuidString.lowercased(); target.id = id; args += ["--session-id", id]; onSession(id) }
        if !target.tools { args += ["--tools", "", "--disable-slash-commands", "--append-system-prompt", persona] }
        guard let p = claudeProcess(args, dir: target.dir) else { onEvent(.failed("I can't find the claude command.")); return }
        p.currentDirectoryURL = URL(fileURLWithPath: target.cwd)
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = Pipe()
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            DispatchQueue.main.async { self?.consume(d) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.proc === p else { return }
                if self.busy { self.onEvent(.failed("The claude process stopped.")) }
                self.proc = nil; self.stdin = nil; self.busy = false
            }
        }
        do { try p.run(); proc = p; stdin = inPipe.fileHandleForWriting }
        catch { onEvent(.failed("I can't start claude.")) }
    }

    private func consume(_ d: Data) {
        buffer += d
        takeJSONLines(&buffer).forEach(handle)
    }

    private func handle(_ m: [String: Any]) {
        switch m["type"] as? String {
        case "system":
            if let sid = m["session_id"] as? String, sid != target.id { target.id = sid; onSession(sid) }
        case "assistant":
            let content = (m["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for c in content {
                if c["type"] as? String == "text", let t = c["text"] as? String, !t.isEmpty { onEvent(.text(t)) }
                if c["type"] as? String == "tool_use" {
                    onEvent(.step(describeTool(c["name"] as? String ?? "tool", c["input"] as? [String: Any] ?? [:])))
                }
            }
        case "control_request":
            guard let id = m["request_id"] as? String, let r = m["request"] as? [String: Any] else { return }
            if r["subtype"] as? String == "can_use_tool" {
                let input = r["input"] as? [String: Any] ?? [:]
                onEvent(.permission(id: id, title: describeTool(r["tool_name"] as? String ?? "tool", input, full: true), input: input))
            } else {
                write(["type": "control_response", "response": ["subtype": "error", "request_id": id, "error": "not supported by the pet"]])
            }
        case "result":
            busy = false
            onEvent(.done((m["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)))
        default: break
        }
    }
}

// MARK: overlays

/// Scrollable, selectable speech bubble (long replies scroll instead of being cut off).
final class BubbleView: NSScrollView {
    let text = NSTextView()
    init() {
        super.init(frame: .zero)
        drawsBackground = true; backgroundColor = NSColor(white: 1, alpha: 0.96); hasVerticalScroller = true
        autohidesScrollers = true; borderType = .noBorder; wantsLayer = true; layer?.cornerRadius = 8; isHidden = true
        text.isEditable = false; text.isSelectable = true; text.drawsBackground = false
        text.font = .systemFont(ofSize: 12, weight: .medium); text.textColor = NSColor(white: 0.15, alpha: 1)
        text.textContainerInset = NSSize(width: 6, height: 5); text.isVerticallyResizable = true
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        documentView = text
    }
    required init?(coder: NSCoder) { fatalError() }
    var string: String { get { text.string } set { text.string = newValue; text.scrollToBeginningOfDocument(nil) } }
    func fittingHeight(width: CGFloat) -> CGFloat {
        text.frame.size.width = width
        guard let lm = text.layoutManager, let tc = text.textContainer else { return 30 }
        lm.ensureLayout(for: tc)
        return lm.usedRect(for: tc).height + 12
    }
}

/// "Claude wants to run …  [Deny] [Allow]"
final class PermissionCard: NSView {
    let label = NSTextField(wrappingLabelWithString: "")
    let allow = NSButton(title: "Allow", target: nil, action: nil), deny = NSButton(title: "Deny", target: nil, action: nil)
    var onAnswer: (Bool) -> Void = { _ in }
    init() {
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 8; layer?.backgroundColor = NSColor(calibratedRed: 1, green: 0.97, blue: 0.9, alpha: 0.97).cgColor
        label.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular); label.maximumNumberOfLines = 5
        allow.bezelStyle = .rounded; deny.bezelStyle = .rounded; allow.keyEquivalent = "\r"
        allow.target = self; allow.action = #selector(yes); deny.target = self; deny.action = #selector(no)
        [label, allow, deny].forEach(addSubview); isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func yes() { onAnswer(true) }
    @objc func no() { onAnswer(false) }
    override func layout() {
        super.layout()
        allow.frame = NSRect(x: bounds.width - 76, y: 4, width: 70, height: 26)
        deny.frame = NSRect(x: bounds.width - 150, y: 4, width: 70, height: 26)
        label.frame = NSRect(x: 8, y: 32, width: bounds.width - 16, height: bounds.height - 36)
    }
}

// MARK: plan limits (the percentages /usage shows), from the endpoint Claude Code itself calls

struct Limit { let name: String; let used: Double; let resets: Date? }
struct LimitError: Error { let text: String }

func sha256Hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

/// Keychain item holding a config dir's login, named the way Claude Code names it:
/// "Claude Code-credentials", plus "-<first 8 hex of sha256(dir)>" for a non-default CLAUDE_CONFIG_DIR.
func keychainService(_ dir: URL) -> String {
    guard let env = configEnv(dir) else { return "Claude Code-credentials" }
    let hash = sha256Hex(Data(env.precomposedStringWithCanonicalMapping.utf8))
    return "Claude Code-credentials-\(hash.prefix(8))"
}

/// Fetches the plan limits for one account; `done` runs on a background queue. Best-effort: this reads Claude Code's
/// private credential layout and an undocumented endpoint. On a 401 with `refresh`, has Claude Code renew the login
/// with a tiny headless haiku turn (it rotates the token itself, so the keychain item stays its own) and retries once.
func planLimits(_ dir: URL, refresh: Bool = false, done: @escaping (Result<[Limit], LimitError>) -> Void) {
    // Read through /usr/bin/security, as Claude Code does: the item trusts that tool, so there's no prompt. Reading it
    // directly asks again whenever Claude Code rewrites the item on a token refresh, even after "Always Allow".
    // Account = the user name, as Claude Code stores it; stray items with other accounts can share the service name.
    let user = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
    guard let r = runTool("/usr/bin/security", ["find-generic-password", "-a", user, "-s", keychainService(dir), "-w"]) else {
        return done(.failure(LimitError(text: "can't run security")))
    }
    guard r.status != 44 else { return done(.failure(LimitError(text: "no login found"))) }   // errSecItemNotFound
    guard r.status == 0, let creds = (try? JSONSerialization.jsonObject(with: r.out)) as? [String: Any],
          let token = (creds["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String else {
        return done(.failure(LimitError(text: "can't read login (\(r.status))")))
    }
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 10)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    URLSession.shared.dataTask(with: req) { body, resp, _ in
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401, refresh, let p = claudeProcess(["-p", "reply OK only", "--model", "haiku", "--tools", "", "--no-session-persistence"], dir: dir) {
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            p.terminationHandler = { _ in planLimits(dir, done: done) }
            if (try? p.run()) != nil { return }
        }
        guard status == 200, let body, let j = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return done(.failure(LimitError(text: status == 401 ? "login expired, open Claude Code once" : "unavailable (\(status))")))
        }
        let names = [("five_hour", "5-hour"), ("seven_day", "Weekly"), ("seven_day_opus", "Opus"), ("seven_day_sonnet", "Sonnet")]
        done(.success(names.compactMap { key, name in
            guard let l = j[key] as? [String: Any], let used = l["utilization"] as? Double else { return nil }
            let at = (l["resets_at"] as? String).flatMap { isoFrac.date(from: $0) ?? isoPlain.date(from: $0) }
            return Limit(name: name, used: used, resets: at)
        }))
    }.resume()
}

// MARK: app

/// A small copy of the pet for the settings window, drawn the way the pet is.
final class SpritePreview: NSView {
    var sprite: Sprite? { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 240) }
    override func draw(_ dirtyRect: NSRect) {
        guard let s = sprite, let im = s.image(s.hold(.closed)) else { return }
        NSGraphicsContext.current?.imageInterpolation = .high
        im.draw(in: NSRect(x: (bounds.width - bounds.height * s.aspect) / 2, y: 0, width: bounds.height * s.aspect, height: bounds.height),
                                from: .zero, operation: .sourceOver, fraction: 1)
    }
}

/// The settings window. Every control applies at once; reload() reads them back from the app's state each time it opens
/// and whenever the sprite changes, so the preview and the controls follow a character change.
final class SettingsPanel: NSObject {
    unowned let app: App
    let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let size = NSPopUpButton(), character = NSPopUpButton(), preview = SpritePreview()
    let top: NSButton, fade: NSButton
    let voice: NSSegmentedControl, opacity = NSSlider(value: 1, minValue: 0.3, maxValue: 1, target: nil, action: nil)

    init(_ app: App) {
        self.app = app
        top = NSButton(checkboxWithTitle: "Always on top", target: nil, action: nil)
        fade = NSButton(checkboxWithTitle: "See-through on hover", target: nil, action: nil)
        voice = NSSegmentedControl(labels: Voice.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
        super.init()
        size.addItems(withTitles: app.sizes.map(\.0))
        for (c, a) in [(size, #selector(sizeChanged)), (voice, #selector(voiceChanged))] { c.target = self; c.action = a }
        for (c, a) in [(top, #selector(topChanged)), (fade, #selector(fadeChanged))] { c.target = self; c.action = a }
        opacity.target = self; opacity.action = #selector(opacityChanged)
        let label = { (t: String) in NSTextField(labelWithString: t) }
        let grid = NSGridView(views: [
            [label("Size"), size], [label("Character"), character], [label("Voice"), voice], [label("Opacity"), opacity], [NSView(), top], [NSView(), fade]])
        grid.rowSpacing = 10; grid.columnSpacing = 12; grid.column(at: 0).xPlacement = .trailing
        let row = NSStackView(views: [preview, grid]); row.spacing = 24; row.alignment = .centerY
        let box = NSView(); row.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(row)
        NSLayoutConstraint.activate([row.topAnchor.constraint(equalTo: box.topAnchor, constant: 20), row.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -20),
                                     row.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 20), row.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -20)])
        window.title = "Claude Pet Settings"; window.contentView = box; window.isReleasedWhenClosed = false; window.collectionBehavior = .moveToActiveSpace
        window.level = .floating; window.setContentSize(box.fittingSize); window.center()
    }
    func show() { reload(characters: true); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
    func reload(characters scan: Bool = false) {   // scan: list the characters folder again (on show, and after a switch, which may follow an add)
        size.selectItem(at: app.sizeIndex ?? -1)
        if scan {
            character.removeAllItems()
            addCharacters(to: character.menu!, action: #selector(characterChanged), target: self)
        }
        character.selectItem(withTitle: app.currentCharacter)
        preview.sprite = app.view.sprite
        voice.selectedSegment = app.voiceIndex
        top.state = app.window.level == .floating ? .on : .off; fade.state = app.fadeOnHover ? .on : .off
        opacity.doubleValue = Double(app.opacity)
    }
    @objc func sizeChanged() { app.setSize(size.indexOfSelectedItem) }
    @objc func characterChanged() { if let dir = character.selectedItem?.representedObject as? URL { app.setCharacter(character.titleOfSelectedItem!, dir) } }
    @objc func voiceChanged() { app.setVoice(Voice.allCases[voice.selectedSegment]) }
    @objc func topChanged() { app.setTop(top.state == .on) }
    @objc func fadeChanged() { app.setFade(fade.state == .on) }
    @objc func opacityChanged() { app.setOpacity(CGFloat(opacity.doubleValue)) }
}

final class App: NSObject, NSApplicationDelegate, NSTextFieldDelegate, NSMenuDelegate {
    let monitor = Monitor()
    var window: PetWindow!, view: PetView!, status: NSStatusItem!
    let bubble = BubbleView(), card = PermissionCard(), input = NSTextField()
    let statusPill: NSTextField = {
        let f = NSTextField(wrappingLabelWithString: "")
        f.isEditable = false; f.isSelectable = false; f.drawsBackground = true; f.isHidden = true
        f.backgroundColor = NSColor(white: 1, alpha: 0.8); f.textColor = NSColor(white: 0.15, alpha: 1)
        f.font = .systemFont(ofSize: 10); f.alignment = .center
        f.wantsLayer = true; f.layer?.cornerRadius = 8
        return f
    }()
    let pollQueue = DispatchQueue(label: "pet.monitor"); var polling = false
    var bubbleTimer: Timer?, t: Double = 0
    var inputSince: Double = 0       // last time the input opened or changed: an empty one closes after 30 s
    var waiting = false              // sent a message, no text back yet: the bubble shows animated dots
    var wasWorking = false, agentStep = "", otherActivity = ""
    var pending: [(id: String, title: String, input: [String: Any])] = []
    var lastUsage: [String] = []
    let usageLabel: NSTextField = {
        let f = NSTextField(labelWithString: ""); f.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }()
    lazy var usagePopover: NSPopover = {
        let vc = NSViewController(); vc.view = NSView(); vc.view.addSubview(usageLabel)
        NSLayoutConstraint.activate([
            usageLabel.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor, constant: 14),
            usageLabel.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor, constant: -14),
            usageLabel.topAnchor.constraint(equalTo: vc.view.topAnchor, constant: 12),
            usageLabel.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor, constant: -12),
        ])
        let p = NSPopover(); p.contentViewController = vc; p.behavior = .transient
        return p
    }()
    let resetFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE HH:mm"; return f }()
    var limits: [String: Result<[Limit], LimitError>] = [:], limitsFetched = Date.distantPast   // per account label
    var loginRefreshed: [String: Date] = [:]   // per account label; renewing costs a haiku turn, so at most every 10 min
    let headroom: CGFloat = 230
    let sizes: [(String, CGFloat)] = [("Small", 160), ("Medium", 240), ("Large", 340)]
    var height: CGFloat { CGFloat(UserDefaults.standard.object(forKey: "height") as? Double ?? 240) }
    var fadeOnHover = UserDefaults.standard.bool(forKey: "fadeOnHover")
    var opacity = CGFloat(UserDefaults.standard.object(forKey: "opacity") as? Double ?? 1)
    var sizeIndex: Int? { sizes.firstIndex { $0.1 == height } }
    var voiceIndex: Int { Voice.allCases.firstIndex(of: voice)! }
    /// The settings with a fixed list of choices, for the menu-bar submenus (Settings has its own controls for them).
    lazy var choices: [(title: String, options: [String], current: () -> Int?, set: (Int) -> Void)] = [
        ("Size", sizes.map(\.0), { [unowned self] in sizeIndex }, { [unowned self] in setSize($0) }),
        ("Voice", Voice.allCases.map(\.title), { [unowned self] in voiceIndex }, { [unowned self] in setVoice(Voice.allCases[$0]) })]
    var choiceMenus: [NSMenu] = []
    var settings: SettingsPanel?, spriteGen = 0   // spriteGen numbers the sprite builds, so a slow old one can't replace a newer
    var currentCharacter: String { UserDefaults.standard.string(forKey: "character") ?? defaultCharacter }
    let relative: RelativeDateTimeFormatter = { let f = RelativeDateTimeFormatter(); f.unitsStyle = .short; return f }()
    var sigterm: DispatchSourceSignal?

    var petChatID: String? {
        get { UserDefaults.standard.string(forKey: "chatSession") }
        set { UserDefaults.standard.set(newValue, forKey: "chatSession") }
    }
    func petChat() -> Target { Target(id: petChatID, cwd: home.path, dir: accounts.first?.dir, tools: false, name: "Pet chat") }
    lazy var agent = Agent(target: petChat())

    func applicationDidFinishLaunching(_ n: Notification) {
        if let s = UserDefaults.standard.string(forKey: "character"), !s.hasPrefix("Claude (") {   // saved before every name was Claude (<name>)
            UserDefaults.standard.set(s == "Claude" || s == "Opus" ? defaultCharacter : s.hasPrefix("Opus (") ? "Claude" + s.dropFirst(4) : "Claude (\(s))", forKey: "character")
        }
        DispatchQueue.global(qos: .background).async { Clip.pruneCache() }
        window = PetWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.level = UserDefaults.standard.object(forKey: "onTop") as? Bool ?? true ? .floating : .normal
        view = PetView(sprite: characters().first { $0.name == currentCharacter }
            .flatMap { Sprite($0.dir) } ?? Sprite(Bundle.main.resourceURL!)!)
        view.onClick = { [weak self] in self?.toggleInput() }
        view.onMoved = { [weak self] in self?.window.saveFrame(usingName: "pet") }   // she opens there next time
        view.onTouch = { [weak self] in guard let self else { return }; self.poke(self.startle) }
        view.onRightClick = { [weak self] in self?.toggleUsagePanel() }
        window.contentView = view
        input.isHidden = true; input.delegate = self
        input.focusRingType = .none; input.bezelStyle = .roundedBezel; input.font = .systemFont(ofSize: 12)
        [statusPill, bubble, card, input].forEach { view.addSubview($0) }
        card.onAnswer = { [weak self] ok in self?.answerPermission(ok) }
        agent.onEvent = { [weak self] e in self?.agentEvent(e) }
        agent.onSession = { [weak self] id in if self?.agent.target.tools == false { self?.petChatID = id } }
        monitor.ignoreSession = { [weak self] in self?.agent.target.id }
        view.sprite.onSettled = { [weak self] in   // her size is known once her clips are
            guard let self else { return }
            window.setContentSize(petSize(height))   // borderless: setFrameUsingName restores only the origin
            var restored = window.setFrameUsingName("pet")
            if !restored, let s = UserDefaults.standard.string(forKey: "origin") {   // position saved by v0.1
                window.setFrameOrigin(NSPointFromString(s)); restored = true
            }
            resize(height, keepBottom: restored); view.needsDisplay = true
        }
        updatePlaceholder()
        window.orderFrontRegardless()
        setupMenu()
        // `pkill` / logout send SIGTERM: quit through AppKit so the claude child process is stopped too
        signal(SIGTERM, SIG_IGN)
        sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm?.setEventHandler { NSApp.terminate(nil) }; sigterm?.resume()
        Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in self?.tick() }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.pollActivity() }
        pollActivity(); refreshSessions(); watchPermissionPrompts()
        pollQueue.async { _ = claudeLaunch; _ = Sfx.soft; _ = Sfx.chip }   // resolve the claude path and build the blips early, off main
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.say("Hello. Click me to chat.") }
    }

    func petSize(_ h: CGFloat) -> NSSize { let h = h * view.sprite.scale; return NSSize(width: max(h * view.sprite.aspect, 300), height: h + headroom) }

    func resize(_ h: CGFloat, keepBottom: Bool = true) {
        let size = petSize(h), w = size.width
        let origin: NSPoint
        if keepBottom { origin = NSPoint(x: window.frame.midX - w / 2, y: window.frame.minY) }
        else { let v = NSScreen.main!.visibleFrame; origin = NSPoint(x: v.maxX - w - 40, y: v.minY + 10) }
        window.setFrame(NSRect(origin: origin, size: size), display: true)
        view.spriteHeight = h * view.sprite.scale
        window.saveFrame(usingName: "pet"); layoutOverlays()
        UserDefaults.standard.set(Double(h), forKey: "height")
    }


    /// Visibility and frames of everything above the head, from state:
    /// [input] [status pill] [permission card, or else the bubble]. Call after any state change.
    func layoutOverlays() {
        statusPill.isHidden = statusPill.stringValue.isEmpty
        card.isHidden = pending.isEmpty
        if !card.isHidden { bubble.isHidden = true }
        let w = window.frame.width
        input.frame = NSRect(x: 8, y: view.spriteHeight + 4, width: w - 16, height: 24)
        var y = view.spriteHeight + (input.isHidden ? 6 : 32)
        let fit = statusPill.sizeThatFits(NSSize(width: w - 24, height: .greatestFiniteMagnitude))
        statusPill.frame = NSRect(x: 4, y: y, width: w - 8, height: min(fit.height + 6, 30))
        if !statusPill.isHidden { y += statusPill.frame.height + 4 }
        let room = view.spriteHeight + headroom - y - 4
        card.frame = NSRect(x: 4, y: y, width: w - 8, height: min(130, room))
        bubble.frame = NSRect(x: 4, y: y, width: w - 8, height: min(bubble.fittingHeight(width: w - 8), room))
    }

    func tick() {   // 30fps: waiting dots, animation
        t += 1 / 30
        if waiting && Int(t * 30) % 12 == 0 { bubble.string = String(repeating: "·", count: Int(t * 2.5) % 3 + 1) }
        while !anim.isEmpty && t >= animStepEnd {   // catch up on frames shorter than a tick (fast typing)
            anim.removeFirst()
            animStepEnd += anim.first?.1 ?? 0
        }
        typeStep()
        let goal: Pose = asleep ? .sleep : statusPill.isHidden ? .closed : .work   // writing for as long as the pill is up
        if goal != rest && anim.isEmpty { play(leave(rest) + clip(Clip.rests[goal]?.enter), .idle); rest = goal }   // through standing
        let lp = loop
        if anim.isEmpty && (lp != nil || t >= nextIdle) { idleAnimation(); nextIdle = t + .random(in: 2.5...6) }
        let resting = lp.flatMap { view.sprite.clips[$0]?.first } ?? view.sprite.hold(rest)   // the first frame of the loop for where she is
        var want = anim.first?.0 ?? resting
        if !view.sprite.ready(want) {   // the frame drawn is still decoding (a quarter of a second): she stays as she is and the sequence waits
            want = view.pose
            if !anim.isEmpty { animStepEnd = t + anim[0].1 }
        }
        view.pose = want
        // see-through on hover: ease towards 30% in about half a second, and back
        let hover = fadeOnHover && view.shown.rect.contains(view.convert(window.mouseLocationOutsideOfEventStream, from: nil))
        let target: CGFloat = hover ? min(0.3, opacity) : opacity
        view.fade = abs(target - view.fade) < 0.01 ? target : view.fade + (target - view.fade) * 0.2
        if !input.isHidden && t - inputSince > 30 && input.stringValue.isEmpty { closeInput() }
    }
    // dozes off after 5 minutes without a click, a word or a busy Claude Code session; poke() wakes her with a stretch, or with a start when she's clicked
    var lastActive = 0.0, rest = Pose.closed   // the pose she rests in; she moves to another through clips
    var wake: [(Pose, Double)] { leave(.sleep) }
    var startle: [(Pose, Double)] { clip(.surprise) }
    var asleep: Bool { t - lastActive > 300 }
    func poke(_ wakeup: [(Pose, Double)]? = nil) {
        if asleep { play(wakeup ?? wake, .expression); rest = .closed }
        lastActive = t
    }
    func leave(_ p: Pose) -> [(Pose, Double)] {   // back to standing: the clip out, or the one in backwards
        Clip.rests[p].map { r in let out = clip(r.exit); return out.isEmpty ? clip(r.enter).reversed() : out } ?? []
    }
    /// A clip's frames, repeated to fill `seconds` if given; none when the character has no such clip.
    func clip(_ c: Clip?, for seconds: Double? = nil) -> [(Pose, Double)] {
        guard let c, let f = view.sprite.clips[c] else { return [] }
        return (0..<(seconds.map { Int(($0 / Clip.frame).rounded(.up)) } ?? f.count)).map { (f[$0 % f.count], Clip.frame) }
    }

    // animation: one sequence of (pose, seconds) at a time, stepped by tick(); then back to the neutral face.
    // A sequence of equal or higher priority replaces the current one; a lower one is dropped.
    enum Priority: Int { case idle, expression, talk }
    var anim: [(Pose, Double)] = [], animPriority = Priority.idle, animStepEnd = 0.0, nextIdle = 2.0
    func play(_ seq: [(Pose, Double)], _ priority: Priority) {
        guard !seq.isEmpty, anim.isEmpty || priority.rawValue >= animPriority.rawValue else { return }
        anim = seq; animPriority = priority; animStepEnd = t + seq[0].1
    }
    // typewriter: the bubble's text appears a character at a time (about 11 a second, a pause at commas and sentence
    // ends, faster for long text so it takes ~5 s at most) with a blip at most every 0.18 s; say() plays the mouth
    // flap on the same schedule
    var typing: (full: [Character], shown: Int, next: Double, step: Double, voiced: Bool, tune: Tune)?
    var voice = Voice.saved(), lastBlip = 0.0, sayText = ""   // the voice picked; when the last blip played; the whole text being said
    let pauses = Set(",.!?;:，。！？；：、\n")
    func pauseAfter(_ c: Character, step: Double) -> Double { pauses.contains(c) ? step * 2.8 : step }
    func typeStep() {   // called by tick
        guard var ty = typing else { return }
        let before = ty.shown
        while ty.shown < ty.full.count && t >= ty.next {
            let c = ty.full[ty.shown]; ty.shown += 1; ty.next += pauseAfter(c, step: ty.step)
            if ty.voiced && !pauses.contains(c) && !c.isWhitespace && t - lastBlip >= voice.gap { Sfx.blip(voice, &ty.tune); lastBlip = t }
        }
        if ty.shown != before { bubble.string = String(ty.full.prefix(ty.shown)); layoutOverlays() }
        typing = ty.shown == ty.full.count ? nil : ty
    }
    var idleActions: [(chance: Double, seq: [(Pose, Double)])] { [   // the idle loop blinks, and reading holds the clip's last frame
        (0.06, clip(.yawn)),
        (0.14, clip(.closed_to_read) + [(view.sprite.hold(.read), 4.6)] + clip(.closed_to_read).reversed()),
        (0.80, clip(.idle_loop)),
    ] }
    var loop: Clip? { rest == .closed ? nil : Clip.rests[rest]?.loop }   // the loop she plays where she is: writing or asleep
    func idleAnimation() {   // pick one idle action by its chance; writing or asleep, that loop
        if let c = loop { play(clip(c), .idle); return }
        var r = Double.random(in: 0..<1)
        for a in idleActions { r -= a.chance; if r < 0 { play(a.seq, .idle); return } }
    }

    /// Type `text` into the bubble and keep it up for `hold` seconds after (it also stays while the input is open or
    /// Claude is working); `then` plays right after the typing.
    func say(_ text: String, hold: TimeInterval? = nil, then: [(Pose, Double)] = [], voiced: Bool = true) {
        let full = Array(text), step = min(0.09, 5 / Double(max(full.count, 1)))
        let woke = asleep; poke()   // the talk replaces poke's stretch: stretch once she's said it
        sayText = text; bubble.string = ""; bubble.isHidden = false
        typing = (full, 0, t, step, voiced, Tune(text))
        let long = full.reduce(0) { $0 + pauseAfter($1, step: step) }
        play(clip(.talk, for: long) + (woke ? wake : []) + then, .talk)   // she talks in the talking clip while it types
        holdBubble((hold ?? max(4, Double(text.count) / 12)) + long)
    }
    /// Keep the bubble up for `hold` seconds (longer while the input is open or Claude is working).
    func holdBubble(_ hold: TimeInterval) {
        bubbleTimer?.invalidate()
        bubbleTimer = Timer.scheduledTimer(withTimeInterval: hold, repeats: true) { [weak self] tm in
            guard let self else { return }
            if self.agent.busy || !self.input.isHidden { return }   // check again next period
            self.hideBubble()
        }
    }
    func hideBubble() { bubble.isHidden = true; bubbleTimer?.invalidate() }
    func readTime(_ s: String) -> TimeInterval { 15 + Double(s.count) / 4 }   // ~4 CJK chars/s, plus slack

    // input
    func updatePlaceholder() { input.placeholderString = "Message \(agent.target.name)…" }
    func toggleInput() {
        if !input.isHidden { closeInput(); return }
        input.isHidden = false; inputSince = t; layoutOverlays()
        NSApp.activate(ignoringOtherApps: true); window.makeKey(); window.makeFirstResponder(input)
    }
    func closeInput() { input.isHidden = true; input.stringValue = ""; layoutOverlays(); window.resignKey() }
    func controlTextDidChange(_ n: Notification) { inputSince = t }
    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) { closeInput(); return true }
        guard sel == #selector(NSResponder.insertNewline(_:)) else { return false }
        let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !agent.busy else { return true }
        input.stringValue = ""
        agentStep = ""; say("·", hold: 3600, voiced: false); waiting = true
        agent.send(text)
        refreshPill()
        return true
    }

    // agent events
    func agentEvent(_ e: Agent.Event) {
        switch e {
        case .text(let s): waiting = false; say(s, hold: 3600)
        case .step(let s): agentStep = s
        case .permission(let id, let title, let input):
            pending.append((id, title, input)); showCard()
        case .done(let s):
            waiting = false; agentStep = ""
            if s.isEmpty || s == sayText { holdBubble(readTime(sayText)) }   // already said by .text: let it finish
            else { say(s, hold: readTime(s)) }
        case .failed(let s): waiting = false; agentStep = ""; say(s)
        }
        refreshPill()
    }
    func showCard() {
        if let p = pending.first {
            card.label.stringValue = "\(agent.target.name) wants to run:\n\(p.title)"
            window.orderFrontRegardless()
        }
        layoutOverlays()
    }
    func answerPermission(_ ok: Bool) {
        guard !pending.isEmpty else { return }
        let p = pending.removeFirst()
        agent.answer(permission: p.id, allow: ok, input: p.input)
        if pending.isEmpty && !bubble.string.isEmpty { bubble.isHidden = false }
        showCard()
    }

    // status pill: the attached session's step, otherwise whatever other Claude Code session is busy
    func refreshPill() {
        let s = agent.busy ? "\(agent.target.name): \(agentStep.isEmpty ? "thinking" : agentStep)" : otherActivity
        guard s != statusPill.stringValue else { return }
        statusPill.stringValue = s; layoutOverlays()
    }

    // Claude Code activity in other sessions
    func pollActivity() {
        guard !polling else { return }   // the first scan of big transcripts can take longer than the 2s tick
        polling = true
        pollQueue.async { [weak self] in
            guard let self else { return }
            let (act, rows) = self.monitor.poll()
            DispatchQueue.main.async { self.polling = false; self.show(act, rows) }
            self.updateAsk()   // hides the permission bubble once answered; also a fallback for the watcher
        }
    }

    // a terminal / IDE session is waiting on a permission prompt (sessions the pet runs get a card instead)
    var hookWatch: DispatchSourceFileSystemObject?, askText: String?
    func watchPermissionPrompts() {   // show a prompt the moment the hook writes it, not on the next 2 s poll
        let url = Monitor.hookFile
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)   // start empty: older prompts don't matter
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.extend, .write], queue: pollQueue)
        src.setEventHandler { [weak self] in self?.updateAsk() }
        src.setCancelHandler { close(fd) }
        src.resume(); hookWatch = src
    }
    func updateAsk() {   // on pollQueue
        guard let change = monitor.askChange() else { return }
        DispatchQueue.main.async {
            switch change {
            case .show(let project, let tool):
                guard self.pending.isEmpty else { return }
                self.askText = "\(project) needs your permission: \(tool)"
                self.window.orderFrontRegardless(); self.say(self.askText!, hold: 120)
            case .hide:
                if self.sayText == self.askText { self.hideBubble() }
                self.askText = nil
            }
        }
    }

    func show(_ act: Activity?, _ rows: [(label: String, usage: Usage)]) {
        let fresh = act.map { Date().timeIntervalSince($0.last) < 600 } ?? false
        let working = fresh && (act?.working ?? false)
        otherActivity = working ? "\(act!.project): \(act!.detail)" : ""
        if wasWorking && !working, let a = act, fresh, !a.interrupted, a.last.timeIntervalSince(a.since) > 20, !agent.busy {
            say("Done in \(a.project). Your turn.", then: clip(.yawn))
        }
        if working || agent.busy { poke() }
        wasWorking = working
        refreshPill()
        var lines = rows.map { "\($0.label): \(shortCount($0.usage.output)) out · \(shortCount($0.usage.input)) in · \($0.usage.sessions) sessions" }
        if let a = act, a.context > 0 { lines.append("Context (\(a.project)): \(shortCount(a.context))") }
        let changed = lines != lastUsage
        lastUsage = lines
        if usagePopover.isShown { fetchLimits(); updateUsagePanel() }
        guard changed else { return }
        let total = rows.reduce(0) { $0 + $1.usage.output }
        status.button?.title = total > 0 ? "✦ \(shortCount(total))" : "✦"
        usageItems.forEach { status.menu?.removeItem($0) }
        usageItems = lines.map { NSMenuItem(title: $0, action: nil, keyEquivalent: "") }
        for (i, it) in usageItems.enumerated() { status.menu?.insertItem(it, at: 1 + i) }
    }

    // usage panel (right-click the pet): plan limits, today's tokens per account, context, what's running now
    func toggleUsagePanel() {
        if usagePopover.isShown { usagePopover.close(); return }
        fetchLimits(); updateUsagePanel()
        NSApp.activate(ignoringOtherApps: true)
        usagePopover.show(relativeTo: view.spriteRect, of: view, preferredEdge: .minX)
    }
    func fetchLimits() {   // at most once a minute; accounts in parallel, off pollQueue (keychain prompt, network)
        guard Date().timeIntervalSince(limitsFetched) > 60 else { return }
        limitsFetched = Date()
        for a in accounts {
            let refresh = Date().timeIntervalSince(loginRefreshed[a.label] ?? .distantPast) > 600
            if refresh { loginRefreshed[a.label] = Date() }
            DispatchQueue.global(qos: .utility).async {
                planLimits(a.dir, refresh: refresh) { r in DispatchQueue.main.async { self.limits[a.label] = r; if self.usagePopover.isShown { self.updateUsagePanel() } } }
            }
        }
    }
    func limitLines() -> [String] {
        accounts.flatMap { a -> [String] in
            let head = accounts.count > 1 ? [a.label] : []
            switch limits[a.label] {
            case nil: return head + ["  loading…"]
            case .failure(let e): return head + ["  \(e.text)"]
            case .success(let ls):
                return head + ls.map { l in
                    let n = 18, filled = min(n, Int((l.used / 100 * Double(n)).rounded()))
                    let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: n - filled)
                    let left = l.name.padding(toLength: 7, withPad: " ", startingAt: 0)
                    let pct = String(format: "%3d%%", Int(l.used.rounded()))
                    return "  \(left) \(bar) \(pct)" + (l.resets.map { "  resets \(resetFormat.string(from: $0))" } ?? "")
                }
            }
        }
    }
    func updateUsagePanel() {
        let now = statusPill.stringValue.isEmpty ? "idle" : statusPill.stringValue
        usageLabel.stringValue = (["Plan limits"] + limitLines() + ["", "Today's tokens"]
            + (lastUsage.isEmpty ? ["  no activity yet"] : lastUsage.map { "  " + $0 })
            + ["", "Talking to: \(agent.target.name)", "Now: \(now)"]).joined(separator: "\n")
    }

    // menu
    var usageItems: [NSMenuItem] = []
    var sessionLabel: NSMenuItem!, sessionMenu = NSMenu(), characterMenu = NSMenu()
    var sessions: [Session] = []
    func refreshSessions() {   // off the main thread; the submenus show the last result
        pollQueue.async { let s = recentSessions(); DispatchQueue.main.async { self.sessions = s } }
    }
    func setupMenu() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "✦"
        let m = NSMenu()
        m.addItem(withTitle: "Today's usage (output tokens in the icon)", action: nil, keyEquivalent: "")
        m.addItem(.separator())
        sessionLabel = m.addItem(withTitle: "", action: nil, keyEquivalent: "")
        m.addItem(withTitle: "Session", action: nil, keyEquivalent: "").submenu = sessionMenu
        m.addItem(withTitle: "Stop", action: #selector(stopAgent), keyEquivalent: "")
        [sessionMenu, characterMenu].forEach { $0.delegate = self }
        m.addItem(.separator())
        m.addItem(withTitle: "Character", action: nil, keyEquivalent: "").submenu = characterMenu
        for c in choices {
            let sub = NSMenu(); sub.delegate = self; choiceMenus.append(sub)
            for (i, t) in c.options.enumerated() { let it = sub.addItem(withTitle: t, action: #selector(pickChoice(_:)), keyEquivalent: ""); it.tag = i; it.target = self }
            m.addItem(withTitle: c.title, action: nil, keyEquivalent: "").submenu = sub
        }
        m.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        m.addItem(.separator())
        m.addItem(withTitle: "About", action: #selector(about), keyEquivalent: "")
        m.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        m.items.forEach { if $0.action != nil && $0.action != #selector(NSApplication.terminate(_:)) { $0.target = self } }
        m.delegate = self
        status.menu = m
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if let i = choiceMenus.firstIndex(where: { $0 === menu }) {   // tick the current choice
            let cur = choices[i].current(); menu.items.forEach { $0.state = $0.tag == cur ? .on : .off }; return
        }
        if menu === characterMenu {
            menu.removeAllItems()
            addCharacters(to: menu, action: #selector(pickCharacter(_:)), target: self)
            menu.items.forEach { $0.state = $0.title == currentCharacter ? .on : .off }
            return
        }
        if menu === status.menu {
            sessionLabel.title = "Talking to: \(agent.target.name)\(agent.target.tools ? "" : " (no tools)")"
            refreshSessions(); return
        }
        menu.removeAllItems()
        let pet = menu.addItem(withTitle: "Pet chat (no tools)", action: #selector(switchToPetChat), keyEquivalent: "")
        pet.target = self; pet.state = agent.target.tools ? .off : .on
        menu.addItem(.separator())
        for (i, s) in sessions.enumerated() where s.id != petChatID {
            let it = menu.addItem(withTitle: "\(s.label)  ·  \(relative.localizedString(for: s.modified, relativeTo: Date()))", action: #selector(switchSession(_:)), keyEquivalent: "")
            it.target = self; it.tag = i; it.state = s.id == agent.target.id ? .on : .off
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "New session in folder…", action: #selector(newSessionInFolder), keyEquivalent: "").target = self
        let open = agent.target.tools && agent.target.id != nil   // the pet chat has no tools on purpose: don't hand it a terminal
        menu.addItem(withTitle: "Open in Terminal", action: open ? #selector(openInTerminal) : nil, keyEquivalent: "").target = self
    }
    func switchTo(_ t: Target) {
        agent.attach(t); pending = []; agentStep = ""; waiting = false
        updatePlaceholder(); refreshPill()
        say(t.tools ? "Attached to \(t.name). I can use tools here; I'll ask before anything risky." : "Back to our chat.")
    }
    @objc func switchToPetChat() { switchTo(petChat()) }
    @objc func switchSession(_ item: NSMenuItem) {
        let s = sessions[item.tag]
        switchTo(Target(id: s.id, cwd: s.cwd, dir: s.dir, tools: true, name: s.label))
    }
    func pickFolder() -> URL? {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }
    @objc func newSessionInFolder() {
        guard let url = pickFolder() else { return }
        switchTo(Target(id: nil, cwd: url.path, dir: accounts.first?.dir, tools: true, name: url.lastPathComponent))
    }
    @objc func openInTerminal() { resumeInTerminal(agent.target) }
    @objc func stopAgent() { agent.interrupt() }
    func setTop(_ on: Bool) { window.level = on ? .floating : .normal; UserDefaults.standard.set(on, forKey: "onTop") }
    func setFade(_ on: Bool) { fadeOnHover = on; UserDefaults.standard.set(on, forKey: "fadeOnHover") }
    func setOpacity(_ a: CGFloat) { opacity = a; UserDefaults.standard.set(Double(a), forKey: "opacity") }
    func setSize(_ i: Int) { resize(sizes[i].1); settings?.reload() }
    /// Builds a sprite, then hands it back on the main thread once its resting frames are decoded,
    /// unless a newer build was asked for meanwhile.
    func loadSprite(_ dir: URL, then: @escaping (Sprite?) -> Void) {
        spriteGen += 1; let gen = spriteGen
        DispatchQueue.global(qos: .userInitiated).async {
            let s = Sprite(dir)
            DispatchQueue.main.async {   // handed over once settled, so the old character stays up meanwhile
                guard let s else { return then(nil) }
                let done = { if gen == self.spriteGen { then(s) } }
                if s.settled { done() } else { s.onSettled = done }
            }
        }
    }
    func setVoice(_ v: Voice) {
        voice = v; UserDefaults.standard.set(v.rawValue, forKey: "voice"); settings?.reload()
        say(v == .off ? "Quiet now." : "Like this?")
    }
    func setCharacter(_ name: String, _ dir: URL) {
        loadSprite(dir) { [weak self] s in
            guard let s else { self?.say("I can't open that one."); return }
            self?.switchCharacter(name, s)
        }
    }
    @objc func pickChoice(_ item: NSMenuItem) { if let i = choiceMenus.firstIndex(where: { $0 === item.menu }) { choices[i].set(item.tag) } }
    @objc func pickCharacter(_ item: NSMenuItem) { if let dir = item.representedObject as? URL { setCharacter(item.title, dir) } }
    func switchCharacter(_ name: String, _ s: Sprite) {
        UserDefaults.standard.set(name, forKey: "character")
        view.sprite = s; resize(height); settings?.reload(characters: true)
    }
    @objc func openSettings() { settings = settings ?? SettingsPanel(self); settings!.show() }
    @objc func about() {
        let a = NSAlert()
        a.messageText = "Claude desktop pet"
        a.informativeText = "Character: ZipZipPipe original design; 3-heads-tall chibi version is a derivative work. CC BY-NC-SA 4.0. Non-commercial. Not affiliated with Anthropic."
        NSApp.activate(ignoringOtherApps: true); a.runModal()
    }
    func applicationWillTerminate(_ n: Notification) { agent.stop() }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
