# 改善に参加する / Contributing

## どこを直す？ / Where does a change belong?

| 対象 / Area | リポジトリ / Repository |
|---|---|
| 導入ガイド・ランチャー・メニューバー / Guide, launcher, menu bar | [yukihamada/sente](https://github.com/yukihamada/sente) |
| ターミナル画面・ツール・エージェント / Terminal UI, tools, agent | [Core release branch](https://github.com/yukihamada/opencode/tree/headless-model-fallback) |

本体の既定ブランチと配布ブランチは異なります。Senteの配布ソースを見るときは **`headless-model-fallback`** を選んでください。本体のビルド手順はそのブランチのコードとワークフローを確認してください。

The core repository’s default branch differs from its release branch. Select **`headless-model-fallback`** for Sente’s release source; check that branch’s code and workflow for build instructions.

ランチャーとメニューバーの変更は、このリポジトリへのPRで提案できます。メンテナが配布元との同期を確認します。

Propose launcher and menu bar changes here. Maintainers coordinate synchronization with the distribution source.

## 不具合報告 / Bug reports

次の情報があると再現しやすくなります。 / Please include:

- OS・端末・使用バージョン / OS, terminal and installed version
- 実行したコマンド・モデル / Command and model
- 期待した結果・実際の結果 / Expected and actual result
- 最小の再現手順 / Minimal reproduction steps
- 秘密を除いたエラー / Redacted error output

`te doctor` は診断に使えますが、結果を公開する前に個人情報や内部パスを除いてください。脆弱性は[SECURITY.md](./SECURITY.md)の窓口へ。

Use `te doctor` to diagnose issues, and remove personal information and internal paths before sharing output. Report vulnerabilities through [SECURITY.md](./SECURITY.md).

## macOSアプリをビルド / Build the macOS app

macOSとXcode Command Line Tools（`swiftc`）が必要です。

Requires macOS and Xcode Command Line Tools (`swiftc`).

```sh
git clone https://github.com/yukihamada/sente.git
cd sente/sente-app
./build.sh
open build/Sente.app
```

生成先は `sente-app/build/Sente.app`。コマンド実行には別途 `te` の導入が必要です。`./build.sh --install` は `/Applications/Sente.app` を置き換えるため、ローカルビルドを確認してから使ってください。

Output: `sente-app/build/Sente.app`. Install `te` separately to run commands from the app. `./build.sh --install` replaces `/Applications/Sente.app`; check the local build first.

## PRに添えるもの / Include with your PR

1. 何が困っていたか / The problem
2. 何を変えたか / The change
3. どう確認したか / Verification

READMEだけならリンクと掲載コマンドを確認。ランチャーなら `sh -n te-install.sh` に加え、変更した処理を検証。UIなら変更箇所のスクリーンショットを添えてください。

For documentation, check links and commands. For the launcher, run `sh -n te-install.sh` and exercise the changed behavior. For UI changes, include a screenshot of the affected area.
