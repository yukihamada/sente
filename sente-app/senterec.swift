// senterec — AEC(エコーキャンセル)付き録音ヘルパー(sox recの置き換え・2026-08-06本人指示
// 「パソコンの音は拾わないでほしい」)。
//
// macOSのVoice Processing I/O(FaceTimeと同じOS機能)を使い、このMac自身が鳴らしている音
// (SenteのTTS読み上げ・YouTube・通知音など、既定出力デバイスに流れる全て)をマイク入力から
// 差し引いて録音する。別デバイス(ラジオ等)の物理的な音は参照が無いので消せない=そちらは
// te側のこだま判定・幻聴フィルタが引き続き受け持つ。
//
// 使い方: senterec out.wav [--silence 1.5] [--max 90] [--meter] [--start-thresh 0.02]
//   - 音が来るまで書き込まない(soxのsilence先頭トリム相当)・無音がsilence秒続いたら終了
//   - --meter: soxの -S 互換のVU行([ ===|=== ])をstderrへ(teのメーター描画をそのまま使える)
//   - 常にexit 0(声ゼロでも)。呼び出し側はファイルサイズで判定する(teの既存ロジックと同じ)
// ビルド: swiftc -O -o senterec senterec.swift (te-install.shがswiftc存在時に自動ビルド)
import AVFoundation
import Foundation

var out = ""
var silence = 1.5
var maxSec = 90.0
var meter = false
var startTh: Float = 0.02
var stopTh: Float = 0.02
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--silence": silence = Double(args.isEmpty ? "" : args.removeFirst()) ?? 1.5
    case "--max": maxSec = Double(args.isEmpty ? "" : args.removeFirst()) ?? 90
    case "--meter": meter = true
    case "--start-thresh": startTh = Float(args.isEmpty ? "" : args.removeFirst()) ?? 0.02
    case "--stop-thresh": stopTh = Float(args.isEmpty ? "" : args.removeFirst()) ?? 0.02
    default: out = a
    }
}
if out.isEmpty {
    FileHandle.standardError.write("usage: senterec out.wav [--silence s] [--max s] [--meter]\n".data(using: .utf8)!)
    exit(2)
}

let engine = AVAudioEngine()
let input = engine.inputNode
// ここが本体: OSのエコーキャンセル(+ノイズ抑制/AGC)を入力に有効化。
// 失敗してもAECなしのプレーン録音として続行(録れないよりまし・te側フィルタが受け持つ)
do { try input.setVoiceProcessingEnabled(true) } catch {
    FileHandle.standardError.write("senterec: voice processing unavailable (plain capture)\n".data(using: .utf8)!)
}
let fmt = input.outputFormat(forBus: 0)
let fileSettings: [String: Any] = [
    AVFormatIDKey: kAudioFormatLinearPCM,
    AVSampleRateKey: fmt.sampleRate,
    AVNumberOfChannelsKey: 1,
    AVLinearPCMBitDepthKey: 16,
    AVLinearPCMIsFloatKey: false,
    AVLinearPCMIsBigEndianKey: false,
]
guard let file = try? AVAudioFile(forWriting: URL(fileURLWithPath: out), settings: fileSettings) else {
    FileHandle.standardError.write("senterec: cannot open output\n".data(using: .utf8)!)
    exit(2)
}
guard let monoFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fmt.sampleRate, channels: 1, interleaved: false) else { exit(2) }

let lock = NSLock()
var started = false
var lastVoice = Date()
var recStart = Date()
var lastRMS: Float = 0
var finished = false

input.installTap(onBus: 0, bufferSize: 2048, format: fmt) { buf, _ in
    guard let ch = buf.floatChannelData else { return }
    let n = Int(buf.frameLength)
    if n == 0 { return }
    var sum: Float = 0
    let p = ch[0]
    for i in 0..<n { sum += p[i] * p[i] }
    let rms = (sum / Float(n)).squareRoot()
    lock.lock()
    lastRMS = rms
    if !started {
        if rms >= startTh {
            started = true
            recStart = Date()
            lastVoice = Date()
        }
    } else if rms >= stopTh {
        lastVoice = Date()
    }
    let writing = started && !finished
    lock.unlock()
    if writing {
        // モノラルへ落として書く(voice processingは通常1chだが、多chデバイスでも落ちないように)
        if let mono = AVAudioPCMBuffer(pcmFormat: monoFmt, frameCapacity: buf.frameLength) {
            mono.frameLength = buf.frameLength
            if let dst = mono.floatChannelData { dst[0].update(from: p, count: n) }
            try? file.write(from: mono)
        }
    }
}

do { try engine.start() } catch {
    FileHandle.standardError.write("senterec: engine start failed\n".data(using: .utf8)!)
    exit(2)
}

let t0 = Date()
let timer = Timer(timeInterval: 0.2, repeats: true) { _ in
    lock.lock()
    let rms = lastRMS
    let st = started
    let idle = Date().timeIntervalSince(lastVoice)
    let recElapsed = Date().timeIntervalSince(recStart)
    lock.unlock()
    if meter {
        // パディングは空白にする: teのsente_meter_drawは '=' '-' '!' をレベル文字として数えるため
        let bars = min(8, Int(rms * 120))
        let vu = String(repeating: "=", count: bars) + String(repeating: " ", count: 8 - bars)
        FileHandle.standardError.write(("\r[ " + vu + "|" + vu + " ]").data(using: .utf8)!)
    }
    // 終了条件: 録音開始後にsilence秒の無音 / 録音がmax秒に達した / 声が来ないまま(max+10)秒
    if (st && (idle >= silence || recElapsed >= maxSec)) || (!st && Date().timeIntervalSince(t0) >= maxSec + 10) {
        lock.lock(); finished = true; lock.unlock()
        engine.stop()
        exit(0)
    }
}
RunLoop.main.add(timer, forMode: .common)
RunLoop.main.run()
