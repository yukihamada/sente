# Sente（先手）

[English](./README.en.md) | 日本語

**声で使うコーディングエージェント。** ターミナル1つ、またはメニューバーのアイコン1つで、話しかけるだけで作業が進みます。

```sh
curl -fsSL https://teai.io/te | sh
```

- **macOS / Linux** — そのまま動きます
- **Windows** — WSL の中で上のコマンド（`te` の全機能）。ネイティブは PowerShell 版（`sente.exe` 本体のみ）
- 必要なもの: `python3`（標準で入っています）

---

## 30秒で始める

```sh
te register          # メールアドレスだけで登録（ブラウザ不要）
te "いま何をするべき？"
```

声で使うなら:

```sh
koe                  # 話しかけて、返事も声で返ってくる（Ctrl-C で終了）
```

macOS ならメニューバー常駐の **Sente.app** も入ります。

```sh
te app install
```

---

## あなた向けの使い方

### 開発者

```sh
te run "このリポジトリのテストを直して"   # 作業ディレクトリで実行
te -m teai/auto "..."                    # モデル指定
te resume                                # 直前のセッションを再開
te models                                # 使えるモデル一覧
te doctor                                # 環境診断
```

`/v1/chat/completions` 互換の API をそのまま使えます。主要なコーディングエージェントの CLI からも接続できます。

### 非開発者

コマンドを覚える必要はありません。Sente.app を入れて、アイコンをクリックして話しかけるだけです。返事は声で返ってきます。

### 情シス・セキュリティ担当

`te privacy` で、このバージョンが実際にどこへ何を送るかが表示されます。README に書くより正確なので、導入前に一度実行してください。

要点だけ:

導入前に `te privacy` を実行して、実際に送られる内容を確認してください。
社内展開・ロールアウトの前でも、この1コマンドで自社のセキュリティ基準に照らせます。

- プロンプトとコード文脈 → `teai.io`（応答生成と課金計算）
- 声 → `koe.live` で文字起こし。**音声の保存は既定でオフ**（`te privacy stt-log on` で任意提供）
- **PII スクラビング**（任意・オプション）: `te privacy scrub on` で、送信前に手元の Ollama と正規表現で氏名・住所・電話・API キーを検出し、プレースホルダに置き換えてから送信します。Ollama が使えない場合は**平文のまま送らずエラーで止まります**（フェイルクローズ）
- **BYOK**: `te byok add <provider> <key>` で自分の API キーを登録できます（対応プロバイダは `te byok` で確認できます）

### コスト重視

```sh
te stats            # 残高と、モデル別の消費内訳
te topup 10000      # チャージ（¥1 = 6クレジット）
```

安いモデルを選ぶだけなら `te fast`。`te stats` のモデル別内訳を見て、どこに消えているか把握できます。

### 大量処理・バッチ

`/v1/chat/completions` 互換エンドポイントをそのまま並列で叩けます。`te run` はモデル起因の失敗時に次のモデルで1回だけ再試行します（無効化は `TE_NO_FALLBACK=1`）。

### 日本語重視

UI も声も日本語が既定です。`te lang en` で英語に切り替わります。声の合成・認識は koe.live（日本語に強い音声）を使います。

### 音声クリエイター

```sh
te voice enroll     # 15秒の録音で、自分の声を登録
te voice <そのID>    # 自分の声で返事が返ってくる
koe "読み上げたい文"  # 単発の合成
```

### 国産志向

teai.io / koe.live は株式会社イネブラ（Enabler Inc.・東京）が運営する、日本のサービスです。
声の合成・認識も国内で開発されたものを使います。

### 研究者

```sh
te bench                          # 公開ベンチを自分のモデルで実測
te bench jp-business teai/auto    # 評価セットとモデルを指定
```

設問・正解も公開データなので、誰が測っても同じ問題で比べられます。
結果は再現可能で、モデル間の比較にもそのまま使えます。

### 経営者

`te stats` がコストの唯一の正本です。チーム導入は `te byok add` で自社の API キーを登録する運用も選べます。

---

## 声（KOE）

| コマンド | 内容 |
|---|---|
| `koe` / `te talk` | 声の連続対話 |
| `te v` | 声で1回だけ指示 |
| `te voice on` / `off` | 読み上げの ON/OFF（実行中でも即効く） |
| `te voice <id>` | 声の切替（`te voice enroll` で自分の声を登録） |
| `te voice queue` | 溜まっている読み上げを表示 |
| `te voice stop` / `skip` | 止める / 次へ |

**複数のターミナルで同時に作業していても、声は重なりません。** 複数セッションを検知した時だけ、読み上げを共通のキューに溜めてまとめて喋ります（1本だけならそのまま即再生）。3件以上溜まった時は要約して端的に報告します。

---

## データはどこへ行くか

`te privacy` を実行してください。実装そのままの説明が出ます。

---

## Sente.app をビルドする

```sh
cd sente-app
./build.sh              # → build/Sente.app
./build.sh --install    # → /Applications へ配置
```

Xcode の Command Line Tools（`swiftc`）が必要です。Xcode プロジェクトは不要で、`swiftc` 1発 + バンドル手組みです。

---

## セキュリティ

脆弱性の報告は [SECURITY.md](./SECURITY.md) へ（公開 Issue ではなくメールでお願いします）。

## ライセンス

MIT License. Copyright (c) 2026 Yuki Hamada.

`te-install.sh`（コマンド本体）と `sente-app/`（macOS アプリ）の両方が対象です。
