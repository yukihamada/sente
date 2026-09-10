// Sente.app — 声で使う teai.io コーディングエージェント(メニューバー常駐)
//
// 中身は CLI の `sente`(= te talk)をそのまま子プロセスで走らせ、その出力行から
// 状態(待機/聞き取り/考え中/読み上げ)を読み取ってメニューバーに映すだけの薄い殻。
// ロジックを二重に持たないので、CLI を直せばアプリも直る。
//
// ビルド: ./build.sh → Sente.app
import AppKit
import AVFoundation
import Carbon.HIToolbox   // グローバルホットキー(⌃⌥スペース=押して話す)。Accessibility権限不要
import ServiceManagement
import UserNotifications

enum State {
    case stopped, idle, listening, thinking, speaking, error

    var icon: String {
        switch self {
        case .stopped:   return "⏸"
        case .idle:      return "🎙"
        case .listening: return "👂"
        case .thinking:  return "💭"
        case .speaking:  return "🔊"
        case .error:     return "⚠️"
        }
    }

    // メニューバーはモノクロのSF Symbol(テンプレート画像)で表示する。絵文字より
    // ネイティブで、ライト/ダークメニューバーに自動で馴染む(本人指示「シンプルでモダン」)。
    var symbol: String {
        switch self {
        case .stopped:   return "mic.slash"
        case .idle:      return "mic"
        case .listening: return "waveform"
        case .thinking:  return "ellipsis"
        case .speaking:  return "speaker.wave.2"
        case .error:     return "exclamationmark.triangle"
        }
    }

    var label: String {
        switch self {
        case .stopped:   return "停止中"
        case .idle:      return "待機中(話しかけてください)"
        case .listening: return "聞き取り中…"
        case .thinking:  return "考え中…"
        case .speaking:  return "話しています"
        case .error:     return "エラー"
        }
    }
}

// MARK: - セッションストア
//
// エンジン(opencode.db)のセッションをメニューとログビューアの両方から扱うため1箇所に集める。
// 読むだけでなく「再開」もここ: TUIが `-s <id>` でセッション再開に対応しているので、
// Terminal.appでそのセッションの作業ディレクトリに移って `te -s <id>` を開けば、
// アプリだけで(再起動後でも)過去のセッションにすぐ戻れる。
enum SessionStore {
    // セッションDBは歴史的経緯で複数ある:
    //  - native: ~/.local/share/sente/sente-<channel>.db — 現行エンジンの正本(チャンネル名でファイルが分かれる)
    //  - 旧チャンネルのsente*.db(例: sente-dev.db) — 過去ビルドのセッションが残っている
    //  - legacy: ~/.local/share/opencode/opencode.db — 素のopencode時代(+上書き事故期間)のもの
    // 一覧は全部を混ぜて見せ、再開はnativeに無いものだけexport/importで橋渡しする。
    static let legacyDBPath = NSHomeDirectory() + "/.local/share/opencode/opencode.db"

    /// 現行エンジンのDB。チャンネルによりファイル名が変わる(sente.db / sente-dev.db 等)ので、
    /// 一番新しく更新されているものを正とする。
    static func nativeDBPath() -> String? {
        let dir = NSHomeDirectory() + "/.local/share/sente"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        func mtime(_ p: String) -> Date {
            (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date ?? .distantPast
        }
        return names.filter { $0.hasPrefix("sente") && $0.hasSuffix(".db") }
            .map { dir + "/" + $0 }
            .max { mtime($0) < mtime($1) }
    }

    /// nativeも含む、セッションが入っている可能性のある全DB(native優先の順)。
    static func allDBPaths() -> [String] {
        var out: [String] = []
        if let native = nativeDBPath() { out.append(native) }
        let dir = NSHomeDirectory() + "/.local/share/sente"
        if let names = try? FileManager.default.contentsOfDirectory(atPath: dir) {
            for n in names.sorted() where n.hasPrefix("sente") && n.hasSuffix(".db") {
                let p = dir + "/" + n
                if !out.contains(p) { out.append(p) }
            }
        }
        if FileManager.default.fileExists(atPath: legacyDBPath) { out.append(legacyDBPath) }
        return out
    }

    struct Row {
        let id: String
        let title: String       // DB上の生タイトル("New session ..."含む)
        let directory: String
        let updated: Date
        let cost: Double
        let sourceDB: String    // このセッションが入っているDB
        let native: Bool        // 現行エンジンのDBに居る(=そのまま再開できる)
    }

    private static func runCapture(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        // 🪤 waitUntilExit()を先に呼ぶとパイプバッファ超過(~64KB)でデッドロックする
        // (長い会話のセッションのJSON出力は普通に超える)。読み取りを先に始める。
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func sqlEscape(_ s: String) -> String { s.replacingOccurrences(of: "'", with: "''") }

    /// sqlite3 CLIを読み取り専用で呼び、結果をJSON配列としてパースする。DBは
    /// 実行中のエンジンが書き込み続けているが、-readonly + WALなので読み取りは競合しない。
    static func query(_ sql: String, db: String?) -> [[String: Any]] {
        guard let db, FileManager.default.fileExists(atPath: db) else { return [] }
        let out = runCapture("/usr/bin/sqlite3", ["-readonly", "-json", db, sql])
        guard let data = out.data(using: .utf8), !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return json
    }

    /// 直近のセッション(全ディレクトリ・両DB混合)。会話が実質無いもの(起動しただけ・
    /// 環境音の誤認識のみ)は除外するが、応答がツール実行だけのものは再開する価値があるので残す。
    static func recentSessions(limit: Int) -> [Row] {
        let sql = """
            SELECT id, title, directory, time_updated, cost FROM session s
            WHERE EXISTS (
              SELECT 1 FROM message m JOIN part p ON p.message_id = m.id
              WHERE m.session_id = s.id AND json_extract(m.data,'$.role') = 'assistant'
                AND json_extract(p.data,'$.type') IN ('text','tool')
            )
            ORDER BY time_updated DESC LIMIT \(limit)
        """
        let native = nativeDBPath()
        var seen = Set<String>()
        var all: [Row] = []
        // allDBPathsはnative先頭なので、同じidが複数DBに居る場合(橋渡しimport済み)はnativeが勝つ
        for db in allDBPaths() {
            for r in cachedList(sql: sql, db: db, limit: limit) {
                guard !seen.contains(r.id) else { continue }
                seen.insert(r.id)
                all.append(Row(id: r.id, title: r.title, directory: r.directory,
                               updated: r.updated, cost: r.cost, sourceDB: db, native: db == native))
            }
        }
        return Array(all.sorted { $0.updated > $1.updated }.prefix(limit))
    }

    private struct RawRow { let id, title, directory: String; let updated: Date; let cost: Double }
    private static let cacheLock = NSLock()
    private static var listCache: [String: (mtime: Date, rows: [RawRow])] = [:]

    /// DBが更新されていない限り一覧クエリを再実行しない(20秒毎のメニュー更新で
    /// 1.5GB級の旧DBに毎回0.7秒のクエリを打たないため)。キー=DBパス+limit。
    private static func cachedList(sql: String, db: String, limit: Int) -> [RawRow] {
        func mtime(_ p: String) -> Date {
            (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date ?? .distantPast
        }
        let key = "\(db)|\(limit)"
        let m = mtime(db)
        cacheLock.lock()
        if let hit = listCache[key], hit.mtime == m { cacheLock.unlock(); return hit.rows }
        cacheLock.unlock()
        let rows: [RawRow] = query(sql, db: db).compactMap { row in
            guard let id = row["id"] as? String, let title = row["title"] as? String,
                  let directory = row["directory"] as? String,
                  let updatedMs = (row["time_updated"] as? NSNumber)?.doubleValue else { return nil }
            return RawRow(id: id, title: title, directory: directory,
                          updated: Date(timeIntervalSince1970: updatedMs / 1000),
                          cost: (row["cost"] as? NSNumber)?.doubleValue ?? 0)
        }
        cacheLock.lock()
        listCache[key] = (m, rows)
        cacheLock.unlock()
        return rows
    }

    /// 作業ディレクトリの表示用短縮名。ホーム=声(talk)のセッションなのでそれとわかる名前に。
    static func dirLabel(_ directory: String) -> String {
        if directory == NSHomeDirectory() { return "ホーム(声)" }
        return (directory as NSString).lastPathComponent
    }

    static let dateDisplay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d HH:mm"
        f.locale = Locale(identifier: "ja_JP")
        return f
    }()

    /// メニュー・一覧共通の1行ラベル。"New session ..." はタイトルとして無意味なので出さない。
    static func displayTitle(_ row: Row, withDir: Bool) -> String {
        let dateStr = dateDisplay.string(from: row.updated)
        let name = row.title.hasPrefix("New session") ? "" : " \(row.title)"
        let dir = withDir ? " — \(dirLabel(row.directory))" : ""
        let costStr = row.cost > 0 ? String(format: " ($%.3f)", row.cost) : ""
        return "\(dateStr)\(name)\(dir)\(costStr)"
    }

    /// te 本体のパス。⚠ `sente`(basename)で起動するとガードレールなしモードになるため、
    /// 再開は必ず te 名で起動する。
    static func tePath() -> String? {
        for p in ["\(NSHomeDirectory())/.local/bin/te", "/usr/local/bin/te", "/opt/homebrew/bin/te"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// エンジン本体(Sente改名OpenCode)のパス。橋渡しexport/importに使う。
    static func enginePath() -> String? {
        for p in ["\(NSHomeDirectory())/.opencode/bin/opencode", "\(NSHomeDirectory())/.local/bin/opencode",
                  "/opt/homebrew/bin/opencode", "/usr/local/bin/opencode"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// 他DB(opencode.db・旧チャンネルのsente-*.db)のセッションを現行エンジンのDBへ持ってくる。
    /// エンジンの `export`/`import` を使う(importはセッションIDを保つと実測確認済み)。
    /// ⚠ opencode.db は稼働中の旧プロセスが書いていることがあり、直接エンジンで開くと
    /// マイグレーションが走って壊しかねないため、そこだけバックアップコピーに対して開く。
    /// 旧チャンネルのsente-*.dbは誰も書いていない(同系エンジンの遺物)ので直接開いてよい。
    private static func bridgeSession(_ id: String, from sourceDB: String) -> Bool {
        guard let engine = enginePath() else { return false }
        let cacheDir = NSHomeDirectory() + "/.cache/sente"
        try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        var exportDB = sourceDB
        if sourceDB == legacyDBPath {
            let copy = cacheDir + "/legacy-opencode-bridge.db"
            func mtime(_ p: String) -> Date {
                (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date ?? .distantPast
            }
            if !FileManager.default.fileExists(atPath: copy) || mtime(copy) < mtime(sourceDB) {
                // .backup はWAL込みの整合スナップショットを取る
                _ = runCapture("/usr/bin/sqlite3", ["-readonly", sourceDB, ".backup '\(sqlEscape(copy))'"])
            }
            exportDB = copy
        }
        let json = cacheDir + "/legacy-session-\(id).json"
        let shq = { (s: String) in s.replacingOccurrences(of: "'", with: "'\\''") }
        let sh = "SENTE_DB='\(shq(exportDB))' '\(shq(engine))' export \(id) > '\(json)' && '\(shq(engine))' import '\(json)'"
        let out = runCapture("/bin/sh", ["-c", sh])
        defer { try? FileManager.default.removeItem(atPath: json) }
        return out.contains("Imported session")
    }

    /// nativeのDBにそのセッションが居るか(橋渡し済み判定)
    private static func existsInNative(_ id: String) -> Bool {
        !query("SELECT 1 FROM session WHERE id = '\(sqlEscape(id))' LIMIT 1", db: nativeDBPath()).isEmpty
    }

    /// Terminal.appの新しいタブでそのセッションを再開する。ディレクトリが消えていたら
    /// (scratchpad等の一時作業)ホームで開く — TUI側はセッションIDだけで履歴を復元できる。
    /// 現行エンジンのDBに無いセッションは先にexport/importで橋渡しする(数秒かかる
    /// ことがあるので呼び出し側はバックグラウンドで呼ぶこと)。
    static func resume(id: String, directory: String, sourceDB: String) {
        // idはコマンド文字列に埋め込むので、DB由来とはいえ形を検証してから使う
        guard id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
              let te = tePath() else { return }
        if !existsInNative(id), !bridgeSession(id, from: sourceDB) { return }
        let dir = FileManager.default.fileExists(atPath: directory) ? directory : NSHomeDirectory()
        let shq = { (s: String) in s.replacingOccurrences(of: "'", with: "'\\''") }
        let cmd = "cd '\(shq(dir))' && exec '\(shq(te))' -s \(id)"
        let esc = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(esc)\"\nend tell"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }
}

// MARK: - ✅ やること(~/.config/teai/todo.md)
/// Markdown のチェックリスト1行=1件。人間もCLIもClaudeも同じファイルを編集する(アプリは読む+印を付けるだけ)。
///   ## 見出し                          → サブメニューの区切り(開いている件がある時だけ出る)
///   - [ ] タイトル || 指示 ⏳15分       → ⏳N分 = 見込み(書いた人の目安・任意)
///   - [ ] !タイトル || 指示             → 先頭 ! = お金/対外送信/削除を含む「要確認」(開始前に一度確認)
///   - [ ] … ▶2026-09-03 00:58           → ▶ = 開始時刻(アプリが「開始」で書く)。メニューに ⏱経過 が出る
///   - [x] … ✅2026-09-03 (23分)         → 済み(アプリが「済みにする」で書く。▶があれば実所要も)
struct TodoItem {
    let line: Int          // 1始まりの行番号(印を付ける書き換え先)
    let section: String?   // 直前の ## 見出し
    let title: String
    let prompt: String
    let done: Bool
    let confirm: Bool
    let estimateMin: Int?  // ⏳見込み(分)
    let startedAt: Date?   // ▶開始
    let doneAt: String?    // ✅済み(日付文字列)
    let actualMin: Int?    // ✅の (N分)

    var elapsedMin: Int? { startedAt.map { max(0, Int(Date().timeIntervalSince($0) / 60)) } }
    /// 見込みと経過から「あと約N分」。見込みが無ければ nil(数字を作らない)。
    var remainingMin: Int? {
        guard let e = estimateMin else { return nil }
        return max(0, e - (elapsedMin ?? 0))
    }
}

enum TodoStore {
    static let template = """
    # やること(Sente.app メニュー「やること」に出ます)
    # 書式: - [ ] タイトル || 指示 ⏳見込み分   先頭 ! = 要確認(お金/対外送信/削除)。## 見出し で区切り
    ## 今日
    - [ ] 例: READMEのTODOを整理して ⏳10分
    """
    /// 司令塔の指示書の初期版(~/.config/teai/todo-orchestrator.md が無い時だけ書く。以後はユーザーが育てる)
    static let orchestratorTemplate = """
    # 司令塔 — todo.md をまとめて進める指示書

    あなたは ~/.config/teai/todo.md の未完了タスク全件を進める司令塔です。30本のセッションを立てるのではなく、あなた1本が段取りします。

    ## 手順
    1. todo.md を読む。`- [ ]` が未完了。`!` 付き=要確認(お金・対外送信・削除・GUI・電話など人間の手が要る)。`⏳N分`=見込み。
    2. **先に承認シート**を作る: 要確認(!)の全件について「番号・タイトル・私が何をするか(電話で聞くこと/貼る文面/開くURL/押すボタン)・所要分・AIが先にやっておけること」を1件1ブロックで ~/.config/teai/todo-approval.md に書き、`open` で開く。文面が必要なものは human-gates(tasks/human-gates.md の 00xx)を読んで完成品を載せる。そして私に「番号ごとに GO / 直す:内容 / やらない で返してください」と1回だけ聞く。
    3. 返事を待つ間に、`!` の無いタスクを **同時最大3件** で進める(Agent ツール・原則 sonnet)。同じリポジトリを触るものは同時に走らせない(worktree で分離)。順序依存: 24hルール台帳(tasks/24h-rule-20260902.md)の回答が要るものは回答後。m5 復旧が前提のものは m5 疎通後。
    4. 1件終わるごとに todo.md の該当行を `- [x]` にし、末尾に `✅YYYY-MM-DD (実所要N分)` を添える。失敗・保留は `- [ ]` のまま末尾に `⚠理由` を1行で追記して止まる(黙って進まない・例外を握り潰さない)。
    5. GO が返った要確認タスクから実行。「直す」は直して再提示。「やらない」は行末に `⏸やらない(日付)` を付けて残す(消さない)。
    6. 全部終わったら、実所要と見込みの差・詰まり・次に決めることを 10 行以内で報告する。

    ## ルール
    - done は証拠(diff/URL/実測)とセット。推測で直さない。本番データ変更は CHANGELOG。
    - 対外文案は `python3 ~/.claude/tools/yuki-reviewer/check.py "<文案>"` で過去の指摘と照合してから承認シートに載せる。
    - デプロイは git push → GitHub Actions(fly deploy 直叩き禁止)。PR は stacked を避け `gh pr merge --auto`。
    - 費用: サブエージェントは sonnet 既定。1タスクが見込みの3倍を超えたら止めて報告。
    - 秘密はコミットしない。数字は盛らない(未確認は「未確認」)。
    """

    static let stamp: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm"; return f }()

    /// NSRegularExpression の薄い皮(bare-slash regex はコンパイルフラグが要るので使わない)。
    static func match(_ pattern: String, in text: String) -> (range: Range<String.Index>, groups: [String?])? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range, in: text) else { return nil }
        let groups = (1..<m.numberOfRanges).map { i -> String? in
            Range(m.range(at: i), in: text).map { String(text[$0]) }
        }
        return (r, groups)
    }

    static func load(_ url: URL) -> [TodoItem] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [TodoItem] = []
        var section: String? = nil
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") { section = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces); continue }
            let done: Bool
            if line.hasPrefix("- [ ] ") { done = false }
            else if line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") { done = true }
            else { continue }
            var body = String(line.dropFirst(6))
            // 末尾の印(⏳/▶/✅)は本文から剥がして構造化する
            var estimate: Int? = nil, started: Date? = nil, doneAt: String? = nil, actual: Int? = nil
            if let m = match(#"\s*⏳(\d+)分"#, in: body) { estimate = m.groups[0].flatMap { Int($0) }; body.removeSubrange(m.range) }
            if let m = match(#"\s*▶(\d{4}-\d{2}-\d{2} \d{2}:\d{2})"#, in: body) { started = m.groups[0].flatMap { stamp.date(from: $0) }; body.removeSubrange(m.range) }
            if let m = match(#"\s*✅(\S+)(?: \((\d+)分\))?"#, in: body) { doneAt = m.groups[0]; actual = m.groups.count > 1 ? m.groups[1].flatMap { Int($0) } : nil; body.removeSubrange(m.range) }
            var title = body, prompt = body
            if let r = body.range(of: " || ") {
                title = String(body[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                prompt = String(body[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            title = title.trimmingCharacters(in: .whitespaces)
            var confirm = false
            if title.hasPrefix("!") { confirm = true; title = String(title.dropFirst()).trimmingCharacters(in: .whitespaces) }
            if prompt.hasPrefix("!") { prompt = String(prompt.dropFirst()).trimmingCharacters(in: .whitespaces) }
            if prompt.isEmpty { prompt = title }
            guard !title.isEmpty else { continue }
            out.append(TodoItem(line: i + 1, section: section, title: title, prompt: prompt, done: done, confirm: confirm,
                                estimateMin: estimate, startedAt: started, doneAt: doneAt, actualMin: actual))
        }
        return out
    }

    /// 指定行だけ書き換える(他の行=人間の並べ替え/メモには一切触らない)。
    private static func rewrite(_ url: URL, line: Int, _ f: (String) -> String?) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var lines = text.components(separatedBy: "\n")
        let idx = line - 1
        guard lines.indices.contains(idx), let new = f(lines[idx]) else { return }
        lines[idx] = new
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// 「開始」= ▶時刻 を添える(既に▶があれば触らない=最初の着手時刻を残す)。
    static func markStarted(_ url: URL, line: Int) {
        rewrite(url, line: line) { raw in
            guard raw.contains("- [ ] "), !raw.contains("▶") else { return nil }
            return raw + " ▶\(stamp.string(from: Date()))"
        }
    }

    /// 「済み」= `- [ ]`→`- [x]` + ✅日付(▶があれば実所要 (N分) も)。
    static func markDone(_ url: URL, line: Int) {
        rewrite(url, line: line) { raw in
            guard let r = raw.range(of: "- [ ] ") else { return nil }
            var actual = ""
            if let m = match(#"▶(\d{4}-\d{2}-\d{2} \d{2}:\d{2})"#, in: raw), let g = m.groups[0], let s = stamp.date(from: g) {
                actual = " (\(max(1, Int(Date().timeIntervalSince(s) / 60)))分)"
            }
            return raw.replacingCharacters(in: r, with: "- [x] ") + " ✅\(String(stamp.string(from: Date()).prefix(10)))\(actual)"
        }
    }
}

// MARK: - 🤖 自動エージェント(te agent)。正本= ~/Library/LaunchAgents/tokyo.hamada.sente-agent-*.plist(配備) + ~/Library/Logs/Sente/agents.jsonl(実行記録)
// アプリは読むだけ。実行は te agent run(=普通の te と同じ経路)、配備/解除は te agent deploy/undeploy。
struct AgentRun { let ts: String; let event: String; let exit: Int?; let tries: Int? }
struct AgentInfo {
    let name: String
    let schedule: String
    let description: String
    var lastStart: String?
    var lastEnd: AgentRun?
    /// start の後に end がまだ無い=実行中(ts は同一書式なので文字列比較でよい)。
    /// ただし start から6時間以上 end が無いものは「記録なし」扱い(exec で終了記録が残らなかった旧版の残骸・強制終了)
    var startedWithoutEnd: Bool { guard let st = lastStart else { return false }; guard let e = lastEnd else { return true }; return st > e.ts }
    var running: Bool { startedWithoutEnd && AgentStore.isRecent(lastStart ?? "", withinHours: 6) }
    var stale: Bool { startedWithoutEnd && !running }
    var failed: Bool { !startedWithoutEnd && (lastEnd?.exit ?? 0) != 0 }
}
enum AgentStore {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let plistDir = home.appendingPathComponent("Library/LaunchAgents")
    static let logDir = home.appendingPathComponent("Library/Logs/Sente")
    static let prefix = "tokyo.hamada.sente-agent-"
    static func logFile(_ name: String) -> URL { logDir.appendingPathComponent("agent-\(name).log") }
    static func defFile(_ name: String) -> URL { home.appendingPathComponent(".config/sente/agent/\(name).md") }
    /// agents.jsonl(1行=1イベント・数KB)を全部読む
    static func events() -> [(name: String, run: AgentRun)] {
        guard let text = try? String(contentsOf: logDir.appendingPathComponent("agents.jsonl"), encoding: .utf8) else { return [] }
        var out: [(String, AgentRun)] = []
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let name = o["agent"] as? String, let ts = o["ts"] as? String, let ev = o["event"] as? String else { continue }
            out.append((name, AgentRun(ts: ts, event: ev, exit: o["exit"] as? Int, tries: o["tries"] as? Int)))
        }
        return out
    }
    static func load() -> [AgentInfo] {
        var byName: [String: AgentInfo] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(atPath: plistDir.path))?.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".plist") } ?? []
        for f in files {
            let name = String(f.dropFirst(prefix.count).dropLast(6))
            var sched = "(時刻不明)"
            if let d = try? Data(contentsOf: plistDir.appendingPathComponent(f)),
               let pl = (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String: Any] {
                sched = scheduleText(pl["StartCalendarInterval"])
            }
            byName[name] = AgentInfo(name: name, schedule: sched, description: description(name), lastStart: nil, lastEnd: nil)
        }
        for (name, run) in events() {
            if byName[name] == nil {
                byName[name] = AgentInfo(name: name, schedule: "(手動)", description: description(name), lastStart: nil, lastEnd: nil)
            }
            if run.event == "start" { byName[name]?.lastStart = run.ts }
            if run.event == "end" { byName[name]?.lastEnd = run }
        }
        return byName.values.sorted { $0.name < $1.name }
    }
    static func scheduleText(_ v: Any?) -> String {
        func one(_ d: [String: Any]) -> String {
            let h = d["Hour"] as? Int ?? 0, m = d["Minute"] as? Int ?? 0
            let wd = (d["Weekday"] as? Int).map { ["日", "月", "火", "水", "木", "金", "土"][$0 % 7] + " " } ?? ""
            return wd + String(format: "%02d:%02d", h, m)
        }
        if let d = v as? [String: Any] { return "毎日 " + one(d) }
        if let a = v as? [[String: Any]], !a.isEmpty { return a.map(one).joined(separator: "・") }
        return "(手動)"
    }
    static func description(_ name: String) -> String {
        guard let t = try? String(contentsOf: defFile(name), encoding: .utf8) else { return "" }
        for line in t.split(separator: "\n").prefix(12) where line.hasPrefix("description:") {
            return String(line.dropFirst("description:".count)).trimmingCharacters(in: .whitespaces)
        }
        return ""
    }
    /// "2026-09-05T22:59:05" → 今日なら "22:59"、他日なら "9/4 22:59"
    static func shortTime(_ ts: String) -> String {
        guard ts.count >= 16 else { return ts }
        let day = String(ts.prefix(10)), hm = String(ts.dropFirst(11).prefix(5))
        if day == todayString() { return hm }
        let parts = day.split(separator: "-")
        return parts.count == 3 ? "\(Int(parts[1]) ?? 0)/\(Int(parts[2]) ?? 0) \(hm)" : ts
    }
    static func todayString() -> String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date()) }
    static func nowString() -> String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; return f.string(from: Date()) }
    static func isRecent(_ ts: String, withinHours h: Double) -> Bool {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX")
        guard let d = f.date(from: ts) else { return false }
        return Date().timeIntervalSince(d) < h * 3600
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static let openingTaskCategoryID = "OPENING_TASK"
    static let musicCategoryID = "MUSIC_PAUSE"
    // 🎵 音楽再生中の常時聞き取りは誤認識・自問自答のもとなので、検知したら「オフにするか」を
    // 通知で確認する(本人要望)。オフ中も ⌃⌥スペース(押して話す)で一言だけ使える。
    private var musicPlaying = false
    private var musicPromptShown = false   // 同じ再生エピソードで何度も聞かない
    private var pausedForMusic = false     // 音楽理由の一時停止(音楽が止まったら自動再開)
    // 設定(UserDefaults永続): 自動オフ=確認せず即オフ / ブラウザ検知=YouTube等の音も対象(既定on)
    private var musicAutoPause = UserDefaults.standard.bool(forKey: "musicAutoPause")
    private var musicDetectBrowser = UserDefaults.standard.object(forKey: "musicDetectBrowser") as? Bool ?? true
    // ブラウザ音声は通知音などの短い音でも一瞬立つので、2回連続(約10秒)で初めて「再生中」とみなす
    private var browserAudioStreak = 0
    private var pttProcess: Process?       // 押して話す(te v)のワンショットプロセス
    private var hotKeyRef: EventHotKeyRef?
    // 👂 耳のモード(2026-08-29本人指示「会議中は議事録・それ以外は独り言」):
    //  - hitorigoto(既定): boyaki --journal で独り言を貯め、静かになったらまとめて解析→
    //    必要なものだけ te run で実行(危険語は通知のみ)。すぐの返事はしない。
    //  - kaiwa: 従来の sente talk(話しかけるとすぐ声で返事)
    // どちらのモードでも、会議(Zoom検知 or 手動)中は議事録録音に切り替わる。
    private var earMode = UserDefaults.standard.string(forKey: "earMode") ?? "hitorigoto"
    private var boyakiProcess: Process?
    private var boyakiLastStart = Date.distantPast
    private var boyakiQuickDeaths = 0      // 起動直後死(ロック衝突等)の連続回数。少数回はリトライする
    private var userStoppedEar = false     // メニューから明示停止した(自動再開しない)
    private var earPausedForPTT = false    // 一言きく(te v)のためにマイクを一時的に譲った
    // 📝 議事録
    private var meetingRecording = false
    private var meetingAuto = false        // Zoom検知で自動開始した(=Zoom終了で自動停止する)
    private var recProcess: Process?
    private var recStartedAt: Date?
    private var recWavPath: String?
    private var zoomStreak = 0             // 2回連続(約10秒)検知で開始
    private var zoomGoneStreak = 0         // 3回連続(約15秒)不在で終了
    private var minutesGenerating = false
    private var lastMinutesPath: String? = UserDefaults.standard.string(forKey: "lastMinutesPath")
    // 🪨 布石(fuseki watch, Alpha): 呼ばれなくても盤面(human-gates・最近のリポジトリ)を見続け、
    // 変化があった時だけ ♟ 先手の一手(opening-task/opening-last)を更新する裏プロセス。
    // 何も実行しない・提案のみ。読み取り側(checkOpeningTask)は元々あったので、ここでは
    // 「te watch」の起動/停止/永続化だけを足す(2026-08-31本人指示)。既定はOFF(Alphaゆえ)。
    private var fusekiProcess: Process?
    private var fusekiEnabled: Bool = UserDefaults.standard.bool(forKey: "fusekiEnabled")
    private var statusItem: NSStatusItem!
    private var process: Process?
    private var state: State = .stopped { didSet { DispatchQueue.main.async { self.render() } } }
    private var lastHeard = ""
    private var lastReply = ""
    private let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Sente", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sente.log")
    }()
    private var speakTimer: Timer?
    private lazy var logViewer = LogViewerController(logURL: logURL)
    // 📱 iPhone の Sente がミラーした会話(sente.teai.io /conversations)。メニューから読める・開ける(2026-09-02 本人指示)。
    private let phone = PhoneConversations()
    // 🖥 このMac(何が動いているか): ~/.local/share/mac-status を読むだけ。計測は launchd
    // `tokyo.hamada.mac-status-log`(30分毎・差分ログ+失敗通知)。本人指示2026-09-03「Sente.app の中にも入れてほしい」
    private let macStatus = MacStatusStore()
    private let macStatusViewer = MacStatusViewer()
    private lazy var phoneViewer = PhoneConversationViewer()
    private static let phoneTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d HH:mm"
        return f
    }()
    // 🖥 いま並行して動いているClaude Code/Sente talkのセッション一覧+状況。
    // ps/lsofはやや重いのでバックグラウンドで取得し、結果だけメインスレッドでrender()に反映する。
    private var runningSessions: [(icon: String, label: String, tty: String?, elapsedMin: Int, last: String?)] = []
    // 🕰 過去のセッション(エンジンDB由来)。メニューからワンクリックでTerminal再開できるようにする
    // (本人要望: 再起動後もアプリだけで過去のセッションにすぐ戻れるように)。
    private var recentSessions: [SessionStore.Row] = []
    private var micDenied = false
    // 🩺 CLIが吐く「耳✓/口✓/脳✓/MCP✓」診断行のパース結果。talkは動いていても
    // 実際には聞けない/答えられない状態のまま黙って走っていることがあり、メニューを
    // 見ないと気づけない(実測: 「脳✗キー無効」「口✗koe.live HTTP 000000」が繰り返し発生)。
    private var diagnosticIssue: String?
    private var micReadIssue = false
    private var lastActivity = Date()
    private var restartCount = 0
    private var lastRestartAt = Date.distantPast

    // ♟ 先手の一手(te ima/te next が書く $CONFIG_DIR/opening-task 等)。定期的に覗いて
    // あればメニューに直接「やる」ボタンを出す — CLI側は声の「やって」でしか拾えないため、
    // GUIからもワンクリックで着手できるようにする(ロジックはCLI側のまま、ここは読むだけ)。
    private var openingSay: String?
    private var openingTask: String?
    private var openingAlert: String?
    // CLI(sente_opening)が付ける危険度。"confirm"ならワンクリックで即実行せず一度確認する
    // (2026-08-29実障害: 広告キャンペーンの再開/停止判断タスクが一言/一クリックで実行されかけた)
    private var openingRisk: String = "safe"
    // ✅ やること(~/.config/teai/todo.md が正本)。アプリは読む+「済み」にするだけで、
    // 並べ替え/追加はCLI・Claude・人間が同じファイルを直接編集する(ロジック二重化しない)。
    private var todos: [TodoItem] = []
    // 🤖 自動エージェント(te agent)の配備+直近結果。60秒毎に読み直し、失敗(exit≠0)は通知する
    private var agents: [AgentInfo] = []
    private static let agentSeenKey = "agentEventsSeenTs"
    private static let agentFailCategoryID = "AGENT_FAIL"
    private var todoMtime: Date?
    private var imaRunning = false
    // 一度 denied になるとOS側は二度と許可ダイアログを出さないため、システム設定への導線を出す
    private var notificationDenied = false
    private let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/teai", isDirectory: true)

    // Finder から起動すると PATH が最小限になり、sox(rec)や te を見つけられない。
    // 実際に使う場所を明示的に足しておく。
    private var richPath: String {
        let home = NSHomeDirectory()
        let extras = ["\(home)/.local/bin", "\(home)/.opencode/bin", "/opt/homebrew/bin",
                      "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let current = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return (extras + [current]).joined(separator: ":")
    }

    private var sentePath: String? {
        for p in ["\(NSHomeDirectory())/.local/bin/sente", "\(NSHomeDirectory())/.local/bin/te",
                  "/usr/local/bin/sente", "/opt/homebrew/bin/sente"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        render()
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
            self?.refreshNotificationStatus()
        }
        // 通知からワンタップで着手できるように「やる/あとで」ボタンを登録しておく
        let doAction = UNNotificationAction(identifier: "DO_ACTION", title: "やる", options: [])
        let laterAction = UNNotificationAction(identifier: "LATER_ACTION", title: "あとで", options: [])
        let category = UNNotificationCategory(identifier: Self.openingTaskCategoryID, actions: [doAction, laterAction],
                                               intentIdentifiers: [], options: [])
        // 🎵 音楽再生検知の確認ボタン
        let musicPause = UNNotificationAction(identifier: "MUSIC_PAUSE_ACTION", title: "オフにする(音楽の間)", options: [])
        let musicKeep = UNNotificationAction(identifier: "MUSIC_KEEP_ACTION", title: "このまま聞く", options: [])
        let musicAlways = UNNotificationAction(identifier: "MUSIC_ALWAYS_ACTION", title: "今後は自動でオフ", options: [])
        let musicCategory = UNNotificationCategory(identifier: Self.musicCategoryID, actions: [musicPause, musicAlways, musicKeep],
                                                    intentIdentifiers: [], options: [])
        // 🤖 エージェント失敗通知(タップでログを開く)
        let agentCategory = UNNotificationCategory(identifier: Self.agentFailCategoryID, actions: [], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category, musicCategory, agentCategory])
        // 読み上げ中は CLI 側が /tmp/sente_speaking.lock を置く。出力行だけでは
        // 「話している」区間が取れないので、これを覗いて状態に反映する。
        speakTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.process != nil || self.pttProcess != nil else { return }
            let speaking = FileManager.default.fileExists(atPath: "/tmp/sente_speaking.lock")
            if speaking, self.state != .speaking { self.state = .speaking }
            else if !speaking, self.state == .speaking { self.state = .idle }
        }
        requestMicrophoneAccess()
        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            guard let self, self.process != nil, self.state == .idle else { return }
            if Date().timeIntervalSince(self.lastActivity) > 60 {
                let granted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                if !granted {
                    self.micDenied = true
                    DispatchQueue.main.async { self.render() }
                }
            }
        }
        checkOpeningTask()
        checkTodos()
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.checkOpeningTask()
            self?.checkTodos()
            self?.refreshNotificationStatus()
        }
        refreshRunningSessions()
        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.refreshRunningSessions() }
        // 🎵 ミュージック/Spotifyの再生を5秒毎に確認(初回はAutomation許可ダイアログが1度出る)
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.checkMusicPlaying() }
        // 📓 毎晩21:30に今日の独り言(件数・実行したタスク・気になりごと要約)を日報へ自動追記
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.checkNippoAppend() }
        // 🤖 自動エージェント: 配備と直近結果を読み、失敗は通知(ファイルを読むだけなので60秒毎)
        checkAgents()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let before = self.agents.map { "\($0.name)|\($0.lastStart ?? "")|\($0.lastEnd?.ts ?? "")" }
            self.checkAgents()
            let after = self.agents.map { "\($0.name)|\($0.lastStart ?? "")|\($0.lastEnd?.ts ?? "")" }
            if before != after { self.render() }
        }
        // 📱 iPhone の会話: 起動時 + 5 分毎に取り直す(電話側は数ターン毎/背面化時にミラーする)。トークンが無ければ何もしない。
        phone.refresh { [weak self] in self?.render() }
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.phone.refresh { self?.render() } }
        // 🖥 このMac: ファイルを読むだけなので60秒毎。撮り直しは手動(メニュー)か launchd(30分毎)
        macStatus.reload()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.macStatus.reload()
            if self.macStatusViewer.isVisible { self.macStatusViewer.update(self.macStatus) }
            self.render()
        }
        registerPushToTalkHotkey()
        startEar()
        if fusekiEnabled { startFuseki() }
        // ☀️ 起動時ブリーフ(本人指示2026-08-31「起動したらめちゃくちゃ便利に」): 開いた瞬間に
        // 待たされる/探し回るのではなく、裏で te ima(sente_opening full)を1回呼んでおく。
        // CLI側が声で読み上げ+opening-task/opening-lastを書くので、既存のcheckOpeningTask
        // ポーリングがそのまま通知・メニュー表示に拾い上げる(新しい配線は不要)。数秒待つのは
        // マイク許可ダイアログ等の起動直後の処理と声が重ならないようにするため。
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.autoMorningBriefIfNeeded()
        }
    }

    /// 直近`minGap`以内に呼んでいなければ te ima を1回だけ裏実行する(クラッシュ再起動の
    /// 連発やアップデート後の再起動で何度も声が鳴らないための下限のみ・日付境界はあえて見ない
    /// — 「起動したら」という本人の言葉どおり、実際に起動された時に応える設計)。
    private func autoMorningBriefIfNeeded() {
        let key = "lastAutoBriefAt"
        let minGap: TimeInterval = 3 * 60 * 60
        if let last = UserDefaults.standard.object(forKey: key) as? Date,
           Date().timeIntervalSince(last) < minGap { return }
        guard !imaRunning else { return }
        UserDefaults.standard.set(Date(), forKey: key)
        runTeCommand(["ima"]) { [weak self] _ in
            self?.checkOpeningTask()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stop()
        stopBoyaki()
        stopFuseki()
        recProcess?.interrupt()   // 録音中に終了しても sox がwavヘッダを書き終えられるように
    }

    /// $CONFIG_DIR/opening-task(あれば「やって」用の一手)・opening-last(読み上げた提案文)・
    /// opening-alert(深刻な滞留の警告・te ima full時のみ)を覗く。
    /// CLI側(sente_opening)が書き/消すファイルをそのまま読むだけで、判断ロジックは持たない。
    /// メニューを開かないと気づけないと意味が薄いので、提案・警告が変わった時は通知も出す。
    private func checkOpeningTask() {
        let task = (try? String(contentsOf: configDir.appendingPathComponent("opening-task"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let say = (try? String(contentsOf: configDir.appendingPathComponent("opening-last"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let alert = (try? String(contentsOf: configDir.appendingPathComponent("opening-alert"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let risk = (try? String(contentsOf: configDir.appendingPathComponent("opening-risk"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let newTask = (task?.isEmpty == false) ? task : nil
        let newSay = (say?.isEmpty == false) ? say : nil
        let newAlert = (alert?.isEmpty == false) ? alert : nil
        guard newTask != openingTask || newSay != openingSay || newAlert != openingAlert else { return }
        if let s = newAlert, s != openingAlert { notify(title: "⚠️ Sente", body: s) }
        else if let s = newSay, s != openingSay {
            notify(title: "♟ 先手の一手", body: s, categoryID: newTask != nil ? Self.openingTaskCategoryID : nil)
        }
        openingTask = newTask
        openingSay = newSay
        openingAlert = newAlert
        openingRisk = risk == "confirm" ? "confirm" : "safe"
        DispatchQueue.main.async { self.render() }
    }

    private func notify(title: String, body: String, categoryID: String? = nil, userInfo: [String: String]? = nil) {
        guard !notificationDenied else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let categoryID { content.categoryIdentifier = categoryID }
        if let userInfo { content.userInfo = userInfo }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// 一度 denied になると requestAuthorization を再度呼んでもOSはダイアログを出さない
    /// (次に変わるのはユーザーがシステム設定で手動変更した時だけ)ので、都度実際の状態を見て
    /// メニューに「システム設定を開く」導線を出すかどうかを決める。
    private func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let denied = settings.authorizationStatus == .denied
            DispatchQueue.main.async {
                guard let self, self.notificationDenied != denied else { return }
                self.notificationDenied = denied
                self.render()
            }
        }
    }

    // MARK: - 実行中セッション(Claude Code / Sente talk)

    /// 🪤 `waitUntilExit()`を先に呼ぶと、出力がパイプバッファ(~64KB)を超えた時点で
    /// 子プロセスの書き込みがブロックされ、親はwaitUntilExit()で待ち続けるデッドロックに
    /// なる(`ps -eo ...`の全プロセス一覧は普通に超える)。読み取りを先に始めてから待つ。
    private func runShell(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func refreshRunningSessions() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let sessions = self?.collectRunningSessions() ?? []
            let recent = SessionStore.recentSessions(limit: 10)
            DispatchQueue.main.async {
                guard let self else { return }
                self.runningSessions = sessions
                self.recentSessions = recent
                self.render()
            }
        }
    }

    /// Claude Code は起動中セッションを ~/.claude/sessions/<pid>.json に登録している({sessionId,cwd,status,name,…})。
    /// pid から会話ログ(~/.claude/projects/<cwd slug>/<sessionId>.jsonl)を **一意に** 引けるので取り違えが起きない
    /// (最新ファイル推定だと同じcwdの別セッションの発言が混ざった=2026-09-03実測)。登録が無いpidは nil(推測しない)。
    static func claudeSession(pid: Int32) -> (sessionId: String, cwd: String, status: String?)? {
        let p = NSHomeDirectory() + "/.claude/sessions/\(pid).json"
        guard let d = FileManager.default.contents(atPath: p),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let sid = o["sessionId"] as? String, let cwd = o["cwd"] as? String else { return nil }
        return (sid, cwd, o["status"] as? String)
    }

    /// そのセッションの会話ログ末尾64KBから、最後の assistant テキストを1行で返す。
    static func lastAssistantText(pid: Int32) -> String? {
        guard let sess = claudeSession(pid: pid) else { return nil }
        let slug = sess.cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        let path = NSHomeDirectory() + "/.claude/projects/" + slug + "/" + sess.sessionId + ".jsonl"
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let tail: UInt64 = 1_048_576   // ツール出力が大きいセッションは末尾64KBに assistant text が無いことがある(実測)→1MB
        try? fh.seek(toOffset: size > tail ? size - tail : 0)
        guard let data = try? fh.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() {
            guard line.contains("\"type\":\"assistant\""),
                  let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let content = msg["content"] as? [[String: Any]] else { continue }
            let texts = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            guard let t = texts.last?.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces), !t.isEmpty else { continue }
            return t
        }
        return nil
    }

    /// Terminal.appの各タブの custom title(Claude Codeが今の作業内容で自動更新している
    /// タブ名)をtty経由で引く。cwdだけだと大半が同じ"workspace"になり区別がつかない
    /// (実測で指摘)ため、これを主なラベルソースにする。
    private func fetchTerminalTabTitles() -> [String: String] {
        let script = """
            tell application "Terminal"
                set out to ""
                repeat with w in windows
                    repeat with t in tabs of w
                        set out to out & (tty of t) & "|||" & (custom title of t) & linefeed
                    end repeat
                end repeat
                return out
            end tell
            """
        var map: [String: String] = [:]
        for line in runShell("/usr/bin/osascript", ["-e", script]).split(separator: "\n") {
            let parts = line.components(separatedBy: "|||")
            guard parts.count == 2 else { continue }
            let tty = parts[0].trimmingCharacters(in: .whitespaces)
            let title = parts[1].trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { map[tty] = title }
        }
        return map
    }

    /// `ps`でClaude Code(`claude ...`)とSente talk(`sente talk`)のプロセスを見つけ、
    /// tty→Terminalタブ名(無ければcwd末尾)で「どのセッションか」、CPU使用率で簡易な
    /// 状況(作業中/待機中)を組み立てる。ttyはクリックでそのタブに切り替えるのにも使う。
    private func collectRunningSessions() -> [(icon: String, label: String, tty: String?, elapsedMin: Int, last: String?)] {
        // etime=[[dd-]hh:]mm:ss → 分。「今のセッションが何分走っているか」を一覧に出すため(本人要望 2026-09-03)
        func minutes(_ etime: String) -> Int {
            var days = 0; var rest = etime
            if let d = rest.range(of: "-") { days = Int(rest[..<d.lowerBound]) ?? 0; rest = String(rest[d.upperBound...]) }
            let parts = rest.split(separator: ":").compactMap { Int($0) }
            let secs: Int
            switch parts.count {
            case 3: secs = parts[0] * 3600 + parts[1] * 60 + parts[2]
            case 2: secs = parts[0] * 60 + parts[1]
            default: secs = 0
            }
            return days * 1440 + secs / 60
        }
        let psOut = runShell("/bin/ps", ["-eo", "pid=,tty=,pcpu=,etime=,command="])
        var claude: [(pid: Int32, tty: String?, cpu: Double, min: Int)] = []
        var sente: [(pid: Int32, tty: String?, cpu: Double, min: Int)] = []
        for rawLine in psOut.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let fields = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard fields.count == 5, let pid = Int32(fields[0]), let cpu = Double(fields[2]) else { continue }
            let ttyRaw = String(fields[1])
            let tty = ttyRaw.hasPrefix("ttys") ? "/dev/\(ttyRaw)" : nil
            let min = minutes(String(fields[3]))
            let command = String(fields[4])
            if command.hasPrefix("claude ") || command == "claude" { claude.append((pid, tty, cpu, min)) }
            else if command.contains("sente talk") { sente.append((pid, tty, cpu, min)) }
        }
        let allPids = claude.map(\.pid) + sente.map(\.pid)
        guard !allPids.isEmpty else { return [] }
        var lsofArgs = ["-a"]
        for pid in allPids { lsofArgs += ["-p", String(pid)] }
        lsofArgs += ["-d", "cwd", "-Fn"]
        var cwdByPid: [Int32: String] = [:]
        var currentPid: Int32?
        for line in runShell("/usr/sbin/lsof", lsofArgs).split(separator: "\n") {
            if line.hasPrefix("p") { currentPid = Int32(line.dropFirst()) }
            else if line.hasPrefix("n"), let pid = currentPid { cwdByPid[pid] = String(line.dropFirst()) }
        }
        let titleByTTY = fetchTerminalTabTitles()
        func label(pid: Int32, tty: String?) -> String {
            if let tty, let title = titleByTTY[tty] { return title }
            return cwdByPid[pid].map { ($0 as NSString).lastPathComponent } ?? "?"
        }
        var result: [(String, String, String?, Int, String?)] = []
        for (pid, tty, cpu, min) in claude.sorted(by: { $0.cpu > $1.cpu }) {
            // 「待機中」の中身=最後にClaudeが言ったこと(大半はGO待ちの質問)。transcript(~/.claude/projects/<cwd slug>/*.jsonl)の末尾から拾う
            let last = Self.lastAssistantText(pid: pid)
            // 状態は Claude Code 自身の登録(status: idle/…)があればそれを正とし、無ければCPUで推定
            let status = Self.claudeSession(pid: pid)?.status
            let state = status.map { $0 == "idle" ? "待機中" : "作業中" } ?? (cpu > 3 ? "作業中" : "待機中")
            result.append(("🤖", "\(label(pid: pid, tty: tty)) — \(state)", tty, min, last))
        }
        for (pid, tty, cpu, min) in sente {
            result.append(("🎙", "\(label(pid: pid, tty: tty)) — \(cpu > 1 ? "話している" : "待機中")", tty, min, nil))
        }
        return result
    }

    // MARK: - 🖥 このMac
    private func macStatusMenuItem() -> NSMenuItem {
        let sub = NSMenu()
        let snap = macStatus.snapshot
        var title = "このMac"
        var warn = 0
        if let snap {
            let failedJobs = snap.jobs.filter { $0.1 != "0" }
            let down = snap.reach.filter { $0.1 != "OK" }
            warn = failedJobs.count + down.count
            title = "このMac(常駐\(snap.daemons.count)・予約\(snap.jobs.count)" + (warn > 0 ? "・⚠\(warn)" : "") + ")"
            // 1行目=資源(メモリ/スワップ/ディスク)、2行目=Claude/Chrome/起動。キー名は計測ファイルのまま出す(項目が増えても追従)
            let boot = snap.general.first { $0.0 == "起動" }?.1
            let res = snap.general.filter { $0.0 != "起動" }.map { "\($0.0) \($0.1)" }.joined(separator: "・")
            sub.addItem(header(res.isEmpty ? "資源: 計測なし" : res, symbol: "memorychip"))
            let proc = snap.claude.map { "\($0.0 == "セッション" ? "Claude" : $0.0) \($0.1)" }.joined(separator: "・")
            sub.addItem(header(proc + (boot.map { "・起動 \($0)" } ?? ""), symbol: "cpu"))
            let reach = snap.reach.map { "\($0.0) \($0.1)" }.joined(separator: "・")
            sub.addItem(header("到達性: \(reach)", symbol: down.isEmpty ? "antenna.radiowaves.left.and.right" : "exclamationmark.triangle"))
            sub.addItem(.separator())
            let dm = NSMenu()
            for d in snap.daemons { let h = header(d.0); h.toolTip = "pid \(d.1)"; dm.addItem(h) }
            let dp = NSMenuItem(title: "常駐 \(snap.daemons.count)(ずっと動いている)", action: nil, keyEquivalent: "")
            dp.image = symbolImage("play.circle"); dp.submenu = dm; sub.addItem(dp)
            let jm = NSMenu()
            for j in failedJobs { jm.addItem(header("\(j.0) — 前回失敗(exit=\(j.1))", symbol: "xmark.octagon")) }
            if !failedJobs.isEmpty { jm.addItem(.separator()) }
            for j in snap.jobs where j.1 == "0" { jm.addItem(header(j.0)) }
            let jp = NSMenuItem(title: failedJobs.isEmpty ? "予約 \(snap.jobs.count)(時間が来たら動く)" : "予約 \(snap.jobs.count)(⚠ \(failedJobs.count)件が前回失敗)",
                                action: nil, keyEquivalent: "")
            jp.image = symbolImage(failedJobs.isEmpty ? "clock" : "clock.badge.exclamationmark"); jp.submenu = jm; sub.addItem(jp)
            let pm = NSMenu()
            for p in snap.ports { pm.addItem(header("\(p.0)  ← \(p.1)")) }
            let pp = NSMenuItem(title: "待受ポート \(snap.ports.count)", action: nil, keyEquivalent: "")
            pp.image = symbolImage("network"); pp.submenu = pm; sub.addItem(pp)
            sub.addItem(.separator())
        } else {
            sub.addItem(header("まだ計測がありません(「いま撮り直す」で30秒ほど)", symbol: "hourglass"))
            sub.addItem(.separator())
        }
        sub.addItem(header("最近の変化(新しい順)", symbol: "arrow.triangle.2.circlepath"))
        if macStatus.changes.isEmpty {
            sub.addItem(header("  変化なし"))
        } else {
            for l in macStatus.changes.prefix(6) { let h = header(truncated(l, 64)); h.toolTip = l; sub.addItem(h) }
            if macStatus.changes.count > 6 { sub.addItem(header("  他 \(macStatus.changes.count - 6) 件 → 全体を見る")) }
        }
        sub.addItem(.separator())
        sub.addItem(item("全体を見る…", #selector(showMacStatus), "", symbol: "doc.text.magnifyingglass"))
        let rf = item(macStatus.running ? "撮り直し中…" : "いま撮り直す", #selector(refreshMacStatusNow), "", symbol: "arrow.clockwise")
        rf.isEnabled = !macStatus.running
        sub.addItem(rf)
        if let at = macStatus.checkedAt { sub.addItem(header("最終チェック \(at)(30分毎に自動)")) }
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.image = symbolImage(warn > 0 ? "desktopcomputer.trianglebadge.exclamationmark" : "desktopcomputer")
        parent.submenu = sub
        return parent
    }

    @objc private func showMacStatus() {
        macStatus.reload()
        macStatusViewer.show(macStatus) { [weak self] in self?.refreshMacStatusNow() }
    }

    @objc private func refreshMacStatusNow() {
        macStatus.refreshNow { [weak self] in
            guard let self else { return }
            if self.macStatusViewer.isVisible { self.macStatusViewer.update(self.macStatus) }
            self.render()
        }
        render()
    }

    /// セッション一覧のクリックで、そのClaude Code/Sente talkが動いているTerminalタブに
    /// 直接切り替える(本人指摘: クリックしたらターミナルに移れるようにしてほしい)。
    /// 初回はmacOSがTerminal操作の許可を求めるダイアログを出すことがある。
    @objc private func focusSession(_ sender: NSMenuItem) {
        guard let tty = sender.representedObject as? String else { return }
        let script = """
            tell application "Terminal"
                activate
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            set frontmost of w to true
                            set selected tab of w to t
                            return
                        end if
                    end repeat
                end repeat
            end tell
            """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }

    /// フォアグラウンド(=メニュー展開中など)でもバナーを出す。既定だとアクティブなアプリでは抑制されるため。
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                 withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// 通知の「やる」ボタン(または通知本体のタップ)から直接着手できるようにする。
    /// 「あとで」・時間切れでの黙殺時は何もしない(opening-taskはメニューに残り続ける)。
    /// 🎵通知は「オフにする」ボタンか本文タップで一時停止、「このまま聞く」は何もしない。
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                 withCompletionHandler completionHandler: @escaping () -> Void) {
        let isDefaultTap = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        if response.notification.request.content.categoryIdentifier == Self.musicCategoryID {
            if response.actionIdentifier == "MUSIC_PAUSE_ACTION" || isDefaultTap {
                DispatchQueue.main.async { self.pauseForMusic() }
            } else if response.actionIdentifier == "MUSIC_ALWAYS_ACTION" {
                // 「今後は自動でオフ」= 設定を永続化した上で今回もオフにする
                DispatchQueue.main.async {
                    self.musicAutoPause = true
                    UserDefaults.standard.set(true, forKey: "musicAutoPause")
                    self.pauseForMusic()
                }
            }
        } else if response.notification.request.content.categoryIdentifier == Self.agentFailCategoryID {
            if let name = response.notification.request.content.userInfo["agent"] as? String {
                DispatchQueue.main.async { NSWorkspace.shared.open(AgentStore.logFile(name)) }
            }
        } else if response.actionIdentifier == "DO_ACTION" || isDefaultTap {
            DispatchQueue.main.async { self.runOpeningTask() }
        }
        completionHandler()
    }

    /// 録音は子プロセス(sox)がするが、macOS のマイク許可は起動元アプリに紐づく。
    /// 先に自分で要求しておかないと、子プロセスの録音が無音になる。
    private func requestMicrophoneAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] ok in
                self?.micDenied = !ok
                DispatchQueue.main.async { self?.render() }
            }
        default:
            micDenied = true
            DispatchQueue.main.async {
                let a = NSAlert()
                a.messageText = "マイクの使用が許可されていません"
                a.informativeText = "システム設定 → プライバシーとセキュリティ → マイク で Sente を有効にしてください。"
                a.addButton(withTitle: "システム設定を開く")
                a.addButton(withTitle: "あとで")
                if a.runModal() == .alertFirstButtonReturn,
                   let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    // MARK: - 🎵 音楽再生の検知と一時停止 / 🎙 押して話す

    /// 音楽/音声の再生を電源アサーション(pmset -g assertions)で確認する。
    /// 実測シグナル: ミュージック=`pid 587(Music): … PreventUserIdleSystemSleep
    /// named:"com.apple.Music.playback"` / Chrome系=`pid N(Google Chrome): …
    /// NoIdleSleepAssertion named:"Playing audio"`(⚠アサーション種別がMusicと違うので
    /// 種別では絞らない)。Safari="WebKit Media Playback"・Firefox="audio-playing"。
    /// 🪤 最初はosascriptで player state を読む実装だったが、Apple Event は
    /// TCC(オートメーション許可)が必要で、許可ダイアログに気づかないと黙って永遠に
    /// 検知できない。pmsetは無許可で読めて確実。coreaudiodのaudio-out行はSente自身の
    /// 読み上げ(afplay)でも立つので使わない(プロセス名/アサーション名で絞るのが肝)。
    private func checkMusicPlaying() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let out = self.runShell("/usr/bin/pmset", ["-g", "assertions"])
            var direct = false, browser = false, zoom = false
            for line in out.split(separator: "\n") {
                if line.range(of: #"pid \d+\(Music\):.*com\.apple\.Music\.playback"#, options: .regularExpression) != nil
                    || line.range(of: #"pid \d+\(Spotify\):"#, options: .regularExpression) != nil {
                    direct = true
                }
                if line.contains("named: \"Playing audio\"")            // Chrome/Edge/Brave/Arc
                    || line.contains("WebKit Media Playback")            // Safari
                    || line.contains("named: \"audio-playing\"")         // Firefox
                    || line.contains("named: \"video-playing\"") {
                    browser = true
                }
                // 📝 Zoomは会議中だけ電源アサーションを持つ(待機中は無し=実測)。
                // ⚠会議中の実アサーション名は未実測のためプロセス名だけで判定(unverified)
                if line.range(of: #"pid \d+\(zoom\.us\):"#, options: .regularExpression) != nil {
                    zoom = true
                }
            }
            DispatchQueue.main.async {
                self.handleAudioSignals(direct: direct, browser: browser)
                self.handleZoom(zoom)
            }
        }
    }

    /// 専用アプリ(Music/Spotify)は即時、ブラウザ音声は2回連続(約10秒)で「再生中」判定。
    /// ブラウザは通知音・短い動画プレビューでも一瞬アサーションが立つため、即時にすると
    /// 確認通知が乱発してうるさくなる。
    private func handleAudioSignals(direct: Bool, browser: Bool) {
        browserAudioStreak = browser ? browserAudioStreak + 1 : 0
        let playing = direct || (musicDetectBrowser && browserAudioStreak >= 2)
        handleMusic(playing)
    }

    private func handleMusic(_ playing: Bool) {
        guard playing != musicPlaying else { return }
        musicPlaying = playing
        // 📝 会議の議事録録音中は音楽まわりの自動制御をしない(録音は続ける)
        if meetingRecording { return }
        append("\n--- 🎵 音楽\(playing ? "再生開始" : "停止")を検知 (talk=\(process != nil ? "on" : "off") paused=\(pausedForMusic) auto=\(musicAutoPause)) \(Date()) ---\n")
        if playing {
            if process != nil || boyakiProcess != nil, !pausedForMusic {
                if musicAutoPause {
                    // 設定済みなら聞かずに即オフ(通知は事後報告だけ)
                    pauseForMusic()
                    notify(title: "🎵 Sente", body: "音楽の間、聞き取りをオフにしました(⌃⌥スペースで一言きけます)")
                } else if !musicPromptShown {
                    // 「オフにする?」を確認する(1再生エピソードにつき1回)。
                    // 通知が許可されていない環境ではメニューの「🎵 音楽の間オフにする」から手動で。
                    musicPromptShown = true
                    notify(title: "🎵 音楽の再生を検知しました",
                           body: "聞き取りを音楽の間オフにしますか?(オフ中も ⌃⌥スペース で一言きけます)",
                           categoryID: Self.musicCategoryID)
                }
            }
        } else {
            musicPromptShown = false
            if pausedForMusic { resumeFromMusic(auto: true) }
        }
        render()
    }

    @objc private func toggleMusicAutoPause() {
        musicAutoPause.toggle()
        UserDefaults.standard.set(musicAutoPause, forKey: "musicAutoPause")
        // いま音楽再生中に「自動でオフ」を入れたら、その場で効かせる
        if musicAutoPause, musicPlaying, process != nil, !pausedForMusic { pauseForMusic() }
        render()
    }

    @objc private func toggleMusicDetectBrowser() {
        musicDetectBrowser.toggle()
        UserDefaults.standard.set(musicDetectBrowser, forKey: "musicDetectBrowser")
        browserAudioStreak = 0
        render()
    }

    @objc func pauseForMusic() {
        guard process != nil || boyakiProcess != nil else { return }
        pausedForMusic = true
        stopEar()
        lastReply = "🎵 音楽の間、聞き取りをオフにしました(⌃⌥スペースで一言きけます)"
        render()
    }

    private func resumeFromMusic(auto: Bool) {
        pausedForMusic = false
        restartCount = 0
        startEar()
        if auto { notify(title: "🎙 Sente", body: "音楽が止まったので聞き取りを再開しました") }
        render()
    }

    @objc private func resumeFromMusicMenu() { resumeFromMusic(auto: false) }

    /// ⌃⌥スペース(またはメニュー)で一言だけきく: `te v` のワンショット実行。
    /// 常時聞き取り(talk)が動いている間はマイクが競合するので何もしない。
    @objc func pushToTalk() {
        guard !meetingRecording, pttProcess == nil, let sente = sentePath else { return }
        if process != nil || boyakiProcess != nil {
            // 耳が動いていたらマイクを譲ってもらい、te v が終わったら自動で戻す
            earPausedForPTT = true
            stopEar()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.pushToTalk() }
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "exec '\(sente)' v"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = richPath
        env["TERM"] = "dumb"
        p.environment = env
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.append(text)
            text.split(separator: "\n", omittingEmptySubsequences: true).forEach { self?.consume(String($0)) }
        }
        p.terminationHandler = { [weak self] _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.pttProcess = nil
                if self.process == nil { self.state = .stopped }
                // 耳を譲ってもらって一言きいた場合は、終わったら元のモードに自動で戻す
                if self.earPausedForPTT {
                    self.earPausedForPTT = false
                    if !self.pausedForMusic, !self.meetingRecording { self.startEar() }
                }
                self.render()
            }
        }
        do {
            try p.run()
            pttProcess = p
            state = .listening
            append("\n--- 押して話す(te v) \(Date()) ---\n")
        } catch {
            lastReply = error.localizedDescription
        }
        render()
    }

    /// ⌃⌥スペースをグローバルホットキーとして登録する(Carbon RegisterEventHotKey =
    /// Accessibility権限が要らない方式)。他アプリが同じキーを取っていると失敗するが、
    /// その場合もメニューの「🎙 一言きく」から同じことができる。
    private func registerPushToTalkHotkey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, userData -> OSStatus in
            guard let userData else { return noErr }
            let me = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { me.pushToTalk() }
            return noErr
        }, 1, &eventType, selfPtr, nil)
        let hotKeyID = EventHotKeyID(signature: OSType(0x53454E54), id: 1)   // 'SENT'
        let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey),
                                         hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef)
        if status != noErr { append("\n⚠ ⌃⌥スペースのホットキー登録に失敗 (status=\(status)) — メニューの「一言きく」は使えます\n") }
    }

    // MARK: - 👂 耳のモード(会話/独り言)と切替

    private var boyakiPath: String? {
        let p = "\(NSHomeDirectory())/.local/bin/boyaki"
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    /// いまのモードの「耳」を起動する(会議録音中は何もしない)
    private func startEar() {
        guard !meetingRecording, !minutesGenerating else { return }
        userStoppedEar = false
        if earMode == "kaiwa" { start() } else { startBoyaki() }
    }

    /// 動いている耳(talk/boyaki)を全部止める
    private func stopEar() {
        stop()
        stopBoyaki()
    }

    private func setEarMode(_ mode: String) {
        guard earMode != mode else { return }
        earMode = mode
        UserDefaults.standard.set(mode, forKey: "earMode")
        guard !meetingRecording else { render(); return }
        stopEar()
        // 終了処理(マイク解放)を待ってから次のモードを起動する
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, !self.pausedForMusic, !self.meetingRecording else { return }
            self.startEar()
        }
        render()
    }

    @objc private func setModeKaiwa() { setEarMode("kaiwa") }
    @objc private func setModeHitorigoto() { setEarMode("hitorigoto") }

    /// 📓 独り言モード: boyaki --journal を子プロセスで回す。発話は貯まるだけで、
    /// boyaki側が「静かになったら」まとめて解析し、必要なタスクだけ te run で実行する。
    private func startBoyaki() {
        guard boyakiProcess == nil, process == nil else { return }
        guard let boyaki = boyakiPath else {
            state = .error
            lastReply = "boyaki が見つかりません(独り言モードには ~/.local/bin/boyaki が必要)"
            render()
            return
        }
        // 🧹 親を失った孤児boyaki(アプリが強制終了された時の残骸)がロックとマイクを掴んだ
        // ままだと、新しいboyakiが「多重起動」判定で即死→耳が黙って止まる(2026-08-29実障害:
        // 並行セッションのアプリ差し替えkillで発生)。PPID=1の孤児だけ先に片付ける。
        // 端末から手で起動したboyaki(親=シェル)には触らない。
        let orphans = runShell("/bin/sh", ["-c",
            "ps -eo pid=,ppid=,command= | awk '$2==1 && /boyaki\\.py --journal/ {print $1}'"])
        for pidStr in orphans.split(separator: "\n") {
            if let pid = Int32(pidStr.trimmingCharacters(in: .whitespaces)) {
                kill(pid, SIGTERM)
                append("\n🧹 孤児boyaki(PID \(pid))を片付けました\n")
            }
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "exec '\(boyaki)' --journal"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = richPath
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.append(text)
            for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("📓 ") {
                    self?.lastHeard = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    DispatchQueue.main.async { self?.render() }
                } else if line.hasPrefix("⚙ 実行") || line.hasPrefix("→ ") {
                    self?.lastReply = String(line.prefix(120))
                    DispatchQueue.main.async { self?.render() }
                }
            }
        }
        p.terminationHandler = { [weak self] _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.boyakiProcess = nil
                if self.process == nil { self.state = .stopped }
                // 予期せぬ終了は自動再開(明示停止・PTT譲り・音楽停止・会議切替では再開しない)。
                // 起動直後死(ロック衝突・マイク競合)も少数回はリトライする — 以前は「30秒以上
                // 生きた時だけ再開」で、ロック衝突1回で耳が黙って止まりっぱなしになる実害があった。
                let uptime = Date().timeIntervalSince(self.boyakiLastStart)
                if uptime >= 30 { self.boyakiQuickDeaths = 0 } else { self.boyakiQuickDeaths += 1 }
                if self.earMode == "hitorigoto", !self.userStoppedEar, !self.earPausedForPTT,
                   !self.pausedForMusic, !self.meetingRecording {
                    if uptime >= 30 || self.boyakiQuickDeaths <= 3 {
                        let delay: TimeInterval = uptime >= 30 ? 5 : 8
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.startEar() }
                    } else {
                        self.lastReply = "独り言モードが繰り返し止まるため自動再開を停止しました(「聞き始める」で再開)"
                    }
                }
                self.render()
            }
        }
        do {
            try p.run()
            boyakiProcess = p
            boyakiLastStart = Date()
            state = .idle
            append("\n--- boyaki(独り言モード) 開始 \(Date()) ---\n")
        } catch {
            state = .error
            lastReply = error.localizedDescription
        }
        render()
    }

    private func stopBoyaki() {
        guard let p = boyakiProcess else { return }
        boyakiProcess = nil
        p.terminationHandler = nil
        p.terminate()   // SIGTERM: boyaki側がロックファイルを掃除して終了する
    }

    /// 🪨 布石を裏で回す(`te watch` = fuseki watchと同じ実体)。マイクは使わないので
    /// 耳(talk/boyaki)の状態とは独立に動かせる。落ちても有効なら数秒後に自動再起動する。
    private func startFuseki() {
        guard fusekiProcess == nil else { return }
        guard let te = sentePath else {
            lastReply = "布石を起動できません(~/.local/bin/te が見つかりません)"
            render()
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "exec '\(te)' watch"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = richPath
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.append(text)
        }
        p.terminationHandler = { [weak self] _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.fusekiProcess = nil
                // 有効なままの予期せぬ終了(クラッシュ等)だけ自動再起動する。トグルOFFでの
                // 明示停止はfusekiEnabledを先にfalseにしてから呼ぶので、ここには来ない。
                if self.fusekiEnabled {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                        guard let self, self.fusekiEnabled else { return }
                        self.startFuseki()
                    }
                }
                self.render()
            }
        }
        do {
            try p.run()
            fusekiProcess = p
            append("\n--- 🪨 布石(fuseki watch) 開始 \(Date()) ---\n")
        } catch {
            lastReply = "布石の起動に失敗: \(error.localizedDescription)"
        }
        render()
    }

    private func stopFuseki() {
        guard let p = fusekiProcess else { return }
        fusekiProcess = nil
        p.terminationHandler = nil
        p.terminate()   // SIGTERM: te watch側のtrapが片付けて終了する
    }

    /// 🔊/🔇 読み上げのワンクリック切替。~/.config/teai/mute が正本(te voice on/off・声コマンドと共通)。
    /// launcher側は読み上げのたびにこのファイルを見るので、実行中のセッションにも即効く。
    private var mutePath: String { NSHomeDirectory() + "/.config/teai/mute" }
    @objc private func toggleVoiceMute() {
        let fm = FileManager.default
        if fm.fileExists(atPath: mutePath) {
            try? fm.removeItem(atPath: mutePath)
        } else {
            try? fm.createDirectory(atPath: NSHomeDirectory() + "/.config/teai", withIntermediateDirectories: true)
            fm.createFile(atPath: mutePath, contents: nil)
            // いま鳴っている読み上げもその場で止める(launcherのsente_stop_speakingと同じ手順)
            fm.createFile(atPath: "/tmp/sente_say_stop", contents: nil)
            for exe in ["afplay", "mpg123"] {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
                p.arguments = ["-x", exe]
                try? p.run()
            }
            try? fm.removeItem(atPath: "/tmp/sente_speaking.lock")
            try? fm.removeItem(atPath: "/tmp/sente_turn_open")
            // 共通キュー(voiceq)に溜まっている分も捨てる(CLIの te voice stop と同じ)
            runVoiceQ("stop")
        }
        render()
    }

    // ── 🔊 声キュー(voiceq) ───────────────────────────────────────────────
    // 各ターミナルの読み上げは ~/.config/teai/voiceq/ に溜まり、単一ワーカーが
    // まとめて喋る。ここから「いま何件溜まっているか」を見て、止める/次へができる。
    private var voiceQPath: String { NSHomeDirectory() + "/.config/teai/voiceq.py" }

    /// 溜まっている件数(0=なし)。ワーカー稼働中は -1 を返さず件数のみ。
    private func voiceQPendingCount() -> Int {
        let dir = NSHomeDirectory() + "/.config/teai/voiceq/pending"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return 0 }
        return names.filter { $0.hasSuffix(".json") }.count
    }

    private func voiceQRunning() -> Bool {
        FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.config/teai/voiceq/worker.lock")
    }

    /// 直近に発話したセッションの本数(voiceq.py が recent.json に書いたもの)。
    /// 1本だけならキューは使われず即再生されるので、メニューも出さない(2026-09-11)。
    private func voiceQParallelCount() -> Int {
        let p = NSHomeDirectory() + "/.config/teai/voiceq/recent.json"
        guard let d = FileManager.default.contents(atPath: p),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return 0 }
        let window: Double = 180
        let now = Date().timeIntervalSince1970
        return o.values.reduce(0) { acc, v in
            guard let t = v as? Double else { return acc }
            return acc + (now - t < window ? 1 : 0)
        }
    }

    private func runVoiceQ(_ sub: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [voiceQPath, sub]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = richPath
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    @objc private func voiceQStop() { runVoiceQ("stop"); render(); voiceQViewer.refresh() }
    @objc private func voiceQSkip() { runVoiceQ("skip"); render(); voiceQViewer.refresh() }

    /// 🔊 声キューをウィンドウで見る(メニューだけでなく中身も確認したい本人要望 2026-09-11)
    @objc private func showVoiceQueue() { voiceQViewer.show() }

    private lazy var voiceQViewer = VoiceQueueController(onStop: { [weak self] in
        self?.runVoiceQ("stop"); self?.render()
    }, onSkip: { [weak self] in
        self?.runVoiceQ("skip"); self?.render()
    })

    @objc private func toggleFuseki() {
        fusekiEnabled.toggle()
        UserDefaults.standard.set(fusekiEnabled, forKey: "fusekiEnabled")
        if fusekiEnabled { startFuseki() } else { stopFuseki() }
        render()
    }

    /// 📓 貯まっている独り言をいますぐまとめて解析(結果はboyakiが通知で知らせる)
    @objc private func digestNow() {
        runBoyaki(args: "--digest-now", note: "📓 貯まった独り言を解析しています…(結果は通知で)")
    }

    /// boyakiのワンショットサブコマンド(--digest-now / --nippo-append)を裏で実行する
    private func runBoyaki(args: String, note: String) {
        guard let boyaki = boyakiPath else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "exec '\(boyaki)' \(args)"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = richPath
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        lastReply = note
        render()
    }

    /// 📓→📝 毎晩21:30に今日の独り言サマリを日報(~/workspace/tasks/nippo/)へ自動追記する。
    /// 実体はboyaki --nippo-append(マーカー置換で冪等)。1日1回ガードはUserDefaultsの日付。
    private func checkNippoAppend() {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let today = f.string(from: Date())
        guard UserDefaults.standard.string(forKey: "boyakiNippoDate") != today else { return }
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        guard (c.hour ?? 0) * 60 + (c.minute ?? 0) >= 21 * 60 + 30 else { return }
        UserDefaults.standard.set(today, forKey: "boyakiNippoDate")
        runBoyaki(args: "--nippo-append", note: "📓 今日の独り言を日報へ追記しています…")
    }

    @objc private func nippoAppendNow() {
        runBoyaki(args: "--nippo-append", note: "📓 今日の独り言を日報へ追記しています…(結果は通知で)")
    }

    // MARK: - 📝 会議の議事録(録音→文字起こし→要約)

    private var minutesDir: String { NSHomeDirectory() + "/Documents/Sente議事録" }

    /// Zoomの在席をデバウンスして議事録録音を自動開始/終了する。
    /// 手動開始した録音はZoomが消えても止めない(Meet等のZoom以外の会議で使うため)。
    private func handleZoom(_ present: Bool) {
        guard !minutesGenerating else { return }
        if present {
            zoomGoneStreak = 0
            zoomStreak += 1
            if !meetingRecording, zoomStreak >= 2 { startMeeting(auto: true) }
        } else {
            zoomStreak = 0
            if meetingRecording, meetingAuto {
                zoomGoneStreak += 1
                if zoomGoneStreak >= 3 { endMeeting() }
            }
        }
    }

    @objc private func startMeetingManual() { startMeeting(auto: false) }

    /// 会議モード: 耳(talk/boyaki)を止め、AECなしの素のマイク録音に切り替える。
    /// AECなし=スピーカーから出る相手の声もマイクで拾える(⚠ヘッドホン利用時は
    /// 相手の声が録れず自分の発言だけの議事録になる)。
    private func startMeeting(auto: Bool) {
        guard !meetingRecording else { return }
        meetingRecording = true
        meetingAuto = auto
        stopEar()
        pttProcess?.terminate()
        let dir = NSHomeDirectory() + "/Library/Application Support/Sente/minutes"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let wav = dir + "/rec-\(f.string(from: Date())).wav"
        recWavPath = wav
        recStartedAt = Date()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // 録音はマイク解放(stopEarの終了処理)を待ってから。execなのでSIGINTはsox本体に届く
        p.arguments = ["-c", "sleep 1.5; exec rec -q -r 16000 -c 1 -b 16 '\(wav)'"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = richPath
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            recProcess = p
            append("\n--- 📝 議事録 録音開始(auto=\(auto)) \(Date()) → \(wav) ---\n")
            notify(title: "📝 議事録", body: auto ? "Zoom会議を検知 — 録音を始めました(終了で自動的に議事録になります)"
                                                  : "録音を始めました(メニューの「議事録を終える」で生成)")
        } catch {
            meetingRecording = false
            lastReply = "録音を開始できませんでした: \(error.localizedDescription)"
        }
        render()
    }

    @objc private func endMeetingManual() { endMeeting() }

    private func endMeeting() {
        guard meetingRecording else { return }
        meetingRecording = false
        zoomStreak = 0
        zoomGoneStreak = 0
        recProcess?.terminationHandler = nil
        recProcess?.interrupt()   // SIGINT: soxがwavヘッダを確定して終了する
        recProcess = nil
        guard let wav = recWavPath else { return }
        minutesGenerating = true
        append("\n--- 📝 議事録 録音終了 \(Date()) ---\n")
        notify(title: "📝 議事録", body: "録音を終えました。文字起こしと議事録を作っています…(数分かかります)")
        render()
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"
        let out = minutesDir + "/\(f.string(from: Date())).md"
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            _ = self.runShell("/bin/sh", ["-c", Self.minutesPipeline, "minutes", wav, out])
            let size = ((try? FileManager.default.attributesOfItem(atPath: out))?[.size] as? Int) ?? 0
            let ok = size > 0
            DispatchQueue.main.async {
                self.minutesGenerating = false
                if ok {
                    self.lastMinutesPath = out
                    UserDefaults.standard.set(out, forKey: "lastMinutesPath")
                    self.appendMinutesLinkToNippo(out)
                    self.notify(title: "📝 議事録ができました", body: (out as NSString).lastPathComponent + " — メニューから開けます")
                    self.lastReply = "📝 議事録: \(out)"
                } else {
                    self.notify(title: "📝 議事録", body: "生成に失敗しました(talkの生ログ参照)")
                }
                if !self.pausedForMusic { self.startEar() }
                self.render()
            }
        }
    }

    /// 📝→📓 生成した議事録への1行リンクを今日の日報へ追記する(本人指示 2026-08-29)。
    /// マーカー区間に1会議=1行で足していく。同じファイルは二重に足さない。
    /// /nippoのAI書き直しは手書き行を保持する運用なので、この行も残る。
    private func appendMinutesLinkToNippo(_ minutesPath: String) {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let day = df.string(from: Date())
        let nippo = NSHomeDirectory() + "/workspace/tasks/nippo/\(day).md"
        var cur = (try? String(contentsOfFile: nippo, encoding: .utf8)) ?? "# 日報 \(day)\n"
        guard !cur.contains(minutesPath) else { return }
        let tf = DateFormatter(); tf.dateFormat = "HH:mm"
        let line = "- [\(tf.string(from: Date()))] \((minutesPath as NSString).lastPathComponent) — `\(minutesPath)`"
        if let r = cur.range(of: "<!-- minutes-end -->") {
            cur.replaceSubrange(r.lowerBound..<r.lowerBound, with: line + "\n")
        } else {
            cur = cur.trimmingCharacters(in: .whitespacesAndNewlines)
                + "\n\n<!-- minutes-start -->\n## 📝 会議の議事録(自動)\n\n" + line + "\n<!-- minutes-end -->\n"
        }
        try? FileManager.default.createDirectory(atPath: (nippo as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        try? cur.write(toFile: nippo, atomically: true, encoding: .utf8)
        append("\n--- 📝 議事録リンクを日報へ追記: \(line) ---\n")
    }

    @objc private func openLatestMinutes() {
        guard let p = lastMinutesPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: p))
    }

    /// 録音wav→55秒チャンク→koe.live STT→teai(kimi-k3)で議事録Markdown。
    /// sh -c にそのまま渡す($0=名前, $1=wav, $2=出力md)。STTはte本体と同じ無認証エンドポイント。
    private static let minutesPipeline = #"""
    set -eu
    WAV="$1"; OUT="$2"
    PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"; export PATH
    TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
    sox "$WAV" "$TMPD/c_.wav" trim 0 55 : newfile : restart 2>/dev/null || cp "$WAV" "$TMPD/c_001.wav"
    TR="$TMPD/tr.txt"; : > "$TR"; i=0
    for f in "$TMPD"/c_*.wav; do
      [ -f "$f" ] || continue
      SEC=$((i*55)); i=$((i+1))
      TXT="$(curl -s -m 90 -X POST 'https://koe.live/api/stt?lang=ja' -H 'Content-Type: audio/wav' --data-binary @"$f" \
        | sed -n 's/.*"text":"\([^"]*\)".*/\1/p' || true)"
      [ -n "$TXT" ] && printf '[%02d:%02d] %s\n' $((SEC/60)) $((SEC%60)) "$TXT" >> "$TR" || true
    done
    mkdir -p "$(dirname "$OUT")"
    if ! [ -s "$TR" ]; then printf '# 議事録\n\n(文字起こしが空でした — 録音を確認してください)\n' > "$OUT"; exit 0; fi
    [ -f "$HOME/.config/teai/credentials" ] && . "$HOME/.config/teai/credentials" || true
    python3 - "$TR" "$OUT" "${TEAI_API_KEY:-}" <<'PY'
    import sys, json, urllib.request, datetime, pathlib
    tr = pathlib.Path(sys.argv[1]).read_text()
    out, key = sys.argv[2], sys.argv[3]
    minutes = "(TEAI_API_KEY が見つからず要約は未生成 — 文字起こしのみ)"
    if key:
        prompt = ("以下は会議音声の文字起こしです(1本のマイク録音のため話者は分かれていません)。"
                  "日本語で議事録を作ってください。構成: ## 要点(3〜6行) / ## 決定事項 / "
                  "## TODO(誰が・何を・いつまでか分かる範囲で) / ## 補足。"
                  "文字起こしに無いことを足さないでください。\n\n" + tr)
        body = json.dumps({"model": "moonshotai/kimi-k3",
                           "messages": [{"role": "user", "content": prompt}],
                           "max_tokens": 1500}).encode()
        req = urllib.request.Request("https://api.teai.io/v1/chat/completions", data=body,
                                     headers={"Content-Type": "application/json",
                                              "Authorization": "Bearer " + key,
                                              "User-Agent": "sente-app/1.4"})
        try:
            with urllib.request.urlopen(req, timeout=240) as r:
                minutes = json.load(r)["choices"][0]["message"]["content"].strip()
        except Exception as e:
            minutes = f"(議事録の自動生成に失敗: {e})"
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    pathlib.Path(out).write_text(f"# 議事録 {now}\n\n{minutes}\n\n---\n\n## 文字起こし全文\n\n{tr}\n")
    PY
    echo OK
    """#

    // MARK: - プロセス

    private func start() {
        guard process == nil, boyakiProcess == nil else { return }
        guard let sente = sentePath else {
            state = .error
            lastReply = "sente が見つかりません"
            showInstallHelp()
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // login shell にしないのは、ユーザーの rc が対話前提で固まることがあるため。
        // 必要な PATH はこちらで渡す。
        p.arguments = ["-c", "exec '\(sente)' talk"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = richPath
        env["TERM"] = "dumb"          // TUI 用のエスケープを出させない
        p.environment = env
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.append(text)
            text.split(separator: "\n", omittingEmptySubsequences: true).forEach {
                self?.consume(String($0))
            }
        }
        p.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.process = nil
            self.state = .stopped
            DispatchQueue.main.async { self.scheduleAutoRestart() }
        }
        do {
            try p.run()
            process = p
            state = .idle
            append("\n--- sente 開始 \(Date()) ---\n")
        } catch {
            state = .error
            lastReply = error.localizedDescription
        }
    }

    private func stop() {
        guard let p = process else { return }
        process = nil
        p.terminationHandler = nil
        p.interrupt()                                   // talk ループを Ctrl-C 相当で止める
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if p.isRunning { p.terminate() }
        }
        state = .stopped
    }

    /// talk は無音継続での自然終了(dead air)や予期せぬクラッシュで落ちることがあり、
    /// 気づかず「止まったまま」放置されると意味が無い。stop()経由(ユーザー主導)では
    /// terminationHandlerをnilにしているのでここは呼ばれない — 予期せぬ終了だけを対象にする。
    /// 短時間の繰り返しクラッシュで暴走しないよう、指数バックオフ+上限を掛ける。
    private func scheduleAutoRestart() {
        let now = Date()
        restartCount = now.timeIntervalSince(lastRestartAt) < 30 ? restartCount + 1 : 1
        lastRestartAt = now
        guard restartCount <= 5 else {
            lastReply = "talkが繰り返し落ちるため自動再起動を停止しました(「聞き始める」で手動再開できます)"
            render()
            return
        }
        // 🪤 実測(2026-08-28): 「耳✗(録音が読めません)」の状態は他インスタンスとの
        // 録音デバイス競合で起きることが多く、即リトライしてもまだ塞がっていて同じ理由で
        // また即終了する→14〜32秒間隔で5回連続クラッシュ、という悪循環を実機で確認した。
        // 競合解消の時間を稼ぐため、このケースだけ基準となる待ち時間を長くする。
        let base = micReadIssue ? 20.0 : 1.0
        let delay = min(base * pow(2.0, Double(restartCount - 1)), 60)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.start() }
    }

    private func append(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if let fh = try? FileHandle(forWritingTo: logURL) {
            fh.seekToEndOfFile(); fh.write(data); try? fh.close()
        } else {
            try? data.write(to: logURL)
        }
    }

    /// CLI の出力行から状態を拾う。文言は te-install.sh の talk ループと対になっている。
    private func consume(_ raw: String) {
        let line = raw.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if line.isEmpty { return }
        lastActivity = Date()
        if line.contains("聞き取り中") { state = .listening; return }
        if line.contains("🎤"), let q = line.range(of: "「"), let e = line.range(of: "」") {
            lastHeard = String(line[q.upperBound..<e.lowerBound])
            state = .thinking
            DispatchQueue.main.async { self.render() }
            return
        }
        if line.hasPrefix("> build") { state = .thinking; return }
        if line.contains("🩺") {
            micReadIssue = line.contains("耳✗")
            diagnosticIssue = line.contains("✗") ? line : nil
            DispatchQueue.main.async { self.render() }
            return
        }
        if line.contains("⚠") {
            // 起動時の定型文言・軽微な警告まで「エラー」にすると、talkは実際には
            // 正常に走っているのにGUIだけ止まって見える(実測で頻発)。本当に停止に
            // 至った場合は terminationHandler が state を .stopped にするので、
            // ここでは致命的でないと分かっている既知の文言だけ通常表示に留める。
            let benign = ["ガードレールなしモード", "音が小さめです", "マイク入力音量", "常駐モードが応答しない", "既に動いていた"]
            lastReply = String(line.prefix(120))
            if !benign.contains(where: { line.contains($0) }) { state = .error }
            DispatchQueue.main.async { self.render() }
            return
        }
        if line.contains("Sente talk") { state = .idle; return }
        // ふつうの本文行は返事とみなして最後の1行だけ覚えておく(メニューで見せる)
        if !line.hasPrefix("🎙"), !line.hasPrefix("🧹"), !line.hasPrefix("ℹ"), !line.hasPrefix("(") {
            lastReply = String(line.prefix(120))
            DispatchQueue.main.async { self.render() }
        }
    }

    private func showInstallHelp() {
        let a = NSAlert()
        a.messageText = "Sente CLI が見つかりません"
        a.informativeText = "ターミナルで次を実行してからアプリを開き直してください:\n\ncurl -fsSL https://teai.io/te | sh"
        a.addButton(withTitle: "コマンドをコピー")
        a.addButton(withTitle: "閉じる")
        if a.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("curl -fsSL https://teai.io/te | sh", forType: .string)
        }
    }

    // MARK: - メニュー

    private func render() {
        let hasDiagnosticIssue = diagnosticIssue != nil
        var symbol = (micDenied || hasDiagnosticIssue) ? "exclamationmark.triangle" : state.symbol
        if boyakiProcess != nil, state == .idle { symbol = "waveform" }   // 独り言モードで待機中
        if pausedForMusic { symbol = "music.note" }    // 音楽での一時停止は理由が見えるアイコンに
        if meetingRecording { symbol = "record.circle" } // 議事録の録音中
        if minutesGenerating { symbol = "hourglass" }
        if let img = symbolImage(symbol, size: 15) {
            statusItem.button?.image = img
            statusItem.button?.imagePosition = .imageLeft
            // ♟ 未読の一手があることをメニューを開かずに一目でわかるように(小さな点)
            statusItem.button?.title = openingTask != nil ? "•" : ""
        } else {
            // 古いOS等でSymbolが引けない時だけ従来の絵文字にフォールバック
            statusItem.button?.image = nil
            statusItem.button?.title = openingTask != nil ? "♟\(state.icon)" : state.icon
        }
        statusItem.button?.toolTip = micDenied ? "Sente — マイクが許可されていません"
            : hasDiagnosticIssue ? "Sente — 一部機能が使えていません(メニュー参照)" : "Sente — \(state.label)"

        let menu = NSMenu()
        if meetingRecording {
            let mins = Int(Date().timeIntervalSince(recStartedAt ?? Date()) / 60)
            menu.addItem(header("議事録 録音中(\(mins)分)", symbol: "record.circle"))
        } else if minutesGenerating {
            menu.addItem(header("議事録を作成中…(できたら通知します)", symbol: "hourglass"))
        } else if boyakiProcess != nil {
            menu.addItem(header("独り言モード(貯めて、まとめて実行)", symbol: "waveform"))
        } else {
            menu.addItem(header(state.label, symbol: state.symbol))
        }
        if micDenied {
            menu.addItem(header("マイクが許可されていません", symbol: "exclamationmark.triangle"))
            menu.addItem(item("マイクを許可する(システム設定)", #selector(openMicSettings), "m"))
        }
        // 🩺 talkは動いていても実際には聞けない/答えられない状態のことがある(耳✗/口✗/脳✗/MCP✗)。
        // 実測で「脳✗キー無効」「口✗koe.live接続不可」が繰り返し起きていたのに気づけなかったため。
        if let issue = diagnosticIssue {
            for line in humanizeDiagnostics(issue) { menu.addItem(header(line, symbol: "exclamationmark.triangle")) }
        }
        if !lastHeard.isEmpty { menu.addItem(header(truncated(stripLeadingEmoji(lastHeard)), symbol: "mic")) }
        if !lastReply.isEmpty { menu.addItem(header(truncated(stripLeadingEmoji(lastReply)), symbol: "text.bubble")) }
        menu.addItem(.separator())
        // 🔊 読み上げのワンクリックON/OFF(2026-09-02本人指示)。正本=~/.config/teai/mute
        // (te voice on/off・声「静かにして」と同じファイル)。OFFにした瞬間、いま鳴っている声も止める。
        let voiceMuted = FileManager.default.fileExists(atPath: mutePath)
        let voiceItem = item(voiceMuted ? "読み上げ(いまOFF)— クリックでON" : "読み上げ(いまON)— クリックでOFF",
                             #selector(toggleVoiceMute), "k", symbol: voiceMuted ? "speaker.slash" : "speaker.wave.2")
        voiceItem.state = voiceMuted ? .off : .on
        menu.addItem(voiceItem)
        // 🔊 声キュー: 複数セッションが並行している時だけ出す。
        // 1本だけなら voiceq はキューを通さず即再生するので、メニューも出さない(2026-09-11)。
        let vqCount = voiceQPendingCount()
        let vqParallel = voiceQParallelCount()
        if vqCount > 0 || vqParallel >= 2 || voiceQRunning() {
            let vqMenu = NSMenu()
            vqMenu.addItem(header(vqCount > 0 ? "\(vqCount)件 溜まっています" : "いま喋っています", symbol: "waveform"))
            vqMenu.addItem(.separator())
            vqMenu.addItem(item("いまのを止めて次へ", #selector(voiceQSkip), "", symbol: "forward"))
            vqMenu.addItem(item("ぜんぶ止めて捨てる", #selector(voiceQStop), "", symbol: "stop"))
            vqMenu.addItem(.separator())
            vqMenu.addItem(item("ウィンドウで見る", #selector(showVoiceQueue), "", symbol: "macwindow"))
            let vqItem = NSMenuItem(title: "声キュー(\(vqCount))", action: nil, keyEquivalent: "")
            vqItem.image = symbolImage("speaker.wave.2.badge.exclamationmark")
            vqItem.submenu = vqMenu
            menu.addItem(vqItem)
        } else if vqParallel >= 2 {
            // 並行している時は待ち0でも開ける(「いま何も溜まっていない」を確認したい本人要望)
            menu.addItem(item("声キュー(0)", #selector(showVoiceQueue), "", symbol: "speaker.wave.2"))
        }
        menu.addItem(.separator())
        // 👂 耳まわり(議事録/耳のモード/解析/音楽検知)は1つのサブメニューに畳む(2026-09-03 Elonレビュー: 34項目の壁)。
        // 緊急性の高い「停止する」「読み上げ」「一言きく」だけトップに残す。
        let listenMenu = NSMenu()
        // 📝 議事録: 録音の開始/終了(自動=Zoom検知・手動=Meet等どの会議でも)+最新を開く
        if meetingRecording {
            listenMenu.addItem(item("議事録を終える(生成する)", #selector(endMeetingManual), "g", symbol: "stop.circle"))
        } else if !minutesGenerating {
            listenMenu.addItem(item("議事録をいまから録る(会議用)", #selector(startMeetingManual), "g", symbol: "record.circle"))
        }
        if lastMinutesPath != nil {
            listenMenu.addItem(item("最新の議事録を開く", #selector(openLatestMinutes), "", symbol: "doc.text"))
        }
        listenMenu.addItem(.separator())
        // 👂 耳のモード切替(会議録音中は切替不可)
        let earMenu = NSMenu()
        let hitorigotoItem = item("独り言(貯めて、まとめて実行)", #selector(setModeHitorigoto), "", symbol: "waveform")
        hitorigotoItem.state = earMode == "hitorigoto" ? .on : .off
        earMenu.addItem(hitorigotoItem)
        let kaiwaItem = item("会話(話しかけるとすぐ返事)", #selector(setModeKaiwa), "", symbol: "bubble.left.and.bubble.right")
        kaiwaItem.state = earMode == "kaiwa" ? .on : .off
        earMenu.addItem(kaiwaItem)
        let earParent = NSMenuItem(title: "耳のモード", action: nil, keyEquivalent: "")
        earParent.image = symbolImage("ear")
        earParent.submenu = earMenu
        earParent.isEnabled = !meetingRecording
        listenMenu.addItem(earParent)
        // 📓 独り言モードの手動解析
        if earMode == "hitorigoto", boyakiPath != nil {
            listenMenu.addItem(item("いますぐまとめて解析", #selector(digestNow), "d", symbol: "sparkles"))
        }
        // 🎵 音楽再生まわり: 一時停止中はそれとわかる見出し+再開導線、再生中に聞き取り中なら手動オフ導線
        if pausedForMusic {
            listenMenu.addItem(header("音楽再生中のため聞き取りオフ", symbol: "music.note"))
            listenMenu.addItem(item("いま再開する", #selector(resumeFromMusicMenu), "", symbol: "play.circle"))
        } else if musicPlaying, process != nil || boyakiProcess != nil {
            listenMenu.addItem(item("音楽の間オフにする", #selector(pauseForMusic), "", symbol: "music.note"))
        }
        // 🎵 設定(チェックマークで現在値を表示。トグルは即時反映+永続)
        let musicMenu = NSMenu()
        let autoItem = item("検知したら聞かずに自動でオフ", #selector(toggleMusicAutoPause), "")
        autoItem.state = musicAutoPause ? .on : .off
        musicMenu.addItem(autoItem)
        let browserItem = item("ブラウザの音声も検知(YouTube等)", #selector(toggleMusicDetectBrowser), "")
        browserItem.state = musicDetectBrowser ? .on : .off
        musicMenu.addItem(browserItem)
        let musicParent = NSMenuItem(title: "音楽検知の設定", action: nil, keyEquivalent: "")
        musicParent.image = symbolImage("music.note")
        musicParent.submenu = musicMenu
        listenMenu.addItem(musicParent)
        if process == nil, boyakiProcess == nil, !meetingRecording {
            menu.addItem(item("聞き始める", #selector(startFromMenu), "s", symbol: "mic"))
            // 停止中(音楽での一時停止含む)は「押して話す」でワンショットだけ使える
            if pttProcess != nil {
                menu.addItem(header("一言ききとり中…", symbol: "waveform"))
            } else {
                menu.addItem(item("一言きく(⌃⌥スペース)", #selector(pushToTalk), "", symbol: "mic.circle"))
            }
        } else if !meetingRecording {
            menu.addItem(item("停止する", #selector(stopFromMenu), "s", symbol: "stop.circle"))
            if pttProcess == nil, boyakiProcess != nil {
                menu.addItem(item("一言きく(⌃⌥スペース)", #selector(pushToTalk), "", symbol: "mic.circle"))
            }
        }
        let listenParent = NSMenuItem(title: meetingRecording ? "耳・議事録(録音中)" : "耳・議事録", action: nil, keyEquivalent: "")
        listenParent.image = symbolImage(meetingRecording ? "record.circle" : "ear")
        listenParent.submenu = listenMenu
        menu.addItem(listenParent)
        menu.addItem(.separator())
        // ♟ 次にやること — 先手の一手(CLIの提案)と todo.md の「次」を同じ棚に置く(導線を二重にしない)
        menu.addItem(header("次にやること", symbol: "flag"))
        // ♟ 先手の一手 — fuseki watch/talk中の提案がファイルに残っていれば、クリック1つで着手できるようにする
        if let alert = openingAlert { menu.addItem(header(truncated(stripLeadingEmoji(alert)), symbol: "exclamationmark.triangle")) }
        if let task = openingTask {
            // 提案文と「やる」ボタンを1行に(2026-09-03 Elonレビュー: 二重導線)。クリック=着手、要確認なら確認ダイアログ
            let text = stripLeadingEmoji(openingSay ?? task)
            let label = imaRunning ? "実行中…: \(text)" : "先手: \(text)" + (openingRisk == "confirm" ? "(要確認)" : "")
            let runItem = item(truncated(label, 64), #selector(runOpeningTask), "",
                               symbol: openingRisk == "confirm" ? "exclamationmark.circle" : "play.circle")
            runItem.toolTip = task
            runItem.isEnabled = !imaRunning
            menu.addItem(runItem)
        } else if let say = openingSay { menu.addItem(header(truncated(stripLeadingEmoji(say)), symbol: "lightbulb")) }
        // ✅ やること — todo.md を上から。進行中は ⏱経過、未着手は ⏳見込み。先頭の未着手1件はワンクリック。
        let openTodos = todos.filter { !$0.done }
        let running = openTodos.filter { $0.startedAt != nil }
        for t in running.prefix(3) {
            var s = "進行中: \(t.title)"
            if let e = t.elapsedMin { s += "  ⏱\(Self.humanMinutes(e))" }
            if let r = t.remainingMin { s += "・あと約\(Self.humanMinutes(r))" }
            let row = NSMenuItem(title: truncated(s, 64), action: #selector(markTodoDone(_:)), keyEquivalent: "")
            row.target = self; row.representedObject = t.line
            row.image = symbolImage("hourglass"); row.toolTip = "クリックで済みにする\n\(t.prompt)"
            menu.addItem(row)
        }
        if let next = openTodos.first(where: { $0.startedAt == nil }) {
            var s = "次: \(next.title)"
            if let e = next.estimateMin { s += "  ⏳\(Self.humanMinutes(e))" }
            let nextItem = item(truncated(s, 64), #selector(startNextTodo), "",
                                symbol: next.confirm ? "exclamationmark.circle" : "play.circle")
            nextItem.toolTip = next.prompt
            menu.addItem(nextItem)
        }
        if FileManager.default.fileExists(atPath: todoFile.path) {
            let sub = NSMenu()
            var lastSection: String?? = .none
            var n = 0
            for t in openTodos {
                if lastSection != .some(t.section) {
                    if n > 0 { sub.addItem(.separator()) }
                    if let sec = t.section {
                        let secItems = openTodos.filter { $0.section == sec }
                        let secEst = secItems.compactMap { $0.estimateMin }.reduce(0, +)
                        sub.addItem(header(sec + "  \(secItems.count)件" + (secEst > 0 ? "・計\(Self.humanMinutes(secEst))" : "")))
                    }
                    lastSection = .some(t.section)
                }
                n += 1
                var label = "\(n). \(t.title)"
                if let e = t.elapsedMin { label += "  ⏱\(Self.humanMinutes(e))" + (t.remainingMin.map { "・あと約\(Self.humanMinutes($0))" } ?? "") }
                else if let e = t.estimateMin { label += "  ⏳\(Self.humanMinutes(e))" }
                let row = NSMenuItem(title: truncated(label, 64), action: nil, keyEquivalent: "")
                row.toolTip = t.prompt
                row.image = symbolImage(t.startedAt != nil ? "hourglass" : (t.confirm ? "exclamationmark.circle" : "circle"))
                let acts = NSMenu()
                let sItem = NSMenuItem(title: t.startedAt != nil ? "Senteで続ける" : "Senteで開始", action: #selector(startTodoSente(_:)), keyEquivalent: "")
                sItem.target = self; sItem.representedObject = t.line; sItem.image = symbolImage("circle.inset.filled")
                acts.addItem(sItem)
                let cItem = NSMenuItem(title: t.startedAt != nil ? "Claude Codeで続ける" : "Claude Codeで開始", action: #selector(startTodoClaude(_:)), keyEquivalent: "")
                cItem.target = self; cItem.representedObject = t.line; cItem.image = symbolImage("terminal")
                acts.addItem(cItem)
                acts.addItem(.separator())
                let dItem = NSMenuItem(title: "済みにする", action: #selector(markTodoDone(_:)), keyEquivalent: "")
                dItem.target = self; dItem.representedObject = t.line; dItem.image = symbolImage("checkmark.circle")
                acts.addItem(dItem)
                row.submenu = acts
                sub.addItem(row)
            }
            if openTodos.isEmpty { sub.addItem(header("全部済み。todo.md に次を書けばここに出ます", symbol: "checkmark.seal")) }
            sub.addItem(.separator())
            let doneItems = todos.filter { $0.done }
            if !doneItems.isEmpty {
                let doneSub = NSMenu()
                for t in doneItems.reversed().prefix(20) {
                    var s = t.title
                    if let a = t.actualMin { s += "  \(a)分" + (t.estimateMin.map { "(見込み\($0))" } ?? "") }
                    if let d = t.doneAt { s += "  \(d)" }
                    doneSub.addItem(header(truncated(s, 70), symbol: "checkmark"))
                }
                let doneParent = NSMenuItem(title: "済み(\(doneItems.count))", action: nil, keyEquivalent: "")
                doneParent.image = symbolImage("checkmark.circle"); doneParent.submenu = doneSub
                sub.addItem(doneParent)
            }
            addAgentItems(to: sub)
            sub.addItem(item("やることを編集(todo.md)", #selector(openTodoFile), "", symbol: "square.and.pencil"))
            sub.addItem(item("いま読み直す", #selector(reloadTodos), "", symbol: "arrow.clockwise"))
            let estTotal = openTodos.compactMap { $0.estimateMin }.reduce(0, +)
            var title = "やること("
            if let firstSec = openTodos.first?.section, firstSec.contains("今日") {
                let todayCount = openTodos.filter { $0.section == firstSec }.count
                title += "今日 \(todayCount)件・"
            }
            title += "残り \(openTodos.count)"
            if !running.isEmpty { title += "・進行中 \(running.count)" }
            if estTotal > 0 { title += "・見込み計 \(Self.humanMinutes(estTotal))" }
            let failedAgents = agents.filter { $0.failed }.count
            if failedAgents > 0 { title += "・エージェント失敗 \(failedAgents)" }
            title += ")"
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            parent.image = symbolImage("checklist")
            parent.submenu = sub
            menu.addItem(parent)
            // 🧭 司令塔: 30本のターミナルを立てず、1本のClaude Codeが todo.md 全件を「AIで閉じられる順・同時3件」で進め、
            // 要確認(!)は一括承認シート1枚に畳んで私のGOを1回で取る(本人決定 2026-09-03「それで行こう」)。
            if !openTodos.isEmpty {
                let auto = openTodos.filter { !$0.confirm }.count
                let gated = openTodos.count - auto
                let orch = item("全部まとめて進める(司令塔: AI \(auto)件・承認シート \(gated)件)", #selector(startOrchestrator), "",
                                symbol: "point.3.connected.trianglepath.dotted")
                orch.toolTip = "1本のClaude Codeが todo.md 全件を進めます。要確認(!)は承認シートにまとめて1回で聞きます。指示書=\(orchestratorFile.path)"
                menu.addItem(orch)
            }
        } else {
            menu.addItem(item("やること(todo.md を作る)", #selector(openTodoFile), "", symbol: "checklist"))
            addAgentItems(to: menu)
        }
        let imaTitle = (imaRunning ? "考え中…" : "いまの状況を聞く(te ima)") + (fusekiEnabled ? (fusekiProcess != nil ? "・🪨布石が見てます" : "・🪨布石 起動中") : "")
        let imaItem = item(imaTitle, #selector(runTeIma), "i", symbol: "info.circle")
        imaItem.isEnabled = !imaRunning
        menu.addItem(imaItem)
        menu.addItem(.separator())
        // 🖥 いま並行して動いているClaude Code/Sente talkの一覧+状況(本人指摘: 見えるようにしてほしい)
        if !runningSessions.isEmpty {
            let sessHeader = header("実行中のセッション(\(runningSessions.count))")
            sessHeader.toolTip = "⏱ = 起動からの経過時間(実測)"
            menu.addItem(sessHeader)
            // 作業中を先に・上位3件だけトップに出し、残りは「他N件」に畳む(7件全露出はメニューの地平線を食う)
            func sessionRow(_ s: (icon: String, label: String, tty: String?, elapsedMin: Int, last: String?)) -> NSMenuItem {
                var title = truncated(s.label, 44) + "  ⏱\(Self.humanMinutes(s.elapsedMin))"
                if let l = s.last { title += "  「\(truncated(l, 28))」" }
                let sym = s.icon == "🤖" ? "terminal" : "mic"
                guard let tty = s.tty else { let h = header(title, symbol: sym); h.toolTip = s.last; return h }
                let mi = NSMenuItem(title: title, action: #selector(focusSession(_:)), keyEquivalent: "")
                mi.toolTip = s.last.map { "最後にClaudeが言ったこと:\n" + $0 }
                mi.target = self
                mi.representedObject = tty
                mi.image = symbolImage(sym)
                return mi
            }
            let shown = runningSessions.prefix(3)
            let rest = runningSessions.dropFirst(3)
            for s in shown { menu.addItem(sessionRow(s)) }
            if !rest.isEmpty {
                let more = NSMenu()
                for s in rest { more.addItem(sessionRow(s)) }
                let moreParent = NSMenuItem(title: "他 \(rest.count) 件", action: nil, keyEquivalent: "")
                moreParent.image = symbolImage("ellipsis")
                moreParent.submenu = more
                menu.addItem(moreParent)
            }
            menu.addItem(.separator())
        }
        // 🖥 このMac — 何が動いているか(常駐/予約ジョブ/ポート/到達性)+最近の変化。数字は計測ファイルの値のみ(作らない)
        if macStatus.available {
            menu.addItem(macStatusMenuItem())
            menu.addItem(.separator())
        }
        // 🕰 過去のセッションを再開 — 再起動後でもアプリだけでワンクリックで戻れる。
        // クリックでTerminalの新タブが当時の作業ディレクトリで `te -s <id>` を開く。
        if !recentSessions.isEmpty {
            let sub = NSMenu()
            for row in recentSessions {
                let mi = NSMenuItem(title: truncated(SessionStore.displayTitle(row, withDir: true), 60),
                                    action: #selector(resumeSessionFromMenu(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = [row.id, row.directory, row.sourceDB]
                mi.toolTip = row.directory
                sub.addItem(mi)
            }
            sub.addItem(.separator())
            sub.addItem(item("一覧から選ぶ(ログを見る)…", #selector(showLogViewer), ""))
            let parent = NSMenuItem(title: "過去のセッションを再開", action: nil, keyEquivalent: "")
            parent.image = symbolImage("clock.arrow.circlepath")
            parent.submenu = sub
            menu.addItem(parent)
            menu.addItem(.separator())
        }
        // 📱 iPhone の会話 — 電話の Sente が sente.teai.io にミラーした会話を、ここから読める(クリックで開く)。
        if phone.available {
            let sub = NSMenu()
            for (i, c) in phone.conversations.prefix(10).enumerated() {
                let mi = NSMenuItem(title: truncated("\(Self.phoneTime.string(from: c.ended))  \(c.title)", 60),
                                    action: #selector(openPhoneConversation(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = i
                mi.toolTip = "\(c.deviceName) · \(c.messages.count)件"
                sub.addItem(mi)
            }
            if phone.conversations.isEmpty {
                let note = phone.lastError.map { "取得できません(\($0))" }
                    ?? (phone.fetchedAt == nil ? "取得中…" : "まだ会話がありません(iPhone で話すとここに出ます)")
                sub.addItem(header(note))
            }
            sub.addItem(.separator())
            sub.addItem(item("すべて見る…", #selector(showPhoneConversations), ""))
            sub.addItem(item("いま更新", #selector(refreshPhoneConversations), ""))
            let parent = NSMenuItem(title: "iPhone の会話", action: nil, keyEquivalent: "")
            parent.image = symbolImage("iphone")
            parent.submenu = sub
            menu.addItem(parent)
            menu.addItem(.separator())
        }
        // ➕ タスク: 追加(既定=Senteで開始)+最近のタスクは後からどちらのエンジンでも開始できる
        menu.addItem(item("タスクを追加…", #selector(addTaskFromMenu), "a", symbol: "plus.circle"))
        if !recentTasks.isEmpty {
            let sub = NSMenu()
            for t in recentTasks {
                let row = NSMenuItem(title: truncated(t, 50), action: nil, keyEquivalent: "")
                let engines = NSMenu()
                let sItem = NSMenuItem(title: "Senteで開始", action: #selector(startRecentTaskSente(_:)), keyEquivalent: "")
                sItem.target = self
                sItem.representedObject = t
                sItem.image = symbolImage("circle.inset.filled")
                engines.addItem(sItem)
                let cItem = NSMenuItem(title: "Claude Codeで開始", action: #selector(startRecentTaskClaude(_:)), keyEquivalent: "")
                cItem.target = self
                cItem.representedObject = t
                cItem.image = symbolImage("terminal")
                engines.addItem(cItem)
                row.submenu = engines
                sub.addItem(row)
            }
            sub.addItem(.separator())
            sub.addItem(item("履歴を消す", #selector(clearRecentTasks), ""))
            let parent = NSMenuItem(title: "最近のタスク", action: nil, keyEquivalent: "")
            parent.image = symbolImage("list.bullet")
            parent.submenu = sub
            menu.addItem(parent)
        }
        let nippo = NSMenuItem(title: "日報", action: nil, keyEquivalent: "")
        nippo.image = symbolImage("book.closed")
        let nippoMenu = NSMenu()
        let writeItem = item(imaRunning ? "書き込み中…" : "今日の日報を書く/更新", #selector(writeNippo), "n", symbol: "square.and.pencil")
        writeItem.isEnabled = !imaRunning
        nippoMenu.addItem(writeItem)
        let todayItem = item("今日の日報を開く", #selector(openTodayNippo), "")
        todayItem.isEnabled = FileManager.default.fileExists(atPath: nippoFile(daysAgo: 0).path)
        nippoMenu.addItem(todayItem)
        let yesterdayItem = item("昨日の日報を開く", #selector(openYesterdayNippo), "")
        yesterdayItem.isEnabled = FileManager.default.fileExists(atPath: nippoFile(daysAgo: 1).path)
        nippoMenu.addItem(yesterdayItem)
        nippoMenu.addItem(item("過去の日報(フォルダ)", #selector(openNippoFolder), "", symbol: "folder"))
        if boyakiPath != nil {
            // 毎晩21:30の自動追記と同じもの(boyaki --nippo-append)を手動で
            nippoMenu.addItem(item("独り言を日報へ追記(いま)", #selector(nippoAppendNow), "", symbol: "sparkles"))
        }
        nippo.submenu = nippoMenu
        menu.addItem(nippo)
        // 開く: 他エージェント(ターミナル/ブラウザ)+残高まわりをここに集約(本人指示2026-08-31
        // 「開くもの結構多いから見やすく」)。フラットに6項目並んでいたのを1つのサブメニューへ。
        // 中は「エージェントを開く」「状況を見る」の2グループに区切り、見た目の意味は変えない
        // (どのitemがどこへ飛ぶかは既存のまま・キー操作 t も維持)。
        let openParent = NSMenuItem(title: "開く", action: nil, keyEquivalent: "")
        openParent.image = symbolImage("arrow.up.forward.app")
        let openMenu = NSMenu()
        openMenu.addItem(item("sente cloud(ブラウザ)", #selector(openCloudWeb), "", symbol: "globe"))
        openMenu.addItem(item("Sente(ターミナル)", #selector(openSenteTerminal), "t", symbol: "terminal"))
        openMenu.addItem(item("Claude Code(ターミナル)", #selector(openClaudeTerminal), "", symbol: "terminal"))
        openMenu.addItem(item("Codex(ターミナル)", #selector(openCodexTerminal), "", symbol: "terminal"))
        openMenu.addItem(.separator())
        openMenu.addItem(item("残高チェック(ターミナル)", #selector(openBalanceTerminal), "", symbol: "dollarsign.circle"))
        openMenu.addItem(item("残高・消費グラフ(ブラウザ)", #selector(openBalanceGraph), "", symbol: "chart.line.uptrend.xyaxis"))
        openParent.submenu = openMenu
        menu.addItem(openParent)
        // その他: 設定寄り・低頻度のものを1つに畳む(ログ/布石Alpha/ログイン時起動/通知)
        let otherMenu = NSMenu()
        otherMenu.addItem(item("ログを見る", #selector(showLogViewer), "l", symbol: "doc.text.magnifyingglass"))
        // 🪨 布石: トグルON中の状態は「いまの状況を聞く」の行に一言だけ出す(嘘の精度を出さないよう「見てます」止まり)
        let fusekiItem = item("布石で見張る(裏で盤面をチェック)[Alpha]", #selector(toggleFuseki), "", symbol: "binoculars")
        fusekiItem.state = fusekiEnabled ? .on : .off
        otherMenu.addItem(fusekiItem)
        otherMenu.addItem(.separator())
        let loginItem = item("ログイン時に起動", #selector(toggleLoginItem), "")
        loginItem.state = loginItemEnabled ? .on : .off
        otherMenu.addItem(loginItem)
        if notificationDenied {
            otherMenu.addItem(header("通知が許可されていません", symbol: "bell.badge"))
            otherMenu.addItem(item("通知を許可する(システム設定)", #selector(openNotificationSettings), ""))
        }
        let otherParent = NSMenuItem(title: notificationDenied ? "その他(通知が未許可)" : "その他", action: nil, keyEquivalent: "")
        otherParent.image = symbolImage("ellipsis.circle")
        otherParent.submenu = otherMenu
        menu.addItem(otherParent)
        menu.addItem(.separator())
        menu.addItem(item("Sente について", #selector(showAbout), ""))
        menu.addItem(.separator())
        menu.addItem(item("Sente を終了", #selector(quit), "q"))
        statusItem.menu = menu
    }

    /// SF Symbolのモノクロ(テンプレート)画像。メニュー/メニューバー共通。
    private func symbolImage(_ name: String, size: CGFloat = 13) -> NSImage? {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .regular))
        img?.isTemplate = true
        return img
    }

    private func header(_ title: String, symbol: String? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        if let symbol { i.image = symbolImage(symbol) }
        return i
    }

    /// CLI由来のテキストは絵文字始まり(💬📓🎵…)のことがある。メニューはSF Symbolで
    /// 意味を示すので、先頭の絵文字は剥がして文字だけにする(二重アイコン防止)。
    private func stripLeadingEmoji(_ s: String) -> String {
        var t = Substring(s)
        while let f = t.unicodeScalars.first, f.value > 0x2000, f.properties.isEmojiPresentation || f.properties.isEmoji {
            t = t.dropFirst()
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// CLI出力には既に絵文字が付いていることがあり、そのまま前置すると二重になる
    /// (実測: メニューに「💬 💬 ...」「🩺 🩺 ...」と出るバグがあった)。
    private func withEmoji(_ emoji: String, _ text: String) -> String {
        text.hasPrefix(emoji) ? text : "\(emoji) \(text)"
    }

    /// 分 → "42分" / "1h05m" / "2d03h"(メニュー幅を食わない最短表記)
    static func humanMinutes(_ m: Int) -> String {
        if m < 60 { return "\(m)分" }
        if m < 1440 { return String(format: "%dh%02dm", m / 60, m % 60) }
        return String(format: "%dd%02dh", m / 1440, (m % 1440) / 60)
    }

    /// NSMenuItemは折り返されないため、長い文言は要点だけ残して省略する。
    private func truncated(_ s: String, _ limit: Int = 48) -> String {
        s.count > limit ? String(s.prefix(limit)) + "…" : s
    }

    /// 🩺診断行の生文字列("耳✗(録音が読めません) 口✓(koe.live) ...")を、非エンジニアにも
    /// 伝わる短文に変換する。✗があるものだけ見せる(✓は正常なのでノイズになる)。
    private func humanizeDiagnostics(_ raw: String) -> [String] {
        var out: [String] = []
        if raw.contains("耳✗") { out.append("声が聞けていません") }
        if raw.contains("口✗") { out.append("声で返せません(接続エラー)") }
        if raw.contains("脳✗") { out.append("考えられません(キー無効/接続不可)") }
        if raw.contains("MCP✗") { out.append("一部ツールが使えません") }
        return out
    }

    private func item(_ title: String, _ action: Selector, _ key: String, symbol: String? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        if let symbol { i.image = symbolImage(symbol) }
        return i
    }

    @objc private func resumeSessionFromMenu(_ sender: NSMenuItem) {
        guard let arr = sender.representedObject as? [String], arr.count == 3 else { return }
        // 橋渡しimportで数秒かかることがあるため裏で実行する
        DispatchQueue.global(qos: .userInitiated).async {
            SessionStore.resume(id: arr[0], directory: arr[1], sourceDB: arr[2])
        }
    }

    @objc private func startFromMenu() { pausedForMusic = false; restartCount = 0; startEar() }
    @objc private func stopFromMenu() { userStoppedEar = true; stopEar() }
    @objc private func showLogViewer() { logViewer.show() }
    @objc private func openPhoneConversation(_ sender: NSMenuItem) {
        guard let i = sender.representedObject as? Int else { return }
        phoneViewer.show(phone.conversations, select: i)
    }
    @objc private func showPhoneConversations() { phoneViewer.show(phone.conversations, select: 0) }
    @objc private func refreshPhoneConversations() {
        phone.refresh { [weak self] in
            self?.render()
            if self?.phoneViewer.isVisible == true, let convs = self?.phone.conversations { self?.phoneViewer.show(convs, select: 0) }
        }
    }
    @objc private func openMicSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc private func quit() { stop(); NSApp.terminate(nil) }

    // MARK: - 先手の一手 / te ima

    /// `te run "<task>"` / `te ima` をバックグラウンドで一回だけ実行し、完了後に結果をメニューへ反映する。
    /// talk の常駐プロセスとは別の使い捨てプロセスなので richPath/PATH の扱いは start() と揃える。
    private func runTeCommand(_ args: [String], onDone: @escaping (String) -> Void) {
        guard let sente = sentePath, !imaRunning else { return }
        imaRunning = true
        DispatchQueue.main.async { self.render() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        let quoted = args.map { "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: " ")
        p.arguments = ["-c", "exec '\(sente)' \(quoted)"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = richPath
        p.environment = env
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        // 🪤 出力が長い自律タスク(例: 何十行も報告するte run)がパイプバッファ(~64KB)を
        // 超えると、terminationHandlerでまとめて読む方式は子プロセスの書き込みブロック→
        // 終了できない→terminationHandlerが永遠に呼ばれない、という無音のハングになる。
        // readabilityHandlerで都度吸い出し、終了時に結合する。
        var collected = Data()
        pipe.fileHandleForReading.readabilityHandler = { fh in
            let chunk = fh.availableData
            if !chunk.isEmpty { collected.append(chunk) }
        }
        p.terminationHandler = { [weak self] _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            let text = String(data: collected, encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                self?.imaRunning = false
                onDone(text)
            }
        }
        do { try p.run() } catch {
            imaRunning = false
            lastReply = error.localizedDescription
            DispatchQueue.main.async { self.render() }
        }
    }

    @objc private func runOpeningTask() {
        guard let task = openingTask else { return }
        // ⚠ お金/対外送信/削除など実際に影響のある一手はワンクリックで即実行せず、
        // 一度確認を挟む(2026-08-29実障害: 広告キャンペーン判断タスクが一クリックで
        // 実行されかけた)。CLI側(talkの声「やって」)も同様に二段階確認になっている。
        if openingRisk == "confirm" {
            let a = NSAlert()
            a.messageText = "実際に影響のある操作です"
            a.informativeText = "お金・対外送信・削除など後戻りしにくい操作の可能性があります。内容:\n\n\(task)\n\n本当に実行しますか?"
            a.addButton(withTitle: "実行する")
            a.addButton(withTitle: "キャンセル")
            a.alertStyle = .warning
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        runTeCommand(["run", task]) { [weak self] output in
            guard let self else { return }
            let lastLine = output.split(separator: "\n").last.map(String.init) ?? "完了しました"
            self.lastReply = String(lastLine.prefix(120))
            try? FileManager.default.removeItem(at: self.configDir.appendingPathComponent("opening-task"))
            try? FileManager.default.removeItem(at: self.configDir.appendingPathComponent("opening-risk"))
            try? FileManager.default.removeItem(at: self.configDir.appendingPathComponent("opening-drop-armed"))
            self.openingTask = nil
            self.openingRisk = "safe"
            self.render()
        }
    }

    @objc private func runTeIma() {
        runTeCommand(["ima"]) { [weak self] output in
            guard let self else { return }
            self.checkOpeningTask()
            let a = NSAlert()
            a.messageText = "いまの状況"
            a.informativeText = output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "取得できませんでした(TEAI_API_KEY / ネットワークを確認してください)" : output
            a.addButton(withTitle: "閉じる")
            a.runModal()
        }
    }

    // MARK: - 日報 (/nippo と同じ正本 ~/workspace/tasks/nippo/ を見る)

    private var nippoDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("workspace/tasks/nippo")
    }

    private func nippoFile(daysAgo: Int) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        let day = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        return nippoDir.appendingPathComponent(f.string(from: day) + ".md")
    }

    @objc private func openTodayNippo() { NSWorkspace.shared.open(nippoFile(daysAgo: 0)) }
    @objc private func openYesterdayNippo() { NSWorkspace.shared.open(nippoFile(daysAgo: 1)) }
    @objc private func openNippoFolder() { NSWorkspace.shared.open(nippoDir) }

    @objc private func writeNippo() {
        // CLI 側の /nippo と同じ手順書(~/.claude/commands/nippo.md)に従わせる。
        // 手順書が無い環境でも自走できるよう要点(収集スクリプト・正本パス・実測のみ)は指示に含める。
        // 2026-09-05: エージェント形式(te agent)に寄せる。定義 ~/.config/sente/agent/nippo.md があれば
        // `te agent run nippo`(launchd の 21:30 定期実行と完全に同じ定義・同じ経路)。
        // 定義が無い環境だけ、従来どおり要点を直接指示する(二重定義を増やさないため task はフォールバック専用)。
        let agentDef = NSHomeDirectory() + "/.config/sente/agent/nippo.md"
        let args: [String]
        if FileManager.default.fileExists(atPath: agentDef) {
            args = ["agent", "run", "nippo"]
        } else {
            let task = "今日の日報を書いて。手順書 ~/.claude/commands/nippo.md があればそれに従う。"
                + "無ければ: bash ~/.claude/daily/nippo-collect.sh の出力(全リポジトリの当日実コミット)を材料に、"
                + "~/workspace/tasks/nippo/今日の日付(YYYY-MM-DD).md へ成果単位で実測のみ・PR番号つきでまとめ、"
                + "既存ファイルがあれば手書き行を消さずマージし、workspace リポジトリにコミットする。"
            args = ["run", task]
        }
        runTeCommand(args) { [weak self] output in
            guard let self else { return }
            let lastLine = output.split(separator: "\n").last.map(String.init) ?? "完了しました"
            self.lastReply = String(lastLine.prefix(120))
            self.render()
            let today = self.nippoFile(daysAgo: 0)
            if FileManager.default.fileExists(atPath: today.path) {
                NSWorkspace.shared.open(today)
            }
        }
    }

    // MARK: - 他エージェントのランチャー (sente cloud / Sente / Claude Code / Codex)

    @objc private func openCloudWeb() { NSWorkspace.shared.open(URL(string: "https://sente.teai.io")!) }

    /// Terminalで ~/workspace を起点にコマンドを1つ開く。AppleScript(要Automation許可)でなく
    /// .commandファイル経由なので追加の権限ダイアログが出ない。
    private func openInTerminal(name: String, command: String) {
        let file = configDir.appendingPathComponent("launch-\(name).command")
        let script = "#!/bin/sh\nexport PATH=\"\(richPath)\"\ncd \"$HOME/workspace\" 2>/dev/null || cd \"$HOME\"\nexec \(command)\n"
        try? script.write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        NSWorkspace.shared.open(file)
    }

    @objc private func openSenteTerminal() { openInTerminal(name: "sente", command: "te") }
    @objc private func openClaudeTerminal() { openInTerminal(name: "claude", command: "claude") }
    @objc private func openCodexTerminal() { openInTerminal(name: "codex", command: "codex") }

    // MARK: - ➕ タスク追加(既定=Senteで開始・同じタスクをClaude Codeでも開始できる)

    /// 最近追加したタスク(新しい順・最大7件)。メニューからどちらのエンジンでも再実行できる。
    private var recentTasks: [String] {
        get { UserDefaults.standard.stringArray(forKey: "recentTasks") ?? [] }
        set { UserDefaults.standard.set(Array(newValue.prefix(7)), forKey: "recentTasks") }
    }

    private func shellQuote(_ s: String) -> String { s.replacingOccurrences(of: "'", with: "'\\''") }

    /// タスクを指定エンジンのターミナルで開始する。どちらも対話セッションに初期プロンプトとして
    /// 渡すので、開始後もそのまま続きを話せる(sente=te TUIの--prompt / claude=位置引数)。
    private func startTask(_ task: String, engine: String, remember: Bool = true, label: String? = nil) {
        if remember {
            var tasks = recentTasks.filter { $0 != task }
            tasks.insert(task, at: 0)
            recentTasks = tasks
        }
        let cmd = engine == "claude" ? "claude '\(shellQuote(task))'"
                                     : "te --prompt '\(shellQuote(task))'"
        openInTerminal(name: "task-\(engine)", command: cmd)
        lastReply = "タスクを\(engine == "claude" ? "Claude Code" : "Sente")で開始: \(label ?? task)"
        render()
    }

    // MARK: - ✅ やること(todo.md)

    private var todoFile: URL { configDir.appendingPathComponent("todo.md") }

    /// todo.md の更新時刻が変わった時だけ読み直す(15秒毎・他プロセスの編集を拾う)。
    private func checkTodos() {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: todoFile.path)[.modificationDate] as? Date) ?? nil
        guard mtime != todoMtime else { return }
        todoMtime = mtime
        todos = TodoStore.load(todoFile)
        DispatchQueue.main.async { self.render() }
    }

    private func todo(forLine line: Int) -> TodoItem? { todos.first { $0.line == line } }

    /// やることを開始する。指示文の末尾に「済んだら todo.md の行を [x] に」を添えるので、
    /// エージェント側で完了まで閉じられる(人間の手が要る部分は手順を出して止まる約束も添える)。
    private func startTodo(_ t: TodoItem, engine: String) {
        if t.confirm {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "お金・対外送信・削除を含む可能性があります"
            a.informativeText = "\(t.title)\n\n\(t.prompt)\n\n開始しますか?(実際の送信・決済・削除の前にはもう一度確認が入ります)"
            a.addButton(withTitle: "開始する")
            a.addButton(withTitle: "キャンセル")
            a.alertStyle = .warning
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        let prompt = """
        やること「\(t.title)」\(t.estimateMin.map { "(見込み \($0)分)" } ?? "")

        \(t.prompt)

        ルール: 人間の手が要る部分(電話・GUI操作・決済・対外送信)は手順を1画面にまとめて止まり、私のGOを待つ。\
        済んだら \(todoFile.path) の該当行(「\(t.title)」・\(t.line)行目付近)の `- [ ]` を `- [x]` に書き換える。
        """
        startTask(prompt, engine: engine, remember: false, label: t.title)
        TodoStore.markStarted(todoFile, line: t.line)
        todoMtime = nil
        checkTodos()
    }

    @objc private func startNextTodo() {
        guard let t = todos.first(where: { !$0.done && $0.startedAt == nil }) ?? todos.first(where: { !$0.done }) else { return }
        startTodo(t, engine: "sente")
    }
    @objc private func startTodoSente(_ sender: NSMenuItem) {
        if let l = sender.representedObject as? Int, let t = todo(forLine: l) { startTodo(t, engine: "sente") }
    }
    @objc private func startTodoClaude(_ sender: NSMenuItem) {
        if let l = sender.representedObject as? Int, let t = todo(forLine: l) { startTodo(t, engine: "claude") }
    }
    @objc private func markTodoDone(_ sender: NSMenuItem) {
        guard let l = sender.representedObject as? Int, let t = todo(forLine: l) else { return }
        TodoStore.markDone(todoFile, line: l)
        lastReply = "済み: \(t.title)"
        todoMtime = nil
        checkTodos()
    }
    @objc private func openTodoFile() {
        if !FileManager.default.fileExists(atPath: todoFile.path) {
            try? TodoStore.template.write(to: todoFile, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(todoFile)
    }
    @objc private func reloadTodos() { todoMtime = nil; checkTodos() }

    // MARK: - 🤖 自動エージェント(te agent)
    /// やること▸ の末尾に「自動エージェント」棚を足す(名前・予定時刻・直近結果。▸ いま実行/ログ/定義)
    private func addAgentItems(to m: NSMenu) {
        guard !agents.isEmpty else { return }
        m.addItem(.separator())
        let failed = agents.filter { $0.failed }.count
        let h = header("自動エージェント(\(agents.count)" + (failed > 0 ? "・失敗 \(failed)" : "") + ")", symbol: "gearshape.2")
        h.toolTip = "te agent で配備した定期実行。定義= ~/.config/sente/agent/<name>.md / 記録= ~/Library/Logs/Sente/agents.jsonl"
        m.addItem(h)
        for a in agents { m.addItem(agentMenuItem(a)) }
    }
    private func agentMenuItem(_ a: AgentInfo) -> NSMenuItem {
        var status = "未実行"
        var symbol = "clock"
        if a.running {
            status = "実行中(\(AgentStore.shortTime(a.lastStart ?? ""))〜)"; symbol = "hourglass"
        } else if a.stale {
            status = "終了記録なし(開始 \(AgentStore.shortTime(a.lastStart ?? "")))"; symbol = "questionmark.circle"
        } else if let e = a.lastEnd {
            if (e.exit ?? 0) == 0 { status = "成功 \(AgentStore.shortTime(e.ts))"; symbol = "checkmark.circle" }
            else { status = "失敗 exit \(e.exit ?? -1) \(AgentStore.shortTime(e.ts))"; symbol = "exclamationmark.triangle" }
            if let t = e.tries, t > 1 { status += "(再試行\(t)回)" }
        }
        let parent = NSMenuItem(title: truncated("\(a.name)  \(a.schedule)  \(status)", 64), action: nil, keyEquivalent: "")
        parent.image = symbolImage(symbol)
        if !a.description.isEmpty { parent.toolTip = a.description }
        let sub = NSMenu()
        let run = item(imaRunning ? "実行中…(別の te が動いています)" : "いま実行(te agent run \(a.name))", #selector(runAgentNow(_:)), "", symbol: "play")
        run.representedObject = a.name
        run.isEnabled = !imaRunning
        sub.addItem(run)
        let log = item("ログを開く", #selector(openAgentLog(_:)), "", symbol: "doc.text")
        log.representedObject = a.name
        log.isEnabled = FileManager.default.fileExists(atPath: AgentStore.logFile(a.name).path)
        sub.addItem(log)
        let def = item("定義を開く(\(a.name).md)", #selector(openAgentDef(_:)), "", symbol: "square.and.pencil")
        def.representedObject = a.name
        def.isEnabled = FileManager.default.fileExists(atPath: AgentStore.defFile(a.name).path)
        sub.addItem(def)
        parent.submenu = sub
        return parent
    }
    /// 配備一覧+直近結果を読み直し、前回見た時刻より新しい end(exit≠0)を通知する。
    /// 初回起動は「今」を既読にして過去の失敗を蒸し返さない。
    private func checkAgents() {
        agents = AgentStore.load()
        var seen = UserDefaults.standard.string(forKey: Self.agentSeenKey)
        if seen == nil {
            seen = AgentStore.nowString()
            UserDefaults.standard.set(seen, forKey: Self.agentSeenKey)
        }
        guard let seenTs = seen else { return }
        var newest = seenTs
        for (name, run) in AgentStore.events() where run.event == "end" && run.ts > seenTs {
            if run.ts > newest { newest = run.ts }
            if (run.exit ?? 0) != 0 {
                notify(title: "エージェント \(name) が失敗しました",
                       body: "exit \(run.exit ?? -1)・\(AgentStore.shortTime(run.ts))。タップでログを開きます(agent-\(name).log)",
                       categoryID: Self.agentFailCategoryID, userInfo: ["agent": name])
            }
        }
        if newest != seenTs { UserDefaults.standard.set(newest, forKey: Self.agentSeenKey) }
    }
    @objc private func runAgentNow(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        runTeCommand(["agent", "run", name]) { [weak self] output in
            guard let self else { return }
            let lastLine = output.split(separator: "\n").last.map(String.init) ?? "完了しました"
            self.lastReply = String(lastLine.prefix(120))
            self.checkAgents()
            self.render()
        }
    }
    @objc private func openAgentLog(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        NSWorkspace.shared.open(AgentStore.logFile(name))
    }
    @objc private func openAgentDef(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        NSWorkspace.shared.open(AgentStore.defFile(name))
    }

    // MARK: - 🧭 司令塔(todo.md 全件をまとめて進める)

    private var orchestratorFile: URL { configDir.appendingPathComponent("todo-orchestrator.md") }

    @objc private func startOrchestrator() {
        let open = todos.filter { !$0.done }
        let auto = open.filter { !$0.confirm }
        let gated = open.filter { $0.confirm }
        let est = open.compactMap { $0.estimateMin }.reduce(0, +)
        if !FileManager.default.fileExists(atPath: orchestratorFile.path) {
            try? TodoStore.orchestratorTemplate.write(to: orchestratorFile, atomically: true, encoding: .utf8)
        }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "全部まとめて進めます"
        a.informativeText = """
        残り \(open.count) 件(見込み計 \(Self.humanMinutes(est)))を 1 本の Claude Code が進めます。

        ・AIで閉じられる \(auto.count) 件 → 同時最大3件・リポジトリ別に分離して実行、済んだ行は [x] に
        ・要確認(!) \(gated.count) 件 → 先に「承認シート」1枚にまとめて開きます。GO/直す/やらない を1回で返せます
        ・お金・対外送信・削除は GO が出るまで実行しません

        指示書: \(orchestratorFile.path)(編集可)
        """
        a.addButton(withTitle: "始める")
        a.addButton(withTitle: "指示書を見る")
        a.addButton(withTitle: "キャンセル")
        switch a.runModal() {
        case .alertFirstButtonReturn:
            let prompt = "\(orchestratorFile.path) を読み、その指示どおりに \(todoFile.path) の未完了タスクをすべて進めてください。最初に承認シートを作って開くこと。"
            startTask(prompt, engine: "claude", remember: false, label: "司令塔(全部まとめて進める)")
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(orchestratorFile)
        default: break
        }
    }

    @objc private func addTaskFromMenu() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "タスクを追加"
        a.informativeText = "何をやってほしいか書いてください。Enter(既定)でSenteが開始します。"
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        tf.placeholderString = "例: READMEのTODOを整理して"
        a.accessoryView = tf
        a.addButton(withTitle: "Senteで開始")
        a.addButton(withTitle: "Claude Codeで開始")
        a.addButton(withTitle: "キャンセル")
        a.window.initialFirstResponder = tf
        let res = a.runModal()
        let task = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return }
        switch res {
        case .alertFirstButtonReturn:  startTask(task, engine: "sente")
        case .alertSecondButtonReturn: startTask(task, engine: "claude")
        default: break
        }
    }

    @objc private func startRecentTaskSente(_ sender: NSMenuItem) {
        if let t = sender.representedObject as? String { startTask(t, engine: "sente") }
    }
    @objc private func startRecentTaskClaude(_ sender: NSMenuItem) {
        if let t = sender.representedObject as? String { startTask(t, engine: "claude") }
    }
    @objc private func clearRecentTasks() {
        UserDefaults.standard.removeObject(forKey: "recentTasks")
        render()
    }
    // 残高一覧+APIキー台帳+低残高アラート(毎時launchd jp.yukihamada.balance-watch)の手動確認
    @objc private func openBalanceTerminal() {
        openInTerminal(name: "balance", command: "python3 \"$HOME/.claude/tools/balance-watch/balance_check.py\"")
    }

    // 残高推移+消費レート(1h/24h/7d/30d)のグラフHTMLを生成してブラウザで開く。
    // 生成スクリプト自身が `open` するのでターミナル窓は出さない。
    @objc private func openBalanceGraph() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "python3 \"$HOME/.claude/tools/balance-watch/balance_check.py\" --graph >/dev/null 2>&1"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = richPath
        p.environment = env
        try? p.run()
    }

    // MARK: - ログイン項目 / About

    private var loginItemEnabled: Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    @objc private func toggleLoginItem() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            lastReply = "ログイン項目の変更に失敗: \(error.localizedDescription)"
        }
        render()
    }

    @objc private func showAbout() {
        let a = NSAlert()
        a.messageText = "Sente"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        a.informativeText = "声で使う teai.io コーディングエージェント v\(version)\n\n中身は CLI(te talk)をそのまま走らせるだけの薄い殻です。\nhttps://teai.io"
        a.addButton(withTitle: "閉じる")
        a.runModal()
    }
}

// MARK: - ログビューア
//
// talkラッパー(te-install.sh)のプレーンテキストログは、声認識や診断の薄い実況で
// しかなく、実際に何を話し何をしたかは中身のopencodeエンジンのセッション
// (~/.local/share/opencode/opencode.db)にしか残っていない。なので生ログではなく
// opencodeのDBを直接(読み取り専用で)見て、セッション一覧+会話本文の2ペインで見せる。
final class LogViewerController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow?
    private let logURL: URL   // talkラッパーの生ログ。フォールバック+デバッグ用にFinderボタンだけ残す
    private var sessions: [SessionStore.Row] = []
    private var tableView: NSTableView!
    private var textView: NSTextView!
    private var resumeButton: NSButton!

    init(logURL: URL) {
        self.logURL = logURL
        super.init()
    }

    func show() {
        loadSessions()
        if window == nil { buildWindow() }
        tableView.reloadData()
        if !sessions.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            renderSession(sessions[0])
        } else {
            textView.string = "まだセッションがありません。(opencode.dbが見つからないか、まだ使っていません)"
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func loadSessions() {
        // 声(talk=ホーム)だけでなく、各プロジェクトで使ったCLIセッションも全部見せる
        // (本人要望: senteのCLIのセッションを細かく見たい)。ディレクトリは行のツールチップと
        // 本文ヘッダに出す。会話が実質無いセッションの除外はSessionStore側の基準に従う。
        sessions = SessionStore.recentSessions(limit: 200)
    }

    private func buildWindow() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 520),
                            styleMask: [.titled, .closable, .resizable, .miniaturizable],
                            backing: .buffered, defer: false)
        win.title = "Sente ログ"
        win.minSize = NSSize(width: 480, height: 300)
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 880, height: 520))

        let footer = NSView(frame: NSRect(x: 0, y: 0, width: 880, height: 32))
        footer.autoresizingMask = [.width]
        let openInFinderButton = NSButton(title: "talkの生ログをFinderで開く", target: self, action: #selector(openInFinder))
        openInFinderButton.bezelStyle = .rounded
        openInFinderButton.controlSize = .small
        openInFinderButton.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(openInFinderButton)
        // ▶ 選択中のセッションをTerminalで再開(te -s <id>)。再起動後でもここから即戻れる。
        let resume = NSButton(title: "▶ このセッションを再開", target: self, action: #selector(resumeSelected))
        resume.bezelStyle = .rounded
        resume.controlSize = .small
        resume.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(resume)
        self.resumeButton = resume
        NSLayoutConstraint.activate([
            openInFinderButton.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 10),
            openInFinderButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            resume.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -10),
            resume.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])

        let split = NSSplitView(frame: NSRect(x: 0, y: 32, width: 880, height: 488))
        split.autoresizingMask = [.width, .height]
        split.isVertical = true
        split.dividerStyle = .thin

        // 🪤 NSScrollViewをゼロサイズのまま addSubview すると、NSSplitView が
        // 右ペイン(本文)に幅を割り振らずテーブルだけで埋めてしまう(実機で確認)。
        // 明示的な初期frameを与えてから追加する。
        let listWidth: CGFloat = 280
        let listScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: listWidth, height: 488))
        listScroll.hasVerticalScroller = true
        listScroll.borderType = .noBorder
        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 24
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        col.width = listWidth - 4
        table.addTableColumn(col)
        table.dataSource = self
        table.delegate = self
        listScroll.documentView = table
        self.tableView = table

        let textScroll = NSScrollView(frame: NSRect(x: listWidth, y: 0, width: 880 - listWidth, height: 488))
        textScroll.hasVerticalScroller = true
        textScroll.borderType = .noBorder
        let tv = NSTextView(frame: textScroll.bounds)
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        tv.textContainerInset = NSSize(width: 10, height: 10)
        tv.textContainer?.widthTracksTextView = true
        tv.autoresizingMask = [.width, .height]
        textScroll.documentView = tv
        self.textView = tv

        split.addSubview(listScroll)
        split.addSubview(textScroll)

        container.addSubview(split)
        container.addSubview(footer)
        win.contentView = container
        self.window = win
        // addSubviewでレイアウトが確定した後でないと setPosition が効かない(実機で確認)
        split.setPosition(listWidth, ofDividerAt: 0)
    }

    @objc private func openInFinder() { NSWorkspace.shared.open(logURL) }

    @objc private func resumeSelected() {
        let row = tableView.selectedRow
        guard row >= 0, row < sessions.count else { return }
        let s = sessions[row]
        DispatchQueue.global(qos: .userInitiated).async {
            SessionStore.resume(id: s.id, directory: s.directory, sourceDB: s.sourceDB)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { sessions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let s = sessions[row]
        let field = NSTextField(labelWithString: SessionStore.displayTitle(s, withDir: true))
        field.font = .systemFont(ofSize: 12)
        field.toolTip = "\(s.directory)\n\(s.id)"
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < sessions.count else { textView.string = ""; return }
        renderSession(sessions[row])
    }

    private static let timeOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// ツール呼び出し1件を「🔧 名前 — 要点」の1行に要約する。中身全部はノイズなので、
    /// bashはコマンド・ファイル系はパス、それ以外はdescription/JSON先頭だけ。
    private func toolSummary(_ part: [String: Any]) -> String? {
        guard let tool = part["tool"] as? String else { return nil }
        let state = part["state"] as? [String: Any]
        let input = state?["input"] as? [String: Any]
        let status = state?["status"] as? String
        var hint = ""
        if let cmd = input?["command"] as? String { hint = cmd }
        else if let path = input?["filePath"] as? String ?? input?["file_path"] as? String { hint = (path as NSString).lastPathComponent }
        else if let desc = input?["description"] as? String { hint = desc }
        else if let pattern = input?["pattern"] as? String { hint = pattern }
        let mark = status == "error" ? "❌" : "🔧"
        let oneLine = hint.replacingOccurrences(of: "\n", with: " ⏎ ")
        return "\(mark) \(tool)\(oneLine.isEmpty ? "" : " — \(oneLine.prefix(100))")"
    }

    /// セッションの発話(role=user)・応答(role=assistant)のtextに加えて、何をしたか
    /// (toolの実行1行サマリ)も薄く見せる(本人要望: 細かく見たい)。step-start/finish等の
    /// 内部イベントは引き続き出さない。冒頭にディレクトリ等のヘッダを付ける。
    private func renderSession(_ session: SessionStore.Row) {
        let rows = SessionStore.query("""
            SELECT json_extract(m.data,'$.role') as role, p.data as part_data, p.time_created as t
            FROM message m JOIN part p ON p.message_id = m.id
            WHERE m.session_id = '\(SessionStore.sqlEscape(session.id))'
            ORDER BY p.time_created ASC
        """, db: session.sourceDB)
        let attr = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: 13)
        let fontBold = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let fontTool = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let costStr = session.cost > 0 ? String(format: "  💰$%.3f", session.cost) : ""
        attr.append(NSAttributedString(string: "📁 \(session.directory)\(costStr)\n\(session.id)\n\n",
                                        attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: fontTool]))
        for row in rows {
            guard let role = row["role"] as? String,
                  let partDataStr = row["part_data"] as? String,
                  let partJSON = partDataStr.data(using: .utf8),
                  let part = try? JSONSerialization.jsonObject(with: partJSON) as? [String: Any] else { continue }
            let type = part["type"] as? String
            if type == "tool", role == "assistant" {
                if let line = toolSummary(part) {
                    attr.append(NSAttributedString(string: "    " + line + "\n",
                                                    attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: fontTool]))
                }
                continue
            }
            guard type == "text", var text = part["text"] as? String, !text.isEmpty else { continue }
            // 声認識した発話の後ろにシステムプロンプト(音声対話モードの指示文)が
            // そのまま連結されているため、実際の発話部分だけを切り出す。
            if role == "user", let range = text.range(of: " — (音声対話モード") {
                text = String(text[text.startIndex..<range.lowerBound])
            }
            let isUser = role == "user"
            var prefix = isUser ? "🗣 " : "💬 "
            if isUser, let ms = (row["t"] as? NSNumber)?.doubleValue {
                prefix = "[\(Self.timeOnly.string(from: Date(timeIntervalSince1970: ms / 1000)))] " + prefix
            }
            attr.append(NSAttributedString(string: prefix + text + "\n\n",
                                            attributes: [.foregroundColor: isUser ? NSColor.systemBlue : NSColor.labelColor,
                                                         .font: isUser ? fontBold : font]))
        }
        textView.textStorage?.setAttributedString(
            attr.length > 0 ? attr : NSAttributedString(string: "(このセッションには会話がありません)", attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
    }

    func windowWillClose(_ notification: Notification) { window = nil }
}

// MARK: - 🔊 声キュー(voiceq)のウィンドウ

/// 複数ターミナルから溜まった読み上げを、メニューだけでなくウィンドウで一覧したい
/// (本人要望 2026-09-11)。中身・順番・件数がひと目で分かり、ここから止められる。
final class VoiceQueueController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow?
    private var tableView: NSTableView!
    private var statusLabel: NSTextField!
    private var items: [(session: String, text: String)] = []
    private var timer: Timer?
    private let onStop: () -> Void
    private let onSkip: () -> Void

    private var pendingDir: String { NSHomeDirectory() + "/.config/teai/voiceq/pending" }
    private var lockPath: String { NSHomeDirectory() + "/.config/teai/voiceq/worker.lock" }

    /// 直近に発話したセッション数。1本なら voiceq はキューを通さず即再生する。
    private func parallelCount() -> Int {
        let p = NSHomeDirectory() + "/.config/teai/voiceq/recent.json"
        guard let d = FileManager.default.contents(atPath: p),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return 0 }
        let now = Date().timeIntervalSince1970
        return o.values.reduce(0) { acc, v in
            guard let t = v as? Double else { return acc }
            return acc + (now - t < 180 ? 1 : 0)
        }
    }

    init(onStop: @escaping () -> Void, onSkip: @escaping () -> Void) {
        self.onStop = onStop
        self.onSkip = onSkip
        super.init()
    }

    func show() {
        if window == nil { buildWindow() }
        refresh()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // 溜まり方は逐次変わるので、開いている間だけ1秒ごとに更新する
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        load()
        tableView.reloadData()
        let running = FileManager.default.fileExists(atPath: lockPath)
        let parallel = parallelCount()
        statusLabel.stringValue = items.isEmpty
            ? (running ? "いま喋っています(待ち 0件)"
                       : (parallel >= 2 ? "待ちはありません(いまは各セッションがそのまま喋ります)"
                                        : "いまは1本だけなので、キューを通さずそのまま喋ります"))
            : "\(items.count)件 待っています" + (running ? " — いま喋っています" : "")
    }

    private func load() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: pendingDir) else { items = []; return }
        var out: [(String, String)] = []
        for n in names.sorted() where n.hasSuffix(".json") {
            guard let d = fm.contents(atPath: pendingDir + "/" + n),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let t = o["text"] as? String else { continue }
            out.append(((o["session"] as? String) ?? "?", t))
        }
        items = out
    }

    private func buildWindow() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 440),
                            styleMask: [.titled, .closable, .resizable, .miniaturizable],
                            backing: .buffered, defer: false)
        win.title = "声キュー"
        win.minSize = NSSize(width: 420, height: 260)
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 440))

        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(status)
        self.statusLabel = status

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 720, height: 380))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 34
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        col.width = 700
        table.addTableColumn(col)
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        self.tableView = table
        container.addSubview(scroll)

        let skip = NSButton(title: "いまのを止めて次へ", target: self, action: #selector(doSkip))
        skip.bezelStyle = .rounded
        let stop = NSButton(title: "ぜんぶ止めて捨てる", target: self, action: #selector(doStop))
        stop.bezelStyle = .rounded
        let reload = NSButton(title: "再読み込み", target: self, action: #selector(doReload))
        reload.bezelStyle = .rounded
        for b in [skip, stop, reload] { b.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(b) }

        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            status.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: reload.topAnchor, constant: -10),
            reload.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            reload.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            skip.trailingAnchor.constraint(equalTo: stop.leadingAnchor, constant: -8),
            skip.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            stop.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            stop.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])

        win.contentView = container
        self.window = win
    }

    @objc private func doStop() { onStop(); refresh() }
    @objc private func doSkip() { onSkip(); refresh() }
    @objc private func doReload() { refresh() }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count else { return nil }
        let it = items[row]
        let cell = NSView()
        let body = NSTextField(labelWithString: it.text)
        body.font = .systemFont(ofSize: 12)
        body.lineBreakMode = .byTruncatingTail
        body.translatesAutoresizingMaskIntoConstraints = false
        let tag = NSTextField(labelWithString: String(it.session.prefix(14)))
        tag.font = .systemFont(ofSize: 10)
        tag.textColor = .secondaryLabelColor
        tag.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(body)
        cell.addSubview(tag)
        NSLayoutConstraint.activate([
            tag.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            tag.topAnchor.constraint(equalTo: cell.topAnchor, constant: 2),
            body.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            body.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            body.topAnchor.constraint(equalTo: tag.bottomAnchor, constant: 0),
            body.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -2),
        ])
        return cell
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        window = nil
    }
}

// MARK: - 📱 iPhone の会話(sente.teai.io /conversations)

/// iPhone の Sente が数ターン毎/背面化時にミラーする会話スナップショット(端末ごと・最新 300 件)を取り、
/// 発言の間が 2 時間以上空いたところで「会話」に区切って見せる。トークンは te と同じ
/// ~/.config/teai/sente-cloud-token。無ければ `available` が false でメニュー自体が出ない。
final class PhoneConversations {
    struct Message {
        let role: String
        let text: String
        let ts: Date?
        let model: String
        let mode: String
    }
    struct Conversation {
        let device: String
        let deviceName: String
        let started: Date
        let ended: Date
        let messages: [Message]
        /// 最初の発話 1 行(メニュー・一覧の見出し)
        var title: String {
            let first = messages.first(where: { $0.role == "user" })?.text ?? messages.first?.text ?? ""
            let one = first.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            return one.isEmpty ? "(会話)" : one
        }
    }

    static let gap: TimeInterval = 2 * 3600
    static let base = URL(string: "https://sente.teai.io")!
    private(set) var conversations: [Conversation] = []
    private(set) var lastError: String?
    private(set) var fetchedAt: Date?
    private var inflight = false
    private var tokenPath: String { NSHomeDirectory() + "/.config/teai/sente-cloud-token" }
    var available: Bool { FileManager.default.fileExists(atPath: tokenPath) }

    func refresh(_ done: @escaping () -> Void) {
        guard !inflight,
              let tok = (try? String(contentsOfFile: tokenPath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines),
              !tok.isEmpty else { return }
        inflight = true
        var req = URLRequest(url: Self.base.appendingPathComponent("conversations"), timeoutInterval: 20)
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        req.setValue("sente-app/1.0", forHTTPHeaderField: "User-Agent")   // 🪤 既定 UA は Cloudflare が bot 判定して 403
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            guard let self else { return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            var convs: [Conversation] = []
            var error: String?
            if let err {
                error = err.localizedDescription
            } else if code == 401 {
                error = "トークン期限切れ(te login)"
            } else if code != 200 {
                error = "HTTP \(code)"
            } else if let data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let list = obj["conversations"] as? [[String: Any]] {
                for snap in list { convs += Self.split(snap) }
                convs.sort { $0.ended > $1.ended }
            } else {
                error = "応答が読めません"
            }
            DispatchQueue.main.async {
                self.inflight = false
                self.conversations = convs
                self.lastError = error
                self.fetchedAt = Date()
                done()
            }
        }.resume()
    }

    /// 1 端末のスナップショット(時系列)を、発言間が gap 以上空いたところで別会話に切る。ts の無い旧メッセージは直前の会話に付く。
    static func split(_ snap: [String: Any]) -> [Conversation] {
        let device = snap["device"] as? String ?? "?"
        let name = snap["name"] as? String ?? "iPhone"
        let updated = Date(timeIntervalSince1970: ((snap["updatedAt"] as? Double) ?? 0) / 1000)
        let raw = (snap["messages"] as? [[String: Any]]) ?? []
        var out: [Conversation] = []
        var cur: [Message] = []
        var last: Date?
        func close() {
            guard !cur.isEmpty else { return }
            let ts = cur.compactMap(\.ts)
            out.append(Conversation(device: device, deviceName: name, started: ts.first ?? updated, ended: ts.last ?? updated, messages: cur))
            cur = []
        }
        for m in raw {
            let ts = (m["ts"] as? Double).map { Date(timeIntervalSince1970: $0) }
            if let ts, let l = last, ts.timeIntervalSince(l) > gap { close() }
            cur.append(Message(role: m["role"] as? String ?? "assistant", text: m["text"] as? String ?? "", ts: ts,
                               model: m["model"] as? String ?? "", mode: m["mode"] as? String ?? ""))
            if let ts { last = ts }
        }
        close()
        return out
    }
}

/// 左に会話一覧、右に本文。読むための窓(編集しない)。📋 で本文をコピーできる。
final class PhoneConversationViewer: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow?
    private var tableView: NSTableView!
    private var textView: NSTextView!
    private var conversations: [PhoneConversations.Conversation] = []
    var isVisible: Bool { window?.isVisible == true }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d(E)"
        return f
    }()

    func show(_ convs: [PhoneConversations.Conversation], select: Int) {
        conversations = convs
        if window == nil { buildWindow() }
        tableView.reloadData()
        if !conversations.isEmpty {
            let i = max(0, min(select, conversations.count - 1))
            tableView.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
            render(conversations[i])
        } else {
            textView.string = "まだ会話がありません。iPhone の Sente で話すと、数ターン後にここに出ます。"
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildWindow() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 520),
                            styleMask: [.titled, .closable, .resizable, .miniaturizable],
                            backing: .buffered, defer: false)
        win.title = "iPhone の会話"
        win.minSize = NSSize(width: 480, height: 300)
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 860, height: 520))
        let footer = NSView(frame: NSRect(x: 0, y: 0, width: 860, height: 32))
        footer.autoresizingMask = [.width]
        let copy = NSButton(title: "📋 この会話をコピー", target: self, action: #selector(copySelected))
        copy.bezelStyle = .rounded
        copy.controlSize = .small
        copy.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(copy)
        let web = NSButton(title: "sente.teai.io を開く", target: self, action: #selector(openWeb))
        web.bezelStyle = .rounded
        web.controlSize = .small
        web.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(web)
        NSLayoutConstraint.activate([
            copy.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -10),
            copy.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            web.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 10),
            web.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])

        let split = NSSplitView(frame: NSRect(x: 0, y: 32, width: 860, height: 488))
        split.autoresizingMask = [.width, .height]
        split.isVertical = true
        split.dividerStyle = .thin
        // 🪤 LogViewer と同じ: ゼロサイズの NSScrollView を足すと右ペインに幅が配られない。初期 frame を明示する。
        let listWidth: CGFloat = 280
        let listScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: listWidth, height: 488))
        listScroll.hasVerticalScroller = true
        listScroll.borderType = .noBorder
        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 24
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("conversation"))
        col.width = listWidth - 4
        table.addTableColumn(col)
        table.dataSource = self
        table.delegate = self
        listScroll.documentView = table
        tableView = table

        let textScroll = NSScrollView(frame: NSRect(x: listWidth, y: 0, width: 860 - listWidth, height: 488))
        textScroll.hasVerticalScroller = true
        textScroll.borderType = .noBorder
        let tv = NSTextView(frame: textScroll.bounds)
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        tv.textContainerInset = NSSize(width: 10, height: 10)
        tv.textContainer?.widthTracksTextView = true
        tv.autoresizingMask = [.width, .height]
        textScroll.documentView = tv
        textView = tv

        split.addSubview(listScroll)
        split.addSubview(textScroll)
        container.addSubview(split)
        container.addSubview(footer)
        win.contentView = container
        window = win
        split.setPosition(listWidth, ofDividerAt: 0)
    }

    private func selected() -> PhoneConversations.Conversation? {
        let row = tableView.selectedRow
        return row >= 0 && row < conversations.count ? conversations[row] : nil
    }

    @objc private func copySelected() {
        guard let c = selected() else { return }
        let text = c.messages.map { ($0.role == "user" ? "🗣 " : "💬 ") + $0.text }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    @objc private func openWeb() { NSWorkspace.shared.open(PhoneConversations.base) }

    func numberOfRows(in tableView: NSTableView) -> Int { conversations.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let c = conversations[row]
        let field = NSTextField(labelWithString: "\(Self.day.string(from: c.ended)) \(Self.time.string(from: c.ended))  \(c.title)")
        field.font = .systemFont(ofSize: 12)
        field.toolTip = "\(c.deviceName) · \(c.messages.count)件"
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if let c = selected() { render(c) } else { textView.string = "" }
    }

    private func render(_ c: PhoneConversations.Conversation) {
        let attr = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: 13)
        let fontBold = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let fontMeta = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let modes = Set(c.messages.map(\.mode).filter { !$0.isEmpty }).sorted().joined(separator: "/")
        let models = Set(c.messages.map(\.model).filter { !$0.isEmpty }).sorted().joined(separator: ", ")
        attr.append(NSAttributedString(
            string: "📱 \(c.deviceName)  \(Self.day.string(from: c.started)) \(Self.time.string(from: c.started))–\(Self.time.string(from: c.ended))  \(c.messages.count)件"
                + (modes.isEmpty ? "" : "  \(modes)") + (models.isEmpty ? "" : "  \(models)") + "\n\n",
            attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: fontMeta]))
        for m in c.messages {
            let isUser = m.role == "user"
            var prefix = isUser ? "🗣 " : "💬 "
            if isUser, let ts = m.ts { prefix = "[\(Self.time.string(from: ts))] " + prefix }
            attr.append(NSAttributedString(string: prefix + m.text + "\n\n",
                                            attributes: [.foregroundColor: isUser ? NSColor.systemBlue : NSColor.labelColor,
                                                         .font: isUser ? fontBold : font]))
        }
        textView.textStorage?.setAttributedString(attr)
    }

    func windowWillClose(_ notification: Notification) { window = nil }
}

// `Sente --phone-check`: print the iPhone conversations the menu would show, as one JSON object, and exit.
// Lets sente-ios/scripts/e2e-phone.sh prove the phone → cloud → Sente.app path without a person opening the menu.
if CommandLine.arguments.contains("--phone-check") {
    let pc = PhoneConversations()
    guard pc.available else {
        print("{\"error\":\"no sente-cloud token\",\"conversations\":[]}")
        exit(2)
    }
    var done = false
    pc.refresh { done = true }
    let deadline = Date().addingTimeInterval(30)
    while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }   // refresh finishes on the main queue
    let list: [[String: Any]] = pc.conversations.map {
        ["device": $0.device, "name": $0.deviceName, "title": $0.title, "messages": $0.messages.count, "ended": $0.ended.timeIntervalSince1970]
    }
    let obj: [String: Any] = ["conversations": list, "error": pc.lastError ?? NSNull(), "fetched": done]
    if let data = try? JSONSerialization.data(withJSONObject: obj), let text = String(data: data, encoding: .utf8) { print(text) }
    exit(done && pc.lastError == nil ? 0 : 1)
}

// MARK: - 🖥 このMac(何が動いているか)
/// `~/.claude/tools/mac-status-log.sh` が30分毎(launchd)に書く `~/.local/share/mac-status/` を読む。
/// current.txt=いまの全体像(丸め値) / log/YYYY-MM-DD.log=変化だけの一文ログ / last-check=最終チェック時刻。
/// アプリ側は計測しない(重い ps/lsof を60秒毎に回さない)。撮り直しはスクリプトを1回叩くだけ。
final class MacStatusStore {
    struct Snapshot {
        var general: [(String, String)] = []   // 全体: メモリ使用/スワップ/ディスク空き/起動
        var daemons: [(String, String)] = []   // 常駐: label, pid
        var jobs: [(String, String)] = []      // 予約: label, exit
        var ports: [(String, String)] = []     // 待受: addr, command
        var apps: [String] = []
        var claude: [(String, String)] = []
        var switches: [(String, String)] = []
        var reach: [(String, String)] = []     // 到達性: host, OK/NG
    }
    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/mac-status")
    static let script = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/tools/mac-status-log.sh").path
    private(set) var snapshot: Snapshot?
    private(set) var changes: [String] = []    // 新しい順 "HH:MM 内容"(昨日分は "M/d HH:MM 内容")
    private(set) var checkedAt: String?
    private(set) var running = false
    var available: Bool { FileManager.default.fileExists(atPath: Self.script) }

    func reload() {
        let cur = Self.dir.appendingPathComponent("current.txt")
        snapshot = (try? String(contentsOf: cur, encoding: .utf8)).map(Self.parse)
        checkedAt = (try? String(contentsOf: Self.dir.appendingPathComponent("last-check"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        changes = Self.loadChanges(days: 2)
    }

    /// いま撮り直す(スクリプト1回=差分ログも更新)。終わったら reload 済みで done。
    func refreshNow(_ done: @escaping () -> Void) {
        guard !running, available else { done(); return }
        running = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [Self.script]
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            try? p.run()
            p.waitUntilExit()
            DispatchQueue.main.async { self?.running = false; self?.reload(); done() }
        }
    }

    static func parse(_ text: String) -> Snapshot {
        var s = Snapshot()
        var sec = ""
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            if line.hasPrefix("## ") { sec = String(line.dropFirst(3)); continue }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            switch sec {
            case "常駐", "予約":
                guard let r = line.range(of: " ", options: .backwards) else { continue }
                let name = String(line[..<r.lowerBound])
                let kv = String(line[r.upperBound...])
                let v = kv.split(separator: "=", maxSplits: 1).last.map(String.init) ?? kv
                if sec == "常駐" { s.daemons.append((name, v)) } else { s.jobs.append((name, v)) }
            case "ポート":
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                s.ports.append((parts[0], parts.count > 1 ? parts[1] : ""))
            case "アプリ":
                s.apps.append(line)
            default:
                let parts = line.components(separatedBy: ": ")
                let kv = (parts[0], parts.dropFirst().joined(separator: ": "))
                switch sec {
                case "全体": s.general.append(kv)
                case "Claude": s.claude.append(kv)
                case "停止スイッチ": s.switches.append(kv)
                case "到達性": s.reach.append(kv)
                default: break
                }
            }
        }
        return s
    }

    /// 変化ログ(今日+昨日)を新しい順に平らに。"[HH:MM]" 見出し行の下に続く行が中身。
    static func loadChanges(days: Int) -> [String] {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let md = DateFormatter(); md.dateFormat = "M/d"
        var out: [String] = []
        for d in 0..<days {
            guard let day = Calendar.current.date(byAdding: .day, value: -d, to: Date()) else { continue }
            let f = dir.appendingPathComponent("log/\(df.string(from: day)).log")
            guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            var blocks: [[String]] = []
            for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let line = String(raw)
                if line.hasPrefix("[") { blocks.append([line]) }
                else if !blocks.isEmpty { blocks[blocks.count - 1].append(line) }
            }
            for b in blocks.reversed() {
                let head = b[0]
                let time = head.count >= 7 ? String(head.dropFirst().prefix(5)) : head
                let prefix = d == 0 ? time : "\(md.string(from: day)) \(time)"
                let rest = head.count > 7 ? String(head.dropFirst(7)).trimmingCharacters(in: .whitespaces) : ""
                if !rest.isEmpty { out.append("\(prefix) \(rest)") }
                for l in b.dropFirst() { out.append("\(prefix) \(l)") }
            }
        }
        return out
    }
}

/// 「全体を見る…」の窓。1枚のテキスト(等幅)にいまの全体像+最近の変化。下に「いま撮り直す」「コピー」。
final class MacStatusViewer: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var textView: NSTextView!
    private var onRefresh: (() -> Void)?
    var isVisible: Bool { window?.isVisible == true }

    func show(_ store: MacStatusStore, refresh: @escaping () -> Void) {
        onRefresh = refresh
        if window == nil { buildWindow() }
        update(store)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func update(_ store: MacStatusStore) {
        guard let tv = textView else { return }
        var s = ""
        if let snap = store.snapshot {
            s += "このMacで動いているもの   最終チェック \(store.checkedAt ?? "?")(30分毎に自動)\n\n"
            s += "■ 全体\n" + (snap.general + snap.claude).map { "  \($0.0): \($0.1)" }.joined(separator: "\n") + "\n\n"
            s += "■ 到達性\n" + snap.reach.map { "  \($0.1 == "OK" ? "🟢" : "🔴") \($0.0)" }.joined(separator: "\n") + "\n\n"
            s += "■ 常駐 \(snap.daemons.count)  ずっと動いているもの\n"
            s += snap.daemons.map { "  ▶ \($0.0)   pid \($0.1)" }.joined(separator: "\n") + "\n\n"
            let failed = snap.jobs.filter { $0.1 != "0" }
            s += "■ 予約 \(snap.jobs.count)  時間が来たら動くもの" + (failed.isEmpty ? "" : "  (⚠ \(failed.count)件が前回失敗)") + "\n"
            s += failed.map { "  🔴 \($0.0)   前回失敗 exit=\($0.1)" }.joined(separator: "\n") + (failed.isEmpty ? "" : "\n")
            s += snap.jobs.filter { $0.1 == "0" }.map { "  ・ \($0.0)" }.joined(separator: "\n") + "\n\n"
            s += "■ 待受ポート \(snap.ports.count)\n" + snap.ports.map { "  \($0.0)  ← \($0.1)" }.joined(separator: "\n") + "\n\n"
            s += "■ 起動中アプリ \(snap.apps.count)\n  " + snap.apps.joined(separator: ", ") + "\n\n"
            s += "■ 停止スイッチ\n" + snap.switches.map { "  \($0.0): \($0.1)" }.joined(separator: "\n") + "\n\n"
        } else {
            s += "まだ計測がありません。「いま撮り直す」を押すと30秒ほどで出ます。\n\n"
        }
        s += "■ 最近の変化(今日・昨日、新しい順)\n"
        s += store.changes.isEmpty ? "  変化なし\n" : store.changes.map { "  " + $0 }.joined(separator: "\n") + "\n"
        s += "\n計測: launchd tokyo.hamada.mac-status-log(30分毎)  ファイル: ~/.local/share/mac-status/\n"
        s += "失敗に変わった予約・止まった常駐・届かなくなった先は macOS 通知でも知らせます。\n"
        tv.string = s
    }

    private func buildWindow() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                            styleMask: [.titled, .closable, .resizable, .miniaturizable],
                            backing: .buffered, defer: false)
        win.title = "このMacで動いているもの"
        win.minSize = NSSize(width: 420, height: 300)
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 560))
        let footer = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 32))
        footer.autoresizingMask = [.width]
        let refresh = NSButton(title: "いま撮り直す", target: self, action: #selector(refreshTapped))
        refresh.bezelStyle = .rounded
        refresh.controlSize = .small
        refresh.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(refresh)
        let copy = NSButton(title: "📋 コピー", target: self, action: #selector(copyAll))
        copy.bezelStyle = .rounded
        copy.controlSize = .small
        copy.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(copy)
        NSLayoutConstraint.activate([
            refresh.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 10),
            refresh.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            copy.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -10),
            copy.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])
        let textScroll = NSScrollView(frame: NSRect(x: 0, y: 32, width: 720, height: 528))
        textScroll.autoresizingMask = [.width, .height]
        textScroll.hasVerticalScroller = true
        textScroll.borderType = .noBorder
        let tv = NSTextView(frame: textScroll.bounds)
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.textContainerInset = NSSize(width: 10, height: 10)
        tv.textContainer?.widthTracksTextView = true
        tv.autoresizingMask = [.width, .height]
        textScroll.documentView = tv
        textView = tv
        container.addSubview(textScroll)
        container.addSubview(footer)
        win.contentView = container
        window = win
    }

    @objc private func refreshTapped() { onRefresh?() }
    @objc private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
    }
    func windowWillClose(_ notification: Notification) { window = nil }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // Dock に出さないメニューバー常駐
app.run()
