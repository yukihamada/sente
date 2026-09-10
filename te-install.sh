#!/bin/sh
# Sente (先手) — the teai.io coding agent (powered by OpenCode)
# "Always keep sente": the agent makes the first move for you.
#
#   Install:  curl -fsSL https://teai.io/te | sh
#   Then:     te                    # interactive coding agent (TUI)
#             te run "fix the bug"  # one-shot
#             te register           # メールだけで新規登録(ブラウザ不要)
#             te login              # set / replace your teai.io API key
#             te memory             # 永続記憶(浅い索引/トピック/深いcold)を見る
#             te doctor             # check your setup
#
# Design: we do NOT fork OpenCode. `te` is a thin launcher that points
# OpenCode (via OPENCODE_CONFIG) at a teai.io-generated config, so you
# always get the latest OpenCode agent + the live teai.io model catalog.
set -eu

TEAI_SITE="${TEAI_SITE:-https://teai.io}"
TEAI_API="${TEAI_API:-https://api.teai.io}"
CONFIG_DIR="$HOME/.config/teai"
BIN_DIR="${TE_INSTALL_DIR:-$HOME/.local/bin}"
CREDS="$CONFIG_DIR/credentials"
# Bump this string whenever te-install.sh changes in a way worth seeing in the
# Sente KPI dashboard's version breakdown (handle_admin_stats_timeseries /
# admin.html) — it's sent as X-Sente-Client-Version so a rollout can be tracked.
# Not tied to git/CI automatically; a stale value here just means the dashboard
# undercounts how many users are on the newest te-install.sh, nothing breaks.
TE_SCRIPT_VERSION="2026-09-10"

# 🔧 複合版teの自己修復(2026-09-10): 過去にインストールした te が「インストーラ部+ランチャー部」の
#   複合ファイルのまま残っていると、te stats/start 等のサブコマンド実行時に先頭のインストーラ部が
#   再実行されてしまう(実機で確認)。このスクリプトが「サブコマンド付きで、かつ自分が複合版」として
#   呼ばれた場合、ランチャー部(2番目の#!/bin/sh以降)だけを取り出して $0 を置き換えてから exec で
#   再起動する。curl|sh の新規インストール(引数なし or --setup)では発動しない。
#   無効化=TE_NO_SELF_REPAIR=1。
if [ "${TE_NO_SELF_REPAIR:-0}" != "1" ] && [ $# -gt 0 ] && [ -f "$0" ] \
   && grep -qE '^cat > "\$BIN_DIR/\.te\.new' "$0" 2>/dev/null; then
  _TE_LSTART="$(grep -n '^#!/bin/sh' "$0" 2>/dev/null | sed -n '2p' | cut -d: -f1)"
  _TE_LEND="$(grep -n '^LAUNCHER$' "$0" 2>/dev/null | head -1 | cut -d: -f1)"
  if [ -n "$_TE_LSTART" ] && [ -n "$_TE_LEND" ] && [ "$_TE_LEND" -gt "$_TE_LSTART" ]; then
    _TE_LEND=$((_TE_LEND - 1))
    _TE_TMP="$(mktemp "${TMPDIR:-/tmp}/te_repair_XXXXXX" 2>/dev/null)" || _TE_TMP=""
    if [ -n "$_TE_TMP" ]; then
      sed -n "${_TE_LSTART},${_TE_LEND}p" "$0" > "$_TE_TMP" 2>/dev/null
      if sh -n "$_TE_TMP" 2>/dev/null && [ -w "$0" ]; then
        chmod +x "$_TE_TMP" 2>/dev/null
        if mv -f "$_TE_TMP" "$0" 2>/dev/null; then
          echo "🔧 複合版の te をランチャーのみに修復しました(再実行します)" >&2
          exec "$0" "$@"
        fi
      fi
      rm -f "$_TE_TMP" 2>/dev/null
    fi
  fi
fi

# --- Install-time flags -------------------------------------------------------
# `curl -fsSL https://teai.io/te | sh -s -- --setup <st_token>`
# ダッシュボードが発行する短命(15分)・一回限りのセットアップトークン。下の
# 「3. API key」節で本物の te_ キーに交換して保存する。平文キーをコマンド行に
# 載せないための間接層(履歴・画面共有に写っても15分で腐り、1回しか使えない)。
# 環境変数 TEAI_SETUP_TOKEN でも渡せる。
SETUP_TOKEN="${TEAI_SETUP_TOKEN:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --setup)
      if [ $# -ge 2 ]; then SETUP_TOKEN="$2"; shift; fi
      ;;
    --setup=*) SETUP_TOKEN="${1#--setup=}" ;;
  esac
  shift
done

# 色は stdout/stderr が両方ともTTYで、かつ NO_COLOR が未設定の時だけ有効にする。
# `curl -fsSL ... | sh` は標準入力がパイプでも標準出力/エラーは端末なので、判定はfd 1/2で行う
# (stdinのTTY性は見ない)。tput不要の生ANSIなので、tputが無い環境でも壊れない。
if [ -t 1 ] && [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  BOLD="\033[1m"; DIM="\033[2m"; GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; CYAN="\033[36m"; RESET="\033[0m"
else
  BOLD=""; DIM=""; GREEN=""; YELLOW=""; RED=""; CYAN=""; RESET=""
fi
info()  { printf "  ${CYAN}→${RESET}  %s\n" "$1"; }
ok()    { printf "  ${GREEN}✓${RESET}  %s\n" "$1"; }
warn()  { printf "  ${YELLOW}!${RESET}  %s\n" "$1"; }
fail()  { printf "  ${RED}✗${RESET}  %s\n" "$1"; exit 1; }

# Best-effort: stamp provider.teai.options.headers["X-Sente-Client-Version"] =
# $TE_SCRIPT_VERSION into a freshly-fetched /te/config JSON file, so the server
# can track te-install.sh rollout in the Sente KPI dashboard (the client tag
# itself, X-Sente-Client, is already baked in server-side by build_te_config).
# Missing python3 is not fatal — the config still works, just untagged for
# version (same tolerance as the MCP-filter patch in refresh_config below).
patch_te_config_headers() {
  command -v python3 >/dev/null 2>&1 || return 0
  python3 - "$1" "$TE_SCRIPT_VERSION" <<'PYHDRPATCH' 2>/dev/null || true
import json, sys
path, version = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as f:
        d = json.load(f)
    opts = d["provider"]["teai"]["options"]
    headers = opts.get("headers")
    if not isinstance(headers, dict):
        headers = {}
        opts["headers"] = headers
    headers["X-Sente-Client-Version"] = version
    with open(path, "w", encoding="utf-8") as f:
        json.dump(d, f, ensure_ascii=False)
except Exception:
    pass
PYHDRPATCH
}

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT)
    # Git Bash / MSYS から来た場合。te ランチャーは POSIX sh + /dev/tty + pgrep 前提なので
    # ネイティブ Windows では動かない。2経路を案内: ①PowerShell 版インストーラ(sente.exe 本体のみ)
    # ②WSL(te/koe の全機能)。
    warn "Windows detected. Two options:"
    echo "  1) PowerShell (Sente TUI only):  irm $TEAI_SITE/te.ps1 | iex"
    echo "  2) WSL (full te/koe):            curl -fsSL $TEAI_SITE/te | sh   (inside WSL)"
    exit 1 ;;
esac

printf "\n  ${BOLD}${CYAN}te${RESET} ${DIM}—${RESET} teai.io coding agent\n"
printf "  ${DIM}────────────────────────────${RESET}\n\n"
# 🔍 透明性: curl|sh に不安を持つ人のため、何をするかを最初に宣言する(root/sudo不要)
printf "  ${DIM}このスクリプトがやること: ①%s に te/koe/fuseki を配置 ②%s に設定作成\n" "$BIN_DIR" "$CONFIG_DIR"
printf "  ③OpenCode本体の取得(無ければ) ④macOS: 録音ヘルパーをローカルでビルド。\n"
printf "  システム領域は触りません。全部消す=te uninstall / データの扱い=te privacy${RESET}\n\n"
mkdir -p "$CONFIG_DIR" "$BIN_DIR"
chmod 700 "$CONFIG_DIR" 2>/dev/null || true

# --- 1. Ensure OpenCode is installed -----------------------------------------
find_opencode() {
  command -v opencode 2>/dev/null && return 0
  for p in "$HOME/.opencode/bin/opencode" "$HOME/.local/bin/opencode" \
           /opt/homebrew/bin/opencode /usr/local/bin/opencode; do
    [ -x "$p" ] && { echo "$p"; return 0; }
  done
  return 1
}

# teai の実体は "Sente"(yukihamada/opencode の headless-model-fallback ブランチ) —
# ブランディングだけでなく起動速度・セキュリティ修正がバイナリ側に入っている
# (2026-08-30: models.dev全プロバイダを毎回組み立てる無駄を除去 等)。
# stock の opencode.ai/install だと本家の素のバイナリが入ってしまい、これらの
# 修正を受け取れないので、対応プラットフォームでは GitHub Releases の自前ビルドを
# 先に試す。失敗時(未対応OS/アーキ・ネットワーク不調)は既存の stock フォールバックへ。
install_sente_binary() {
  SIB_OS="$(uname -s)"; SIB_ARCH="$(uname -m)"
  case "$SIB_OS" in
    Darwin) SIB_PLAT="darwin" ;;
    Linux)  SIB_PLAT="linux" ;;
    *)      return 1 ;;
  esac
  case "$SIB_ARCH" in
    arm64|aarch64) SIB_ARCH="arm64" ;;
    x86_64|amd64)  SIB_ARCH="x64" ;;
    *)             return 1 ;;
  esac
  # 🧬 CPU/libc に合わせて派生ビルドを選ぶ(fork の install スクリプトと同じ判定):
  #   -baseline: AVX2 の無い x64(古い Intel/AMD・一部 VM)。bun の既定ビルドは AVX2 前提で
  #              無い CPU では "Illegal instruction" で即死する
  #   -musl:     Alpine 等 glibc の無い Linux。glibc ビルドは "not found" で起動しない
  SIB_SUFFIX=""
  if [ "$SIB_ARCH" = "x64" ]; then
    case "$SIB_PLAT" in
      linux)  grep -qwi avx2 /proc/cpuinfo 2>/dev/null || SIB_SUFFIX="-baseline" ;;
      darwin) [ "$(sysctl -n hw.optional.avx2_0 2>/dev/null || echo 0)" = "1" ] || SIB_SUFFIX="-baseline" ;;
    esac
  fi
  if [ "$SIB_PLAT" = "linux" ]; then
    if [ -f /etc/alpine-release ] || { command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; }; then
      SIB_SUFFIX="${SIB_SUFFIX}-musl"
    fi
  fi
  SIB_ASSET="sente-${SIB_PLAT}-${SIB_ARCH}${SIB_SUFFIX}.tar.gz"
  SIB_URL="https://github.com/yukihamada/opencode/releases/latest/download/${SIB_ASSET}"
  SIB_DIR="$HOME/.opencode/bin"
  mkdir -p "$SIB_DIR" 2>/dev/null || return 1
  SIB_TMP="$(mktemp -d "${TMPDIR:-/tmp}/sente_install_XXXXXX")" || return 1
  curl -fsSL --retry 2 --retry-delay 1 -m 60 "$SIB_URL" -o "$SIB_TMP/sente.tar.gz" 2>/dev/null || { rm -rf "$SIB_TMP"; return 1; }
  # 🔒 SHA256検証(fork commit 70bb874f のロジック移植): 同リリースの SHA256SUMS.txt
  # と照合。不一致=即中断(return 1→stockフォールバックせず失敗にする=改ざん品を
  # 静かに入れない)。SUMS取得失敗(古いリリース等)は警告して続行するが、
  # TE_REQUIRE_CHECKSUM=1 ならそこでも止める(厳格モード)。
  SIB_SUMS_URL="https://github.com/yukihamada/opencode/releases/latest/download/SHA256SUMS.txt"
  if curl -fsSL -m 30 "$SIB_SUMS_URL" -o "$SIB_TMP/SHA256SUMS.txt" 2>/dev/null; then
    SIB_EXPECTED="$(grep " ${SIB_ASSET}\$" "$SIB_TMP/SHA256SUMS.txt" | awk '{print $1}')"
    if command -v shasum >/dev/null 2>&1; then
      SIB_ACTUAL="$(shasum -a 256 "$SIB_TMP/sente.tar.gz" | awk '{print $1}')"
    elif command -v sha256sum >/dev/null 2>&1; then
      SIB_ACTUAL="$(sha256sum "$SIB_TMP/sente.tar.gz" | awk '{print $1}')"
    else
      SIB_ACTUAL=""
    fi
    if [ -z "$SIB_ACTUAL" ]; then
      warn "No shasum/sha256sum available — checksum verification skipped for $SIB_ASSET"
      [ "${TE_REQUIRE_CHECKSUM:-0}" = "1" ] && { rm -rf "$SIB_TMP"; return 1; }
    elif [ -z "$SIB_EXPECTED" ] || [ "$SIB_EXPECTED" != "$SIB_ACTUAL" ]; then
      warn "Checksum mismatch for $SIB_ASSET (expected ${SIB_EXPECTED:-none}, got $SIB_ACTUAL) — aborting"
      rm -rf "$SIB_TMP"; return 1
    fi
  else
    warn "No SHA256SUMS.txt for this release — skipping checksum verification (set TE_REQUIRE_CHECKSUM=1 to fail here)"
    [ "${TE_REQUIRE_CHECKSUM:-0}" = "1" ] && { rm -rf "$SIB_TMP"; return 1; }
  fi
  tar -xzf "$SIB_TMP/sente.tar.gz" -C "$SIB_TMP" 2>/dev/null || { rm -rf "$SIB_TMP"; return 1; }
  [ -x "$SIB_TMP/sente" ] || { rm -rf "$SIB_TMP"; return 1; }
  mv -f "$SIB_TMP/sente" "$SIB_DIR/opencode" && chmod +x "$SIB_DIR/opencode"
  rm -rf "$SIB_TMP"
  [ -x "$SIB_DIR/opencode" ]
}

# `te update` re-curls this installer with TE_FORCE_BINARY_UPDATE=1 so an
# existing (possibly stock-opencode or older Sente) binary actually gets
# replaced — normal runs never touch an already-found binary (see
# OPENCODE_DISABLE_AUTOUPDATE note further down: engine updates are opt-in,
# only through `te update`).
if [ "${TE_FORCE_BINARY_UPDATE:-0}" = "1" ]; then
  info "Updating Sente binary..."
  install_sente_binary && ok "Sente binary updated" || warn "Sente binary update failed (kept existing)"
fi

OPENCODE_BIN="$(find_opencode || true)"
if [ -z "$OPENCODE_BIN" ]; then
  info "Installing Sente (teai.io's coding agent)..."
  if install_sente_binary; then
    :
  elif curl -fsSL --retry 2 --retry-delay 1 -m 30 https://opencode.ai/install | bash >/dev/null 2>&1; then
    :
  elif command -v npm >/dev/null 2>&1; then
    npm install -g opencode-ai >/dev/null 2>&1 || true
  elif command -v brew >/dev/null 2>&1; then
    brew install sst/tap/opencode >/dev/null 2>&1 || true
  fi
  OPENCODE_BIN="$(find_opencode || true)"
  [ -n "$OPENCODE_BIN" ] || fail "Could not install OpenCode. Install it manually (https://opencode.ai) and re-run."
  ok "OpenCode installed: $OPENCODE_BIN"
else
  ok "OpenCode found: $OPENCODE_BIN"
fi

# --- 1.5 Dependency check (new; read-only — reports only, never installs) ----
# opencode is handled above (auto-installed if missing); this just gives a
# single at-a-glance panel for everything `te`/`sente` needs, with a
# copy-pasteable fix command for anything missing.
case "$(uname -s)" in
  Darwin) DEP_PKG="brew install" ;;
  *)
    if command -v apt-get >/dev/null 2>&1; then DEP_PKG="sudo apt-get install -y"
    elif command -v dnf >/dev/null 2>&1; then DEP_PKG="sudo dnf install -y"
    elif command -v pacman >/dev/null 2>&1; then DEP_PKG="sudo pacman -S --noconfirm"
    elif command -v apk >/dev/null 2>&1; then DEP_PKG="sudo apk add"
    else DEP_PKG=""
    fi ;;
esac
dep_fix() { [ -n "$DEP_PKG" ] && printf '%s %s' "$DEP_PKG" "$1" || printf 'install %s via your package manager' "$1"; }
dep_check() {  # $1=command $2=label $3=1 if a fix hint should be shown when missing
  if command -v "$1" >/dev/null 2>&1; then
    printf "  ${GREEN}✓${RESET}  %s\n" "$2"
  elif [ "${3:-0}" = 1 ]; then
    printf "  ${YELLOW}!${RESET}  %s — not found. Fix: %s\n" "$2" "$(dep_fix "$1")"
  else
    printf "  ${YELLOW}!${RESET}  %s — not found (optional)\n" "$2"
  fi
}
printf "  ${GREEN}✓${RESET}  opencode\n"   # already ensured above (installed or found)
dep_check python3 "python3" 1
dep_check sox     "sox (声の録音・talkモードに必要)" 1
dep_check ffmpeg  "ffmpeg (音声変換・任意)" 0
dep_check curl    "curl" 1
dep_check ollama  "ollama (PIIスクラビングに使用・任意・te privacy scrub on で必須)" 0

# --- 2. Fetch the teai.io OpenCode config (live model catalog) ---------------
# NOTE: OpenCode expands leading "~/" for the "instructions" field but NOT for
# "plugin" specs — an unresolved "~/..." plugin path is treated as an npm
# package name and silently fails to load (missing-entry, no error surfaced).
# So the plugin path in the server-generated config is rewritten to a real
# absolute path here, right after every fetch.
if curl -fsSL --retry 2 --retry-delay 1 --max-time 10 "$TEAI_SITE/te/config" -o "$CONFIG_DIR/opencode.json.tmp" 2>/dev/null \
   && grep -q '"provider"' "$CONFIG_DIR/opencode.json.tmp"; then
  sed -i.bak "s#~/.config/teai/plugins/koe-speak.js#$CONFIG_DIR/plugins/koe-speak.js#" "$CONFIG_DIR/opencode.json.tmp"
  rm -f "$CONFIG_DIR/opencode.json.tmp.bak"
  mv "$CONFIG_DIR/opencode.json.tmp" "$CONFIG_DIR/opencode.json"
  patch_te_config_headers "$CONFIG_DIR/opencode.json"
  # 声モード用の MCP ゲートウェイ抜き設定も併せて取る(無くても致命ではない)
  curl -fsSL --retry 2 --retry-delay 1 --max-time 10 "$TEAI_SITE/te/config?mcp=voice" -o "$CONFIG_DIR/opencode-voice.json.tmp" 2>/dev/null \
    && grep -q '"provider"' "$CONFIG_DIR/opencode-voice.json.tmp" \
    && sed -i.bak "s#~/.config/teai/plugins/koe-speak.js#$CONFIG_DIR/plugins/koe-speak.js#" "$CONFIG_DIR/opencode-voice.json.tmp" \
    && rm -f "$CONFIG_DIR/opencode-voice.json.tmp.bak" \
    && mv "$CONFIG_DIR/opencode-voice.json.tmp" "$CONFIG_DIR/opencode-voice.json" \
    || rm -f "$CONFIG_DIR/opencode-voice.json.tmp" "$CONFIG_DIR/opencode-voice.json.tmp.bak"
  patch_te_config_headers "$CONFIG_DIR/opencode-voice.json"
  ok "Model catalog synced from teai.io"
else
  rm -f "$CONFIG_DIR/opencode.json.tmp"
  if [ ! -f "$CONFIG_DIR/opencode.json" ]; then
    cat > "$CONFIG_DIR/opencode.json" <<FALLBACK
{
  "\$schema": "https://opencode.ai/config.json",
  "provider": {
    "teai": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "teai.io",
      "options": { "baseURL": "https://api.teai.io/v1", "apiKey": "{env:TEAI_API_KEY}",
                   "headers": { "X-Sente-Client": "sente", "X-Sente-Client-Version": "$TE_SCRIPT_VERSION" } },
      "models": {
        "auto": { "name": "Auto (teai.io)" },
        "z-ai/glm-5.2": { "name": "GLM-5.2" },
        "deepseek-chat": { "name": "DeepSeek Chat" },
        "gpt-4o": { "name": "GPT-4o" }
      }
    }
  },
  "instructions": ["~/.config/teai/sente-rules.md", "~/.config/teai/memory/MEMORY.md"],
  "plugin": ["$CONFIG_DIR/plugins/koe-speak.js"],
  "model": "teai/auto"
}
FALLBACK
    warn "Could not reach $TEAI_SITE — wrote a minimal fallback config"
  else
    warn "Could not refresh catalog — keeping existing config"
  fi
fi

# --- 3. API key --------------------------------------------------------------
have_key() { [ -f "$CREDS" ] && grep -q "^TEAI_API_KEY=." "$CREDS"; }
if have_key; then
  ok "API key found ($CREDS)"
elif [ -n "${TEAI_API_KEY:-}" ]; then
  printf 'TEAI_API_KEY=%s\n' "$TEAI_API_KEY" > "$CREDS" && chmod 600 "$CREDS"
  ok "API key saved from environment"
elif [ -n "$SETUP_TOKEN" ]; then
  # ダッシュボード発行のセットアップトークンを本物のAPIキーに交換(1回限り・15分)
  info "Setting up your API key automatically…"
  XRESP="$(curl -s --max-time 20 -X POST "$TEAI_API/api/v1/setup-token/exchange" \
    -H 'Content-Type: application/json' \
    -d "{\"token\":\"$SETUP_TOKEN\"}" | cat)" || XRESP=""
  KEY="$(printf '%s' "$XRESP" | sed -n 's/.*"api_key":"\([^"]*\)".*/\1/p' | head -1)"
  if [ -n "$KEY" ]; then
    printf 'TEAI_API_KEY=%s\n' "$KEY" > "$CREDS" && chmod 600 "$CREDS"
    ok "API key issued & saved automatically ($CREDS)"
  else
    XERR="$(printf '%s' "$XRESP" | sed -n 's/.*"error":"\([^"]*\)".*/\1/p' | head -1)"
    warn "Auto-setup failed: ${XERR:-could not reach $TEAI_API} — run 'te login' later, or copy a fresh command from $TEAI_SITE/dashboard."
  fi
elif [ -r /dev/tty ]; then
  echo ""
  printf "  Get your free API key: ${BOLD}%s/dashboard#api-keys${RESET}\n" "$TEAI_SITE"
  printf "  Paste it here (te_...), or press Enter to skip: "
  KEY="$(head -1 /dev/tty | tr -d '[:space:]')" || KEY=""
  if [ -n "$KEY" ]; then
    printf 'TEAI_API_KEY=%s\n' "$KEY" > "$CREDS" && chmod 600 "$CREDS"
    ok "API key saved to $CREDS"
  else
    warn "Skipped. Run 'te login' later."
  fi
else
  warn "No TTY — run 'te login' later, or re-run with TEAI_API_KEY=te_... set."
fi

# --- 4. Install the `te` launcher --------------------------------------------
# 🪤 実行中のte(serve常駐/talk中)がスクリプトを逐次読みしているため、直接 > で上書きすると
# 走行中プロセスが壊れる。一時ファイルに書いてmv(アトミック差し替え=旧inodeは走行中プロセスが保持)
cat > "$BIN_DIR/.te.new.$$" <<'LAUNCHER'
#!/bin/sh
# Sente (先手) — teai.io coding agent (thin launcher over OpenCode)
set -eu
TEAI_SITE="${TEAI_SITE:-https://teai.io}"
TEAI_API="${TEAI_API:-https://api.teai.io}"
CONFIG_DIR="$HOME/.config/teai"
CREDS="$CONFIG_DIR/credentials"
# インストーラが書き込み時に sed で埋める(heredoc は引用付きなので変数展開されない)
TE_SCRIPT_VERSION="__TE_SCRIPT_VERSION__"
# 🔒 設定ディレクトリ(APIキー・調整データ)は本人以外読めないように(共用マシンでの覗き見防止)
[ -d "$CONFIG_DIR" ] && chmod 700 "$CONFIG_DIR" 2>/dev/null

# 🎨 色はstderrがTTYかつNO_COLOR未設定の時だけ(表示専用。判定ロジックは一切変えない)。
# Sente.appは端末を持たずstderrを非TTYのままパイプで読むため、そちらでは常に無色になる
# (状態行を絵文字でパースしているため、非TTYで色コードが混ざると壊れうる — 混ぜない)。
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  SC_GREEN="\033[32m"; SC_YELLOW="\033[33m"; SC_RED="\033[31m"; SC_DIM="\033[2m"; SC_RESET="\033[0m"
else
  SC_GREEN=""; SC_YELLOW=""; SC_RED=""; SC_DIM=""; SC_RESET=""
fi

# 🌍 プラットフォーム差の吸収(2026-09-10 Linux/Windows対応)。
# macOS 前提だった箇所をここに集約し、Linux では XDG パス・GNU ツールへ
# フォールバックする。Windows ネイティブは WSL 前提(te.ps1 は別配布)。
#   sente_os          → darwin|linux|other
#   sente_hash_file   → ファイルの md5(mac: md5 -q / linux: md5sum)
#   sente_sha256      → stdin の sha256(mac: shasum -a 256 / linux: sha256sum)
#   sente_nproc       → CPUコア数(sysctl / nproc)
#   sente_loadavg1    → 1分load average(sysctl / /proc/loadavg)
#   sente_free_mb     → 実質空きメモリMB(vm_stat / /proc/meminfo)
#   sente_stat_mtime  → ファイルの mtime epoch(BSD stat -f / GNU stat -c)
#   sente_data_dir    → アプリデータ(~/.local/share/sente on Linux)
#   sente_log_dir     → ログ(~/.local/state/sente on Linux)
sente_os() {
  case "$(uname -s)" in
    Darwin) echo darwin ;;
    Linux)  echo linux ;;
    *)      echo other ;;
  esac
}
sente_hash_file() {  # $1=path → md5 hex(stdout)。ツールが無ければ空
  if command -v md5 >/dev/null 2>&1; then md5 -q "$1" 2>/dev/null
  elif command -v md5sum >/dev/null 2>&1; then md5sum "$1" 2>/dev/null | awk '{print $1}'
  fi
}
sente_sha256() {  # stdin を sha256 して hex を stdout へ
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum 2>/dev/null | awk '{print $1}'
  fi
}
sente_nproc() {
  if command -v sysctl >/dev/null 2>&1 && sysctl -n hw.ncpu >/dev/null 2>&1; then sysctl -n hw.ncpu 2>/dev/null
  elif command -v nproc >/dev/null 2>&1; then nproc 2>/dev/null
  elif [ -r /proc/cpuinfo ]; then grep -c '^processor' /proc/cpuinfo 2>/dev/null
  fi
}
sente_loadavg1() {
  if command -v sysctl >/dev/null 2>&1 && sysctl -n vm.loadavg >/dev/null 2>&1; then
    sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}'
  elif [ -r /proc/loadavg ]; then awk '{print $1}' /proc/loadavg 2>/dev/null
  fi
}
sente_free_mb() {  # 実質空き物理メモリ(free+inactive/speculative相当)をMB換算
  if [ "$(sente_os)" = "darwin" ]; then
    vm_stat 2>/dev/null | awk '
      /page size of/ { for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) ps=$i }
      /^Pages free/       { v=$0; gsub(/[^0-9]/,"",v); free=v }
      /^Pages inactive/   { v=$0; gsub(/[^0-9]/,"",v); inactive=v }
      /^Pages speculative/{ v=$0; gsub(/[^0-9]/,"",v); spec=v }
      END { if (ps=="") ps=4096; printf "%d", (free+inactive+spec)*ps/1024/1024 }
    '
  elif [ -r /proc/meminfo ]; then
    # MemAvailable は「すぐ使える見込み」のカーネル推定値(mac の free+inactive+spec に相当)
    awk '/^MemAvailable:/ { printf "%d", $2/1024 }' /proc/meminfo 2>/dev/null
  fi
}
sente_stat_mtime() {  # $1=path → mtime epoch。取れなければ 0
  if [ "$(sente_os)" = "darwin" ]; then stat -f %m "$1" 2>/dev/null || echo 0
  else stat -c %Y "$1" 2>/dev/null || echo 0
  fi
}
sente_linux_audio_backend() {  # → pulse|alsa。PulseAudio/PipeWire のサーバが生きていれば pulse
  if command -v pactl >/dev/null 2>&1 && pactl info >/dev/null 2>&1; then echo pulse
  elif [ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pulse/native" ] || [ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pipewire-0" ]; then echo pulse
  else echo alsa
  fi
}
sente_pkg_hint() {  # $1=パッケージ名 → そのOSでのインストールコマンド文字列(案内文用)
  case "$(sente_os)" in
    darwin) printf 'brew install %s' "$1" ;;
    linux)
      if command -v apt-get >/dev/null 2>&1; then printf 'sudo apt-get install -y %s' "$1"
      elif command -v dnf >/dev/null 2>&1; then printf 'sudo dnf install -y %s' "$1"
      elif command -v pacman >/dev/null 2>&1; then printf 'sudo pacman -S --noconfirm %s' "$1"
      elif command -v apk >/dev/null 2>&1; then printf 'sudo apk add %s' "$1"
      else printf 'install %s via your package manager' "$1"
      fi ;;
    *) printf 'install %s' "$1" ;;
  esac
}
# 📂 パス: macOS は ~/Library/...、Linux は XDG(~/.local/share, ~/.local/state)。
# 既存の ~/Library 配下にデータがある Mac ユーザーを壊さないよう、macOS では従来パスを維持。
if [ "$(sente_os)" = "darwin" ]; then
  SENTE_DATA_DIR="$HOME/Library/Application Support/Sente"
  SENTE_LOG_DIR="$HOME/Library/Logs/Sente"
else
  SENTE_DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/sente"
  SENTE_LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/sente"
fi

# 🎙 声の既定: `te voice <id>`で保存した声を使う。環境変数KOE_VOICEの明示指定が常に勝つ。
if [ -z "${KOE_VOICE:-}" ] && [ -f "$CONFIG_DIR/voice" ]; then
  KOE_VOICE="$(head -1 "$CONFIG_DIR/voice" 2>/dev/null | tr -d '[:space:]')"
fi
export KOE_VOICE="${KOE_VOICE:-yuki}"

# 🔇 声のON/OFF(2026-09-02本人指示「簡単に切替+Sente.appでワンクリック」): ~/.config/teai/mute が正本。
# te voice on/off・声「静かにして/声出して」・Sente.appのトグルが全部この1ファイルを触り、
# 読み上げの各所(sente_muted)とkoe-speakプラグインが毎回見る=実行中のセッションにも即効く。
# 環境変数AGENT_KOE=0の明示指定はこの実行に限り常に無音(ファイルより強い)。
sente_muted() {  # 読み上げを止めるべきか — 全読み上げ経路はこの1関数で判定する
  [ "${AGENT_KOE:-1}" = "0" ] && return 0
  [ -n "${NO_KOE:-}" ] && return 0
  [ -f "$CONFIG_DIR/mute" ] && return 0
  return 1
}

# `koe` という名前で引数なし起動されたら、既定を声の連続対話(talk)にする。
# `te`=キーボード中心 / `koe`=声中心、という入口の使い分け。引数があれば従来通り。
# 🔀 2026-08-17: `sente` = te のガードレールなし版(本人指示「senteはteのガードレールなし起動」)。
# permission のみ全許可にした設定(opencode-yolo.json)で起動する。sente-rules.md(規律)は残す。
# 以前の「sente=声対話」は koe に統合済み。OpenCode本体の"Sente"改名による名前衝突事故の
# 教訓から、~/.local/bin/sente は te への symlink としてインストーラが管理する。
case "$(basename "$0")" in
  sente) SENTE_NO_GUARDRAILS=1; export SENTE_NO_GUARDRAILS ;;
  fuseki) [ $# -eq 0 ] && set -- watch ;;  # 🪨 fuseki(布石・Alpha)= 引数なしは te watch と同じ(常時見続ける)。
                                            # koe(引数なし=talk・継続)と対で揃える。単発提案は `fuseki next`
  koe)
    # 🔊 `koe` = KOEへの最短入口(teと同実体)。
    #   koe               → 声の連続対話(旧sente・2026-08-15統合)
    #   koe app           → Koe.app(なければ koe.live)を開く
    #   koe <音声URL>     → koe.live/play(共通プレイヤー)で開く
    #   koe <テキスト...> → 自分の声(KOE_VOICE)で合成して鳴らす
    koe_open() {
      case "$(uname -s)" in
        Darwin) open "$1" ;;
        *) xdg-open "$1" >/dev/null 2>&1 || echo "$1" ;;
      esac
    }
    if [ $# -eq 0 ]; then
      set -- talk
    elif [ "$1" = "app" ] && [ $# -eq 1 ]; then
      if [ "$(uname -s)" = "Darwin" ] && [ -d "/Applications/Koe.app" ]; then open -a Koe; else koe_open "https://koe.live"; fi
      exit 0
    else
      case "$1" in
        http://*|https://*) koe_open "https://koe.live/play?src=$1"; exit 0 ;;
      esac
      KOE_TXT="$*"
      KOE_TMP="$(mktemp "${TMPDIR:-/tmp}/koe_XXXXXX").mp3"
      KOE_HTTP="$(curl -s -m 30 -o "$KOE_TMP" -w '%{http_code}' -X POST "${KOE_BASE:-https://koe.live}/api/speak" \
        -H 'Content-Type: application/json' \
        -d "$(python3 -c 'import json,sys;print(json.dumps({"text":sys.argv[1],"user_id":sys.argv[2],"source":"koe-cli"}))' "$KOE_TXT" "${KOE_VOICE:-yuki}" 2>/dev/null)" 2>/dev/null)"
      if [ "$KOE_HTTP" = "200" ] && [ "$(wc -c < "$KOE_TMP" 2>/dev/null || echo 0)" -gt 1000 ]; then
        afplay "$KOE_TMP" 2>/dev/null || mpg123 "$KOE_TMP" 2>/dev/null || true
        rm -f "$KOE_TMP"
      else
        echo "🔴 合成できませんでした(HTTP ${KOE_HTTP:-?})" >&2
        rm -f "$KOE_TMP"; exit 1
      fi
      exit 0
    fi
    ;;
esac

find_opencode() {
  command -v opencode 2>/dev/null && return 0
  for p in "$HOME/.opencode/bin/opencode" "$HOME/.local/bin/opencode" \
           /opt/homebrew/bin/opencode /usr/local/bin/opencode; do
    [ -x "$p" ] && { echo "$p"; return 0; }
  done
  return 1
}

# 🏷 プロセス名を "sente" にして起動する(pgrep -x sente / oc_stale / resguard の前提)。
# 以前は `exec -a sente "$OC"` だったが、-a は bash/zsh 拡張で Debian/Ubuntu の /bin/sh(dash)
# では "exec: -a: not found" になり TUI が起動しない(2026-09-10 実測)。
# 代わりに $CONFIG_DIR/bin/sente → $OC の symlink を作り、その名前で exec する。
# macOS の pgrep -x / ps comm は basename、Linux は /proc/<pid>/comm(=symlink 名)で一致するので
# 監視側(pgrep -x sente)は無変更で動く。symlink が作れない環境は $OC 直 exec に落ちる(名前は opencode)。
sente_exec_path() {  # → stdout: exec すべきパス(symlink or $OC)。$OC 未設定なら空
  [ -n "${OC:-}" ] || return 1
  SXP="$CONFIG_DIR/bin/sente"
  if [ -L "$SXP" ] && [ "$(readlink "$SXP" 2>/dev/null)" = "$OC" ]; then printf '%s\n' "$SXP"; return 0; fi
  mkdir -p "$CONFIG_DIR/bin" 2>/dev/null && ln -sfn "$OC" "$SXP" 2>/dev/null && [ -x "$SXP" ] && { printf '%s\n' "$SXP"; return 0; }
  printf '%s\n' "$OC"
}
sente_exec() {  # 引数=opencodeへの引数。現在のシェルを sente(=$OC)に置き換える
  exec "$(sente_exec_path)" "$@"
}

# 🔀 実行エンジン切替(2026-08-06本人指示「senteからopencode/Claude Code/Codexを使えるようにして」):
# 既定はopencode(従来どおり)。優先順位: 環境変数TE_ENGINE > ~/.config/teai/engine(`te engine`で永続) > 既定opencode
sente_engine_get() {  # → stdoutへ claude|codex|opencode のいずれか1つ
  if [ -n "${TE_ENGINE:-}" ]; then
    case "$TE_ENGINE" in claude|codex|opencode) printf '%s\n' "$TE_ENGINE"; return 0 ;; esac
  fi
  if [ -f "$CONFIG_DIR/engine" ]; then
    SEG="$(head -1 "$CONFIG_DIR/engine" 2>/dev/null | tr -d '[:space:]')"
    case "$SEG" in claude|codex) printf '%s\n' "$SEG"; return 0 ;; esac
  fi
  printf 'opencode\n'
}
sente_engine_set() {  # $1=claude|codex|opencode — アトミック書き(一時ファイル+mv。既存の *.tmp→mv パターンと同じ手口)
  mkdir -p "$CONFIG_DIR" 2>/dev/null || true
  if [ "$1" = "opencode" ]; then
    rm -f "$CONFIG_DIR/engine" 2>/dev/null || true
    return 0
  fi
  SET_TMP="$(mktemp "$CONFIG_DIR/.engine.XXXXXX" 2>/dev/null || true)"
  if [ -n "$SET_TMP" ]; then
    printf '%s\n' "$1" > "$SET_TMP" && mv -f "$SET_TMP" "$CONFIG_DIR/engine"
  else
    printf '%s\n' "$1" > "$CONFIG_DIR/engine"   # mktempが使えない環境向けの保険
  fi
}

load_key() {
  # Env var wins over the credentials file (12-factor; also enables per-run overrides)
  if [ -z "${TEAI_API_KEY:-}" ] && [ -f "$CREDS" ]; then
    # shellcheck disable=SC1090
    . "$CREDS"
  fi
  export TEAI_API_KEY="${TEAI_API_KEY:-}"
}

# 🔑 鍵が無ければ、その場で登録に案内する。TTYなら「登録する?」と聞いて te register を呼ぶ。
# 鍵があれば何もしない。sente/te/te run 起動の入口で使う(登録できなければ0以外で終了)。
ensure_key() {
  load_key
  [ -z "${TEAI_API_KEY:-}" ] || return 0
  echo "" >&2
  echo "🔑 まだ teai.io のAPIキーがありません。" >&2
  echo "   Senteを使うには無料登録が必要です(30秒・メールだけ)。" >&2
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    echo "   → 端末で次を実行してください: te register  (すでに鍵がある方は te login)" >&2
    echo "   ブラウザ登録: ${TEAI_SITE:-https://teai.io}/register" >&2
    return 1
  fi
  printf "   いま登録しますか? [Y/n]: " >&2
  ANS="$(head -1 /dev/tty 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  case "$ANS" in
    n|no) echo "   あとで: te register / te login ・ ${TEAI_SITE:-https://teai.io}/register" >&2; return 1 ;;
  esac
  # 同じ launcher の register サブコマンドを呼ぶ(実体は $0)
  "$0" register || return 1
  load_key
  [ -n "${TEAI_API_KEY:-}" ] || { echo "   登録が完了していません。te register からやり直してください。" >&2; return 1; }
  return 0
}

# ⚡ 声モードを軽くする。
# opencode はグローバル設定にある MCP サーバを毎回起動し、そのツール定義を
# 全部モデルに送る。手元では212本あり、同じ問いで **7.5秒 → 2.7秒**(初回は
# 30秒超 → 2秒台)と実測で3倍近く違った。声の一往復にその重さは要らないので、
# 話しかけるモードのときだけ MCP を外した設定を使う。
# ファイル読み書き・bash 等の組み込みツールは残るので、ふつうの作業はできる。
# MCP ごと使いたいときは TE_VOICE_MCP=1。
sente_light_env() {
  [ "${TE_VOICE_MCP:-0}" = "1" ] && return 0
  LIGHT_XDG="$CONFIG_DIR/voice-xdg"
  mkdir -p "$LIGHT_XDG/opencode" 2>/dev/null || return 0
  # グローバル設定から mcp だけ外したものを見せる(OPENCODE_CONFIG は別途効く)。
  # 🔴2026-08-15実障害: 以前はここを空の{"$schema":...}だけにしていたが、
  # opencode-voice.json が無い/読めない状況では model・provider(teai)の定義ごと
  # 消えてしまい、OpenCode が teai プロバイダーを見失って組み込みの別モデル
  # (Google gemini-3-pro-image="Nano Banana Pro")にフォールバックしTUIに表示される
  # 実害が出た。model/provider は必ず引き継ぐ。
  python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except Exception:
    d = {}
d.pop("mcp", None)
d.setdefault("$schema", "https://opencode.ai/config.json")
d.setdefault("model", "teai/auto")
with open(sys.argv[2], "w") as f:
    json.dump(d, f)
' "$CONFIG_DIR/opencode.json" "$LIGHT_XDG/opencode/opencode.json" 2>/dev/null \
    || printf '{"$schema":"https://opencode.ai/config.json","model":"teai/auto"}\n' > "$LIGHT_XDG/opencode/opencode.json" 2>/dev/null \
    || return 0
  XDG_CONFIG_HOME="$LIGHT_XDG"
  export XDG_CONFIG_HOME
  # teai 設定側の MCP ゲートウェイ(/te/config の "mcp")も声モードでは外す。
  # サーバ生成の声モード設定(?mcp=voice=koeのみ → opencode-voice.json)があればそちらへ。
  # 全サービス注入はプロンプトが重くなるが、koe単体は遅延ノイズ内と実測済み(2026-08-06)。
  # ⚠ te v はここを共通初期化(export OPENCODE_CONFIG="$CFG")より先に呼ぶので、
  # export はここと初期化側の両方で行う(SENTE_LIGHT マーカーで判定)。
  SENTE_LIGHT=1
  if [ -f "$CONFIG_DIR/opencode-voice.json" ]; then
    OPENCODE_CONFIG="$CONFIG_DIR/opencode-voice.json"
    export OPENCODE_CONFIG
    SENTE_CONFIG="$CONFIG_DIR/opencode-voice.json"
    export SENTE_CONFIG
  fi
}

# 🔒 PIIスクラビング・プロキシ(オプトイン・`te privacy scrub on`): 送信直前にローカルLLM
# (Ollama)+正規表現で個人情報/機密情報(氏名・住所・電話・APIキー等)を検出しプレースホルダへ
# 置換してから teai.io へ転送し、応答は復元してから返す。フェイルクローズ: Ollamaが使えない
# 場合は平文のまま先へ進ませず、ここで明確に止める。
SCRUB_PIDFILE="$CONFIG_DIR/scrub-proxy.pid"
SCRUB_PORTFILE="$CONFIG_DIR/scrub-proxy.port"
SCRUB_SCRIPT="$CONFIG_DIR/scrub-proxy.py"
write_scrub_proxy() {
  local SCRUB_HASH="df0fb725134cd89f11985642f66f5f98"
  [ -f "$SCRUB_SCRIPT" ] && [ "$(sente_hash_file "$SCRUB_SCRIPT")" = "$SCRUB_HASH" ] && return 0
  cat > "$SCRUB_SCRIPT" <<'SCRUBPROXY'
#!/usr/bin/env python3
# Sente scrub proxy: ローカルLLM(Ollama)+正規表現で個人情報/機密情報を検出し、
# プレースホルダに置換してから teai.io へ転送する。応答は復元してから返す。
# フェイルクローズ: スクラブ自体が失敗したら平文のまま上流へは絶対に転送しない。
import http.server
import socketserver
import urllib.request
import urllib.error
import json
import re
import sys
import os
import threading
import time

UPSTREAM = os.environ.get("SENTE_SCRUB_UPSTREAM", "https://api.teai.io")
OLLAMA_URL = os.environ.get("SENTE_SCRUB_OLLAMA", "http://127.0.0.1:11434")
OLLAMA_MODEL = os.environ.get("SENTE_SCRUB_MODEL", "qwen3.5:4b")
DEBUG_LOG = os.environ.get("TE_SCRUB_DEBUG_LOG") or None
PORT_FILE = sys.argv[1] if len(sys.argv) > 1 else None

MAP_LOCK = threading.Lock()
PLACEHOLDER_MAP = {}  # placeholder -> original (プロセス生存期間中は蓄積し続ける)
COUNTERS = {}

REGEX_RULES = [
    # \w は Unicode 文字クラスも含むため ASCII に限定しないと日本語の地の文
    # (例:「メールは」)まで巻き込んでマッチしてしまう(実測で踏んだ罠)
    ("EMAIL", re.compile(r"[A-Za-z0-9][A-Za-z0-9._+-]*@[A-Za-z0-9-]+\.[A-Za-z0-9.-]+")),
    ("PHONE", re.compile(r"0\d{1,4}-\d{1,4}-\d{3,4}\b")),
    ("APIKEY", re.compile(r"\b(?:sk|te|pk|rk|ghp|xox[bpsa])[_-][A-Za-z0-9_-]{10,}\b")),
    ("APIKEY", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("ZIPADDR", re.compile(r"〒?\d{3}-\d{4}[^\n。、]{0,40}")),
    ("TOKEN", re.compile(r"\b[A-Za-z0-9_-]{40,}\b")),
]


def next_placeholder(kind):
    with MAP_LOCK:
        COUNTERS[kind] = COUNTERS.get(kind, 0) + 1
        return "[%s_%d]" % (kind, COUNTERS[kind])


def regex_scrub(text):
    for kind, rx in REGEX_RULES:
        def repl(m, kind=kind):
            ph = next_placeholder(kind)
            with MAP_LOCK:
                PLACEHOLDER_MAP[ph] = m.group(0)
            return ph
        text = rx.sub(repl, text)
    return text


def ollama_detect(text):
    """ローカルLLMに検出だけさせる(書き換えさせない=幻覚による改変を避ける)。
    失敗時は None を返し呼び出し側でフェイルクローズさせる(空配列=検出なし、とは区別する)。"""
    if not text.strip():
        return []
    prompt = (
        "次の文章から、人名・住所・組織名など機微な個人情報になりうる部分文字列だけを"
        "一切改変せずそのまま抜き出し、JSON配列(文字列のみ)で返してください。"
        "無ければ空配列 [] を返してください。説明や前置きは書かないこと。\n\n" + text
    )
    body = json.dumps({
        "model": OLLAMA_MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "stream": False,
        "think": False,
        "options": {"temperature": 0},
    }).encode("utf-8")
    req = urllib.request.Request(
        OLLAMA_URL + "/api/chat", data=body,
        headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            data = json.load(r)
        content = (data.get("message") or {}).get("content", "").strip()
        start, end = content.find("["), content.rfind("]")
        if start == -1 or end == -1:
            return []
        spans = json.loads(content[start:end + 1])
        return [s for s in spans if isinstance(s, str) and s.strip()]
    except Exception:
        return None


PLACEHOLDER_RE = re.compile(r"^\[[A-Z]+_\d+\]$")


def llm_scrub(text):
    spans = ollama_detect(text)
    if spans is None:
        raise RuntimeError("ollama_unavailable")
    for s in spans:
        if PLACEHOLDER_RE.match(s):
            continue  # regexパスで既にマスク済みのプレースホルダ自体を再マスクしない
        with MAP_LOCK:
            already = s in PLACEHOLDER_MAP.values()
        if s and s in text and not already:
            ph = next_placeholder("PERSON")
            with MAP_LOCK:
                PLACEHOLDER_MAP[ph] = s
            text = text.replace(s, ph)
    return text


def scrub_text(text):
    text = regex_scrub(text)
    text = llm_scrub(text)  # raises RuntimeError -> 呼び出し側でフェイルクローズ
    return text


def unscrub_text(text):
    with MAP_LOCK:
        items = sorted(PLACEHOLDER_MAP.items(), key=lambda kv: -len(kv[0]))
    for ph, orig in items:
        text = text.replace(ph, orig)
    return text


def scrub_message_content(content):
    if isinstance(content, str):
        return scrub_text(content)
    if isinstance(content, list):
        out = []
        for part in content:
            if isinstance(part, dict) and part.get("type") == "text" and "text" in part:
                part = dict(part)
                part["text"] = scrub_text(part["text"])
            out.append(part)
        return out
    return content


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # 端末出力を汚さない(静音)

    def _write(self, status, body_bytes, content_type="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.end_headers()
        self.wfile.write(body_bytes)

    def _error(self, code, msg):
        self._write(code, json.dumps({"error": msg}).encode("utf-8"))

    def do_GET(self):
        # モデル一覧取得等の素通し(PIIを含まない読み取り専用リクエスト)
        req = urllib.request.Request(
            UPSTREAM + self.path,
            headers={"Authorization": self.headers.get("Authorization", "")})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                self._write(r.status, r.read())
        except urllib.error.HTTPError as e:
            self._write(e.code, e.read())
        except Exception:
            self._error(502, "upstream_unreachable")

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            payload = json.loads(raw) if raw else {}
        except Exception:
            self._error(400, "invalid_json")
            return

        wants_stream = bool(payload.get("stream"))
        try:
            for m in payload.get("messages", []):
                if isinstance(m, dict) and "content" in m:
                    m["content"] = scrub_message_content(m["content"])
        except RuntimeError:
            # フェイルクローズ: ローカルLLMが使えない -> 平文のまま先へ進めない
            self._error(503, "scrub_failed_ollama_unavailable")
            return
        except Exception:
            self._error(500, "scrub_internal_error")
            return

        payload["stream"] = False  # 復元にはレスポンス全文が要るので常に非ストリームで上流へ
        if DEBUG_LOG:
            try:
                with open(DEBUG_LOG, "a", encoding="utf-8") as f:
                    f.write(json.dumps({"ts": time.time(), "sent": payload}, ensure_ascii=False) + "\n")
            except Exception:
                pass

        upstream_req = urllib.request.Request(
            UPSTREAM + self.path, data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json",
                     "Authorization": self.headers.get("Authorization", "")},
            method="POST")
        try:
            with urllib.request.urlopen(upstream_req, timeout=180) as r:
                resp_body, status = r.read(), r.status
        except urllib.error.HTTPError as e:
            resp_body, status = e.read(), e.code
        except Exception:
            self._error(502, "upstream_unreachable")
            return

        try:
            resp_json = json.loads(resp_body)
            for c in resp_json.get("choices", []):
                msg = c.get("message") or {}
                if isinstance(msg.get("content"), str):
                    msg["content"] = unscrub_text(msg["content"])
            resp_body = json.dumps(resp_json).encode("utf-8")
        except Exception:
            pass  # 復元に失敗しても、スクラブ後のbodyそのもの(上流のエラーJSON等)は返す

        if wants_stream:
            # OpenCode側のSSEパーサを満たすため、全文を1チャンクにまとめて返す
            # (代償: 逐次ストリーミング表示は失われ、応答は一括表示になる)
            self.send_response(status)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            self.wfile.write(b"data: " + resp_body + b"\n\n")
            self.wfile.write(b"data: [DONE]\n\n")
        else:
            self._write(status, resp_body)


def main():
    base_port = int(os.environ.get("SENTE_SCRUB_PORT", "8765"))
    httpd = None
    port = base_port
    for i in range(6):
        try:
            httpd = socketserver.ThreadingTCPServer(("127.0.0.1", base_port + i), Handler)
            port = base_port + i
            break
        except OSError:
            continue
    if httpd is None:
        sys.exit(1)
    if PORT_FILE:
        with open(PORT_FILE, "w") as f:
            f.write(str(port))
    httpd.serve_forever()


if __name__ == "__main__":
    main()
SCRUBPROXY
}
# 起動済みで生きていれば再利用する(Ollamaのモデルウォームアップコストを毎回払わないため。
# 複数の`te`セッションが同時に動くこともある前提で、殺さず共有プロセスとして扱う)。
sente_start_scrub_proxy() {
  if ! command -v ollama >/dev/null 2>&1; then
    echo "✗ PIIスクラビングには ollama が必要です。$(sente_pkg_hint ollama) してから: ollama pull ${TE_SCRUB_MODEL:-qwen3.5:4b}" >&2
    exit 1
  fi
  if ! curl -fsS -m 3 http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
    echo "✗ ollama が起動していません。別ターミナルで 'ollama serve' を実行してから再試行してください" >&2
    exit 1
  fi
  if ! ollama list 2>/dev/null | grep -q "${TE_SCRUB_MODEL:-qwen3.5:4b}"; then
    echo "✗ モデル ${TE_SCRUB_MODEL:-qwen3.5:4b} が未取得です。'ollama pull ${TE_SCRUB_MODEL:-qwen3.5:4b}' を実行してください" >&2
    exit 1
  fi
  if [ -f "$SCRUB_PIDFILE" ] && [ -f "$SCRUB_PORTFILE" ] && kill -0 "$(cat "$SCRUB_PIDFILE" 2>/dev/null)" 2>/dev/null; then
    SCRUB_PORT="$(cat "$SCRUB_PORTFILE" 2>/dev/null)"
    [ -n "$SCRUB_PORT" ] && return 0
  fi
  write_scrub_proxy
  rm -f "$SCRUB_PORTFILE"
  ( SENTE_SCRUB_MODEL="${TE_SCRUB_MODEL:-qwen3.5:4b}" \
    SENTE_SCRUB_UPSTREAM="${TE_SCRUB_UPSTREAM:-https://api.teai.io}" \
    TE_SCRUB_DEBUG_LOG="$([ "${TE_SCRUB_DEBUG:-0}" = 1 ] && echo "$CONFIG_DIR/scrub-debug.log" || true)" \
    nohup python3 "$SCRUB_SCRIPT" "$SCRUB_PORTFILE" >/dev/null 2>&1 & echo $! > "$SCRUB_PIDFILE" )
  local i=0
  while [ ! -s "$SCRUB_PORTFILE" ] && [ "$i" -lt 25 ]; do sleep 0.2; i=$((i+1)); done
  if [ ! -s "$SCRUB_PORTFILE" ]; then
    echo "✗ PIIスクラビング・プロキシの起動に失敗しました" >&2
    exit 1
  fi
  SCRUB_PORT="$(cat "$SCRUB_PORTFILE")"
}
sente_apply_scrub_baseurl() {
  [ -n "${SCRUB_PORT:-}" ] || return 0
  if ! python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
d["provider"]["teai"]["options"]["baseURL"] = "http://127.0.0.1:" + sys.argv[3] + "/v1"
with open(sys.argv[2], "w") as f:
    json.dump(d, f)
' "$CFG" "$CONFIG_DIR/opencode-scrub.json" "$SCRUB_PORT" 2>/dev/null; then
    echo "✗ PIIスクラビング用configの生成に失敗しました" >&2
    exit 1
  fi
  CFG="$CONFIG_DIR/opencode-scrub.json"
  export OPENCODE_CONFIG="$CFG"
  export SENTE_CONFIG="$CFG"
}

# 🎚 使うほど馴染ませる: 声のやりとりを全部残し、次の起動でタイミングを調整する。
# 残すのは「録音そのもの」と「そのターンで何が起きたか」。手元だけに置く(外へは出さない)。
SENTE_REC_DIR="$SENTE_DATA_DIR/rec"
SENTE_TURNS="$SENTE_LOG_DIR/turns.jsonl"
SENTE_TUNE="$HOME/.config/teai/sente-tuning.json"
SENTE_LAT="$SENTE_LOG_DIR/latency.jsonl"
# 声で待てるのはこのくらい、という基準。超え続けるならモデルを速い方へ寄せる。
SENTE_TARGET_S="${TE_VOICE_TARGET_S:-5}"
# 速い順に並べた候補。左ほど速く、右ほど賢い。
# 2026-08-06本人FB「なんでこんなアホなの?」→ grok-3-miniを外し、最速枠も賢いhaiku4.5に
# (haikuは速さがgrok-3-mini並みで賢さが段違い。賢さ採点(sente_quality_judge)が低いと右へ動く)
SENTE_MODEL_LADDER="claude-haiku-4-5-20251001 z-ai/glm-5.2 claude-sonnet-5"
SENTE_QUALITY="$SENTE_LOG_DIR/quality.jsonl"

# 🌙 連続空振り検知(2026-08-13追加): 深夜など「起動したまま席を外した」状態では
# 環境音がempty/hallucination/noiseとして延々記録され続けるだけで害はないが、ログを
# 汚し続ける。DEAD_AIR_FILEに連続回数を数え、ok/barge/echo(=何かしら声を認識できた)
# が来たら0に戻す。閾値超えでtalkループ側が声で一言知らせて安全終了する(sente_dead_air_hit参照)。
SENTE_DEAD_AIR_FILE="/tmp/sente_dead_air_count"
sente_dead_air_bump() {  # $1=outcome
  case "$1" in
    ok|barge|echo) rm -f "$SENTE_DEAD_AIR_FILE" 2>/dev/null ;;
    empty|hallucination|noise|nostart)
      N="$(cat "$SENTE_DEAD_AIR_FILE" 2>/dev/null || echo 0)"
      case "$N" in ''|*[!0-9]*) N=0 ;; esac
      printf '%s' "$((N + 1))" > "$SENTE_DEAD_AIR_FILE" 2>/dev/null || true
      ;;
  esac
}
sente_dead_air_hit() {  # 0=閾値到達(talkループ側が終了処理をする)
  N="$(cat "$SENTE_DEAD_AIR_FILE" 2>/dev/null || echo 0)"
  case "$N" in ''|*[!0-9]*) N=0 ;; esac
  [ "$N" -ge "${TE_DEAD_AIR_LIMIT:-8}" ]
}

sente_log_turn() {  # $1=wav(残す元) $2=結果の種類 $3=聞き取れた文
  [ "${TE_NO_RECORD:-0}" = "1" ] && return 0
  sente_dead_air_bump "$2"
  mkdir -p "$SENTE_REC_DIR" "$(dirname "$SENTE_TURNS")" 2>/dev/null || return 0
  # 🔒 録音と聞き取りログは声の生データ=本人以外読めない権限に(共用マシン対策)
  chmod 700 "$SENTE_REC_DIR" "$(dirname "$SENTE_TURNS")" 2>/dev/null
  [ -f "$SENTE_TURNS" ] || { : > "$SENTE_TURNS" 2>/dev/null; chmod 600 "$SENTE_TURNS" 2>/dev/null; }
  RT_TS="$(date '+%Y%m%d-%H%M%S')"
  # 録音のコピーだけは同期でとる(呼び出し側が元を消すため)。
  # 解析(ffprobe/ffmpeg/python の起動で 0.3〜0.5秒)は待たせる価値がないので裏へ。
  # 声のやりとりでは、この0.5秒がそのまま「返事が遅い」になる。
  [ -f "$1" ] && cp "$1" "$SENTE_REC_DIR/$RT_TS.wav" 2>/dev/null
  (
    RT_DUR=""; RT_PEAK=""
    RT_W="$SENTE_REC_DIR/$RT_TS.wav"
    if [ -f "$RT_W" ]; then
      command -v ffprobe >/dev/null 2>&1 && RT_DUR="$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$RT_W" 2>/dev/null)"
      command -v ffmpeg  >/dev/null 2>&1 && RT_PEAK="$(ffmpeg -i "$RT_W" -af volumedetect -f null /dev/null 2>&1 | sed -n 's/.*max_volume: \(-\{0,1\}[0-9.]*\) dB.*/\1/p')"
    fi
    # jsonの引用符は python に任せる(聞き取り文に " や改行が入るため)
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$RT_TS" "$2" "${RT_DUR:-}" "${RT_PEAK:-}" "${TE_TALK_SILENCE:-1.5}" "$3" \
      | python3 -c '
import sys, json
for line in sys.stdin:
    f = line.rstrip("\n").split("\t")
    while len(f) < 6: f.append("")
    print(json.dumps({"ts": f[0], "outcome": f[1], "dur": f[2], "peak": f[3], "silence": f[4], "heard": f[5]}, ensure_ascii=False))
' >> "$SENTE_TURNS" 2>/dev/null || true
  ) >/dev/null 2>&1 &
}

# 直近のやりとりを見て「話し終わりの待ち時間」を決める。
# 判断はひとつだけ: **文の途中で切られていないか**。日本語は助詞で終わったら
# まだ続きがある合図なので、その割合が高ければ待ちを伸ばす。逆に取りこぼしが
# 少なくて雑音ばかり拾っているなら詰める。1回の変更は±0.3秒までにして暴れさせない。
sente_autotune() {
  [ "${TE_NO_AUTOTUNE:-0}" = "1" ] && return 0
  [ -f "$SENTE_TURNS" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  python3 - "$SENTE_TURNS" "$SENTE_TUNE" <<'PYTUNE' 2>/dev/null || true
import json, sys, os, re
turns_path, tune_path = sys.argv[1], sys.argv[2]
rows = []
try:
    with open(turns_path) as f:
        for line in f:
            try: rows.append(json.loads(line))
            except Exception: pass
except Exception:
    sys.exit(0)
rows = rows[-60:]
if len(rows) < 12: sys.exit(0)          # 少ないうちは動かさない

cur = 1.5
try:
    cur = float(json.load(open(tune_path)).get("talk_silence", 1.5))
except Exception:
    for r in reversed(rows):
        try: cur = float(r.get("silence") or 1.5); break
        except Exception: pass

heard = [r for r in rows if r.get("outcome") == "ok" and (r.get("heard") or "").strip()]
noise = [r for r in rows if r.get("outcome") in ("noise", "hallucination", "short")]
# 助詞・接続で終わる = まだ続きがあったのに切られた合図
CUT = re.compile(r"(て|で|を|に|は|が|と|の|や|ば|し|から|ので|けど|けれど|そして|それで)$")
def tail(s): return re.sub(r"[。、．，!！?？…\s]+$", "", (s or "").strip())
cut = sum(1 for r in heard if CUT.search(tail(r.get("heard"))))
cut_rate = cut / len(heard) if heard else 0.0
noise_rate = len(noise) / len(rows)

new = cur
why = ""
# 🛑 2026-08-17: 「切れている」の判定材料(okサンプル)が少ないと1件で発火し、
# talk_silence が 3.0 まで上がり続けた(実ログ: 1.0→3.0 でok率 38%→5% まで悪化)。
# ①okが8件以上ある時だけ上げる ②上限は2.0(それ以上は録音窓が伸びて環境音を
# 拾いやすくなる悪循環を生む。長く話す人が居たら TE_TALK_SILENCE で明示指定する)
if heard and len(heard) >= 8 and cut_rate >= 0.30:
    new = min(2.0, round(cur + 0.3, 2)); why = f"途中で切れている割合 {cut_rate:.0%}"
elif heard and cut_rate <= 0.10 and noise_rate >= 0.35 and cur > 1.0:
    new = max(1.0, round(cur - 0.2, 2)); why = f"取りこぼしが少なく雑音が多い(雑音 {noise_rate:.0%})"

# 📏 核の4指標(本人指示2026-08-06「動かない核=相手の不安を減らす」の計測面):
# ①自問自答(echo率) ②雑音率 ③ok率 ④割り込み(barge)数。毎起動で記録し、悪化に気づけるようにする
echo_n = sum(1 for r in rows if r.get("outcome") == "echo")
barge_n = sum(1 for r in rows if r.get("outcome") == "barge")
metrics = {"echo_rate": round(echo_n / len(rows), 3), "noise_rate": round(noise_rate, 3),
           "ok_rate": round(len(heard) / len(rows), 3), "barge_n": barge_n, "window": len(rows)}
try:
    keep = {}
    try: keep = json.load(open(tune_path))
    except Exception: pass
    keep["metrics"] = metrics
    if abs(new - cur) >= 0.05:
        keep.update({"talk_silence": new, "why": why, "samples": len(rows)})
        print(f"  🎚 話し終わりの待ちを {cur}s → {new}s に調整しました({why})", file=sys.stderr)
    if metrics["echo_rate"] >= 0.15:
        print(f"  ⚠ 自問自答(こだま)率が {metrics['echo_rate']:.0%} と高めです(直近{len(rows)}ターン)", file=sys.stderr)
    json.dump(keep, open(tune_path, "w"), ensure_ascii=False)
except Exception: pass
PYTUNE
}

# 調整結果があれば、次の起動から効かせる(環境変数で明示指定されていればそちらを優先)
# 応答時間を基準内に収める。超え続けるなら速いモデルへ、余裕があれば賢い方へ戻す。
# 一度に1段だけ動かす(行ったり来たりさせない)。
sente_autotune_model() {
  [ "${TE_NO_AUTOTUNE:-0}" = "1" ] && return 0
  [ -n "${TE_VOICE_FAST_MODEL:-}" ] && return 0      # 明示指定があれば触らない
  [ -f "$SENTE_LAT" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  python3 - "$SENTE_LAT" "$SENTE_TUNE" "$SENTE_TARGET_S" "$SENTE_MODEL_LADDER" "$SENTE_QUALITY" <<'PYLAT' 2>/dev/null || true
import json, sys, os, statistics
lat_path, tune_path, target, ladder = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4].split()
q_path = sys.argv[5] if len(sys.argv) > 5 else ""
rows = []
try:
    for line in open(lat_path):
        try: rows.append(json.loads(line))
        except Exception: pass
except Exception: sys.exit(0)
rows = rows[-20:]
if len(rows) < 8: sys.exit(0)
secs = sorted(float(r.get("sec", 0)) for r in rows)
p50 = statistics.median(secs)
# 📈 賢さ採点(sente_quality_judge)の直近平均。速さより賢さを優先する(2026-08-06本人指示)
qs = []
try:
    for line in open(q_path):
        try:
            v = json.loads(line).get("q")
            if isinstance(v, (int, float)): qs.append(float(v))
        except Exception: pass
except Exception: pass
qs = qs[-12:]
qavg = (sum(qs) / len(qs)) if len(qs) >= 6 else None
tune = {}
try: tune = json.load(open(tune_path))
except Exception: pass
cur = tune.get("voice_model") or ladder[0]
i = ladder.index(cur) if cur in ladder else 0
new, why = cur, ""
if qavg is not None and qavg < 3.6 and i < len(ladder) - 1:
    new, why = ladder[i+1], f"賢さの採点が平均{qavg:.1f}と低いので、多少遅くても賢い方へ"
elif p50 > target and i > 0 and (qavg is None or qavg >= 4.2):
    # 速い方への降格は、賢さに余裕がある時だけ(賢さ不明のうちは従来どおり速度基準)
    new, why = ladder[i-1], f"返事が{p50:.1f}秒かかっていて基準{target:.0f}秒を超えている"
elif p50 < target * 0.5 and i < len(ladder) - 1:
    new, why = ladder[i+1], f"返事が{p50:.1f}秒と余裕があるので、より賢い方へ"
if new != cur:
    tune["voice_model"] = new; tune["voice_model_why"] = why; tune["voice_p50"] = round(p50, 2)
    if qavg is not None: tune["voice_quality"] = round(qavg, 2)
    json.dump(tune, open(tune_path, "w"), ensure_ascii=False)
    print(f"  🎚 声のモデルを {cur} → {new} に({why})", file=sys.stderr)
PYLAT
}

# 📈 回答の「賢さ」を毎ターン裏で採点して残す(本人指示2026-08-06「回答後に賢いかも評価して改善して」)。
# ログは手元のみ(quality.jsonl)。sente_autotune_model がこれを読み、賢さが落ちていたら
# 速度より賢さを優先してモデルを賢い方へ動かす。無効化=TE_NO_QJUDGE=1。
# ($()内ヒアドキュメント禁止=bash3.2罠につき一時ファイル経由)
sente_quality_judge() {  # $1=聞き取り $2=返答 — 裏で(&付きで)呼ぶ。失敗は静かに諦める
  [ "${TE_NO_QJUDGE:-0}" = "1" ] && return 0
  command -v python3 >/dev/null 2>&1 || return 0
  load_key
  [ -n "${TEAI_API_KEY:-}" ] || return 0
  mkdir -p "$(dirname "$SENTE_QUALITY")" 2>/dev/null || return 0
  QJ_TMP="$(mktemp "${TMPDIR:-/tmp}/te_qj_XXXXXX")"
  TEAI_API_KEY="$TEAI_API_KEY" python3 - "$1" "$2" "${TE_QJUDGE_MODEL:-claude-haiku-4-5-20251001}" >"$QJ_TMP" 2>/dev/null <<'PYQJ' || true
import json, os, sys, time, urllib.request
utter, reply, model = sys.argv[1][:300], sys.argv[2][:600], sys.argv[3]
sysmsg = ("あなたは音声アシスタントの回答品質の採点者。ユーザー発話とアシスタント返答を見て1〜5で採点し、"
          "JSONだけを1行で出力: {\"q\": 数, \"why\": \"15字以内\"}。"
          "5=質問に的確に答え簡潔 / 3=無難だが薄い / 1=質問に答えていない・"
          "知らないはずの事実(天気・時刻・ニュース等)を言い切っている・的外れ。")
body = json.dumps({"model": model, "max_tokens": 60, "temperature": 0,
                   "messages": [{"role": "system", "content": sysmsg},
                                {"role": "user", "content": "発話:" + utter + "\n返答:" + reply}]}).encode()
req = urllib.request.Request("https://api.teai.io/v1/chat/completions", data=body,
                             headers={"Content-Type": "application/json",
                                      "Authorization": "Bearer " + os.environ.get("TEAI_API_KEY", "")})
try:
    r = json.load(urllib.request.urlopen(req, timeout=20))
    t = (r["choices"][0]["message"]["content"] or "").strip()
    d = json.loads(t[t.find("{"):t.rfind("}") + 1])
    q = int(d.get("q", 0))
    if 1 <= q <= 5:
        print(json.dumps({"ts": int(time.time()), "q": q, "why": str(d.get("why", ""))[:40],
                          "model": os.environ.get("SENTE_QJ_TARGET", "")}, ensure_ascii=False))
except Exception:
    pass
PYQJ
  [ -s "$QJ_TMP" ] && cat "$QJ_TMP" >> "$SENTE_QUALITY" 2>/dev/null
  rm -f "$QJ_TMP"
}

# ♟ 先手の一手: パソコンの中(人間ゲート正本・最近さわったリポジトリ・裏作業)を見て、
# 「いま最初に打つと一番効く一手」をひとつだけ提案する(2026-08-06本人指示「起動した後に
# パソコンの中見て次何やるか提案してほしい、先手らしく」)。提案に「やって」と返せば
# そのままその作業を始める。起動時に裏で1回+`te next`+声「次何やる?」で呼べる。
# データは全て手元で読み、外に出るのは要約(6000字上限)をteai APIに送る分だけ。無効化=TE_NO_OPENING=1
SENTE_GATES="${TE_GATES_FILE:-$HOME/workspace/tasks/human-gates.md}"
sente_opening_scan() {  # 状況の要約テキストをstdoutへ(2秒以内目安・読むだけで何も変えない)
  printf 'いま: %s\n' "$(date '+%Y-%m-%d(%a) %H:%M')"
  if [ -f "$SENTE_GATES" ]; then
    printf '\n## 人間の判断待ち一覧(正本・上ほど新しい)\n'
    head -100 "$SENTE_GATES" 2>/dev/null || true
  fi
  printf '\n## 最近さわったリポジトリ\n'
  for OPG in $(ls -dt "$HOME"/workspace/*/.git 2>/dev/null | head -5); do
    OPR="${OPG%/.git}"
    OPD="$(git -C "$OPR" status --short 2>/dev/null | wc -l | tr -d ' ')"
    OPA="$(git -C "$OPR" log --oneline @{u}.. 2>/dev/null | wc -l | tr -d ' ')"
    printf -- '- %s: 未コミット%s件 / 未push%sコミット\n' "$(basename "$OPR")" "${OPD:-0}" "${OPA:-0}"
  done
  if [ -d "$CONFIG_DIR/bg" ]; then
    OPB="$(ls "$CONFIG_DIR/bg"/*.json 2>/dev/null | grep -cv 'done' || true)"
    printf '\n## Senteの裏作業(実行中/未報告): %s件\n' "${OPB:-0}"
  fi
  # 🔁 前回の声セッションで何を話していたか(2026-08-10本人採用「続きから」提案)。
  # turns.jsonlの聞き取り(ok/barge)の末尾だけ=途中で終わった話があれば「昨日の◯◯の続き」を出せる
  if [ -f "$SENTE_TURNS" ] && command -v python3 >/dev/null 2>&1; then
    printf '\n## 前回の声セッションの終わりの方(聞き取り・古い順)\n'
    grep -e '"outcome": "ok"' -e '"outcome": "barge"' "$SENTE_TURNS" 2>/dev/null | tail -8 | \
      python3 -c 'import json,sys
for l in sys.stdin:
    try: r = json.loads(l)
    except Exception: continue
    h = (r.get("heard") or "").strip()
    if h: print("- [" + r.get("ts","")[:13] + "] " + h[:90])' 2>/dev/null || true
  fi
  # 🧠 継続学習(2026-08-13本人指示「ログとって継続学習して」): fusekiが過去に何を提案したかを
  # 毎回の文脈に含める。同じ話題を毎回ゼロから提案するのではなく、「これは何度目か」「前と何が
  # 変わったか」を踏まえた一手を選べるようにする(記憶なしの単発提案からの脱却)
  if [ -f "$CONFIG_DIR/fuseki.log" ]; then
    printf '\n## fuseki/先手が過去に提案したこと(直近・古い順)\n'
    tail -20 "$CONFIG_DIR/fuseki.log" 2>/dev/null | grep -v '^      ->' || true
  fi
}
SENTE_OPENING_OFF_FILE="$CONFIG_DIR/opening-off"   # 🔇 声「先手オフにして」で作成・永続(次回起動後も無効のまま)
SENTE_MUTE_FILE="$CONFIG_DIR/mute"   # 🔇 読み上げOFFの正本(te voice off・声「静かにして」・Sente.appワンクリック共通・永続)
sente_opening() {  # $1=cli|talk $2=auto(起動時の自動発火のみ・繰り返し抑制/オフ設定の対象) $3=full(te ima用・状況summary/alertも生成) — 一手を選び、表示+読み上げ+「やって」用のopening-taskを残す
  [ "${TE_NO_OPENING:-0}" = "1" ] && return 0
  # 🔇 永続オフは自動発火だけを止める(`te ima`/`te next`/声「次何やる?」は能動的リクエストなので常に答える)
  [ "${2:-}" = "auto" ] && [ -f "$SENTE_OPENING_OFF_FILE" ] && return 0
  command -v python3 >/dev/null 2>&1 || return 0
  load_key
  [ -n "${TEAI_API_KEY:-}" ] || return 0
  OP_CTX="$(mktemp "${TMPDIR:-/tmp}/te_opctx_XXXXXX")"
  sente_opening_scan > "$OP_CTX" 2>/dev/null || true
  OP_PREV=""
  [ -f "$CONFIG_DIR/opening-last" ] && OP_PREV="$(head -1 "$CONFIG_DIR/opening-last" 2>/dev/null || true)"
  OP_OUT="$(mktemp "${TMPDIR:-/tmp}/te_opout_XXXXXX")"
  TEAI_API_KEY="$TEAI_API_KEY" OP_PREV="$OP_PREV" OP_MODE="${3:-brief}" \
    python3 - "$OP_CTX" "${TE_OPENING_MODEL:-claude-haiku-4-5-20251001}" >"$OP_OUT" 2>/dev/null <<'PYOP' || true
import json, os, sys, urllib.request
ctx = open(sys.argv[1], encoding="utf-8", errors="replace").read()[:6000]
model = sys.argv[2]
prev = os.environ.get("OP_PREV", "")
mode = os.environ.get("OP_MODE", "brief")
sysmsg = ("あなたは『Sente/先手』、囲碁の先手のように一歩先を読む声の相棒。渡された状況から、"
          "いま最初に打つと一番効く一手をひとつだけ選ぶ。優先順位: 期限・判断日が近い人間の判断待ち > "
          "壊れている・止まっているもの > 未pushで消えると痛い作業 > 前回の声セッションで途中だった話の続き > その他。"
          "続きを提案する時は『昨日の◯◯の続き、やりますか?』のように前回の話題だと分かる言い方にする。"
          "渡された状況に『fuseki/先手が過去に提案したこと』の履歴が含まれる場合は必ず読み、"
          "同じ話題を何度目に出すかを踏まえて言い方を変える(例: 2回目以降は『まだ動きがないようですが』"
          "のように経過を匂わせる)。履歴上すでに解決済み・状況が変わったと分かる話題は再提案しない。"
          # ⚠ risk判定: taskが「やって」の一言(声/GUIワンクリック)だけで即実行される経路のため、
          # 実際に取り返しがつきにくい作業だけは一段階多く確認を挟む(2026-08-29実障害:
          # 広告キャンペーンの再開/停止判断タスクが誤って一言で実行されかけた)。
          "taskには必ずriskも付ける。riskを\"confirm\"にする条件(いずれか該当): 実際にお金が動く"
          "(広告予算・入札・決済・送金・購入・発注・入稿・契約系のボタン)、外部に公開/送信される"
          "(メール送信・SNS投稿・リリース・対外リクエスト)、後戻りしにくい操作"
          "(force push・削除・アカウント停止・本番設定変更・PRマージ/本番デプロイ)。"
          # 🪤実測(2026-08-29): 「PR#280をマージし、印刷入稿の準備をする」が「準備」という
          # 言い回しだけでsafeに倒れた。判定は語尾でなく一手に含まれる操作で行わせる。
          "判定は言い回しでなく一手に実際に含まれる操作で行う: 語尾が『準備する』『確認する』でも、"
          "その一手の途中で上記の操作(マージ・入稿・送信など)を実行するならconfirm。"
          "それ以外(調査・報告・コード修正・"
          "ローカル下書き・下調べ)はriskを\"safe\"にする。迷ったら\"confirm\"側に倒す。")
if mode == "full":
    # ♟ te ima(能動的に「状況は?」と聞かれた時)専用: 一手に加え状況の全体像も返す
    sysmsg += (" 能動的に状況を聞かれているので、一手だけでなく全体像も伝える。"
               "JSONだけを1行で出力: {\"summary\": \"状況の要約。実測のみ・数字を盛らない・改行区切りで3行以内・各行40字程度\", "
               "\"alert\": \"深刻な滞留や異常が無ければ空文字。あれば1行で\", "
               "\"say\": \"声でかける提案。60字以内・結論から・最後は『やりますか?』で締める\", "
               "\"task\": \"『やって』と言われたらそのまま作業エージェントに渡す具体的な指示文(1〜2文・対象のファイルや番号を含める)\", "
               "\"risk\": \"safe または confirm\"}。")
else:
    sysmsg += (" JSONだけを1行で出力: {\"say\": \"声でかける提案。60字以内・結論から・最後は『やりますか?』で締める\", "
               "\"task\": \"『やって』と言われたらそのまま作業エージェントに渡す具体的な指示文(1〜2文・対象のファイルや番号を含める)\", "
               "\"risk\": \"safe または confirm\"}。")
sysmsg += "sayには記号・管理番号・URLを入れず、読んで自然な話し言葉にする。"
if prev:
    sysmsg += " 前回と同じ話題は避ける。前回の提案:" + prev[:80]
body = json.dumps({"model": model, "max_tokens": 300 if mode != "full" else 500, "temperature": 0.3,
                   "messages": [{"role": "system", "content": sysmsg},
                                {"role": "user", "content": ctx}]}).encode()
req = urllib.request.Request("https://api.teai.io/v1/chat/completions", data=body,
                             headers={"Content-Type": "application/json",
                                      "Authorization": "Bearer " + os.environ.get("TEAI_API_KEY", "")})
try:
    r = json.load(urllib.request.urlopen(req, timeout=25))
    t = (r["choices"][0]["message"]["content"] or "").strip()
    d = json.loads(t[t.find("{"):t.rfind("}") + 1])
    say, task = str(d.get("say", "")).strip(), str(d.get("task", "")).strip()
    risk = str(d.get("risk", "")).strip().lower()
    out = {"say": say[:120], "task": task[:400], "risk": "confirm" if risk == "confirm" else "safe"}
    if mode == "full":
        out["summary"] = str(d.get("summary", "")).strip()[:300]
        out["alert"] = str(d.get("alert", "")).strip()[:120]
    if say and task:
        print(json.dumps(out, ensure_ascii=False))
except Exception:
    pass
PYOP
  rm -f "$OP_CTX"
  OP_SAY=""; OP_TASK=""; OP_SUMMARY=""; OP_ALERT=""; OP_RISK="safe"
  if [ -s "$OP_OUT" ]; then
    OP_SAY="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("say",""))' "$OP_OUT" 2>/dev/null || true)"
    OP_TASK="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("task",""))' "$OP_OUT" 2>/dev/null || true)"
    OP_RISK="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("risk","safe"))' "$OP_OUT" 2>/dev/null || echo safe)"
    if [ "${3:-}" = "full" ]; then
      OP_SUMMARY="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("summary",""))' "$OP_OUT" 2>/dev/null || true)"
      OP_ALERT="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("alert",""))' "$OP_OUT" 2>/dev/null || true)"
    fi
  fi
  rm -f "$OP_OUT"
  # 新しい一手に更新するたび、前の一手への確認済みフラグは無効化する
  # (別のconfirm対象タスクへ誤って即実行が引き継がれるのを防ぐ)
  rm -f "$CONFIG_DIR/opening-summary" "$CONFIG_DIR/opening-alert" "$CONFIG_DIR/opening-risk" "$CONFIG_DIR/opening-confirm-armed" "$CONFIG_DIR/opening-drop-armed" 2>/dev/null || true
  [ -n "$OP_SUMMARY" ] && printf '%s\n' "$OP_SUMMARY" > "$CONFIG_DIR/opening-summary" 2>/dev/null || true
  [ -n "$OP_ALERT" ] && printf '%s\n' "$OP_ALERT" > "$CONFIG_DIR/opening-alert" 2>/dev/null || true
  [ -n "$OP_SAY" ] || return 0
  # 🔁 自動発火(起動時)だけ繰り返し抑制(2026-08-08本人報告「Facebookトークン失効の提案が
  # 毎回同じで出続けて煩わしい」)。同じ話題を避ける指示をLLMに出していても、対応されない
  # 限り客観的に最優先であり続けるため素直に選ばれ続けてしまう。同じ提案が2回連続で出たら
  # (=3回目の自動発火)、本人が能動的に`te next`/「次何やる?」で聞くまで自動では出さない。
  # opening-last/opening-taskは更新しておく(能動的に聞いた時は普通に答える)
  if [ "${2:-}" = "auto" ]; then
    OP_RPT=0
    [ -f "$CONFIG_DIR/opening-repeat" ] && OP_RPT="$(cat "$CONFIG_DIR/opening-repeat" 2>/dev/null || echo 0)"
    if [ "$OP_SAY" = "$OP_PREV" ]; then OP_RPT=$((OP_RPT + 1)); else OP_RPT=0; fi
    printf '%s' "$OP_RPT" > "$CONFIG_DIR/opening-repeat" 2>/dev/null || true
    if [ "$OP_RPT" -ge 2 ]; then
      printf '%s\n' "$OP_SAY" > "$CONFIG_DIR/opening-last" 2>/dev/null || true
      if [ -n "$OP_TASK" ]; then
        printf '%s\n' "$OP_TASK" > "$CONFIG_DIR/opening-task" 2>/dev/null || true
        printf '%s\n' "$OP_RISK" > "$CONFIG_DIR/opening-risk" 2>/dev/null || true
      fi
      return 0
    fi
  fi
  printf '%s\n' "$OP_SAY" > "$CONFIG_DIR/opening-last" 2>/dev/null || true
  if [ -n "$OP_TASK" ]; then
    printf '%s\n' "$OP_TASK" > "$CONFIG_DIR/opening-task" 2>/dev/null || true
    printf '%s\n' "$OP_RISK" > "$CONFIG_DIR/opening-risk" 2>/dev/null || true
  fi
  if [ "${1:-cli}" = "talk" ]; then
    # 挨拶・合いの手と重ならないよう、読み上げが静かになるのを待つ(最大12秒で諦めて出す)
    OPW=0
    while { [ -f /tmp/sente_speaking.lock ] || pgrep -x afplay >/dev/null 2>&1 || pgrep -x mpg123 >/dev/null 2>&1; } && [ "$OPW" -lt 40 ]; do
      sleep 0.3; OPW=$((OPW+1))
    done
  fi
  printf '  ♟ %s(「やって」で始めます)\n' "$OP_SAY" >&2
  # 🪤 `te next`はサブコマンドcaseから呼ばれ、koe_say_syncの定義行より前に実行される
  # (関数定義順の罠・第5弾GC節と同型)→ 未定義なら黙って画面表示だけにする
  if command -v koe_say_sync >/dev/null 2>&1; then koe_say_sync "$OP_SAY"; fi
}

# 🎙 初回起動の声がけ(2026-08-13本人指示「te/sente/fusekiとも、起動したら僕の声で使い方を
# 説明して使いたくなるような声がけをして」): 名前(te/sente/fuseki)ごとに一度きり、
# 「これは何で、まず何をすればいいか」を僕の声で誘うように話す。2回目以降は鳴らさない
# (コスト+ウザさ回避、opening/greetingの教訓と同じ)。
# 🪤 next/watch/stop は koe_say_sync/koe_say_cached の定義行(このファイルの後方)より前の
# case dispatchから呼ばれるため、それらに依存しない自己完結のTTS呼び出しを別途持つ(koe)ケースと同じ手口)。
fuseki_intro_say() {  # $1=読み上げるテキスト
  sente_muted && return 0
  command -v python3 >/dev/null 2>&1 || return 0
  FI_TMP="$(mktemp "${TMPDIR:-/tmp}/fuseki_intro_XXXXXX").mp3"
  # 🪤 set -eu 下で `VAR="$(curl ...)"` は curl 非0(タイムアウト等)がそのままスクリプト全体を
  # 落とす(第9弾で踏んだ実障害と同型)→ 末尾に || true で必ず0を返す
  FI_HTTP="$(curl -s -m 20 -o "$FI_TMP" -w '%{http_code}' -X POST "${KOE_BASE:-https://koe.live}/api/speak" \
    -H 'Content-Type: application/json' \
    -d "$(python3 -c 'import json,sys;print(json.dumps({"text":sys.argv[1],"user_id":sys.argv[2],"source":"fuseki-intro"}))' "$1" "${KOE_VOICE:-yuki}")" 2>/dev/null || true)"
  if [ "$FI_HTTP" = "200" ] && [ "$(wc -c < "$FI_TMP" 2>/dev/null || echo 0)" -gt 1000 ]; then
    afplay "$FI_TMP" 2>/dev/null || mpg123 "$FI_TMP" 2>/dev/null || true
  fi
  rm -f "$FI_TMP"
}
sente_first_run_intro() {  # $1=te|sente|fuseki — その名前での初回起動だけ発火
  FRI_NAME="$1"
  FRI_MARK="$CONFIG_DIR/intro-seen-$FRI_NAME"
  [ -f "$FRI_MARK" ] && return 0
  mkdir -p "$CONFIG_DIR" 2>/dev/null || true
  touch "$FRI_MARK" 2>/dev/null || true   # 失敗しても再送しない(一度きりでいい・課金回避優先)
  command -v python3 >/dev/null 2>&1 || return 0
  load_key
  [ -n "${TEAI_API_KEY:-}" ] || return 0
  # 🪤 実機検証(2026-08-13)で「まず何を打てば/話しかければいいか具体例を」とだけ指示すると
  # fuseki(打つコマンドが無い受動的ツール)向けにLLMが存在しない「te status」を幻覚生成した
  # → ツールごとに実在する案内文(FRI_HINT)を渡し、それをそのまま使わせる方式に変更
  case "$FRI_NAME" in
    te)     FRI_DESC="キーボードで頼むと動くコーディングエージェント。curl 1行で入り、テキストで頼めばすぐ動く"
            FRI_HINT="te run \"このリポジトリを説明して\" とそのまま打ってみるよう勧める" ;;
    sente)  FRI_DESC="声で頼むと先に動くSente(先手)。話しかけるだけで手が動き、次の一手も声で提案してくる"
            FRI_HINT="「今日は何からやればいい?」のように、まず声で話しかけてみるよう勧める" ;;
    fuseki) FRI_DESC="呼ばれなくても常時盤面(やることリストや最近のリポジトリ)を見続け、状況が変わった時だけ提案してくるfuseki(布石)。Alpha版で何も勝手には実行しない・止めるにはte stop"
            FRI_HINT="何かを打つ必要はなく、このまま少し置いておけば状況が変わった時に自分から声と記録で教えてくれる、と伝える(コマンドを打つよう勧めない)" ;;
    *)      FRI_DESC="teai.ioのエージェントCLI"; FRI_HINT="" ;;
  esac
  FRI_OUT="$(mktemp "${TMPDIR:-/tmp}/te_introout_XXXXXX")"
  TEAI_API_KEY="$TEAI_API_KEY" python3 - "$FRI_NAME" "$FRI_DESC" "$FRI_HINT" >"$FRI_OUT" 2>/dev/null <<'PYINTRO' || true
import json, os, sys, urllib.request
name, desc, hint = sys.argv[1], sys.argv[2], sys.argv[3]
sysmsg = ("あなたは濱田優貴。teai.ioの開発者本人として、いま初めて『" + name + "』を起動した人に、"
          "自分の声で短く語りかける。渡された内容: " + desc + "。"
          "次にすることの案内は必ずこの内容をそのまま使うこと(言い換えは可・新しいコマンド名や機能を作らない): " + hint + "。"
          "「これは使ってみたい」と思えるような、温かく丁寧な一言にする。"
          "口調は柔らかい敬語かフラットな丁寧語(「〜です/ます」「〜してみてください」)。"
          "「お前」「〜だぜ」「〜しろ」等の乱暴な言葉・タメ口の命令形は絶対に使わない。"
          "80字以内・記号やURL・カッコを読み上げに含めず、自然な話し言葉のみ。"
          "JSONだけを1行で出力: {\"say\": \"...\"}")
body = json.dumps({"model": "claude-haiku-4-5-20251001", "max_tokens": 200, "temperature": 0.4,
                   "messages": [{"role": "system", "content": sysmsg},
                                {"role": "user", "content": "起動されました"}]}).encode()
req = urllib.request.Request("https://api.teai.io/v1/chat/completions", data=body,
                             headers={"Content-Type": "application/json",
                                      "Authorization": "Bearer " + os.environ.get("TEAI_API_KEY", "")})
try:
    r = json.load(urllib.request.urlopen(req, timeout=20))
    t = (r["choices"][0]["message"]["content"] or "").strip()
    d = json.loads(t[t.find("{"):t.rfind("}") + 1])
    say = str(d.get("say", "")).strip()
    if say:
        print(json.dumps({"say": say[:160]}, ensure_ascii=False))
except Exception:
    pass
PYINTRO
  FRI_SAY=""
  [ -s "$FRI_OUT" ] && FRI_SAY="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("say",""))' "$FRI_OUT" 2>/dev/null || true)"
  rm -f "$FRI_OUT"
  [ -n "$FRI_SAY" ] || return 0
  printf '  🎙 %s\n' "$FRI_SAY" >&2
  fuseki_intro_say "$FRI_SAY"
}

# 🗣 譲りの一言(2026-08-10本人指示「遮った時『あ、どうぞ』的なのをいろんなパターンで」+
# 「間の開き方は絶妙に」): 読み上げを遮られた/止めた瞬間に、短くマイクを譲る。
# 全文キャッシュ済み(koe_say_cached)なので合成待ちゼロ=止めた0.2秒後に「あ、どうぞ」が鳴る。
# 長い謝罪文は間延びするので使わない。場面: stop=キーで止めた / barge=声で呼ばれたが聞き取れず
sente_yield_say() {
  case "${1:-stop}" in
    barge) YS="$(sente_pick "あ、ごめん。どうぞ。" "はい、聞いてます。どうぞ。" "ん、呼んだ?どうぞ。" "あ、はい。どうぞ。" "ごめん、もう一度どうぞ。")" ;;
    *)     YS="$(sente_pick "あ、どうぞ。" "はい、どうぞ。" "うん、聞いてるよ。" "はい、なんでしょう。" "どうぞどうぞ。" "あ、ごめん。どうぞ。")" ;;
  esac
  koe_say_cached "$YS"
}

# 💬 起動あいさつ=「気の利いた・便利な・気づきを与える一言」(2026-08-10本人指示)。
# 起動を遅くしないため、文章生成(haiku)+音声合成は毎回「次回分」を裏で先に済ませておき
# (greet-next)、起動時は再生するだけ。無ければ時間帯の定型(ローカルキャッシュmp3)へ。
# カスタム固定文= te greeting "..." / オフ= te greeting off / 既定に戻す= te greeting reset
sente_greeting_default() {  # 時間帯の定型(フォールバック)
  case "$(date +%H)" in
    0[5-9]) printf 'おはようございます、センテです。今日は何からいきますか。' ;;
    1[0-6]) printf 'はい、センテです。どうぞ。' ;;
    0[0-4]) printf 'センテです。深夜ですね、ほどほどにいきましょう。' ;;
    *)      printf 'こんばんは、センテです。どうぞ。' ;;
  esac
}
sente_greet_prepare() {  # 次回起動の一言を生成し、mp3合成まで済ませる(必ず裏で呼ぶ・数秒かかる)
  [ -f "$CONFIG_DIR/greeting-off" ] && return 0
  [ -s "$CONFIG_DIR/greeting" ] && return 0        # カスタム固定文中は生成しない
  command -v python3 >/dev/null 2>&1 || return 0
  load_key
  [ -n "${TEAI_API_KEY:-}" ] || return 0
  GP_CTX="$(mktemp "${TMPDIR:-/tmp}/te_grctx_XXXXXX")" || return 0
  sente_opening_scan > "$GP_CTX" 2>/dev/null || true
  GP_PREV="$(head -1 "$CONFIG_DIR/greet-next.txt" 2>/dev/null || head -1 "$CONFIG_DIR/greet-cur.txt" 2>/dev/null || true)"
  GP_TXT="$(TEAI_API_KEY="$TEAI_API_KEY" GP_PREV="$GP_PREV" \
    python3 - "$GP_CTX" "${TE_OPENING_MODEL:-claude-haiku-4-5-20251001}" 2>/dev/null <<'PYGREET' || true
import json, os, sys, urllib.request
ctx = open(sys.argv[1], encoding="utf-8", errors="replace").read()[:6000]
sysmsg = ("あなたは声のエージェント『Sente/先手』の起動あいさつ係。渡された状況(人間の判断待ち・"
          "リポジトリ・前回の会話・いまの時刻)から、起動直後に言うと気が利いている一言を作る。"
          "中身は、時間帯に合う軽いあいさつに続けて、状況から拾った具体的な気づきや便利な一言"
          "(期限が近い判断・放置されて久しいもの・前回の会話の続きの糸口・時間帯への気遣い、など)。"
          "行動の提案・『やりますか?』は言わない(それは別の係が言う)。"
          "自分が何かを『した・しておいた』とは絶対に言わない(あなたは観察するだけで何もしていない)。"
          "気づきはひとつだけに絞る。45字以内・自然な話し言葉・"
          "記号や管理番号やURLなし・激励の常套句や説教はなし・明るく自然体。"
          "JSONだけを1行で出力: {\"say\": \"一言\"}")
prev = os.environ.get("GP_PREV", "")
if prev:
    sysmsg += " 前回と同じ話題は避ける。前回:" + prev[:80]
body = json.dumps({"model": sys.argv[2], "max_tokens": 200, "temperature": 0.6,
                   "messages": [{"role": "system", "content": sysmsg},
                                {"role": "user", "content": ctx}]}).encode()
req = urllib.request.Request("https://api.teai.io/v1/chat/completions", data=body,
                             headers={"Content-Type": "application/json",
                                      "Authorization": "Bearer " + os.environ.get("TEAI_API_KEY", "")})
try:
    r = json.load(urllib.request.urlopen(req, timeout=25))
    t = (r["choices"][0]["message"]["content"] or "").strip()
    d = json.loads(t[t.find("{"):t.rfind("}") + 1])
    s = str(d.get("say", "")).strip()
    if s: print(s[:90])
except Exception:
    pass
PYGREET
)"
  rm -f "$GP_CTX"
  [ -n "$GP_TXT" ] || return 0
  # 合成も先に済ませる(起動時は再生だけ)。失敗してもtxtは残す=起動時にkoe_say_cached経路で読む
  GP_MP3="$CONFIG_DIR/greet-next.${KOE_VOICE:-yuki}.mp3"
  curl -s -m 20 -X POST "${KOE_BASE:-https://koe.live}/api/speak" \
    -H 'Content-Type: application/json' \
    -d "$(python3 -c 'import json,sys;print(json.dumps({"text":sys.argv[1],"user_id":sys.argv[2],"source":"sente"}))' "$GP_TXT" "${KOE_VOICE:-yuki}")" \
    -o "$GP_MP3.tmp" 2>/dev/null || true
  if [ -s "$GP_MP3.tmp" ] && [ "$(head -c 1 "$GP_MP3.tmp" 2>/dev/null)" != "{" ]; then
    mv "$GP_MP3.tmp" "$GP_MP3" 2>/dev/null
  else
    rm -f "$GP_MP3.tmp"
  fi
  printf '%s\n' "$GP_TXT" > "$CONFIG_DIR/greet-next.txt" 2>/dev/null || true
}
sente_greet_play_bg() {  # 起動時に呼ぶ(呼ぶ前に/tmp/sente_speaking.lockを主シェルで置いておく)
  GRE_TXT=""; GRE_MP3=""
  if [ ! -f "$CONFIG_DIR/greeting-off" ]; then
    if [ -s "$CONFIG_DIR/greeting" ]; then
      GRE_TXT="$(head -1 "$CONFIG_DIR/greeting" 2>/dev/null)"
    elif [ -s "$CONFIG_DIR/greet-next.txt" ] && [ -n "$(find "$CONFIG_DIR/greet-next.txt" -mmin -1200 2>/dev/null)" ]; then
      # 🪤 使う分は先に greet-cur へ退避(consume)してから裏へ: 裏のprepareが書く新しい
      # greet-next を、再生後のrm等で巻き添えにしないため(同名のままだと数秒差で消し合う)
      mv "$CONFIG_DIR/greet-next.txt" "$CONFIG_DIR/greet-cur.txt" 2>/dev/null || true
      GRE_TXT="$(head -1 "$CONFIG_DIR/greet-cur.txt" 2>/dev/null)"
      if [ -s "$CONFIG_DIR/greet-next.${KOE_VOICE:-yuki}.mp3" ]; then
        mv "$CONFIG_DIR/greet-next.${KOE_VOICE:-yuki}.mp3" "$CONFIG_DIR/greet-cur.mp3" 2>/dev/null || true
        GRE_MP3="$CONFIG_DIR/greet-cur.mp3"
      fi
      rm -f "$CONFIG_DIR"/greet-next.*.mp3 2>/dev/null   # 声切替で残った他声の合成も掃除
    fi
    [ -n "$GRE_TXT" ] || GRE_TXT="$(sente_greeting_default)"
  fi
  if [ -z "$GRE_TXT" ]; then rm -f /tmp/sente_speaking.lock; return 0; fi   # 挨拶オフ
  printf '  💬 %s\n' "$GRE_TXT" >&2
  (
    if ! sente_muted && [ -n "$GRE_MP3" ] && [ -s "$GRE_MP3" ]; then
      sente_play "$GRE_MP3" || koe_say_cached "$GRE_TXT"
    else
      koe_say_cached "$GRE_TXT"
    fi
    rm -f /tmp/sente_speaking.lock
  ) &
  ( sente_greet_prepare ) >/dev/null 2>&1 &   # 次回分をいまのうちに用意
}

sente_apply_tuning() {
  [ -n "${TE_TALK_SILENCE:-}" ] && return 0
  [ -f "$SENTE_TUNE" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  V="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("talk_silence",""))' "$SENTE_TUNE" 2>/dev/null || true)"
  case "$V" in [0-9]*) TE_TALK_SILENCE="$V"; export TE_TALK_SILENCE ;; esac
  if [ -z "${TE_VOICE_FAST_MODEL:-}" ]; then
    M="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("voice_model",""))' "$SENTE_TUNE" 2>/dev/null || true)"
    [ -n "$M" ] && { TE_VOICE_FAST_MODEL="$M"; export TE_VOICE_FAST_MODEL; }
  fi
}

# 🩺 起動ヘルスチェック(2026-08-10本人指示「起動した時に最初に何したら便利?」→「耳・口・脳」の実測1行)。
# 背景: 08-08〜10の失聴障害は「起動時に耳が死んでいても黙って普通に起動する」ため2日間気づけなかった。
# 耳=本番と同じ録音経路(senterec+AEC)を開始しきい値0で0.5秒実録音してレベルを測る(疎通でなく実測)。
# 口=koe.live疎通 / 脳=teai.io APIキー+残高。3つ並列・正常は1行表示だけ・異常は声でも知らせる。
# 無効化=TE_NO_HEALTH=1
sente_health_check() {
  [ "${TE_NO_HEALTH:-0}" = "1" ] && return 0
  HC_D="$(mktemp -d "${TMPDIR:-/tmp}/te_hc_XXXXXX")" || return 0
  ( # 👂 耳: 実録音0.5秒→ピーク音量。デジタル無音(≤-85dB)=ミュート/入力ゼロの疑い
    HW="$HC_D/ear.wav"
    if [ "${TE_NO_AEC:-0}" != "1" ] && [ -x "$SENTE_AEC_BIN" ]; then
      "$SENTE_AEC_BIN" "$HW" --silence 9 --max 0.5 --start-thresh 0 --no-sys-gate >/dev/null 2>&1 || true
    elif command -v rec >/dev/null 2>&1; then
      rec -q "$HW" trim 0 0.5 >/dev/null 2>&1 || true
    fi
    if [ -s "$HW" ] && command -v ffmpeg >/dev/null 2>&1; then
      HMX="$(ffmpeg -i "$HW" -af volumedetect -f null /dev/null 2>&1 | sed -n 's/.*max_volume: \(-\{0,1\}[0-9.]*\) dB.*/\1/p')"
      HMI="${HMX%%.*}"
      if [ -z "$HMX" ]; then printf 'ng 録音が読めません'
      elif [ "${HMI:-0}" -le -85 ] 2>/dev/null; then printf 'warn 入力がほぼ無音(ミュート?) %sdB' "$HMX"
      else printf 'ok %sdB' "$HMX"; fi
    elif [ -s "$HW" ]; then printf 'ok ?'
    else printf 'ng マイクから音が読めません'; fi > "$HC_D/ear" 2>/dev/null
    rm -f "$HW" ) &
  ( # 🔊 口: koe.live疎通(読み上げ/文字起こしの行き先)
    HKC="$(curl -s -o /dev/null -w '%{http_code}' -m 5 "${KOE_BASE:-https://koe.live}/" 2>/dev/null || echo 000)"
    case "$HKC" in 2*|3*) printf 'ok' ;; *) printf 'ng HTTP %s' "$HKC" ;; esac > "$HC_D/mouth" 2>/dev/null ) &
  ( # 🧠 脳: APIキー+残高
    if [ -n "${TEAI_API_KEY:-}" ]; then
      HME="$(curl -s -m 5 -H "Authorization: Bearer $TEAI_API_KEY" "$TEAI_API/api/v1/auth/me" 2>/dev/null || true)"
      case "$HME" in
        *'"authenticated":true'*)
          HCR="$(printf '%s' "$HME" | sed -n 's/.*"credits_remaining":\([0-9]*\).*/\1/p')"
          printf 'ok 残高%scr' "${HCR:-?}" ;;
        *) printf 'ng キー無効/接続不可(te doctor)' ;;
      esac
    else printf 'ng キー未設定(te register)'; fi > "$HC_D/brain" 2>/dev/null ) &
  ( # 🌐 Playwright MCP: 共通サーバーが起動しているか
    if [ "${TE_NO_PLAYWRIGHT:-0}" = "1" ]; then printf 'skip' > "$HC_D/mcp" 2>/dev/null; else
      HC_MCP_PORT="${PLAYWRIGHT_MCP_PORT:-8932}"
      if curl -s -m 3 -X POST "http://localhost:$HC_MCP_PORT/mcp" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"healthcheck","version":"1.0"}}}' >/dev/null 2>&1; then
        printf 'ok'
      else
        printf 'ng サーバー未起動/接続不可(te clean?) '
      fi > "$HC_D/mcp" 2>/dev/null
    fi ) &
  wait
  HC_EAR="$(cat "$HC_D/ear" 2>/dev/null || echo 'ng ?')"
  HC_MOU="$(cat "$HC_D/mouth" 2>/dev/null || echo 'ng ?')"
  HC_BRA="$(cat "$HC_D/brain" 2>/dev/null || echo 'ng ?')"
  HC_MCP="$(cat "$HC_D/mcp" 2>/dev/null || echo 'ng ?')"
  rm -rf "$HC_D"
  hc_mark() { case "$1" in ok*) printf '✓' ;; warn*) printf '⚠' ;; *) printf '✗' ;; esac; }
  hc_note() { printf '%s' "$1" | cut -d' ' -f2-; }
  # MCP欄は「何を見たか」を必ず出す(以前は正常時に `MCP✓()` と空括弧だけで情報量ゼロだった)
  case "$HC_MCP" in
    ok*)   HC_MCP_LABEL="playwright:${PLAYWRIGHT_MCP_PORT:-8932}" ;;
    skip*) HC_MCP_LABEL="playwright off" ;;
    *)     HC_MCP_LABEL="playwright:${PLAYWRIGHT_MCP_PORT:-8932} $(hc_note "$HC_MCP")" ;;
  esac
  printf '  🩺 耳%s(%s) 口%s(koe.live%s) 脳%s(%s) 🌐MCP%s(%s)\n' \
    "$(hc_mark "$HC_EAR")" "$(hc_note "$HC_EAR")" \
    "$(hc_mark "$HC_MOU")" "$([ "$HC_MOU" = ok ] || printf ' %s' "$(hc_note "$HC_MOU")")" \
    "$(hc_mark "$HC_BRA")" "$(hc_note "$HC_BRA")" \
    "$(hc_mark "$HC_MCP")" "$HC_MCP_LABEL" >&2
  # 異常は声でも知らせる(口が死んでいる時は鳴らせないので効果音のみ)
  case "$HC_MOU" in ok*) ;; *) koe_sfx err 2>/dev/null || true; return 0 ;; esac
  if ! sente_muted && command -v koe_say_sync >/dev/null 2>&1; then
    case "$HC_EAR" in
      ng*)   koe_say_sync "マイクから音が読めていません。サウンド設定の入力を見てください" ;;
      warn*) koe_say_sync "マイクの入力がほぼ無音です。ミュートかもしれません" ;;
    esac
    case "$HC_BRA" in ng*) koe_say_sync "エーピーアイに繋がっていません。テ、ドクターで確認できます" ;; esac
    case "$HC_MCP" in ng*) koe_say_sync "ウェブブラウザ操作の共通サーバーが起動していません。テ、クリーンで古いプロセスを終了してください" ;; esac
  fi
  return 0
}

# 🧹 自動GC: te を起動するたびに、ゴミだけを静かに片付ける。
# 「ゴミ」の定義は保守的に — 誤って作業中のセッションを殺さないことを最優先する:
#   ・親を失った(PPID=1)opencode で、かつ5分以上生きているもの(TE_GC_MIN_AGE で変更可)
#     → 端末で作業中のTUI/runは親シェルが居るので絶対に対象にならない
#   ・自分が作った一時ファイル(sente_say/greet/te_v/te_talk)で60分以上前のもの
#   ・10分以上放置された読み上げlock(異常終了の残骸。これがあると録音が始まらない)
# 無効化=TE_NO_GC=1。手動の強力版(全部停止)は te clean。
oc_gc() {
  [ "${TE_NO_GC:-0}" = "1" ] && return 0
  # 🚀 起動速度改善(2026-08-16): sente/opencode プロセスが0本なら即return。
  # pgrep/ps/find を多数呼ぶ前に、対象が無ければ何もしない。
  [ -z "$(pgrep -x sente 2>/dev/null)" ] && [ -z "$(pgrep -x opencode 2>/dev/null)" ] && return 0
  GCN=0
  for GQ in $(pgrep -x sente 2>/dev/null); do
    GI="$(ps -o ppid=,etime= -p "$GQ" 2>/dev/null)"
    [ -n "$GI" ] || continue
    GPP="$(echo "$GI" | awk '{print $1}')"
    GET="$(echo "$GI" | awk '{print $2}')"
    [ "$GPP" = "1" ] || continue          # 親が生きている=作業中。触らない
    case "$GET" in
      *-*|*:*:*) GOLD=1 ;;                # 日/時間単位=確実に古い
      *:*) GM="${GET%%:*}"; if [ "${GM:-0}" -ge "${TE_GC_MIN_AGE:-5}" ] 2>/dev/null; then GOLD=1; else GOLD=0; fi ;;
      *) GOLD=0 ;;
    esac
    [ "$GOLD" = "1" ] || continue
    # 前回TERMしても死ななかった残骸は、次の起動でKILLまで進む(2段階で丁寧に)
    if kill -0 "$GQ" 2>/dev/null; then
      kill -TERM "$GQ" 2>/dev/null || true
      sleep 0.2
      kill -0 "$GQ" 2>/dev/null && kill -KILL "$GQ" 2>/dev/null
      GCN=$((GCN+1))
    fi
  done
  # 🪤 macOSの /tmp は /private/tmp へのシンボリックリンク。末尾スラッシュを付けないと
  #    find がリンクを辿らず、-maxdepth 1 では中身が1つも見えない(実測で踏んだ)。
  GCD="/tmp/"
  [ -n "${TMPDIR:-}" ] && [ "${TMPDIR%/}" != "/tmp" ] && GCD="$GCD ${TMPDIR%/}/"
  # shellcheck disable=SC2086
  find $GCD -maxdepth 1 \( -name 'sente_say_*.mp3' -o -name 'sente_greet_*.mp3' \
    -o -name 'te_v_*.wav' -o -name 'te_talk_*.wav' -o -name 'te_talk_*.wav.apple' \
    -o -name 'te_spk_*.wav' \) -mmin +60 -delete 2>/dev/null || true
  find /tmp/ -maxdepth 1 \( -name 'sente_speaking.lock' -o -name 'sente_turn_open' -o -name 'sente_ctx_playing' \) -mmin +10 -delete 2>/dev/null || true
  find /tmp/ -maxdepth 1 \( -name 'sente_say_drainer.pid.*' -o -name 'sente_say_queue.*' -o -name 'sente_say_*' \) -mmin +720 -delete 2>/dev/null || true
  # 声の記録は手元にだけ置き、古いものは自分で片付ける(既定7日・TE_REC_KEEP_DAYSで変更可)
  [ -d "$SENTE_REC_DIR" ] && \
    find "$SENTE_REC_DIR" -maxdepth 1 -name '*.wav' \
      -mtime +"${TE_REC_KEEP_DAYS:-7}" -delete 2>/dev/null || true
  # 📦 裏タスクの完了記録(done)は7日超で片付ける(メタ+出力の両方)
  [ -d "$CONFIG_DIR/bg" ] && \
    find "$CONFIG_DIR/bg" -maxdepth 1 \( -name '*.done.json' -o -name '*.out' \) \
      -mtime +7 -delete 2>/dev/null || true
  # 🗄 opencode.db の event テーブル自動 retention(2026-08-16 根本対策)。
  # event はセッションごとに無制限に蓄積し、561MB/96,854件まで肥大化した実績がある。
  # sente 本体に retention 設定は無い(debug config で確認)ため、ここで定期的に
  # 古いセッションの event を削除する。message/part/session は残す=会話履歴は保持、
  # 肥大の主因である event(中間ステップの生ログ)だけを間引く。
  # 実行間隔: 1日1回(マーカーファイルで判定)。保持日数: TE_DB_EVENT_KEEP_DAYS(既定7)。
  # 🪤 2026-09-10: sente rename 後は DB が ~/.local/share/sente/sente*.db(ビルドチャネル別に複数)に
  #    移っていたのに、ここは旧パス opencode.db を見続けて retention が黙って止まっていた
  #    (event テーブル 948MB/48万件まで肥大)。glob で全チャネルの DB を対象にする。
  OCDB_MARK="$CONFIG_DIR/.db-gc-last"
  if command -v sqlite3 >/dev/null 2>&1 && [ -z "$(find "$OCDB_MARK" -mmin -1440 2>/dev/null)" ]; then
    for OCDB in "$HOME/.local/share/sente"/sente*.db "$HOME/.local/share/opencode/opencode.db"; do
      [ -f "$OCDB" ] || continue
      sqlite3 "$OCDB" "PRAGMA busy_timeout=5000; DELETE FROM event WHERE aggregate_id IN (SELECT id FROM session WHERE time_updated < strftime('%s','now','-${TE_DB_EVENT_KEEP_DAYS:-7} days')*1000);" 2>/dev/null || true
      # session 削除後に残った孤児 event(FK は event_sequence 側にしか無い)も落とす
      sqlite3 "$OCDB" "PRAGMA busy_timeout=5000; DELETE FROM event_sequence WHERE aggregate_id LIKE 'ses_%' AND aggregate_id NOT IN (SELECT id FROM session);" 2>/dev/null || true
      sqlite3 "$OCDB" "PRAGMA wal_checkpoint(TRUNCATE);" 2>/dev/null || true
      # VACUUM はファイルを物理的に縮める(削除だけでは空き領域が残る)。数十秒かかりうるので裏へ
      ( sqlite3 "$OCDB" "PRAGMA busy_timeout=5000; VACUUM;" 2>/dev/null || true ) &
    done
    : > "$OCDB_MARK" 2>/dev/null || true
  fi
  # 📜 ログローテーション(2026-09-10: sente.log 143MB/94万行・bridge.log 1.9MB が無限に伸びていた)。
  #    TE_LOG_ROTATE_MB(既定10)を超えたら .1 に退避(1世代だけ・.1 は上書き)。追記中のプロセスは
  #    mv 後も旧 inode に書き続けるが、次回起動で新ファイルへ移る。
  for RL in "$HOME/.local/share/sente/log/sente.log" "$SENTE_LOG_DIR/bridge.log" "$SENTE_LOG_DIR/sente.log"; do
    [ -f "$RL" ] || continue
    RL_KB="$(du -k "$RL" 2>/dev/null | awk '{print $1}')"
    if [ "${RL_KB:-0}" -gt $(( ${TE_LOG_ROTATE_MB:-10} * 1024 )) ] 2>/dev/null; then
      mv -f "$RL" "$RL.1" 2>/dev/null && : > "$RL" 2>/dev/null || true
    fi
  done
  [ "$GCN" -gt 0 ] && echo "  🧹 前回の残骸を${GCN}本片付けました" >&2
  oc_resguard
  oc_resource_advice
  return 0
}

# 🩺 起動時リソース診断(2026-08-17本人指示「起動時にteでリソース見て提案ほしい」「ファイルの
# 容量も確認して提案して」): sente/opencodeの有無に関わらず毎回軽くチェックし、空きメモリ不足・
# CPU高負荷・ディスク空き不足だけを一言警告する(oc_resguardのようにkill/STOPはしない・情報提示のみ)。
# 無効化=TE_NO_RESOURCE_ADVICE=1
oc_resource_advice() {
  [ "${TE_NO_RESOURCE_ADVICE:-0}" = "1" ] && return 0
  # 📌 起動メッセージは一瞬で流れる(2026-08-17本人報告「メッセージが一瞬でしか見えない」)ため、
  # 出した忠告を ~/.config/teai/.last-boot-notes に保存し `te doctor` で再表示できるようにする。
  local NOTES="$CONFIG_DIR/.last-boot-notes"
  : > "$NOTES" 2>/dev/null || true
  local FREE_MB; FREE_MB="$(_sente_free_mb)"
  if [ -n "$FREE_MB" ] && [ "$FREE_MB" -lt "${TE_ADVICE_LOW_MEM_MB:-1536}" ] 2>/dev/null; then
    # 一番重いプロセス: BSD ps は -m(メモリ順)、GNU ps は --sort=-rss
    local TOPMEM
    if [ "$(sente_os)" = "darwin" ]; then
      TOPMEM="$(ps -eo rss,comm -m 2>/dev/null | awk 'NR==2{printf "%s(%dMB)", $2, $1/1024}')"
    else
      TOPMEM="$(ps -eo rss,comm --sort=-rss 2>/dev/null | awk 'NR==2{printf "%s(%dMB)", $2, $1/1024}')"
    fi
    local MSG="💡 空きメモリが少なめです(実質${FREE_MB}MB) — 一番重いのは ${TOPMEM:-不明}。閉じると楽になります"
    echo "  $MSG" >&2; echo "$MSG" >> "$NOTES" 2>/dev/null || true
  fi
  local NCPU; NCPU="$(sente_nproc)"
  local LOAD1; LOAD1="$(sente_loadavg1)"
  if [ -n "$LOAD1" ] && [ -n "$NCPU" ] && [ "$NCPU" -gt 0 ] 2>/dev/null; then
    local HIGH; HIGH="$(awk -v l="$LOAD1" -v n="$NCPU" 'BEGIN{print (l > n*1.5) ? 1 : 0}' 2>/dev/null)"
    if [ "$HIGH" = "1" ]; then
      local TOPCPU
      if [ "$(sente_os)" = "darwin" ]; then
        TOPCPU="$(ps -eo %cpu,comm -r 2>/dev/null | awk 'NR==2{printf "%s(%s%%)", $2, $1}')"
      else
        TOPCPU="$(ps -eo %cpu,comm --sort=-%cpu 2>/dev/null | awk 'NR==2{printf "%s(%s%%)", $2, $1}')"
      fi
      local MSG="💡 CPU負荷が高めです(load ${LOAD1}/${NCPU}コア) — 一番重いのは ${TOPCPU:-不明}"
      echo "  $MSG" >&2; echo "$MSG" >> "$NOTES" 2>/dev/null || true
    fi
  fi
  # ディスク空き容量チェック(既存の ~/.claude/daily/disk-check.sh と同じ閾値・ボリューム)
  local DISK_VOL="/System/Volumes/Data"
  [ -d "$DISK_VOL" ] || DISK_VOL="/"
  local DISK_AVAIL_GB; DISK_AVAIL_GB="$(df -k "$DISK_VOL" 2>/dev/null | tail -1 | awk '{printf "%d", $4/1048576}')"
  local DISK_LOW_GB="${TE_ADVICE_LOW_DISK_GB:-15}"
  if [ -n "$DISK_AVAIL_GB" ] && [ "$DISK_AVAIL_GB" -lt "$DISK_LOW_GB" ] 2>/dev/null; then
    local MSG="💡 ディスク空きが少なめです(${DISK_AVAIL_GB}GB) — ~/.claude/daily/disk-check.sh --clean で掃除できます"
    echo "  $MSG" >&2; echo "$MSG" >> "$NOTES" 2>/dev/null || true
  fi
  # 💳 残高チェック(2026-09-10: 残高0に数日気づかず、チャットは通るのに MCP(画像/声)だけ
  # "Insufficient credits" で止まっていた。チャットは admin/BYOK で残高0でも通る経路があるが、
  # MCP ゲートウェイは tools/call 前に必ず残高を減算するため、残高が無いと画像・声だけ死ぶ)。
  # 閾値 TE_ADVICE_LOW_CREDITS(既定10000)未満で警告。取れない時(オフライン等)は黙る。
  # stderr への表示は1日1回(起動ごとに鳴ると鬱陶しい)、.last-boot-notes には毎回残す。
  if [ -n "${TEAI_API_KEY:-}" ] && [ "${TE_NO_CREDIT_ADVICE:-0}" != "1" ]; then
    local CR_BAL; CR_BAL="$(curl -s -m 3 -H "Authorization: Bearer $TEAI_API_KEY" "$TEAI_API/api/v1/auth/me" 2>/dev/null \
      | sed -n 's/.*"credits_remaining":\(-\{0,1\}[0-9]*\).*/\1/p' | head -1)"
    local CR_LOW="${TE_ADVICE_LOW_CREDITS:-10000}"
    if [ -n "$CR_BAL" ] && [ "$CR_BAL" -lt "$CR_LOW" ] 2>/dev/null; then
      local MSG
      if [ "$CR_BAL" -le 0 ] 2>/dev/null; then
        MSG="💳 クレジット残高が 0 です — 画像生成・声(MCP)が \"Insufficient credits\" で止まります。チャージ: https://teai.io/pricing"
      else
        MSG="💳 クレジット残高が少なめです(${CR_BAL}cr・約¥$((CR_BAL / 6))分) — 0 になると画像生成・声(MCP)が止まります。チャージ: https://teai.io/pricing"
      fi
      echo "$MSG" >> "$NOTES" 2>/dev/null || true
      local CR_MARK="$CONFIG_DIR/.credit-warned-$(date +%Y%m%d)"
      if [ ! -f "$CR_MARK" ]; then
        : > "$CR_MARK" 2>/dev/null || true
        echo "  $MSG" >&2
      fi
    fi
  fi
  # 忠告があった時だけ、流れても取りこぼさないよう見返し方を一言添える
  [ -s "$NOTES" ] && echo "  📌 この忠告は te doctor で見返せます。自動で整えるなら te optimize" >&2
  return 0
}

# 🛡 リソースガード(2026-08-16): sente/opencode のメモリ・CPU過食で Mac 全体が
# フリーズ気味になる実害(9プロセス合計1.75GB・14時間アイドルでCPU暴走等)への対策。
# 殺さず止める(STOP/CONT)を基本にし、暴走・上限超過だけ畳む3層構造。
# 実行タイミング: oc_gc の最後(te のどのサブコマンドでも毎回走る)。状態は
# $CONFIG_DIR/.resguard/<pid> に {cpu秒, epoch} を保存し、前回比で判定する。
# 初回は記録のみ(誤検知防止)。TE_NO_RESOURCE_GUARD=1 で全無効化、
# TE_RESGUARD_DRY=1 でログだけ出して触らない(検証用)。
_sente_free_mb() {  # 実質空き物理メモリをMB換算(mac: vm_stat / linux: /proc/meminfo)。実体は sente_free_mb
  sente_free_mb
}
oc_resguard() {
  [ "${TE_NO_RESOURCE_GUARD:-0}" = "1" ] && return 0
  # 🚀 起動速度改善(2026-08-16): sente/opencode プロセスが0本なら即return。
  [ -z "$(pgrep -x sente 2>/dev/null)" ] && [ -z "$(pgrep -x opencode 2>/dev/null)" ] && return 0
  local RG_DIR="$CONFIG_DIR/.resguard"
  mkdir -p "$RG_DIR" 2>/dev/null || return 0
  local IDLE_MIN="${TE_IDLE_SUSPEND_MIN:-30}"      # ①アイドルSTOPまでの分数
  local RUNAWAY_MIN="${TE_CPU_RUNAWAY_MIN:-30}"    # ②CPU暴走killまでの分数(2026-08-24: 10→30。機械全体が空いていれば②はそもそも見送るため、詰まっている時だけの猶予をさらに延ばす)
  local MAX_RSS="${TE_MAX_RSS_MB:-1024}"           # ②単一プロセスRSS上限MB
  local TOTAL_RSS="${TE_TOTAL_RSS_MB:-2048}"       # ③全体RSS上限MB
  local DRY="${TE_RESGUARD_DRY:-0}"
  # 🩹 2026-08-17本人指示「メモリ余裕あるなら起動して」: MAX_RSS/TOTAL_RSSは固定値で
  # システム全体の空き具合を見ていなかったため、16GB機で数GB空いていても単一プロセスが
  # 1024MBを超えただけでkillされる実害があった。実質空きメモリが十分(既定4096MB=4GB)
  # あればメモリに関するkill/STOP(②のメモリ上限・③の合計RSS)は見送る。
  # 2026-08-24追記: CPU暴走kill(②)も同じMEM_HEADROOM_OKで見送るよう変更(下記参照)。
  local FREE_MB; FREE_MB="$(_sente_free_mb)"
  local FREE_HEADROOM_MB="${TE_FREE_HEADROOM_MB:-4096}"
  local MEM_HEADROOM_OK=0
  [ -n "$FREE_MB" ] && [ "$FREE_MB" -ge "$FREE_HEADROOM_MB" ] 2>/dev/null && MEM_HEADROOM_OK=1
  local NOW; NOW="$(date +%s)"
  local TOTAL=0
  local PIDS; PIDS="$( { pgrep -x sente 2>/dev/null; pgrep -x opencode 2>/dev/null; } || true)"
  local P
  for P in $PIDS; do
    local INFO; INFO="$(ps -o pid=,ppid=,stat=,tty=,time=,rss=,etime= -p "$P" 2>/dev/null)"
    [ -n "$INFO" ] || { rm -f "$RG_DIR/$P" 2>/dev/null; continue; }
    local STAT TTY CPUTIME RSS ETIMES
    STAT="$(echo "$INFO" | awk '{print $3}')"
    TTY="$(echo "$INFO" | awk '{print $4}')"
    # 🖥 フォアグラウンド判定(2026-08-25): BSD ps の STAT に付く "+" は
    # 「制御端末のフォアグラウンドプロセスグループに属する」印。今まさに
    # 画面を見ている対話セッションはCPUアイドルでも凍結対象から外す
    # (「画面に戻ると固まってスクロールもできない」実害への対処。
    # ヘッドレスなserve/orphanはtty="??"でこの印が付かないため対象外のまま)。
    local IS_FG=0
    case "$STAT" in *+*) IS_FG=1 ;; esac
    CPUTIME="$(echo "$INFO" | awk '{print $5}')"   # [[dd-]hh:]mm:ss
    RSS="$(echo "$INFO" | awk '{print $6}')"        # KB
    ETIMES="$(echo "$INFO" | awk '{print $7}')"
    # CPU時間を秒に正規化
    local CPU_S; CPU_S="$(echo "$CPUTIME" | awk -F: '{if(NF==3){split($1,a,"-");d=(a[2]!="")?a[2]:a[1]; if(index($1,"-")){print (d*86400)+($2*3600)+($3*60)+$4}else{print ($1*3600)+($2*60)+$3}} else if(NF==2){print ($1*60)+$2} else{print $1}}' 2>/dev/null)"
    CPU_S="${CPU_S%%.*}"; CPU_S="${CPU_S:-0}"
    local RSS_MB=$(( ${RSS:-0} / 1024 ))
    TOTAL=$(( TOTAL + RSS_MB ))
    local PREV_CPU=0 PREV_TS=0
    if [ -f "$RG_DIR/$P" ]; then read -r PREV_CPU PREV_TS < "$RG_DIR/$P" 2>/dev/null || true; fi
    local ELAPSED=$(( NOW - ${PREV_TS:-$NOW} ))
    local CPU_DELTA=$(( CPU_S - ${PREV_CPU:-$CPU_S} ))
    # 現在値を保存(次回比較用)
    echo "$CPU_S $NOW" > "$RG_DIR/$P" 2>/dev/null || true
    # アイドル判定: CPU不変(±1秒の揺れ許容)なら無活動継続として .idle に開始時刻を保持し、
    # CPUが動いたら消す。.idle の中身=無活動開始epoch(既存があれば保持=連続無活動を測る)。
    # ①STOPと③集計ガードは「無活動開始から閾値経過」したものだけを対象にする。
    # フォアグラウンド対話セッションは.idleを立てない=③の集計STOP候補にも入れない。
    if [ "${PREV_TS:-0}" -gt 0 ] && [ "$CPU_DELTA" -le 1 ] && [ "$IS_FG" != "1" ]; then
      [ -f "$RG_DIR/$P.idle" ] || echo "$PREV_TS" > "$RG_DIR/$P.idle" 2>/dev/null || true
    else
      rm -f "$RG_DIR/$P.idle" 2>/dev/null || true
    fi
    # STOP中なら tty 活動があれば CONT で復帰
    case "$STAT" in
      T*)
        if [ -n "$TTY" ] && [ "$TTY" != "??" ]; then
          local TTYMT; TTYMT="$(sente_stat_mtime "/dev/$TTY")"
          if [ "${TTYMT:-0}" -gt "${PREV_TS:-0}" ]; then
            [ "$DRY" = "1" ] && echo "  🛡 [dry] pid $P を復帰(CONT)" >&2 || { kill -CONT "$P" 2>/dev/null && echo "  🛡 pid $P を復帰しました(キー入力検知)" >&2; }
          fi
        fi
        continue ;;
    esac
    # ②暴走kill: CPUが前回から連続増加(監視間隔の大半をCPUが占有)かつ継続時間が閾値超。
    # 2026-08-24本人指示「止まらないように」: 実質空きメモリが十分(既定4GB超)なら
    # ここも見送る(①③のメモリ系と同じMEM_HEADROOM_OK)。機械に余裕があるのに1本が
    # 長い agentic ループ/ビルドで忙しいだけのケースまで殺していた実害(08-24 resguard-kills.log
    # 2件・機械全体は空いていた)への対処。空きが本当に無い時だけ従来通り危険とみなす。
    if [ "${PREV_TS:-0}" -gt 0 ] && [ "$ELAPSED" -gt 60 ]; then
      if [ "$CPU_DELTA" -ge $(( ELAPSED * 70 / 100 )) ] && [ "$ELAPSED" -ge $(( RUNAWAY_MIN * 60 )) ] && [ "$MEM_HEADROOM_OK" != "1" ]; then
        echo "  🛡 pid $P がCPU暴走(${CPUTIME})のため停止します" >&2
        if [ "$DRY" != "1" ]; then
          # 🔎 フォレンジック(2026-08-17): 殺すだけだと再発時に原因不明のまま繰り返す。
          # kill前に1秒スタックサンプルを記録して次回の根本原因調査に使う。
          # 🪤 PATH上のpython venv等が同名`sample`コマンドを被せることがあるため /usr/bin/sample を直指定。
          local FLOG="$SENTE_LOG_DIR/resguard-kills.log"
          mkdir -p "$(dirname "$FLOG")" 2>/dev/null
          {
            echo "=== $(date '+%Y-%m-%d %H:%M:%S') pid=$P cpu=${CPUTIME} elapsed=${ELAPSED}s ==="
            ps -o pid,ppid,%cpu,%mem,rss,etime,command -p "$P" 2>/dev/null
            [ -x /usr/bin/sample ] && /usr/bin/sample "$P" 1 2>/dev/null | awk '/Call graph:/{f=1} f' | head -60
            echo
          } >> "$FLOG" 2>/dev/null
          kill -TERM "$P" 2>/dev/null; sleep 2; kill -KILL "$P" 2>/dev/null; rm -f "$RG_DIR/$P"
        fi
        continue
      fi
    fi
    # ②メモリ上限kill(システムに実質空き4GB超あれば見送る)
    if [ "$RSS_MB" -gt "$MAX_RSS" ] && [ "$MEM_HEADROOM_OK" != "1" ]; then
      echo "  🛡 pid $P がメモリ上限(${RSS_MB}MB>${MAX_RSS}MB)のため停止します" >&2
      if [ "$DRY" != "1" ]; then kill -TERM "$P" 2>/dev/null; sleep 2; kill -KILL "$P" 2>/dev/null; rm -f "$RG_DIR/$P"; fi
      continue
    fi
    # ①アイドルSTOP: CPU不変(無活動)が閾値超。ただしフォアグラウンド対話セッション
    # (画面を見ているだけで次に何か打つ気満々のsente)は凍結すると「戻ってきたら
    # 固まってスクロールもできない」実害になるため対象外。
    if [ "${PREV_TS:-0}" -gt 0 ] && [ "$CPU_DELTA" -le 1 ] && [ "$ELAPSED" -ge $(( IDLE_MIN * 60 )) ] && [ "$IS_FG" != "1" ]; then
      echo "  🛡 pid $P はアイドル${IDLE_MIN}分超のため一時停止します(キー入力で復帰)" >&2
      [ "$DRY" = "1" ] || kill -STOP "$P" 2>/dev/null || true
      continue
    fi
  done
  # ③集計ガード: 合計RSS超過なら「連続無活動が IDLE_MIN 超」のものから古い順にSTOP。
  # 活動中・無活動が浅い対話セッションは絶対に止めない=操作中に固まる事故を防ぐ。
  # システムに実質空き4GB超あれば、合計RSSが上限を超えていても見送る。
  if [ "$TOTAL" -gt "$TOTAL_RSS" ] && [ "$MEM_HEADROOM_OK" != "1" ]; then
    echo "  🛡 sente関連の合計メモリ ${TOTAL}MB が上限 ${TOTAL_RSS}MB 超過 — アイドルを古い順に一時停止します" >&2
    for P in $(for Q in $PIDS; do
      [ -f "$RG_DIR/$Q.idle" ] || continue
      IS="$(cat "$RG_DIR/$Q.idle" 2>/dev/null)"
      [ -n "$IS" ] && [ $(( NOW - IS )) -ge $(( IDLE_MIN * 60 )) ] && echo "$IS $Q"
    done | sort -n | awk '{print $2}'); do
      [ -n "$P" ] || continue
      [ "$TOTAL" -le "$TOTAL_RSS" ] && break
      local R2; R2="$(ps -o rss= -p "$P" 2>/dev/null | tr -d ' ')"
      [ -n "$R2" ] || continue
      echo "  🛡 pid $P を一時停止($(( R2 / 1024 ))MB・無活動${IDLE_MIN}分超)" >&2
      [ "$DRY" = "1" ] || kill -STOP "$P" 2>/dev/null || true
      TOTAL=$(( TOTAL - R2 / 1024 ))
    done
  fi
  # 死んだPIDの状態ファイルを掃除(.idle も本体も)
  local F; for F in "$RG_DIR"/*; do [ -f "$F" ] || continue; local FP="${F##*/}"; FP="${FP%.idle}"; kill -0 "$FP" 2>/dev/null || rm -f "$F" "$RG_DIR/$FP.idle"; done
  return 0
}

# 🪤 patch_te_config_headers はインストーラ側(この heredoc の外)で定義されている関数。
# ランチャー本文からも呼んでいるのに定義がここには無く、初回起動(opencode.json 無し=
# refresh_config を同期で呼ぶ経路)で "patch_te_config_headers: not found" で止まっていた
# (2026-09-10 dash 上の初回起動テストで実測。既存Macは裏で &走らせて stderr を捨てていたので
# 気づかなかった)。同じ内容をここにも置く。python3 が無ければ何もしない(タグ無しで動く)。
patch_te_config_headers() {
  command -v python3 >/dev/null 2>&1 || return 0
  python3 - "$1" "${TE_SCRIPT_VERSION:-unknown}" <<'PYHDRPATCH' 2>/dev/null || true
import json, sys
path, version = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as f:
        d = json.load(f)
    opts = d["provider"]["teai"]["options"]
    headers = opts.get("headers")
    if not isinstance(headers, dict):
        headers = {}
        opts["headers"] = headers
    headers["X-Sente-Client-Version"] = version
    with open(path, "w", encoding="utf-8") as f:
        json.dump(d, f, ensure_ascii=False)
except Exception:
    pass
PYHDRPATCH
}
refresh_config() {
  # See the matching note in te-install.sh's installer section: OpenCode does
  # not expand "~/" in "plugin" specs, so rewrite it to a real absolute path.
  curl -fsSL --max-time 2 "$TEAI_SITE/te/config" -o "$CONFIG_DIR/opencode.json.tmp" 2>/dev/null \
    && grep -q '"provider"' "$CONFIG_DIR/opencode.json.tmp" \
    && sed -i.bak "s#~/.config/teai/plugins/koe-speak.js#$CONFIG_DIR/plugins/koe-speak.js#" "$CONFIG_DIR/opencode.json.tmp" \
    && rm -f "$CONFIG_DIR/opencode.json.tmp.bak" \
    && mv "$CONFIG_DIR/opencode.json.tmp" "$CONFIG_DIR/opencode.json" \
    || rm -f "$CONFIG_DIR/opencode.json.tmp" "$CONFIG_DIR/opencode.json.tmp.bak"
  # 🧹 ローカル使用実績フィルタ: 使っていない MCP を落としてツール定義を軽くする。
  # サーバ配信は全6台(bimhouse/jiuflow/kamishibai/koe/mu/image)だが、実測で呼び出し実績が
  # あるのは koe(144件)だけ(2026-08-16 opencode.db 調査)。jiuflow(1件)も含め、
  # コーディング作業で使わない MCP はツール定義がコンテキストを圧迫するだけなので、
  # ローカルの opencode.json からは外す。この curl|sh は全 te ユーザー共通の配布物
  # なので、この KEEP セットは実質デフォルトの公開挙動になる — 個人最適化ではない。
  # image(2026-08-25 追加)は「te で画像生成できるように」という直接の要望機能なので、
  # ゼロ設定で使えないと本末転倒として KEEP に含める。TE_MCP_ALL=1 で全 MCP を使いたい時。
  if [ "${TE_MCP_ALL:-0}" != "1" ] && [ -s "$CONFIG_DIR/opencode.json" ]; then
    python3 - "$CONFIG_DIR/opencode.json" <<'PYMCFILTER' 2>/dev/null || true
import json, sys
path = sys.argv[1]
KEEP = {"koe", "image"}
try:
    with open(path, encoding="utf-8") as f:
        d = json.load(f)
    mcp = d.get("mcp")
    if isinstance(mcp, dict):
        d["mcp"] = {k: v for k, v in mcp.items() if k in KEEP}
        with open(path, "w", encoding="utf-8") as f:
            json.dump(d, f, ensure_ascii=False, indent=2)
except Exception:
    pass
PYMCFILTER
  fi
  # patch AFTER the MCP filter above (which re-dumps the whole file) so this
  # header stamp survives instead of being clobbered by it.
  patch_te_config_headers "$CONFIG_DIR/opencode.json"
  # 声モード用: MCP ゲートウェイ抜きの設定(ツール定義が乗らず一往復が軽い)。
  # 失敗しても致命ではない(無ければ声モードは通常設定で動く)。
  curl -fsSL --max-time 2 "$TEAI_SITE/te/config?mcp=voice" -o "$CONFIG_DIR/opencode-voice.json.tmp" 2>/dev/null \
    && grep -q '"provider"' "$CONFIG_DIR/opencode-voice.json.tmp" \
    && sed -i.bak "s#~/.config/teai/plugins/koe-speak.js#$CONFIG_DIR/plugins/koe-speak.js#" "$CONFIG_DIR/opencode-voice.json.tmp" \
    && rm -f "$CONFIG_DIR/opencode-voice.json.tmp.bak" \
    && mv "$CONFIG_DIR/opencode-voice.json.tmp" "$CONFIG_DIR/opencode-voice.json" \
    || rm -f "$CONFIG_DIR/opencode-voice.json.tmp" "$CONFIG_DIR/opencode-voice.json.tmp.bak"
  patch_te_config_headers "$CONFIG_DIR/opencode-voice.json"
}

# Coding discipline rules, referenced by the config "instructions" field.
# These counter failure modes seen in benchmarking: writing before reading
# (hallucinated findings), flagging test-only code as vulnerabilities, and
# stopping before producing the deliverable. Rewritten every run so the rules
# stay in sync with te itself.
ensure_rules() {
  # 🚀 起動速度改善(2026-08-16): 内容は固定なので、既に正しく書かれていればスキップ。
  # ハッシュ比較で変更時のみ書き込む(毎回 cat > する無駄を省く)。
  local RULES_FILE="$CONFIG_DIR/sente-rules.md"
  local RULES_HASH="9553a69a93230027de7ef16990f553d5"
  [ -f "$RULES_FILE" ] && [ "$(sente_hash_file "$RULES_FILE")" = "$RULES_HASH" ] && return 0
  cat > "$RULES_FILE" <<'RULES'
# Sente coding rules — follow mechanically, not as suggestions

## Always
- Read before you write. Open the real code with a tool before you create/edit a
  file or state any finding. Never guess a line number, API, or macro name.
- Cite evidence. Every claim names a file:line you actually read. If unverified,
  write "unverified" — never invent a location or a fix.
- Finish the deliverable. If asked for a file, fix, or report, produce it before
  ending the turn. Exploring is not finishing.
- Big files: search for candidates first, then read only ~30 lines around each
  hit. Never read a 20k-line file top to bottom.
- Match the surrounding code's style, naming, and idioms.

## Memory (3 layers: shallow index / topic files / deep store)
- ~/.config/teai/memory/MEMORY.md is the auto-loaded hot index. It is an index
  only — one line per memory, each linking a topic file in the same directory.
- Before acting on an indexed topic, read its topic file first.
- When you learn a durable fact (a user preference, a project constraint, a
  trap you actually hit), save it: write ~/.config/teai/memory/<slug>.md and
  add one index line to MEMORY.md. Update an existing file instead of creating
  a duplicate; delete entries that turn out to be wrong.
- Deep store: move index lines inactive for ~2 weeks into
  ~/.config/teai/memory/MEMORY_cold.md. Grep it when older context is needed.
- Keep MEMORY.md short — it is injected into every session and costs tokens.
- Never write secrets (API keys, passwords, tokens) into memory files.

## Unknown words — provisional (abductive) reasoning
- When the user uses a word, name, or acronym you cannot resolve (not in memory,
  not in the codebase, or a likely speech-to-text mishearing), do not stop and
  do not silently guess. Check ~/.config/teai/memory/glossary.md first.
- Form the best provisional hypothesis from context: phonetic neighbours of
  names in memory/glossary, the current project, the last few turns. Prefer the
  reading that makes the request actionable.
- Say it in one short clause and proceed: 「『◯◯』は△△のことだと仮定して進めます」.
  Then continue the task under that assumption.
- Record it in glossary.md as `- ◯◯ → △△ (仮説 YYYY-MM-DD: 根拠)`. When the user
  confirms or corrects, rewrite the line as `(確定 YYYY-MM-DD)`. Confirmed terms
  are also fed to speech recognition as vocabulary hints.
- Never act on a provisional hypothesis for irreversible actions (send, delete,
  pay, publish, deploy) — confirm the word first.
RULES
}

# Sente persistent memory (3 layers), referenced by the config "instructions"
# field server-side (build_te_config): memory/MEMORY.md = auto-loaded hot index
# (shallow), topic files beside it = the body (read before acting), and
# MEMORY_cold.md = deep store (grep on demand). ⚠ Unlike sente-rules.md this is
# PER-USER DATA written by the agent on this machine — created once from the
# template below and NEVER overwritten. Nothing personal ships in the template:
# the only seeded content is generic Sente product knowledge (sente-basics.md)
# so a fresh install starts with a working example of the format.
ensure_memory() {
  local MEM_DIR="$CONFIG_DIR/memory"
  mkdir -p "$MEM_DIR"
  if [ ! -f "$MEM_DIR/MEMORY.md" ]; then
    cat > "$MEM_DIR/MEMORY.md" <<'MEMHOT'
# Sente Memory (hot index)
浅い記憶=この索引(毎セッション自動ロード)。本体=このフォルダのトピックファイル(動く前に読む)。深い記憶=MEMORY_cold.md(休眠・完了はここへ降格。必要な時にgrep)。
書き方: 1行=1メモリ `- [題名](ファイル名.md) — 要点`。秘密(APIキー等)は書かない。約2週間動きのない行はMEMORY_cold.mdへ。

- [Senteの基本](sente-basics.md) — サブコマンド・モデル切替・声・記憶の使い方
- [用語集(仮説→確定)](glossary.md) — 初めて聞いた言葉の暫定推論と、確定した意味。声の語彙ヒントにも使う
MEMHOT
  fi
  # 🧭 用語集(2026-09-06 本人「新しい言葉を聞いたら暫定推論を入れて」): 未知語は仮説として書き、
  # 確定したら (確定) に書き換える。(確定) 行は sente_stt_lexicon が声の語彙ヒントへ拾う。
  # 既存インストールにも索引行だけ足す(ファイル本体はユーザーの記憶なので触らない)。
  if [ ! -f "$MEM_DIR/glossary.md" ]; then
    cat > "$MEM_DIR/glossary.md" <<'MEMGLOSS'
# 用語集 — 初めて聞いた言葉の暫定推論(仮説)と確定
書き方: `- 言葉 → 意味 (仮説 YYYY-MM-DD: 根拠)` → ユーザーが認めたら `(確定 YYYY-MM-DD)` に書き換える。
仮説のまま取り消せないこと(送信・削除・支払い・公開)はしない。(確定) の言葉は声の聞き取りヒントにも渡る。

MEMGLOSS
  fi
  if [ -f "$MEM_DIR/MEMORY.md" ] && ! grep -q 'glossary.md' "$MEM_DIR/MEMORY.md" 2>/dev/null; then
    printf -- '- [用語集(仮説→確定)](glossary.md) — 初めて聞いた言葉の暫定推論と、確定した意味。声の語彙ヒントにも使う\n' >> "$MEM_DIR/MEMORY.md"
  fi
  if [ ! -f "$MEM_DIR/MEMORY_cold.md" ]; then
    cat > "$MEM_DIR/MEMORY_cold.md" <<'MEMCOLD'
# Sente Memory (cold — 深い記憶)
hotから降格した索引行の置き場。自動ロードされない。`grep <キーワード> ~/.config/teai/memory/MEMORY_cold.md` で引く。再燃したら行をMEMORY.mdへ戻す。
MEMCOLD
  fi
  if [ ! -f "$MEM_DIR/sente-basics.md" ]; then
    cat > "$MEM_DIR/sente-basics.md" <<'MEMSEED'
# Senteの基本(シード記憶 — プロダクト知識のみ・個人データなし)
- 入口: `te`=キーボードTUI / `sente`・`koe`=声の連続対話 / `te run "…"`=一発実行
- サブコマンド: `te register`(メール登録) `te login` `te models` `te model <id>`(既定モデル永続) `te engine claude|codex|opencode` `te voice on|off` `te doctor` `te update` `te clean` `te memory`
- モデル: 既定`teai/auto`(サーバ側で自動選択)。ショートカット=auto/fast/lux/max
- 記憶: このフォルダが君(エージェント)の永続記憶。索引=MEMORY.md・本体=トピックファイル・深い記憶=MEMORY_cold.md。ユーザーの好み・案件の制約・実際に踏んだ罠を学んだら保存する
- 設定: `~/.config/teai/`(credentials=APIキー・opencode.json=サーバ生成config)。APIキーは記憶ファイルに書かない
MEMSEED
  fi
}

# Voice (KOE) plugin, referenced by the config "plugin" field — see
# ensure_koe_plugin below. Rewritten every run so it stays in sync with te
# itself, same as sente-rules.md above. On by default (mirrors cagent);
# disable per-run with AGENT_KOE=0 or NO_KOE=1.
# 🔊 speakify(2026-09-06 本人「声で読む時そのまま読まず聞きやすいようにして」): 画面用テキストを
# 話し言葉に直す変換器を1本($CONFIG_DIR/speakify.py)にまとめ、読み上げの全経路(koe_speak_text・
# ACPの文ごとキュー・NOTE・koe-speak.jsプラグイン)がこれを通る。ルールベース=数ミリ秒・決定的。
ensure_speakify() {
  local SPK_FILE="$CONFIG_DIR/speakify.py"
  local SPK_HASH="0fd4f5f0a1a90fea942f8cf4db92c239"
  [ -f "$SPK_FILE" ] && [ "$(sente_hash_file "$SPK_FILE")" = "$SPK_HASH" ] && return 0
  cat > "$SPK_FILE" <<'SPEAKIFYPY'
#!/usr/bin/env python3
# Sente speakify — 画面用のテキストを「聞いてわかる話し言葉」に直してから読み上げる。
# stdin=返答テキスト(markdown可) → stdout=読み上げ用テキスト(1段落・文は「。」区切り)
# 方針: ①読めない/読んでも意味がないもの(コード・URL・パス・表・記号)は「画面に出しました」に畳む
#      ②数字・日付・時刻・金額・単位を日本語の読みに ③英字略語は決まった読みに
#      ④箇条書きは「ひとつ目、…」 ⑤長い文は「、」で割る ⑥絵文字は意味語に置き換える
# ルールベース(LLMを使わない)=一往復あたり数ミリ秒・決定的・オフラインでも同じ。
import re, sys

ABBR = {
    # 自社・製品(読みは既存の声応答で使っている表記に合わせる)
    "Sente": "センテ", "sente": "センテ", "teai": "てあい", "teai.io": "てあい", "JiuFlow": "ジウフロー", "jiuflow": "ジウフロー",
    "Koe": "コエ", "KOE": "コエ", "koe.live": "コエ ライブ", "kuberu": "くべる", "nippo": "日報", "MU": "ムー", "wearmu": "ウェアムー",
    "bim.house": "ビムハウス", "SOLUNA": "ソルーナ", "Sente.app": "センテアプリ", "launchd": "ローンチディー",
    # 技術略語
    "PR": "プルリク", "PRs": "プルリク", "CI": "シーアイ", "API": "エーピーアイ", "URL": "ユーアールエル", "DB": "ディービー",
    "TTS": "読み上げ", "STT": "聞き取り", "MCP": "エムシーピー", "JSON": "ジェイソン", "HTML": "エイチティーエムエル", "CSS": "シーエスエス",
    "CLI": "シーエルアイ", "UI": "ユーアイ", "UX": "ユーエックス", "iOS": "アイオーエス", "macOS": "マックオーエス", "GitHub": "ギットハブ",
    "Stripe": "ストライプ", "Fly.io": "フライ", "Fly": "フライ", "Cloudflare": "クラウドフレア", "Supabase": "スーパベース",
    "LLM": "エルエルエム", "OK": "オーケー", "NG": "エヌジー", "TL": "タイムライン", "IP": "アイピー", "ID": "アイディー",
    "SQL": "エスキューエル", "Rust": "ラスト", "Python": "パイソン", "Swift": "スウィフト", "TypeScript": "タイプスクリプト",
    "exit": "終了コード", "merge": "マージ", "deploy": "デプロイ", "Deploy": "デプロイ", "commit": "コミット", "push": "プッシュ",
    "LINE": "ライン", "Whisper": "ウィスパー", "OpenRouter": "オープンルーター", "DeepSeek": "ディープシーク",
}
EMOJI = {
    "✅": "完了。", "☑️": "完了。", "🔴": "注意。", "🟡": "様子見。", "🟢": "良好。", "⏳": "待ち。", "👉": "次の一手。",
    "🎉": "うれしい知らせ。", "⚠️": "注意。", "⚠": "注意。", "❌": "だめ。", "💡": "ヒント。", "🔥": "", "🪤": "罠。",
    "📌": "", "🆕": "新しく、", "🔁": "", "🧭": "", "📊": "", "🛡": "", "🤖": "", "🥋": "", "🎙": "", "📱": "", "📄": "",
}
COUNTERS = ["ひとつ目", "ふたつ目", "みっつ目", "よっつ目", "いつつ目", "むっつ目", "ななつ目", "やっつ目", "ここのつ目", "とお目"]
MONTHS = "月"


def yen(m):
    return m.group(1).replace(",", "") + "円"


def speakify(text: str) -> str:
    t = text.replace("\r", "")
    notes = []  # 「画面に出しました」系は最後に1回だけ
    # コード塊・表・URL・パス
    if re.search(r"```[\s\S]*?```", t):
        t = re.sub(r"```[\s\S]*?```", " ", t); notes.append("コードは画面に出しました")
    if re.search(r"^\s*\|.*\|\s*$", t, re.M):
        t = re.sub(r"^\s*\|.*\|\s*$", " ", t, flags=re.M); notes.append("表は画面に出しました")
    t = re.sub(r"\[([^\]]*)\]\((https?://[^)]*|[^)]*)\)", r"\1", t)  # [label](url) → label
    if re.search(r"https?://\S+", t):
        t = re.sub(r"https?://\S+", " リンク ", t); notes.append("リンクは画面に出しました")
    # ファイルパス → ファイル名だけ(拡張子は読まない)
    def path_repl(m):
        base = m.group(0).rstrip("/").split("/")[-1]
        base = re.sub(r"\.[A-Za-z0-9]{1,5}$", "", base)
        return f" ファイル {base} " if base else " "
    t = re.sub(r"(?:~|/Users/[^\s/]+|/private|/tmp|/etc|/opt)?(?:/[\w.\-]+){2,}/?", path_repl, t)
    t = re.sub(r"`([^`]*)`", r"\1", t)  # インラインコードは中身だけ
    # 絵文字 → 意味語(既知)/削除(その他)
    for k, v in EMOJI.items():
        t = t.replace(k, v)
    t = re.sub(r"[\U0001F300-\U0001FAFF\U00002600-\U000027BF\U0001F000-\U0001F2FF]", "", t)
    # markdown 見出し・強調・引用
    t = re.sub(r"^\s{0,3}#{1,6}\s*(.+)$", r"\1。", t, flags=re.M)
    t = re.sub(r"\*\*(.+?)\*\*", r"\1", t)
    t = re.sub(r"(?<!\w)[*_](.+?)[*_](?!\w)", r"\1", t)
    t = re.sub(r"^\s*>\s?", "", t, flags=re.M)
    # 箇条書き → ひとつ目、ふたつ目…(5件まで。超える分は「、」で続ける)
    lines = t.split("\n")
    out_lines, idx = [], 0
    for ln in lines:
        m = re.match(r"^\s*(?:[-*・•]|\d+[.)])\s+(.+)$", ln)
        if m:
            body = m.group(1).strip()
            body = re.sub(r"^\[[ xX]\]\s*", lambda mm: "済み、" if "x" in mm.group(0).lower() else "", body)
            label = COUNTERS[idx] + "、" if idx < len(COUNTERS) else ""
            idx += 1
            out_lines.append(f"{label}{body}")
        else:
            if ln.strip():
                idx = 0
            out_lines.append(ln)
    t = "\n".join(out_lines)
    # 金額・数値・日付・時刻・単位
    t = re.sub(r"[¥￥]\s?([\d,]+)", yen, t)
    t = re.sub(r"\$\s?([\d,]+(?:\.\d+)?)", lambda m: m.group(1).replace(",", "") + "ドル", t)
    t = re.sub(r"(\d{4})-(\d{2})-(\d{2})", lambda m: f"{int(m.group(2))}月{int(m.group(3))}日", t)
    t = re.sub(r"(?<!\d)(\d{1,2})/(\d{1,2})(?!\d)", lambda m: f"{int(m.group(1))}月{int(m.group(2))}日", t)
    t = re.sub(r"(?<!\d)(\d{1,2}):(\d{2})(?::\d{2})?(?!\d)", lambda m: f"{int(m.group(1))}時" + (f"{int(m.group(2))}分" if int(m.group(2)) else ""), t)
    t = re.sub(r"(\d),(\d{3})", r"\1\2", t); t = re.sub(r"(\d),(\d{3})", r"\1\2", t)
    t = re.sub(r"(\d)\s?%", r"\1パーセント", t)
    t = re.sub(r"(\d)\s?(ms)\b", r"\1ミリ秒", t); t = re.sub(r"(\d)\s?(km)\b", r"\1キロ", t)
    t = re.sub(r"(\d)\s?(MB|GB|KB)\b", lambda m: m.group(1) + {"MB": "メガ", "GB": "ギガ", "KB": "キロバイト"}[m.group(2)], t)
    t = re.sub(r"(\d)\s*[×x]\s*(\d)", r"\1かける\2", t)
    t = re.sub(r"(\d)\s*/\s*(\d)", r"\1のうち\2", t)
    t = re.sub(r"(\d)\s*[〜~]\s*(\d)", r"\1から\2", t)
    # 略語・英単語(単語境界で。長い語から)
    for k in sorted(ABBR, key=len, reverse=True):
        t = re.sub(rf"(?<![A-Za-z0-9.]){re.escape(k)}(?![A-Za-z0-9])", ABBR[k], t)
    # 記号 → 読み/区切り
    t = t.replace("→", "、").replace("←", "、").replace("⇒", "、").replace("&", "と").replace("+", "プラス")
    t = re.sub(r"\s[-=]{2,}\s", "。", t)
    t = re.sub(r"[()（）\[\]【】「」『』<>]", "、", t)
    t = re.sub(r"[#*_|~`>^\\]", " ", t)
    t = re.sub(r"[:：]", "、", t)
    t = re.sub(r"(?<!\d)[/／](?!\d)", "、", t)
    t = t.replace("…", "。").replace("...", "。").replace("・", "、")
    # 改行=文の区切り。空白整理
    t = re.sub(r"[ \t]+", " ", t)
    t = re.sub(r"\s*\n+\s*", "。", t)
    t = re.sub(r"[、,]\s*[、,]+", "、", t)
    t = re.sub(r"^[、。\s]+|[、\s]+$", "", t)
    t = re.sub(r"。\s*、", "。", t)
    t = re.sub(r"、\s*。", "。", t)
    t = re.sub(r"。{2,}", "。", t)
    # 長い文は読点で割る(60字超)
    sents = []
    for s in re.split(r"(?<=[。!！?？])", t):
        s = s.strip()
        if not s:
            continue
        while len(s) > 60:
            cut = s.rfind("、", 20, 60)
            if cut < 0:
                break
            sents.append(s[:cut] + "。"); s = s[cut + 1:]
        sents.append(s if re.search(r"[。!！?？]$", s) else s + "。")
    t = "".join(sents)
    if notes:
        t += "".join(n + "。" for n in dict.fromkeys(notes))
    return t.strip()


if __name__ == "__main__":
    sys.stdout.write(speakify(sys.stdin.read()))
SPEAKIFYPY
}

# 🔊 声キュー(2026-09-10本人指示「ターミナルごとに声が流れるのを、共通のファイルに溜めて
# まとめて流し、状況を見て指示できるようにしてほしい」)。各セッションの読み上げはここに積まれ、
# 単一ワーカー(voiceq.py worker)がまとめて喋る。複数ターミナルで声が重ならない。
ensure_voiceq() {
  local VQ_FILE="$CONFIG_DIR/voiceq.py"
  local VQ_HASH="c69cd4e15d7b9145d7bdcb148d9c39cb"
  [ -f "$VQ_FILE" ] && [ "$(sente_hash_file "$VQ_FILE")" = "$VQ_HASH" ] && return 0
  cat > "$VQ_FILE" <<'VOICEQPY'
#!/usr/bin/env python3
# Sente voice queue — 各セッションの読み上げを共通キューに溜め、単一ワーカーが
# まとめて端的に喋る。複数ターミナルで声が重なる問題の根治(2026-09-10本人指示)。
#
#   enqueue <session_id>  : stdin の返答テキストを speakify してキューへ積み、ワーカーを起こす
#   worker                : キューを1件ずつ取り出し、溜まっていればLLMで要約してから喋る(単一)
#   queue                 : キューの状況を表示
#   stop                  : いま鳴っているのを止め、キューを空にする
#   skip                  : いま鳴っているのを止め、次の1件へ
#
# 状態はすべて ~/.config/teai/voiceq/ 配下。ロックは flock 相当を mkdir で取る。
import json, os, re, shutil, subprocess, sys, time, urllib.request

HOME = os.path.expanduser("~")
CONF = os.path.join(HOME, ".config", "teai")
QDIR = os.path.join(CONF, "voiceq")
PENDING = os.path.join(QDIR, "pending")
LOCK = os.path.join(QDIR, "worker.lock")
STOP = os.path.join(QDIR, "stop")
MUTE = os.path.join(CONF, "mute")
SPEAKIFY = os.path.join(CONF, "speakify.py")
LOG = os.path.join(QDIR, "worker.log")

KOE_BASE = os.environ.get("KOE_BASE", "https://koe.live")
KOE_KEY = os.environ.get("KOE_KEY", "")
SUMMARY_MODEL = os.environ.get("SENTE_VOICEQ_MODEL", "claude-haiku-4-5-20251001")
# 要約は「3件以上」に限る(2026-09-11 ペルソナFB)。2件は連結で十分=コスト0・待ち時間0。
# 実測: 要約1回=約410トークン・3.4秒。2件に毎回かけるのはコスト重視の人に不利で、
# 声の応答も遅くなる。3件以上=人間が一度に追えない量になって初めて要約が価値を持つ。
SUMMARY_MIN_ITEMS = int(os.environ.get("SENTE_VOICEQ_MIN_ITEMS", "3"))
# これだけ更新が無ければ lock は放置されたとみなす(再生1件は最大120秒+合成60秒を見て余裕を持たせる)
LOCK_STALE_SEC = int(os.environ.get("SENTE_VOICEQ_LOCK_STALE", "600"))
# 直近この秒数以内に発話した「別セッション」が何本あるかで、キューを使うか決める。
# 単一セッション(=大半のユーザー)はキューを通さず即再生=従来通りの応答速度・コスト0。
# 複数ターミナルを並行している時だけ、声が重ならないようキューに積む(2026-09-11 本人指示)。
SOLO_WINDOW_SEC = int(os.environ.get("SENTE_VOICEQ_SOLO_WINDOW", "180"))
RECENT = os.path.join(QDIR, "recent.json")


def voice_id():
    v = os.environ.get("KOE_VOICE", "").strip()
    if v:
        return v
    try:
        with open(os.path.join(CONF, "voice")) as f:
            return f.readline().strip() or "yuki"
    except Exception:
        return "yuki"


def muted():
    if os.environ.get("AGENT_KOE") == "0" or os.environ.get("NO_KOE"):
        return True
    return os.path.exists(MUTE)


def log(msg):
    try:
        os.makedirs(QDIR, exist_ok=True)
        with open(LOG, "a") as f:
            f.write("%s %s\n" % (time.strftime("%H:%M:%S"), msg))
    except Exception:
        pass


def speakify(text):
    try:
        p = subprocess.run(["python3", SPEAKIFY], input=text, capture_output=True,
                           text=True, timeout=5)
        out = (p.stdout or "").strip()
        if out:
            return out
    except Exception:
        pass
    return re.sub(r"```[\s\S]*?```|`[^`]*`|https?://\S+", "", text).strip()[:600]


def note_session(session_id):
    """直近 SOLO_WINDOW_SEC 秒に発話した session_id を記録し、同時並行の本数を返す。
    プロセス走査もDB参照もしない(最も安価)。ファイル1つだけ。"""
    now = time.time()
    try:
        with open(RECENT) as f:
            rec = json.load(f)
        if not isinstance(rec, dict):
            rec = {}
    except Exception:
        rec = {}
    rec = {k: v for k, v in rec.items() if now - float(v) < SOLO_WINDOW_SEC}
    rec[session_id or "?"] = now
    tmp = RECENT + ".tmp"
    try:
        with open(tmp, "w") as f:
            json.dump(rec, f)
        os.replace(tmp, RECENT)
    except Exception:
        pass
    return len(rec)


def enqueue(session_id, text):
    os.makedirs(PENDING, exist_ok=True)
    clean = speakify(text or "")
    if not clean:
        return
    parallel = note_session(session_id or "?")
    # 単一セッション=キューを通さず即再生(従来通り・応答速度そのまま・要約コスト0)
    if parallel <= 1:
        log("solo speak %s len=%d" % (session_id, len(clean)))
        play(clean)
        return
    item = {"ts": time.time(), "session": session_id or "?", "text": clean}
    fn = os.path.join(PENDING, "%d_%d.json" % (int(time.time() * 1000), os.getpid()))
    tmp = fn + ".tmp"
    with open(tmp, "w") as f:
        json.dump(item, f, ensure_ascii=False)
    os.replace(tmp, fn)
    log("enqueue %s len=%d (parallel=%d)" % (session_id, len(clean), parallel))
    spawn_worker()


def spawn_worker():
    try:
        if os.path.exists(LOCK):
            return
        subprocess.Popen(["python3", os.path.abspath(__file__), "worker"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         stdin=subprocess.DEVNULL, start_new_session=True)
    except Exception as e:
        log("spawn err %s" % e)


def take_pending():
    items = []
    try:
        names = sorted(os.listdir(PENDING))
    except FileNotFoundError:
        return items
    for n in names:
        if not n.endswith(".json"):
            continue
        p = os.path.join(PENDING, n)
        try:
            with open(p) as f:
                items.append(json.load(f))
        except Exception:
            pass
        try:
            os.remove(p)
        except Exception:
            pass
    return items


def api_key():
    # ~/.config/teai/credentials は `TEAI_API_KEY=te_...` 形式(ファイル全体を鍵として
    # 送ると Bearer が壊れて 402 になる — 2026-09-10 実測)。環境変数が最優先。
    k = os.environ.get("TEAI_API_KEY", "").strip()
    if k:
        return k
    try:
        with open(os.path.join(CONF, "credentials")) as f:
            for line in f:
                line = line.strip()
                if line.startswith("TEAI_API_KEY="):
                    return line.split("=", 1)[1].strip().strip('"').strip("'")
    except Exception:
        pass
    return ""


def summarize(items):
    # 1件はそのまま。2件以下は連結(要約しない=即レス・コスト0)。3件以上で要約。
    if len(items) == 1:
        return items[0]["text"]
    if len(items) < SUMMARY_MIN_ITEMS:
        # 句点の重複(「。。」)は読み上げで不自然なので畳む
        joined = "".join(it["text"].rstrip("。") + "。" for it in items)
        return joined
    try:
        key = api_key()
        if not key:
            raise ValueError("no key")
        lines = []
        for it in items:
            lines.append("・" + it["text"])
        sysmsg = ("あなたは音声アシスタント。複数の作業セッションから同時に届いた報告を、"
                  "聞き手が一度で状況を掴めるよう1つの端的な報告にまとめる。"
                  "話し言葉で、前置きなし、箇条書きにせず、2〜4文。"
                  "重要な完了・エラー・待ちだけを残し、重複は畳む。記号やコードは読まない。"
                  "文体は必ず「です・ます」調。崩した口語(〜ちゃってます/〜しちゃった/"
                  "〜ですね等)や感嘆詞は禁止。事実と次の一手だけを静かに伝える。"
                  "エラーや失敗は必ず残す(要約で消さない)。")
        body = json.dumps({"model": SUMMARY_MODEL, "max_tokens": 200, "temperature": 0.2,
                           "messages": [{"role": "system", "content": sysmsg},
                                        {"role": "user", "content": "\n".join(lines)}]}).encode()
        req = urllib.request.Request("https://api.teai.io/v1/chat/completions", data=body,
                                     headers={"Content-Type": "application/json",
                                              "Authorization": "Bearer " + key})
        r = json.load(urllib.request.urlopen(req, timeout=20))
        out = (r["choices"][0]["message"]["content"] or "").strip()
        if out:
            return out
    except Exception as e:
        log("summarize fallback %s" % e)
    return "。".join(it["text"] for it in items)


def chunk(text, maxlen=80):
    text = text.strip()
    chunks, rest = [], text
    while rest:
        if len(rest) <= maxlen:
            chunks.append(rest)
            break
        w = rest[:maxlen]
        cut = -1
        for i in range(len(w) - 1, -1, -1):
            if w[i] in "。．!！?？\n":
                cut = i
                break
        if cut < 0:
            cut = maxlen - 1
        head = rest[:cut + 1].strip()
        if head:
            chunks.append(head)
        rest = rest[cut + 1:].strip()
    return chunks


def synth(text, out):
    hdr = ["-H", "X-Koe-Admin: " + KOE_KEY] if KOE_KEY else []
    body = json.dumps({"text": text, "user_id": voice_id(), "source": "sente"})
    cmd = ["curl", "-s", "-m", "60", "-o", out, "-X", "POST",
           KOE_BASE + "/api/speak", "-H", "Content-Type: application/json"] + hdr + ["-d", body]
    try:
        subprocess.run(cmd, timeout=65, check=False)
    except Exception as e:
        log("synth err %s" % e)
        return False
    return os.path.exists(out) and os.path.getsize(out) > 1000


def play(text):
    if muted():
        return
    chunks = chunk(text)
    if not chunks:
        return
    files = []
    for i, c in enumerate(chunks):
        out = "/tmp/sente_vq_%d_%d.mp3" % (os.getpid(), i)
        if synth(c, out):
            files.append(out)
    player = "afplay" if sys.platform == "darwin" else "mpg123"
    for f in files:
        if os.path.exists(STOP):
            break
        try:
            subprocess.run([player, f], timeout=120, check=False)
        except Exception:
            pass
    for f in files:
        try:
            os.remove(f)
        except Exception:
            pass


def lock_is_stale():
    # 🪤 ワーカーが落ちて lock だけ残ると、以後ずっと声が出なくなる(単一障害点)。
    # pid の生存と更新時刻の両方で「放置された lock」を検出して回収する(2026-09-11)。
    pidf = os.path.join(LOCK, "pid")
    try:
        age = time.time() - os.path.getmtime(pidf)
    except Exception:
        return True  # pid ファイルが無い=壊れた lock
    if age > LOCK_STALE_SEC:
        return True
    try:
        pid = int(open(pidf).read().strip())
        os.kill(pid, 0)   # 生存確認(信号は送らない)
    except Exception:
        return True
    return False


def release_lock_if_stale():
    if os.path.exists(LOCK) and lock_is_stale():
        log("stale lock detected — reclaiming")
        try:
            shutil.rmtree(LOCK)
        except Exception:
            try:
                os.rmdir(LOCK)
            except Exception:
                pass


def worker():
    os.makedirs(QDIR, exist_ok=True)
    release_lock_if_stale()
    try:
        os.mkdir(LOCK)
    except FileExistsError:
        return  # 既にワーカーが動いている
    try:
        with open(os.path.join(LOCK, "pid"), "w") as f:
            f.write(str(os.getpid()))
        while True:
            time.sleep(0.4)  # 同時に来た分を少し待ってまとめる
            items = take_pending()
            if not items:
                break
            # 長時間の再生中でも lock を新鮮に保つ(放置判定されないように)
            try:
                os.utime(os.path.join(LOCK, "pid"), None)
            except Exception:
                pass
            if os.path.exists(STOP):
                os.remove(STOP)
                log("stopped, dropped %d" % len(items))
                continue
            if muted():
                log("muted, dropped %d" % len(items))
                continue
            text = summarize(items)
            log("speak %d items -> %d chars" % (len(items), len(text)))
            play(text)
    finally:
        try:
            os.remove(os.path.join(LOCK, "pid"))
            os.rmdir(LOCK)
        except Exception:
            pass


def cmd_queue():
    try:
        names = sorted(n for n in os.listdir(PENDING) if n.endswith(".json"))
    except FileNotFoundError:
        names = []
    running = os.path.exists(LOCK)
    print("🔊 声キュー: %d件待ち / ワーカー: %s" % (len(names), "稼働中" if running else "停止"))
    for n in names:
        try:
            with open(os.path.join(PENDING, n)) as f:
                it = json.load(f)
            t = it["text"]
            print("  ・[%s] %s" % (it.get("session", "?")[:16], t[:70] + ("…" if len(t) > 70 else "")))
        except Exception:
            pass
    if not names:
        print("  (待ちなし)")


def cmd_stop():
    os.makedirs(QDIR, exist_ok=True)
    with open(STOP, "w") as f:
        f.write(str(time.time()))
    subprocess.run(["pkill", "-x", "afplay"], check=False)
    subprocess.run(["pkill", "-x", "mpg123"], check=False)
    n = 0
    try:
        for n2 in os.listdir(PENDING):
            if n2.endswith(".json"):
                os.remove(os.path.join(PENDING, n2))
                n += 1
    except FileNotFoundError:
        pass
    print("⏹ 停止しました(待ち %d件を破棄)" % n)


def cmd_skip():
    os.makedirs(QDIR, exist_ok=True)
    with open(STOP, "w") as f:
        f.write(str(time.time()))
    subprocess.run(["pkill", "-x", "afplay"], check=False)
    subprocess.run(["pkill", "-x", "mpg123"], check=False)
    print("⏭ 次の発話へ(いま鳴っている分を止めました)")


def main():
    if len(sys.argv) < 2:
        cmd_queue()
        return
    cmd = sys.argv[1]
    if cmd == "enqueue":
        enqueue(sys.argv[2] if len(sys.argv) > 2 else "?", sys.stdin.read())
    elif cmd == "worker":
        worker()
    elif cmd == "queue":
        cmd_queue()
    elif cmd == "stop":
        cmd_stop()
    elif cmd == "skip":
        cmd_skip()
    else:
        print("usage: voiceq.py enqueue|worker|queue|stop|skip", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
VOICEQPY
}
sente_speakify() {  # stdin→stdout: 聞きやすい話し言葉へ。python3無し/失敗時はそのまま返す
  SPI="$(cat)"
  [ -n "$SPI" ] || return 0
  if command -v python3 >/dev/null 2>&1 && [ -f "$CONFIG_DIR/speakify.py" ]; then
    SPO="$(printf '%s' "$SPI" | python3 "$CONFIG_DIR/speakify.py" 2>/dev/null)"
    [ -n "$SPO" ] && { printf '%s' "$SPO"; return 0; }
  fi
  printf '%s' "$SPI"
}

ensure_koe_plugin() {
  mkdir -p "$CONFIG_DIR/plugins"
  # 🚀 起動速度改善(2026-08-16): 内容は固定なので、既に正しく書かれていればスキップ。
  # ハッシュ比較で変更時のみ書き込む(毎回 cat > する無駄を省く)。
  local KOE_FILE="$CONFIG_DIR/plugins/koe-speak.js"
  local KOE_HASH="6b70b3f441c05fad40906637b63856ce"
  [ -f "$KOE_FILE" ] && [ "$(sente_hash_file "$KOE_FILE")" = "$KOE_HASH" ] && return 0
  cat > "$KOE_FILE" <<'KOEPLUGIN'
// Sente KOE voice plugin — 各セッションの返答を共通キューに積むだけ。
// 実際の読み上げは単一ワーカー(~/.config/teai/voiceq.py worker)が行う。
// これで複数ターミナルが同時に idle になっても声が重ならず、まとめて端的に喋る。
export const KoeSpeak = async ({ client }) => {
  const HOME = process.env.HOME || "";
  const VOICEQ = HOME + "/.config/teai/voiceq.py";

  async function enqueue(sessionID, text) {
    if (!text) return;
    try {
      const { spawn } = await import("node:child_process");
      const proc = spawn("python3", [VOICEQ, "enqueue", sessionID || "?"], {
        stdio: ["pipe", "ignore", "ignore"],
        detached: true,
      });
      proc.stdin.write(text);
      proc.stdin.end();
      proc.unref();
    } catch (e) {
      console.error(`[koe] enqueue error: ${e && e.message}`);
    }
  }

  return {
    event: async ({ event }) => {
      if (event.type !== "session.status") return;
      if (!event.properties || !event.properties.status || event.properties.status.type !== "idle") return;
      if (process.env.AGENT_KOE === "0" || process.env.NO_KOE) return;
      // 🔇 ~/.config/teai/mute は毎回見る(te voice off/声「静かにして」/Sente.appワンクリックが実行中でも即効く)
      try { if ((await import("node:fs")).existsSync((process.env.HOME || "") + "/.config/teai/mute")) return; } catch (e) {}
      const sessionID = event.properties.sessionID;
      try {
        // 🪶 メモリ削減(2026-08-16): 全会話履歴ではなく最新1件だけ取得。
        // limit:1 でサーバは MessageV2.page(ORDER BY DESC+reverse)で最新1件のみ返す。
        const resp = await client.session.messages({ path: { id: sessionID }, query: { limit: 1 } });
        const messages = resp && resp.data ? resp.data : resp;
        if (!Array.isArray(messages) || !messages.length) return;
        const last = messages[messages.length - 1];
        if (!last || !last.info || last.info.role !== "assistant") return;
        const text = (last.parts || [])
          .filter((p) => p.type === "text")
          .map((p) => p.text)
          .join("\n");
        enqueue(sessionID, text).catch(() => {});
      } catch (e) {
        console.error(`[koe] plugin error: ${e && e.message}`);
      }
    },
  };
};
KOEPLUGIN
}

# 🚀 起動速度改善(2026-08-30本人指示「文字描けるまで時間かかるから爆速して」):
# oc_gc 内の oc_resguard/oc_resource_advice は `ps -eo ... -r/-m` で全プロセスを毎回
# 走査しており、Mac全体が高負荷な時ほど重くなって最初の描画を遅らせていた(実測: 高負荷時
# 1秒超)。片付け・診断とも1ターン遅れても実害が無い設計(診断は .last-boot-notes に保存済で
# te doctor から見返せる、GCは次回起動でも回収できる)ので、TUI描画をブロックせず裏で走らせる。
( oc_gc ) & disown $! 2>/dev/null || true

# 🌐 UI言語(te start / te stats / te help の表示言語)。優先順:
#   te lang で保存した設定 > TE_LANG > LC_ALL/LANG > ja。ja 以外は en。
te_ui_lang() {
  UL=""
  [ -f "$CONFIG_DIR/ui-lang" ] && UL="$(cat "$CONFIG_DIR/ui-lang" 2>/dev/null)"
  [ -n "$UL" ] || UL="${TE_LANG:-${LC_ALL:-${LANG:-ja}}}"
  case "$UL" in ja*|ja_JP*) echo ja ;; *) echo en ;; esac
}

case "${1:-}" in
  memory)
    # 🧠 永続記憶(この端末のユーザーごと・サーバへは送らない)。hot索引は毎セッション
    # configのinstructions経由で自動注入される。cold=深い記憶はgrepで引く。
    ensure_memory
    case "${2:-}" in
      cold) cat "$CONFIG_DIR/memory/MEMORY_cold.md"; exit 0 ;;
      path) echo "$CONFIG_DIR/memory"; exit 0 ;;
      *)
        echo "🧠 Sente memory — 浅い(自動ロード)=$CONFIG_DIR/memory/MEMORY.md / 深い=MEMORY_cold.md (te memory cold)"
        echo ""
        cat "$CONFIG_DIR/memory/MEMORY.md"
        exit 0 ;;
    esac ;;
  login)
    mkdir -p "$CONFIG_DIR"
    printf "アカウントがまだなければ 'te register' でメール登録から一発でできます。\nGet your API key: %s/dashboard#api-keys\nPaste it here (te_...): " "$TEAI_SITE"
    KEY="$(head -1 /dev/tty | tr -d '[:space:]')"
    [ -n "$KEY" ] || { echo "No key entered."; exit 1; }
    # 貼り付け直後に検証: 無効な鍵を黙って保存すると、後で使うときにだけ
    # 「デモです」表示になり原因が分かりにくい。ここで /auth/me に当てて確認する。
    ME="$(curl -s --max-time 10 -H "Authorization: Bearer $KEY" "$TEAI_API/api/v1/auth/me" 2>/dev/null || true)"
    case "$ME" in
      *'"authenticated":true'*) ;;
      *)
        echo "❌ このキーは無効です(サーバーが認証できませんでした)。$TEAI_SITE/keys で新しいキーを発行してから、もう一度 'te login' してください。"
        exit 1 ;;
    esac
    printf 'TEAI_API_KEY=%s\n' "$KEY" > "$CREDS" && chmod 600 "$CREDS"
    echo "Saved to $CREDS"
    exit 0 ;;
  register)
    mkdir -p "$CONFIG_DIR"
    if [ -f "$CREDS" ]; then
      echo "ℹ️ すでに $CREDS にAPIキーがあります。別アカウントで登録し直す場合はこのまま続けてください(上書きされます)。"
    fi
    printf "メールアドレスを入力してください: "
    EMAIL="$(head -1 /dev/tty | tr -d '[:space:]')"
    case "$EMAIL" in
      *@*.*) ;;
      *) echo "❌ メールアドレスの形式が正しくありません。"; exit 1 ;;
    esac

    # Webダッシュボードにログインする時だけ使うランダムパスワード(APIキーだけ使うなら不要)
    PASS="$(python3 -c 'import secrets;print(secrets.token_urlsafe(12))' 2>/dev/null)"
    [ -n "$PASS" ] || PASS="Sente-$$-$(date +%s 2>/dev/null || echo 0)x"

    echo "登録中… ($EMAIL)"
    REG_BODY="$(python3 -c 'import json,sys;print(json.dumps({"email":sys.argv[1],"password":sys.argv[2]}))' "$EMAIL" "$PASS")"
    REGRESP="$(curl -s --max-time 20 -X POST "$TEAI_API/api/v1/auth/register" \
      -H 'Content-Type: application/json' -d "$REG_BODY" | cat)"
    if [ -z "$REGRESP" ]; then
      echo "❌ サーバーに接続できませんでした。ネットワークを確認して 'te register' をやり直してください。"; exit 1
    fi
    if ! printf '%s' "$REGRESP" | grep -q '"ok":true'; then
      ERR="$(printf '%s' "$REGRESP" | sed -n 's/.*"error":"\([^"]*\)".*/\1/p' | head -1)"
      echo "❌ 登録に失敗しました: ${ERR:-不明なエラー}"
      case "$ERR" in
        *"already registered"*) echo "   → 登録済みのメールです。'te login' で既存のAPIキー($TEAI_SITE/dashboard#api-keys)を貼ってください。" ;;
      esac
      exit 1
    fi

    echo "✅ 確認コードを $EMAIL に送信しました(メールを確認してください)。"
    TOKEN=""
    TRY=0
    while [ "$TRY" -lt 3 ]; do
      TRY=$((TRY + 1))
      printf "6桁の確認コードを入力してください: "
      CODE="$(head -1 /dev/tty | tr -dc '0-9')"
      if [ -z "$CODE" ]; then echo "コードが未入力です。"; continue; fi
      VER_BODY="$(python3 -c 'import json,sys;print(json.dumps({"email":sys.argv[1],"code":sys.argv[2]}))' "$EMAIL" "$CODE")"
      VERRESP="$(curl -s --max-time 20 -X POST "$TEAI_API/api/v1/auth/verify" \
        -H 'Content-Type: application/json' -d "$VER_BODY" | cat)"
      if printf '%s' "$VERRESP" | grep -q '"ok":true'; then
        TOKEN="$(printf '%s' "$VERRESP" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p' | head -1)"
        break
      fi
      ERR="$(printf '%s' "$VERRESP" | sed -n 's/.*"error":"\([^"]*\)".*/\1/p' | head -1)"
      echo "❌ ${ERR:-確認に失敗しました}"
    done
    if [ -z "$TOKEN" ]; then
      echo "確認できませんでした。'te register' からやり直してください。"; exit 1
    fi

    KEYRESP="$(curl -s --max-time 20 -X POST "$TEAI_API/api/v1/apikeys" \
      -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
      -d '{"name":"sente-cli"}' | cat)"
    NEWKEY="$(printf '%s' "$KEYRESP" | sed -n 's/.*"api_key":"\([^"]*\)".*/\1/p' | head -1)"
    if [ -z "$NEWKEY" ]; then
      echo "APIキーの発行に失敗しました。$TEAI_SITE/dashboard#api-keys から手動で発行して 'te login' に貼ってください。"; exit 1
    fi
    printf 'TEAI_API_KEY=%s\n' "$NEWKEY" > "$CREDS" && chmod 600 "$CREDS"

    ME="$(curl -s --max-time 10 -H "Authorization: Bearer $NEWKEY" "$TEAI_API/api/v1/auth/me" | cat)"
    CREDITS="$(printf '%s' "$ME" | sed -n 's/.*"credits_remaining":\([0-9.]*\).*/\1/p' | head -1)"
    echo ""
    echo "🎉 登録完了! $EMAIL"
    if [ -n "$CREDITS" ]; then
      YEN=$((${CREDITS%.*} / 6))
      echo "   クレジット: ${CREDITS} (約¥${YEN}分・無料)"
    fi
    echo "   Webダッシュボードのパスワード(必要になったら使う・今は不要): $PASS"
    echo "   APIキーを $CREDS に保存しました。"
    echo ""
    echo ""
    echo "🎉 これで使えます。おすすめの最初の一歩:"
    echo "   sente                     # 声で話しかける(「電卓アプリ作って」など)"
    echo "   te run \"1たす1は?\"         # キーボードで一発"
    echo "   te                        # じっくり対話(OpenCode)"
    echo "   ガイド: $TEAI_SITE/blog/sente-start"
    echo "動画やSNSでコードをもらった方は: te redeem <コード>"
    # 登録直後にsenteを勧める(TTYなら声で一言)
    if [ -t 1 ] && command -v afplay >/dev/null 2>&1 && ! sente_muted; then
      ( GRT="$(mktemp "${TMPDIR:-/tmp}/te_greet_XXXXXX").mp3"
        curl -s -m 8 -X POST "${KOE_BASE:-https://koe.live}/api/speak" -H 'Content-Type: application/json' \
          -d '{"text":"登録できました。センテ、と打って話しかけてみてください。","user_id":"yuki","source":"register"}' -o "$GRT" 2>/dev/null \
          && afplay "$GRT" >/dev/null 2>&1; rm -f "$GRT" ) >/dev/null 2>&1 &
    fi
    exit 0 ;;
  redeem)
    shift
    CODE="${1:-}"
    load_key
    [ -n "$TEAI_API_KEY" ] || { echo "No API key. Run: te register (new account) or te login"; exit 1; }
    if [ -z "$CODE" ]; then
      printf "クーポンコードを入力してください: "
      CODE="$(head -1 /dev/tty | tr -d '[:space:]')"
    fi
    [ -n "$CODE" ] || { echo "コードが未入力です。"; exit 1; }
    RESP="$(curl -s --max-time 15 -X POST "$TEAI_API/api/v1/coupon/redeem" \
      -H "Authorization: Bearer $TEAI_API_KEY" -H 'Content-Type: application/json' \
      -d "$(python3 -c 'import json,sys;print(json.dumps({"code":sys.argv[1]}))' "$CODE")" | cat)"
    if printf '%s' "$RESP" | grep -q '"success":true'; then
      GRANTED="$(printf '%s' "$RESP" | sed -n 's/.*"grant_credits":\([0-9]*\).*/\1/p' | head -1)"
      REMAIN="$(printf '%s' "$RESP" | sed -n 's/.*"credits_remaining":\([0-9.]*\).*/\1/p' | head -1)"
      echo "🎁 適用完了! +${GRANTED:-?}クレジット(残高: ${REMAIN:-不明})"
    else
      ERR="$(printf '%s' "$RESP" | sed -n 's/.*"error_ja":"\([^"]*\)".*/\1/p' | head -1)"
      echo "❌ ${ERR:-クーポンの適用に失敗しました}"
      exit 1
    fi
    exit 0 ;;
  resume)
    # ⏸ 途中で止まった続きを一発で: 直前セッションを開き、止まっていたら再開プロンプトまで自動投入
    # (TUI側の --resume。止まっていなければ普通の -c と同じ)
    shift; set -- --resume "$@" ;;
  watashibi|handoff|hikitsugi)
    # 🔥 渡し火: 前のセッションが残した種火(.sente/watashibi/latest.md)だけを読んで、白紙の新セッションで続ける
    # (TUI内では /watashibi。ここは「別ターミナル/別マシンから種火を拾う」用)
    shift
    if [ ! -f .sente/watashibi/latest.md ]; then
      echo "🔥 渡し火の種火が見つかりません: $(pwd)/.sente/watashibi/latest.md"
      echo "   前のセッションで /watashibi を実行すると、ここに引き継ぎ書が書かれます。"
      exit 1
    fi
    set -- --prompt "渡し火 (Watashibi): you are a fresh session. The previous session left its handoff note at \`.sente/watashibi/latest.md\`.
1. Read that file first. Treat it as the whole context; do not try to recover the old conversation.
2. Re-check the current state of the files and tools it names before acting; do not assume earlier edits landed.
3. Continue from the 次の一手 / Next section until the goal is done, then report what you did and what is left.
If the note is missing or unclear, say so in one line and ask." "$@" ;;
  update)
    # Download first, then run: with `curl | sh` a stalled connection leaves sh
    # blocked forever waiting for the rest of the script (seen 2026-09-06 on m5:
    # curl ESTABLISHED but idle, sh in read(0) for 7+ minutes). A whole-file
    # download can carry a hard timeout without cutting a long-running install.
    UPD_TMP="$(mktemp "${TMPDIR:-/tmp}/te_update_XXXXXX")" || exit 1
    if ! curl -fsSL --retry 2 --retry-delay 2 -m 120 "$TEAI_SITE/te" -o "$UPD_TMP"; then
      rm -f "$UPD_TMP"
      echo "🔴 インストーラを取得できませんでした($TEAI_SITE/te)。ネットワークを確認して再実行してください。" >&2
      exit 1
    fi
    TE_FORCE_BINARY_UPDATE=1 sh "$UPD_TMP"; UPD_RC=$?
    rm -f "$UPD_TMP"
    exit $UPD_RC ;;
  models)
    load_key
    curl -fsSL "$TEAI_API/v1/models" | tr ',' '\n' | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | sort
    exit 0 ;;
  bench)
    # 📊 `te bench [<eval>] [<model>]` — 公式ベンチマークを自分のモデルで実測する。
    # 評価セットは teai.io が公開している機械採点の実測ベンチ(/api/v1/bench)。
    # 設問・正解も公開データを使うので、誰が測っても同じ問題で比べられる。
    # 既定: 日本の実務計算(jp-business)・既定モデルがそのまま使われる。
    # 例: te bench / te bench jp-business moonshotai/kimi-k3 / te bench general teai/auto
    shift || true
    EVAL="${1:-jp-business}"
    BENCH_MODEL="${2:-}"
    load_key
    [ -n "$TEAI_API_KEY" ] || { echo "No API key. Run: te register (new account) or te login"; exit 1; }
    command -v python3 >/dev/null 2>&1 || { echo "te bench には python3 が必要です。"; exit 1; }
    if [ -n "$BENCH_MODEL" ]; then
      FORCE_MODEL="$BENCH_MODEL"
    elif [ -f "$CONFIG_DIR/default-model" ]; then
      FORCE_MODEL="$(cat "$CONFIG_DIR/default-model")"
    else
      FORCE_MODEL="teai/auto"
    fi
    # 評価セットを取得(設問+正解のJSONL・公開API)。失敗したら案内して終了。
    EVAL_URL="$TEAI_SITE/api/v1/bench/eval/$EVAL"
    EVAL_TMP="$(mktemp "${TMPDIR:-/tmp}/te_bench_eval_XXXXXX")"
    EVAL_HTTP="$(curl -s --max-time 20 -o "$EVAL_TMP" -w '%{http_code}' "$EVAL_URL")"
    if [ "$EVAL_HTTP" != "200" ] || [ ! -s "$EVAL_TMP" ]; then
      echo "🔴 評価セット '$EVAL' を取得できませんでした(HTTP ${EVAL_HTTP:-?})。"
      echo "   利用できる評価: jp-business(日本の実務計算・182問) / jp-business-hard(難問・26問)"
      echo "   一覧と実測値: $TEAI_SITE/bench"
      rm -f "$EVAL_TMP"
      exit 1
    fi
    BENCH_OUT="$(mktemp "${TMPDIR:-/tmp}/te_bench_out_XXXXXX").json"
    echo "📊 te bench — 評価セット: $EVAL / モデル: $FORCE_MODEL"
    echo "   設問数: $(wc -l < "$EVAL_TMP" | tr -d ' ')問・機械採点・実トークン×単価でコスト集計"
    echo "   (中略せず全問実行します。数分かかります)"
    TEAI_API_KEY="$TEAI_API_KEY" TE_BENCH_EVAL="$EVAL" python3 - "$EVAL_TMP" "$FORCE_MODEL" "$BENCH_OUT" <<'PYBENCH' || { rm -f "$EVAL_TMP" "$BENCH_OUT"; exit 1; }
import json, os, sys, time, urllib.request
eval_file, model, out_file = sys.argv[1], sys.argv[2], sys.argv[3]
api = "https://api.teai.io/v1/chat/completions"
key = os.environ.get("TEAI_API_KEY", "")
items = [json.loads(l) for l in open(eval_file, encoding="utf-8") if l.strip()]
def norm(s):
    return "".join(c for c in (s or "") if not c.isspace() and c not in "，,円日坪%.。").replace("㎡", "")
results, n_ok, n_err, n_call = [], 0, 0, 0
t0 = time.time()
for i, it in enumerate(items):
    body = json.dumps({"model": model, "messages": [{"role": "user", "content": it["prompt"]}],
                       "temperature": 0, "max_tokens": 256}).encode()
    req = urllib.request.Request(api, data=body, headers={"Content-Type": "application/json",
                                                          "Authorization": "Bearer " + key})
    rec = {"id": it["id"], "kind": it.get("kind"), "criteria": it["criteria"]}
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            d = json.loads(r.read())
            content = d["choices"][0]["message"]["content"] or ""
            usage = d.get("usage") or {}
            rec.update({"answer": content.strip(), "ok": norm(content) == norm(it["criteria"]),
                        "prompt_tokens": usage.get("prompt_tokens", 0),
                        "completion_tokens": usage.get("completion_tokens", 0)})
    except urllib.error.HTTPError as e:
        rec["error"] = "HTTP %d: %s" % (e.code, e.read().decode(errors="replace")[:120])
        n_err += 1
    except Exception as e:
        rec["error"] = str(e)
        n_err += 1
    if "error" in rec:
        print("[%d/%d] %s ERROR: %s" % (i+1, len(items), it["id"], rec["error"][:60]), flush=True)
    else:
        n_call += 1
        if rec["ok"]: n_ok += 1
        print("[%d/%d] %s %s criteria=%s answer=%s" % (
            i+1, len(items), "OK " if rec["ok"] else "NG ", it["id"],
            it["criteria"], (rec.get("answer") or "")[:40]), flush=True)
    results.append(rec)
elapsed = time.time() - t0
prompt_tok = sum(r.get("prompt_tokens", 0) for r in results)
comp_tok = sum(r.get("completion_tokens", 0) for r in results)
# 単価は /api/v1/bench の prices_usd_per_1m から取得。
# エイリアス(例: deepseek-v4-flash)は単価表に無い場合があるので、前方一致で正規名へ補正する。
price = {"input": 0.0, "output": 0.0}
price_key = None
try:
    meta = json.load(urllib.request.urlopen("https://teai.io/api/v1/bench", timeout=15))
    prices = meta.get("prices_usd_per_1m", {}) or {}
    if model in prices:
        price_key = model
    else:
        for k in prices:
            if k.startswith(model):
                price_key = k
                break
    p = prices.get(price_key) or {} if price_key else {}
    price = {"input": p.get("input", 0.0) or 0.0, "output": p.get("output", 0.0) or 0.0}
except Exception:
    price_key = None
have_price = bool(price["input"] or price["output"])
cost_usd = (prompt_tok / 1e6) * price["input"] + (comp_tok / 1e6) * price["output"]
if have_price and price_key != model:
    print("   ※ 単価表の正規名 '%s' を使ってコストを計算しました(エイリアス: %s)" % (price_key, model), flush=True)
if not have_price:
    print("   ※ このモデルは単価表に未掲載のため、コストは集計しません(実測トークンのみ)。", flush=True)
result_json = {"eval": os.environ.get("TE_BENCH_EVAL", ""), "model": model,
               "price_key": price_key, "items": len(items), "ok": n_ok,
               "errors": n_err, "prompt_tokens": prompt_tok, "completion_tokens": comp_tok,
               "cost_usd": round(cost_usd, 6) if have_price else None,
               "elapsed_s": round(elapsed, 1), "results": results}
json.dump(result_json, open(out_file, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
denom = max(len(items) - n_err, 1)
print("\n==== %s / %s: %d/%d 正答 (%.1f%%) ・ エラー %d ・ %.1f秒%s ====" % (
    model, os.environ.get("TE_BENCH_EVAL", ""), n_ok, len(items) - n_err,
    100.0 * n_ok / denom, n_err, elapsed,
    (" ・ 実測コスト $%.4f" % cost_usd) if have_price else ""))
PYBENCH
    rm -f "$EVAL_TMP"
    echo ""
    echo "   結果を共有するなら: te bench のこの出力をそのままZenn/ブログにどうぞ"
    echo "   (設問・正解・採点コードは teai.io/bench で全部公開しています)"
    rm -f "$BENCH_OUT"
    exit 0 ;;
  model)
    shift
    ID="${1:-}"
    load_key
    mkdir -p "$CONFIG_DIR"
    if [ -z "$ID" ]; then
      if [ -f "$CONFIG_DIR/default-model" ]; then
        printf "Current default: %s\n\n" "$(cat "$CONFIG_DIR/default-model")"
      else
        echo "Current default: teai/auto (automatic model selection)"
        echo ""
      fi
      echo "Popular models (te models = full catalog):"
      echo "  teai/auto                     — automatic model selection"
      echo "  teai/lux                      — Claude/OpenAI flagship (Fable 5)"
      echo "  moonshotai/kimi-k3            — strongest (2.8T, 1M ctx)"
      echo "  z-ai/glm-5.2                  — balanced"
      echo "  meta-llama/llama-4-maverick   — mid tier"
      echo "  deepseek/deepseek-v4-flash    — fastest & cheapest"
      echo ""
      echo "Usage: te model <id>   (e.g. te model moonshotai/kimi-k3)"
      exit 0
    fi
    printf '%s' "$ID" > "$CONFIG_DIR/default-model"
    echo "✅ Default model set to $ID (persists across runs — override once with: te max / te auto / te fast / te -m teai/<id>)"
    exit 0 ;;
  voice)
    # 🎙 Senteの声の切替(2026-08-06本人指示)。~/.config/teai/voice に永続・環境変数KOE_VOICEが明示されていれば常にそちらが勝つ。
    shift || true
    mkdir -p "$CONFIG_DIR"
    case "${1:-}" in
      "")
        VNOW="${KOE_VOICE:-yuki}"
        if sente_muted; then
          if [ "${AGENT_KOE:-1}" = "0" ] || [ -n "${NO_KOE:-}" ]; then VOFF_BY="環境変数で指定"; else VOFF_BY="te voice off / Sente.app / 声で設定"; fi
          echo "🔇 声: OFF($VOFF_BY)— 戻す: te voice on"
        else
          echo "🔊 声: ON — 消す: te voice off"
        fi
        echo "いまの声: $VNOW$([ -f "$CONFIG_DIR/voice" ] && printf ' (te voiceで設定)')"
        echo "変更: te voice <id>(例: te voice kentaro)/ 戻す: te voice reset"
        echo "自分の声にする: te voice enroll(15秒の録音だけで登録できます)"
        echo "使える声: 自分でenrollした声(koe.live/enroll)や、koe.live/lendable の公開声のID"
        echo "溜まった声: te voice queue / 止める: te voice stop / 次へ: te voice skip"
        ;;
      on|オン|unmute)
        rm -f "$CONFIG_DIR/mute"
        echo "🔊 声をONにしました(talk・run・kuberu 全部で読み上げます。実行中のセッションにも即効きます)"
        [ "${AGENT_KOE:-}" = "0" ] && echo "⚠ ただし今の環境では AGENT_KOE=0 が指定されているため、この端末では鳴りません(unset AGENT_KOE で解除)"
        ;;
      off|オフ|mute)
        mkdir -p "$CONFIG_DIR"; : > "$CONFIG_DIR/mute"
        # いま鳴っている読み上げもその場で止める(sente_stop_speakingと同手順のインライン。
        # 本体関数はこのcaseより後ろで定義されるため、ここでは呼べない=第5弾で踏んだ並び順の罠)
        : > /tmp/sente_say_stop
        pkill -x afplay 2>/dev/null || true
        pkill -x mpg123 2>/dev/null || true
        rm -f /tmp/sente_speaking.lock /tmp/sente_turn_open
        [ -f "$CONFIG_DIR/voiceq.py" ] && python3 "$CONFIG_DIR/voiceq.py" stop >/dev/null 2>&1 || true
        echo "🔇 声をOFFにしました(実行中のセッションも即無音・次回以降も維持・戻す: te voice on)" ;;
      enroll|register|mine|登録)
        # 🎙 自分の声をKOEに登録する導線(CLI版・talkの「自分の声を登録して」と同じ)
        echo "🎙 自分の声をSenteの声にする手順:"
        echo "  1. いま開くページで好きなID(ハンドル名)を決め、表示される一文を読んで録音(15秒)"
        echo "  2. 登録できたら: te voice <そのID>"
        echo "  → https://koe.live/enroll"
        { command -v open >/dev/null 2>&1 && open "https://koe.live/enroll"; } || \
          { command -v xdg-open >/dev/null 2>&1 && xdg-open "https://koe.live/enroll" >/dev/null 2>&1; } || true
        ;;
      reset)
        rm -f "$CONFIG_DIR/voice"
        echo "✅ 既定(yuki)に戻しました" ;;
      queue|q)
        python3 "$CONFIG_DIR/voiceq.py" queue ;;
      stop)
        python3 "$CONFIG_DIR/voiceq.py" stop ;;
      skip)
        python3 "$CONFIG_DIR/voiceq.py" skip ;;
      *)
        VID="$(printf '%s' "$1" | tr -cd 'a-zA-Z0-9_-' | cut -c1-64)"
        [ -n "$VID" ] || { echo "IDが不正です"; exit 1; }
        # 盛らない: 実際に1回合成して使えるか確かめてから保存する(同意未確認・管理者限定の声は403)
        VT="$(mktemp "${TMPDIR:-/tmp}/te_voice_XXXXXX").mp3"
        VC="$(curl -s -m 30 -o "$VT" -w '%{http_code}' -X POST "${KOE_BASE:-https://koe.live}/api/speak" \
          -H 'Content-Type: application/json' \
          -d "$(python3 -c 'import json,sys;print(json.dumps({"text":"こんにちは、センテです。この声でお話しします。","user_id":sys.argv[1],"source":"sente"}))' "$VID" 2>/dev/null)" 2>/dev/null)"
        if [ "$VC" = "200" ] && [ "$(wc -c < "$VT" 2>/dev/null || echo 0)" -gt 1000 ]; then
          printf '%s\n' "$VID" > "$CONFIG_DIR/voice"
          { afplay "$VT" >/dev/null 2>&1 || mpg123 "$VT" >/dev/null 2>&1 || true; }
          echo "✅ 声を $VID にしました(いま鳴ったのがその声です)"
          echo "   ℹ 相槌の作り置きは新しい声で貯め直すため、初回だけ少し遅いことがあります"
        else
          VMSG="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("detail",""))' "$VT" 2>/dev/null || true)"
          echo "🔴 この声は使えませんでした(HTTP ${VC:-?}) ${VMSG}"
        fi
        rm -f "$VT"
        ;;
    esac
    exit 0 ;;
  engine)
    # 🔀 Senteの実行エンジン切替(2026-08-06本人指示)。~/.config/teai/engine に永続。
    # 優先順位: 環境変数TE_ENGINE > このファイル > 既定opencode。talk中の声コマンドでも同じ設定を切り替える。
    shift || true
    mkdir -p "$CONFIG_DIR"
    case "${1:-}" in
      "")
        ENOW="$(sente_engine_get)"
        echo "いまのエンジン: $ENOW$([ -n "${TE_ENGINE:-}" ] && printf ' (環境変数TE_ENGINEで指定中)')"
        echo "切替: te engine claude|codex|opencode / 戻す: te engine reset"
        ;;
      reset|opencode)
        sente_engine_set opencode
        echo "✅ 既定(opencode)に戻しました" ;;
      claude|codex)
        sente_engine_set "$1"
        echo "✅ エンジンを $1 にしました(以後の talk・声のやりとりに反映されます)" ;;
      *)
        echo "使い方: te engine claude|codex|opencode|reset" >&2
        exit 1 ;;
    esac
    exit 0 ;;
  claude)
    shift
    load_key
    [ -n "$TEAI_API_KEY" ] || { echo "No API key. Run: te register (new account) or te login (paste existing key, get one at $TEAI_SITE/dashboard#api-keys)"; exit 1; }
    command -v claude >/dev/null 2>&1 || {
      echo "Claude Code CLI not found. Install: https://claude.com/claude-code"
      exit 1
    }
    # Route Claude Code straight at teai.io's Anthropic-compatible /v1/messages
    # endpoint, reusing the same te_... key `te login` already saved.
    export ANTHROPIC_BASE_URL="$TEAI_API"
    export ANTHROPIC_AUTH_TOKEN="$TEAI_API_KEY"
    MODEL_ARG="${1:-}"
    if [ -n "$MODEL_ARG" ] && [ "${MODEL_ARG#-}" = "$MODEL_ARG" ]; then
      # First arg given and not a flag (e.g. `te claude moonshotai/kimi-k3`) — use it
      # as the model and don't forward it to `claude` itself.
      export ANTHROPIC_MODEL="$MODEL_ARG"
      shift
    elif [ -f "$CONFIG_DIR/default-model" ]; then
      export ANTHROPIC_MODEL="$(cat "$CONFIG_DIR/default-model")"
    fi
    printf "🔗 te claude — teai.io via /v1/messages (model: %s)\n" "${ANTHROPIC_MODEL:-server default}" >&2
    exec claude "$@"
    exit 0 ;;
  whoami)
    load_key
    [ -n "$TEAI_API_KEY" ] || { echo "No API key. Run: te register (new account) or te login"; exit 1; }
    RESP="$(curl -fsSL --max-time 5 -H "Authorization: Bearer $TEAI_API_KEY" "$TEAI_API/api/v1/auth/me")"
    EMAIL="$(printf '%s' "$RESP" | sed -n 's/.*"email":"\([^"]*\)".*/\1/p' | head -1)"
    CREDITS="$(printf '%s' "$RESP" | sed -n 's/.*"credits_remaining":\([0-9.]*\).*/\1/p' | head -1)"
    echo "👋 $EMAIL — credits remaining: ${CREDITS:-unknown}"
    exit 0 ;;
  lang)
    # 🌐 現在のUI言語を表示/設定(TE_LANG)。te start/stats/help の表示言語。
    if [ -n "${2:-}" ]; then
      case "$2" in
        ja|en) printf '%s\n' "$2" > "$CONFIG_DIR/ui-lang" 2>/dev/null || true
               echo "te UI language: $2" ;;
        *) echo "usage: te lang ja|en" >&2; exit 1 ;;
      esac
    else
      echo "te UI language: $(te_ui_lang)"
    fi
    exit 0 ;;
  stats)
    # 📊 コストダッシュボード(2026-09-10 #7学生/#1個人開発者対策): /api/v1/usage を
    # 見やすく表示。今日/30日の消費・残高・モデル別内訳・円換算。--json で素のJSON。
    load_key
    [ -n "$TEAI_API_KEY" ] || { echo "No API key. Run: te register (new account) or te login"; exit 1; }
    STATS_RESP="$(curl -fsSL --max-time 8 -H "Authorization: Bearer $TEAI_API_KEY" "$TEAI_API/api/v1/usage" 2>/dev/null)"
    [ -n "$STATS_RESP" ] || { echo "usageを取得できませんでした。ネットワークを確認してください。" >&2; exit 1; }
    if [ "${2:-}" = "--json" ]; then
      printf '%s' "$STATS_RESP" | python3 -m json.tool 2>/dev/null || printf '%s\n' "$STATS_RESP"
      exit 0
    fi
    # ④ 円換算はプラン別レート(月額→月次クレジット)。従量トップアップは ¥1=6cr。
    TE_STATS_LANG="$(te_ui_lang)" TE_STATS_JSON="$STATS_RESP" python3 - <<'PYSTATS' 2>/dev/null || printf '%s\n' "$STATS_RESP"
import json, os
d = json.loads(os.environ["TE_STATS_JSON"])
u = d.get("usage") or {}
rem = d.get("credits_remaining", 0)
used = d.get("credits_used", 0)
today_cr = u.get("credits_today", 0)
m_cr = u.get("credits_30d", 0)
today_req = u.get("requests_today", 0)
m_req = u.get("requests_30d", 0)
en = os.environ.get("TE_STATS_LANG") == "en"
# プラン別の実効レート(cr/¥)。トップアップは一律 6cr/¥。
PLAN_RATE = {"free": 6.0, "starter": 25000/980, "pro": 30000/4350,
             "business": 100000/14800, "sente_pro": 25000/1480}
plan = (d.get("plan") or "free").lower()
rate = PLAN_RATE.get(plan, 6.0)
yen = lambda c: c / rate
if en:
    print("📊 te stats — cost dashboard")
    print("")
    print(f"  Balance     : {rem:>12,} cr  (~¥{yen(rem):,.0f})")
    print(f"  Total spent : {used:>12,} cr  (~¥{yen(used):,.0f})")
    print("")
    print(f"  Today       : {today_cr:>12,} cr  (~¥{yen(today_cr):,.0f})  /  {today_req:,} req")
    print(f"  Last 30d    : {m_cr:>12,} cr  (~¥{yen(m_cr):,.0f})  /  {m_req:,} req")
else:
    print("📊 te stats — コストダッシュボード")
    print("")
    print(f"  残高        : {rem:>12,} cr  (約¥{yen(rem):,.0f})")
    print(f"  累計消費    : {used:>12,} cr  (約¥{yen(used):,.0f})")
    print("")
    print(f"  今日        : {today_cr:>12,} cr  (約¥{yen(today_cr):,.0f})  /  {today_req:,} req")
    print(f"  直近30日    : {m_cr:>12,} cr  (約¥{yen(m_cr):,.0f})  /  {m_req:,} req")
bm = u.get("by_model_30d") or []
if bm:
    print("")
    print("  By model (30d, top):" if en else "  モデル別(30日・上位):")
    for m in sorted(bm, key=lambda x: -x.get("credits", 0))[:8]:
        print(f"    {m.get('model','?')[:34]:34} {m.get('credits',0):>10,} cr  {m.get('requests',0):>6,} req")
print("")
if en:
    print(f"  Plan: {plan} — ¥ conversion uses your plan rate ({rate:.1f} cr/¥). Top-ups: ¥1=6cr.")
    print("  Raw JSON: te stats --json")
else:
    print(f"  ※ プラン: {plan} — ¥換算はプラン別レート({rate:.1f}cr/¥)。トップアップは ¥1=6cr。詳細JSON: te stats --json")
PYSTATS
    exit 0 ;;
  start)
    # 🌱 非開発者オンボーディング(2026-09-10 #5ライター対策): 用語を避けて「何ができるか」を
    # 対話的に案内。エンジニアでなくても3分で最初の一歩を踏める。--voice で声モード直行。
    # 🌐 表示言語は te_ui_lang(te lang / TE_LANG / LANG)。ja 以外は英語。
    load_key 2>/dev/null || true
    if [ "$(te_ui_lang)" = "en" ]; then
      echo ""
      echo "🌱 Welcome to sente — your first 3 minutes"
      echo ""
      echo "  sente is a companion that helps with your work just by talking to your computer."
      echo "  No tricky commands. Just ask in plain language, or with your voice."
      echo ""
      echo "  Pick one to try:"
      echo ""
      echo "    1) Talk with your voice →  te talk    (say \"check the weather\")"
      echo "    2) Type a request       →  te run \"do X\"  (e.g. te run \"plan my meals\")"
      echo "    3) Chat at your pace    →  te         (interactive, on screen)"
      echo ""
      echo "  Want replies in your own voice:"
      echo "    te voice enroll   (a 15s recording becomes your voice)"
      echo ""
      echo "  You spend credits only as you use it. Current balance:"
      if [ -n "${TEAI_API_KEY:-}" ]; then
        ST_BAL="$(curl -s -m 4 -H "Authorization: Bearer $TEAI_API_KEY" "$TEAI_API/api/v1/auth/me" 2>/dev/null | sed -n 's/.*"credits_remaining":\([0-9.]*\).*/\1/p' | head -1)"
        [ -n "$ST_BAL" ] && echo "    ${ST_BAL} credits left (~¥$(( ${ST_BAL%.*} / 6 )) worth) — details: te stats"
      else
        echo "    (not registered yet → te register for a free account with 100 credits)"
      fi
      echo ""
      echo "  Learn more: te help  /  https://teai.io/docs"
      echo ""
      if [ "${2:-}" = "--voice" ]; then
        echo "  Starting voice mode (te talk)..."
        exec "$0" talk
      fi
      exit 0
    fi
    echo ""
    echo "🌱 ようこそ sente へ — はじめの3分"
    echo ""
    echo "  sente(センテ)は、パソコンに話しかけるだけで作業を手伝ってくれる相棒です。"
    echo "  むずかしい命令はいりません。日本語で、声で、お願いするだけ。"
    echo ""
    echo "  まず試してみましょう。どれか1つ選んでください:"
    echo ""
    echo "    1) 声で話しかける   →  te talk    (マイクに向かって「天気を調べて」など)"
    echo "    2) 文字でお願いする →  te run \"○○して\"  (例: te run \"献立を考えて\")"
    echo "    3) じっくり相談する →  te         (画面を見ながら対話)"
    echo ""
    echo "  あなたの声で返事をしてほしいとき:"
    echo "    te voice enroll   (15秒の録音で、あなたの声になります)"
    echo ""
    echo "  使った分だけクレジットが減ります。今の残高:"
    if [ -n "${TEAI_API_KEY:-}" ]; then
      ST_BAL="$(curl -s -m 4 -H "Authorization: Bearer $TEAI_API_KEY" "$TEAI_API/api/v1/auth/me" 2>/dev/null | sed -n 's/.*"credits_remaining":\([0-9.]*\).*/\1/p' | head -1)"
      [ -n "$ST_BAL" ] && echo "    残り ${ST_BAL} クレジット(約¥$(( ${ST_BAL%.*} / 6 )) 分) — 詳しくは te stats"
    else
      echo "    (まだ登録前です → te register で無料登録・100クレジットつき)"
    fi
    echo ""
    echo "  くわしくは: te help  /  https://teai.io/docs"
    echo ""
    if [ "${2:-}" = "--voice" ]; then
      echo "  声モードを起動します(te talk)..."
      exec "$0" talk
    fi
    exit 0 ;;
  tune)
    sente_autotune
    sente_autotune_model
    if [ -f "$SENTE_TUNE" ] && command -v python3 >/dev/null 2>&1; then
      python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("いまの設定: 話し終わりの待ち %ss (%s / %s件から)" % (d.get("talk_silence"), d.get("why") or "既定", d.get("samples")))
m=d.get("metrics") or {}
if m: print("核の指標(直近%s件): こだま %.0f%% / 雑音 %.0f%% / ちゃんと聞けた %.0f%% / 割り込み %s回" % (m.get("window"), 100*m.get("echo_rate",0), 100*m.get("noise_rate",0), 100*m.get("ok_rate",0), m.get("barge_n",0)))' "$SENTE_TUNE"
    else
      echo "まだ調整できるだけの記録がありません(12回ぶんたまると動きます)"
    fi
    [ -f "$SENTE_TURNS" ] && echo "記録: $(wc -l < "$SENTE_TURNS" | tr -d ' ')ターン / 録音: $(ls "$SENTE_REC_DIR" 2>/dev/null | wc -l | tr -d ' ')本"
    if [ -f "$SENTE_QUALITY" ] && command -v python3 >/dev/null 2>&1; then
      python3 -c '
import json, sys
qs = []
for line in open(sys.argv[1]):
    try:
        v = json.loads(line).get("q")
        if isinstance(v, (int, float)): qs.append(float(v))
    except Exception: pass
if qs:
    r = qs[-12:]
    print("賢さの採点(直近%s件): 平均 %.1f / 5" % (len(r), sum(r)/len(r)))' "$SENTE_QUALITY" 2>/dev/null || true
    fi
    exit 0 ;;
  pro)
    # 💳 Sente Pro(声モード無制限・自動エージェント無制限・自分の声・25,000cr/月)の案内ページを開く
    URLP="$TEAI_SITE/pricing?plan=sente_pro"
    echo "Sente Pro: $URLP"
    if command -v open >/dev/null 2>&1; then open "$URLP"; elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$URLP"; fi
    exit 0 ;;
  goal)
    # 🎯 te loop が向かって進む「目標」を1つだけ持たせる(2026-08-24本人指示「senteにgoalとloopを入れて」)。
    # 複数持たせると手元で追えなくなるので常に1つ・上書きのみ。goal自体は何も実行しない(te loopが読むだけ)。
    shift || true
    mkdir -p "$CONFIG_DIR"
    GOAL_FILE="$CONFIG_DIR/goal"
    if [ $# -eq 0 ]; then
      if [ -f "$GOAL_FILE" ]; then
        echo "🎯 いまのgoal: $(cat "$GOAL_FILE")"
        [ -f "$CONFIG_DIR/loop.log" ] && echo "   直近のloop実行: $(tail -1 "$CONFIG_DIR/loop.log")"
        echo "   実行: te loop / 消す: te goal clear"
      else
        echo "goal未設定。te goal \"やりたいこと\" で設定してください"
        echo "  例: te goal \"CIにstartup smoke testを追加してデプロイ失敗時に自動revertする\""
      fi
    elif [ $# -eq 1 ] && [ "$1" = "clear" ]; then
      rm -f "$GOAL_FILE"
      echo "✅ goalを消しました(実行中のte loopは別端末で te stop してください)"
    else
      printf '%s\n' "$*" > "$GOAL_FILE"
      rm -f "$CONFIG_DIR/loop.log"
      echo "🎯 goalを設定しました: $*"
      echo "   実行: te loop / 確認: te goal / 消す: te goal clear / 止める: te stop"
    fi
    exit 0 ;;
  ima|next)
    # 📍 te ima: いまの状況(3行程度)+推薦の一手をまとめて提案。te next はこのエイリアス
    # (2026-08-27本人指示「koeからclaude code/senteを呼んで状況まとめて次の一手を勧めたい」
    # →Fable(claude-fable-5)と壁打ちして確定した設計: 分散していた入口を1つに統合)
    sente_opening cli "" full
    if [ -s "$CONFIG_DIR/opening-summary" ]; then
      echo "📍 状況"
      sed 's/^/  /' "$CONFIG_DIR/opening-summary"
    fi
    if [ -s "$CONFIG_DIR/opening-alert" ]; then
      echo "⚠ $(cat "$CONFIG_DIR/opening-alert")"
    fi
    if [ -f "$CONFIG_DIR/opening-task" ]; then
      [ "$(cat "$CONFIG_DIR/opening-risk" 2>/dev/null || echo safe)" = "confirm" ] && \
        echo "⚠ お金/対外送信/削除など実際に影響のある操作です — 内容をよく確認してから実行してください"
      echo "→ そのまま打つなら: te run \"$(cat "$CONFIG_DIR/opening-task")\""
    else
      echo "(提案を作れませんでした — TEAI_API_KEY/ネットワークを確認してください)"
    fi
    exit 0 ;;
  watch)
    # 🪨 fuseki(布石・Alpha 2026-08): 呼ばれなくても盤面(human-gates・最近のリポジトリ・裏作業)を
    # 見続け、状況が変わった時だけ「先手の一手」エンジン(sente_opening)へ渡して提案を更新する。
    # 何も実行しない・提案のみ(ログ+声のみ)。既定15分間隔=TE_FUSEKI_INTERVALで変更可。
    # 止める= Ctrl-C (フォアグラウンド) か 別端末/裏実行から `te stop`。
    FW_INTERVAL="${TE_FUSEKI_INTERVAL:-900}"
    FW_LOG="$CONFIG_DIR/fuseki.log"
    FW_STOP="$CONFIG_DIR/fuseki-STOP"
    FW_HASHFILE="$CONFIG_DIR/fuseki-ctxhash"
    # 💰 コスト保険(2026-08-13本人指示「コストも考えつつデーモンにして」・24時間常駐を見越して追加):
    # cksumゲーティングは「状態が変わった時だけ呼ぶ」レベルの節約はできるが、git statusのちらつき等で
    # 短時間に何度も変化判定される最悪ケースへの保険がなかった → 最短間隔+1日の呼び出し上限を追加
    FW_MINGAP="${TE_FUSEKI_MINGAP:-300}"       # 変化があってもこれより短い間隔ではLLMを呼び直さない(秒・既定5分)
    FW_DAILYCAP="${TE_FUSEKI_DAILY_CAP:-50}"   # 1日の呼び出し上限(暴走・flapping対策)
    FW_LASTCALL=0
    rm -f "$FW_STOP" 2>/dev/null || true
    sente_first_run_intro fuseki
    echo "🪨 fuseki watch(Alpha): ${FW_INTERVAL}秒ごとに盤面を見ます。状況が変わった時だけ考えて ${FW_LOG} に記録+声で知らせます(最短${FW_MINGAP}秒間隔・1日${FW_DAILYCAP}回まで)。何も実行はしません。止める= Ctrl-C か別端末で \`te stop\`。"
    FW_LAST=""
    [ -f "$FW_LOG" ] && FW_LAST="$(tail -1 "$FW_LOG" 2>/dev/null | sed 's/^\[[^]]*\] //' || true)"
    trap 'echo; echo "fuseki watch を止めました。"; exit 0' INT TERM
    while :; do
      if [ -f "$FW_STOP" ]; then rm -f "$FW_STOP"; echo "🛑 停止指示を検知しました。"; break; fi
      # 🪤 sente_opening_scan の1行目は分単位で変わる時刻表示なので、そのままハッシュ化すると
      # 毎回「変化あり」判定になり無駄にLLMを呼び続ける → 1行目を除いてハッシュ化する
      FW_HASH="$(sente_opening_scan 2>/dev/null | tail -n +2 | cksum)"
      FW_PREVHASH="$(cat "$FW_HASHFILE" 2>/dev/null || true)"
      if [ "$FW_HASH" != "$FW_PREVHASH" ]; then
        FW_NOW="$(date +%s)"
        FW_CAPFILE="$CONFIG_DIR/fuseki-callcount-$(date +%Y%m%d)"
        FW_CALLS="$(cat "$FW_CAPFILE" 2>/dev/null || true)"
        # 🪤 「変化はしたが、まだ呼ばない」時は FW_HASHFILE を更新しない
        # (次回巡回で条件が満たされたら同じ変化として再判定できるようにするため)
        if [ $(( FW_NOW - FW_LASTCALL )) -lt "$FW_MINGAP" ]; then
          :
        elif [ "${FW_CALLS:-0}" -ge "$FW_DAILYCAP" ]; then
          :
        else
          printf '%s' "$FW_HASH" > "$FW_HASHFILE" 2>/dev/null || true
          FW_LASTCALL="$FW_NOW"
          echo $(( ${FW_CALLS:-0} + 1 )) > "$FW_CAPFILE" 2>/dev/null || true
          sente_opening cli >/dev/null 2>&1 || true
          # 🪤 set -eu 下で opening-last/opening-task が(LLM呼び出し失敗などで)まだ無い時、
          # head の非0終了がそのままループごと落とす実障害を実機で確認 → || true で必ず0を返す
          FW_SAY="$(head -1 "$CONFIG_DIR/opening-last" 2>/dev/null || true)"
          FW_TASK="$(head -1 "$CONFIG_DIR/opening-task" 2>/dev/null || true)"
          if [ -n "$FW_SAY" ] && [ "$FW_SAY" != "$FW_LAST" ]; then
            { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M')" "$FW_SAY"; [ -n "$FW_TASK" ] && printf '      -> %s\n' "$FW_TASK"; } >> "$FW_LOG"
            FW_LAST="$FW_SAY"
          fi
        fi
      fi
      sleep "$FW_INTERVAL" &
      wait $! 2>/dev/null
    done
    exit 0 ;;
  stop)
    # `te watch`/`fuseki watch`/`te loop` を(別端末・裏実行からでも)止める合図を残す。次の巡回で検知して終了する
    mkdir -p "$CONFIG_DIR" 2>/dev/null || true
    touch "$CONFIG_DIR/fuseki-STOP" "$CONFIG_DIR/loop-STOP" 2>/dev/null || true
    echo "🛑 fuseki watch / te loop に停止指示を残しました(次の巡回で終了します)。"
    exit 0 ;;
  clean)
    # 固まった/残った opencode プロセスと読み上げlockを片付ける。
    # 実行中の作業まで止めるので、必ず本数を見せてから消す。
    N="$(pgrep -x sente 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${N:-0}" = 0 ]; then
      echo "残っている sente はありません。"
    else
      echo "残っている sente: ${N}本"
      ps -o pid,etime,command -p "$(pgrep -x sente | tr '\n' ',' | sed 's/,$//')" 2>/dev/null | head -10
      pgrep -x sente 2>/dev/null | while read -r Z; do kill -TERM "$Z" 2>/dev/null; done
      sleep 2
      pgrep -x sente 2>/dev/null | while read -r Z; do kill -KILL "$Z" 2>/dev/null; done
      echo "停止しました。"
    fi
    R="$(pgrep -x rec 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${R:-0}" != 0 ]; then
      echo "残っている録音プロセス(rec): ${R}本 → 停止します"
      # 🪤 rec(sox)はTERMを無視するので最初から-9
      pgrep -x rec 2>/dev/null | while read -r Z; do kill -KILL "$Z" 2>/dev/null; done
      pgrep -x senterec 2>/dev/null | while read -r Z; do kill -KILL "$Z" 2>/dev/null; done
    fi
    rm -f /tmp/sente_speaking.lock /tmp/sente_turn_open /tmp/sente_ctx_playing /tmp/sente_talk.pid /tmp/sente_say_streamed /tmp/sente_say_full_won
    # 🖥 Playwright MCP 常駐サーバーも停止(必要な時は次回起動で自動再起動)
    PW_PORT="${PLAYWRIGHT_MCP_PORT:-8932}"
    PW_PIDS="$(lsof -ti tcp:$PW_PORT 2>/dev/null || true)"
    if [ -n "$PW_PIDS" ]; then
      for PW_PID in $PW_PIDS; do kill -TERM "$PW_PID" 2>/dev/null || true; done
      sleep 1
      for PW_PID in $PW_PIDS; do kill -KILL "$PW_PID" 2>/dev/null || true; done
      rm -f /tmp/playwright-mcp-server.pid
      echo "Playwright MCP サーバーを停止しました。(次回 sente 起動時に自動再起動)"
    fi
    exit 0 ;;
  doctor)
    load_key
    OC="$(find_opencode || true)"
    [ -n "$OC" ] && echo "ok    opencode: $OC ($("$OC" --version 2>/dev/null || echo '?'))" || echo "FAIL  opencode not found — run: te update"
    [ -f "$CONFIG_DIR/opencode.json" ] && echo "ok    config:   $CONFIG_DIR/opencode.json" || echo "FAIL  config missing — run: te update"
    if [ -n "$TEAI_API_KEY" ]; then
      DR_ME_BODY="$(mktemp "${TMPDIR:-/tmp}/te_me_XXXXXX")"
      CODE="$(curl -s -o "$DR_ME_BODY" -w '%{http_code}' --max-time 5 -H "Authorization: Bearer $TEAI_API_KEY" "$TEAI_API/api/v1/auth/me" || echo 000)"
      if [ "$CODE" = "200" ]; then
        DR_EMAIL="$(sed -n 's/.*"email":"\([^"]*\)".*/\1/p' "$DR_ME_BODY" | head -1)"
        DR_PLAN="$(sed -n 's/.*"plan":"\([a-z_]*\)".*/\1/p' "$DR_ME_BODY" | head -1)"
        echo "ok    api key:  valid${DR_EMAIL:+ ($DR_EMAIL${DR_PLAN:+ / $DR_PLAN})}"
        # 💳 残高(2026-09-10: 残高0だとチャットは通るのに MCP(画像/声)だけ Insufficient credits になる。
        #    その非対称が分かりにくいので doctor で残高を必ず出す)
        DR_BAL="$(sed -n 's/.*"credits_remaining":\(-\{0,1\}[0-9]*\).*/\1/p' "$DR_ME_BODY" | head -1)"
        if [ -n "$DR_BAL" ]; then
          if [ "$DR_BAL" -le 0 ] 2>/dev/null; then
            echo "FAIL  credits:  0 — 画像生成・声(MCP)が止まります。チャージ: https://teai.io/pricing"
          elif [ "$DR_BAL" -lt "${TE_ADVICE_LOW_CREDITS:-10000}" ] 2>/dev/null; then
            echo "warn  credits:  ${DR_BAL}cr(約¥$((DR_BAL / 6))分) — 少なめ。0 になると画像生成・声(MCP)が止まります: https://teai.io/pricing"
          else
            echo "ok    credits:  ${DR_BAL}cr(約¥$((DR_BAL / 6))分) — 詳しくは te stats"
          fi
        else
          echo "warn  credits:  残高を読めませんでした(/auth/me に credits_remaining 無し)"
        fi
      else
        echo "warn  api key:  check failed (HTTP $CODE)"
      fi
      rm -f "$DR_ME_BODY"
    else
      echo "FAIL  api key:  missing — run: te register (new account) or te login"
    fi
    N="$(pgrep -x sente 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${N:-0}" = 0 ]; then
      echo "ok    processes: 残留 sente なし"
    else
      # 「N本稼働中=作業中とみなす」だけでは、8/31・9/1起動の放置TUI(各1GB超・CPU累計250h)が
      # 10日間見過ごされた(2026-09-09実測)。1本ずつ 起動からの日数・RSS・端末 を出し、
      # TE_DOCTOR_STALE_DAYS(既定1)日以上のものは warn にして te clean を促す。殺すのはしない。
      DR_STALE=0; DR_RSS=0; DR_LINES=""
      for DR_PID in $(pgrep -x sente 2>/dev/null); do
        DR_INFO="$(ps -o etime=,rss=,tty=,ppid= -p "$DR_PID" 2>/dev/null | awk 'NF')"
        [ -n "$DR_INFO" ] || continue
        DR_ET="$(echo "$DR_INFO" | awk '{print $1}')"
        DR_RS="$(echo "$DR_INFO" | awk '{print $2}')"
        DR_TTY="$(echo "$DR_INFO" | awk '{print $3}')"
        DR_PP="$(echo "$DR_INFO" | awk '{print $4}')"
        DR_RSS=$((DR_RSS + ${DR_RS:-0}))
        case "$DR_ET" in *-*) DR_DAYS="${DR_ET%%-*}" ;; *) DR_DAYS=0 ;; esac
        DR_MARK="  "
        if [ "${DR_DAYS:-0}" -ge "${TE_DOCTOR_STALE_DAYS:-1}" ] 2>/dev/null; then DR_MARK="⚠ "; DR_STALE=$((DR_STALE+1)); fi
        [ "$DR_PP" = "1" ] && DR_MARK="✗ "   # 親なし=孤児(次回起動のGCで消える)
        DR_LINES="$DR_LINES
      ${DR_MARK}pid ${DR_PID}  起動 ${DR_ET}  ${DR_RS:-0}KB  tty ${DR_TTY}"
      done
      if [ "$DR_STALE" -gt 0 ]; then
        echo "warn  processes: sente ${N}本(合計 $((DR_RSS/1024))MB)。${DR_STALE}本が${TE_DOCTOR_STALE_DAYS:-1}日以上前の起動 → 使っていなければ端末で Ctrl-C か te clean"
      else
        echo "ok    processes: sente ${N}本(合計 $((DR_RSS/1024))MB・自動GC対象外=親シェルあり)"
      fi
      printf '%s\n' "$DR_LINES" | sed '/^$/d'
    fi
    # 🔁 launchd KeepAlive × te run のループ検知(2026-09-10: wanpo ジョブが完了後3日間・12,912回
    #    再起動し続けた。プロセス一覧では毎回「起動直後の新しい sente」に見えて素通りだった)。
    #    ~/Library/LaunchAgents の plist で KeepAlive が立っていて、実行スクリプトが te/sente を呼ぶものを
    #    列挙し、直近1時間の launchd 起動回数(ログの行数増ではなく launchctl の LastExitStatus/PID を
    #    取れないので、スクリプトの出力ログ mtime と .sente-done の有無で判定)を出す。
    if [ "$(uname)" = "Darwin" ] && [ -d "$HOME/Library/LaunchAgents" ]; then
      for LA in "$HOME"/Library/LaunchAgents/*.plist; do
        [ -f "$LA" ] || continue
        LA_KA="$(plutil -extract KeepAlive raw -o - "$LA" 2>/dev/null || true)"
        [ "$LA_KA" = "true" ] || [ "$LA_KA" = "1" ] || continue
        LA_PROG="$(plutil -extract ProgramArguments json -o - "$LA" 2>/dev/null | tr -d '[]"\\' | tr ',' ' ')"
        LA_SCRIPT=""
        for LA_A in $LA_PROG; do
          case "$LA_A" in *.sh|*/te|*/sente) LA_SCRIPT="$LA_A" ;; esac
        done
        [ -n "$LA_SCRIPT" ] || continue
        # スクリプト本文が te/sente run を呼ぶか(直接 te を指す plist はそれ自体が対象)
        case "$LA_SCRIPT" in
          */te|*/sente) ;;
          *) [ -f "$LA_SCRIPT" ] && grep -Eq '(^|[ /"])(te|sente)([ ]+(max|fast|lux|auto|k3))?[ ]+run([ ]|$)' "$LA_SCRIPT" || continue ;;
        esac
        LA_LABEL="$(plutil -extract Label raw -o - "$LA" 2>/dev/null || basename "$LA" .plist)"
        LA_DIR="$(dirname "$LA_SCRIPT")"
        LA_LOADED="$(launchctl list 2>/dev/null | grep -c "[[:space:]]$LA_LABEL\$" || true)"   # grep -c は0件で exit 1 → set -e で死ぬ
        if [ -f "$LA_DIR/.sente-done" ]; then
          echo "ok    launchd: $LA_LABEL — KeepAlive の te run。完了マーカー .sente-done あり(空回りしない)"
        elif [ "$LA_LOADED" -gt 0 ]; then
          echo "warn  launchd: $LA_LABEL — KeepAlive で te run を呼ぶが $LA_DIR/.sente-done が無い。"
          echo "      タスクが終わっても無限に再起動する構造。タスク文に「完了したら SENTE_DONE と出力」を足すか、"
          echo "      終わっているなら: touch $LA_DIR/.sente-done  /  止めるなら: launchctl bootout gui/\$(id -u)/$LA_LABEL"
        else
          echo "ok    launchd: $LA_LABEL — KeepAlive の te run(現在は未ロード)"
        fi
      done
    fi
    # 📌 起動時に流れた忠告の見返し(2026-08-17「メッセージが一瞬でしか見えない」対策)
    if [ -s "$CONFIG_DIR/.last-boot-notes" ]; then
      echo ""
      echo "前回起動時の忠告(一瞬で流れた分の見返し):"
      sed 's/^/  /' "$CONFIG_DIR/.last-boot-notes"
    fi
    # 🩺 ヘルスチェック(耳・口・脳・Playwright MCP)
    SENTE_REC_DIR="$SENTE_DATA_DIR/rec"
    SENTE_TUNE="$HOME/.config/teai/sente-tuning.json"
    SENTE_LAT="$SENTE_LOG_DIR/latency.jsonl"
    SENTE_QUALITY="$SENTE_LOG_DIR/quality.jsonl"
    SENTE_DEAD_AIR_FILE="/tmp/sente_dead_air_count"
    SENTE_AEC_BIN="$CONFIG_DIR/bin/senterec"
    sente_health_check
    exit 0 ;;
  optimize)
    # 🔧 環境を自動で最適に整える(2026-08-17本人指示「環境は自動的に最適にしてほしい確認付きで」)。
    # 診断→提案を列挙→各項目 y/n 確認→実行。--yes/-y で全自動承認。
    # 変更は ~/.config/teai 配下と自前プロセスの掃除に限定(破壊的操作は入れない)。
    shift || true
    OPT_YES=0
    case "${1:-}" in --yes|-y) OPT_YES=1 ;; esac
    echo "🔧 te optimize — 環境の診断と最適化(確認付き)"
    OPT_N=0
    _opt_ask() {  # $1=説明。yなら0を返す
      OPT_N=$((OPT_N+1))
      if [ "$OPT_YES" = "1" ]; then echo "  [$OPT_N] $1 → 実行します(--yes)"; return 0; fi
      printf "  [%d] %s — 実行しますか? [y/N] " "$OPT_N" "$1"
      read -r ANS </dev/tty 2>/dev/null || ANS=""
      case "$ANS" in y|Y|yes) return 0 ;; *) echo "      スキップしました"; return 1 ;; esac
    }
    # 1) 残留 sente/opencode プロセスの掃除(作業中でないもの)
    ZOMBIE="$(pgrep -x sente 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${ZOMBIE:-0}" -gt 0 ] 2>/dev/null; then
      if _opt_ask "残留 sente プロセスが ${ZOMBIE}本あります(te clean で停止)"; then
        "$0" clean
      fi
    fi
    # 2) opencode.db の肥大化(50MB超で VACUUM を提案)
    OCDB="$HOME/.local/share/opencode/opencode.db"
    if [ -f "$OCDB" ] && command -v sqlite3 >/dev/null 2>&1; then
      DB_MB="$(du -m "$OCDB" 2>/dev/null | awk '{print $1}')"
      if [ -n "$DB_MB" ] && [ "$DB_MB" -gt 50 ] 2>/dev/null; then
        if _opt_ask "opencode.db が ${DB_MB}MB に肥大化しています(古い event を削除+VACUUM)"; then
          sqlite3 "$OCDB" "DELETE FROM event WHERE aggregate_id IN (SELECT id FROM session WHERE time_updated < strftime('%s','now','-${TE_DB_EVENT_KEEP_DAYS:-7} days')*1000);" 2>/dev/null || true
          sqlite3 "$OCDB" "PRAGMA wal_checkpoint(TRUNCATE);" 2>/dev/null || true
          sqlite3 "$OCDB" "VACUUM;" 2>/dev/null || true
          echo "      → $(du -m "$OCDB" 2>/dev/null | awk '{print $1}')MB になりました"
        fi
      fi
    fi
    # 3) 裏タスク残骸・古い録音の掃除
    OLD_WAV="$(find /tmp -maxdepth 1 -name 'sente_*.wav' -mtime +1 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${OLD_WAV:-0}" -gt 0 ] 2>/dev/null; then
      if _opt_ask "1日以上前の一時録音が ${OLD_WAV}個残っています(削除)"; then
        find /tmp -maxdepth 1 -name 'sente_*.wav' -mtime +1 -delete 2>/dev/null || true
        echo "      削除しました"
      fi
    fi
    # 4) メモリ不足時: 一番重いプロセスを提示(閉じるのは本人がやるので提案のみ)
    FREE_MB="$(_sente_free_mb 2>/dev/null || true)"
    if [ -n "$FREE_MB" ] && [ "$FREE_MB" -lt "${TE_ADVICE_LOW_MEM_MB:-1536}" ] 2>/dev/null; then
      TOPMEM="$(ps -eo rss,comm -m 2>/dev/null | awk 'NR==2{printf "%s(%dMB)", $2, $1/1024}')"
      echo "  💡 空きメモリが ${FREE_MB}MB しかありません。一番重いのは ${TOPMEM:-不明} — 手動で閉じてください(自動で他アプリは殺しません)"
    fi
    # 5) ディスク空き不足時: 掃除スクリプトの実行を提案
    DISK_VOL="/System/Volumes/Data"; [ -d "$DISK_VOL" ] || DISK_VOL="/"
    DISK_AVAIL_GB="$(df -k "$DISK_VOL" 2>/dev/null | tail -1 | awk '{printf "%d", $4/1048576}')"
    if [ -n "$DISK_AVAIL_GB" ] && [ "$DISK_AVAIL_GB" -lt "${TE_ADVICE_LOW_DISK_GB:-15}" ] 2>/dev/null; then
      if [ -x "$HOME/.claude/daily/disk-check.sh" ]; then
        if _opt_ask "ディスク空きが ${DISK_AVAIL_GB}GB しかありません(disk-check.sh --clean を実行)"; then
          "$HOME/.claude/daily/disk-check.sh" --clean || true
        fi
      else
        echo "  💡 ディスク空きが ${DISK_AVAIL_GB}GB しかありません(掃除スクリプト無し・手動で空けてください)"
      fi
    fi
    [ "$OPT_N" = "0" ] && echo "✅ 最適化の提案はありません(環境は良好です)"
    exit 0 ;;
  greeting)
    # 💬 起動あいさつの管理。既定=状況からの気づき一言(裏で先読み生成)・固定文・オフを切替
    shift
    case "${1:-}" in
      off)
        mkdir -p "$CONFIG_DIR" 2>/dev/null; touch "$CONFIG_DIR/greeting-off" 2>/dev/null || true
        rm -f "$CONFIG_DIR/greeting" 2>/dev/null
        echo "挨拶をオフにしました(戻す: te greeting reset)" ;;
      reset)
        rm -f "$CONFIG_DIR/greeting" "$CONFIG_DIR/greeting-off" "$CONFIG_DIR/greet-next.txt" "$CONFIG_DIR"/greet-next.*.mp3 2>/dev/null
        echo "既定に戻しました(状況からの気づき一言・初回や生成失敗時は時間帯あいさつ)" ;;
      "")
        if [ -f "$CONFIG_DIR/greeting-off" ]; then
          echo "挨拶: オフ(te greeting reset で戻せます)"
        elif [ -s "$CONFIG_DIR/greeting" ]; then
          echo "挨拶(固定文): $(head -1 "$CONFIG_DIR/greeting")"
        else
          echo "挨拶: 既定(状況からの気づき一言・声は te voice で変更可)"
          [ -s "$CONFIG_DIR/greet-next.txt" ] && echo "次回の一言(用意済み): $(head -1 "$CONFIG_DIR/greet-next.txt")"
        fi
        echo "使い方: te greeting \"好きな文言\" / te greeting off / te greeting reset" ;;
      *)
        mkdir -p "$CONFIG_DIR" 2>/dev/null
        printf '%s\n' "$*" > "$CONFIG_DIR/greeting" 2>/dev/null || true
        rm -f "$CONFIG_DIR/greeting-off" 2>/dev/null
        echo "挨拶を固定文にしました: $*" ;;
    esac
    exit 0 ;;
  privacy)
    # 🔒 データの扱いを実装どおりに説明する(不安の芽=「声とコードがどこへ行くか分からない」を潰す)。
    # ここに書くことは必ずコードで裏が取れる内容だけにする(盛らない・未実装の約束をしない)
    shift
    case "${1:-}" in
      stt-log)
        case "${2:-}" in
          on)  mkdir -p "$CONFIG_DIR" 2>/dev/null; touch "$CONFIG_DIR/stt-log-optin" 2>/dev/null || true
               echo "✅ 聞き取り改善への音声提供: ON(koe.liveに30日保存→自動削除。te privacy stt-log off でいつでも停止)" ;;
          off) rm -f "$CONFIG_DIR/stt-log-optin" 2>/dev/null || true
               echo "✅ 聞き取り改善への音声提供: OFF(音声は文字起こしに使われるだけで保存されません)" ;;
          *)   echo "usage: te privacy stt-log on|off"; exit 1 ;;
        esac
        exit 0 ;;
      scrub)
        case "${2:-}" in
          on)  mkdir -p "$CONFIG_DIR" 2>/dev/null
               touch "$CONFIG_DIR/pii-scrub-optin" 2>/dev/null && chmod 600 "$CONFIG_DIR/pii-scrub-optin" 2>/dev/null
               echo "✅ PIIスクラビング: ON(次回起動から・ollama+qwen3.5:4bが必要。te privacy scrub off でいつでも停止)" ;;
          off) rm -f "$CONFIG_DIR/pii-scrub-optin" 2>/dev/null || true
               echo "✅ PIIスクラビング: OFF" ;;
          "")  if [ -f "$CONFIG_DIR/pii-scrub-optin" ]; then echo "PIIスクラビング: ON"; else echo "PIIスクラビング: OFF"; fi ;;
          *)   echo "usage: te privacy scrub on|off"; exit 1 ;;
        esac
        exit 0 ;;
    esac
    if [ "${TE_STT_LOG:-}" = "1" ] || { [ "${TE_STT_LOG:-}" != "0" ] && [ -f "$CONFIG_DIR/stt-log-optin" ]; }; then
      PRV_STT="ON(音声+結果をkoe.liveに30日保存→自動削除・off= te privacy stt-log off)"
    else
      PRV_STT="OFF(既定。音声は文字起こしに使われるだけで保存されません)"
    fi
    if [ -f "$CONFIG_DIR/pii-scrub-optin" ]; then
      PRV_SCRUB="ON(送信前にローカルLLM+正規表現で氏名/住所/電話/APIキー等を検出しプレースホルダ化・off= te privacy scrub off)"
    else
      PRV_SCRUB="OFF(既定。te privacy scrub on で有効化)"
    fi
    cat <<PRIVACY
🔒 Sente/te のデータの扱い(このバージョンの実装そのまま)

外に出るもの(すべてHTTPS):
  ・プロンプト/コード文脈 → teai.io(応答生成と課金計算のため。ポリシー: https://teai.io/privacy)
  ・声(te v / te talk / sente) → koe.live /api/stt(文字起こしのため)
      聞き取り改善への音声提供: $PRV_STT
  ・読み上げテキスト → koe.live /api/speak(音声合成のため)
  ・話者確認(任意・既定off): speaker-optinファイルがある時だけ、声をkoe.liveの声紋照合へ送る

PIIスクラビング(任意・既定off): $PRV_SCRUB
  ・te/te run/te v/te talk/te serve のどれでも、送信直前にこのMac上のOllama(qwen3.5:4b)+
    正規表現でメール/電話/住所/APIキー/人名などを検出しプレースホルダに置き換えてから送信し、
    応答は復元してから表示します。Ollamaが起動していない/モデル未取得の場合は
    平文のまま送らずエラーで止まります(フェイルクローズ)。
  ・完全な検出を保証するものではありません(ローカルLLMの検出力に依存)。
  ・ストリーミング表示は失われます(応答は一括表示になります)。

Mac内で完結するもの:
  ・🍎 Appleオンデバイス音声認識(リアルタイム途中表示・サーバ空振り時の補完)は
    macOSの中だけで動き、音声は外部に送られません(TE_APPLE_STT=0で無効)

この端末の中だけに残るもの(外部送信なし):
  ・録音コピー: $SENTE_DATA_DIR/rec(${TE_REC_KEEP_DAYS:-7}日で自動削除)
  ・聞き取りログ: $SENTE_LOG_DIR/(話し終わり待ち時間などの自動調整用)
  ・APIキー: $CONFIG_DIR/credentials(権限600=あなた以外読めません)

オフスイッチ:
  TE_NO_RECORD=1            録音コピー・聞き取りログを一切残さない
  TE_REC_KEEP_DAYS=<日数>    録音コピーの保存日数を変える
  te privacy stt-log off    サーバへの音声提供を止める(既定でoff)
  te privacy scrub off      PIIスクラビングを止める(既定でoff)
  te voice off              読み上げなし(保存・戻す=te voice on)
  AGENT_KOE=0               読み上げなし(この実行だけ・声を送らない・受けない)

全部やめる: te uninstall(本体・設定・APIキー・録音・ログを削除)
PRIVACY
    exit 0 ;;
  app)
    # te app [install [sente|koe]|status] — GUIアプリ(メニューバー常駐のSente.app・
    # 常駐録音/読み上げのKoe.app)を任意で入れる。既定のcurl|sh本体では入れない
    # (透明性優先=このコマンドを打った時だけ/Applicationsに触る)。
    # 両方ともDeveloper ID署名+Apple公証済み(2026-08-31時点)。
    shift
    APP_SUB="${1:-status}"; [ $# -gt 0 ] && shift
    if [ "$(uname -s)" != "Darwin" ]; then
      echo "GUIアプリはmacOS専用です(CLIはこのまま使えます)"
      exit 1
    fi
    SENTE_APP_URL="https://github.com/yukihamada/opencode/releases/download/sente-app-v1.9.1/Sente-1.9.1.zip"
    KOE_APP_DMG_URL="https://github.com/yukihamada/Koe-swift/releases/download/v2.11.0/Koe-Installer.dmg"
    # info/ok/warn はインストーラー側だけの定義でランタイム($BIN_DIR/te)側には無いため自前定義
    info() { printf '  → %s\n' "$1"; }
    ok()   { printf '  ✓ %s\n' "$1"; }
    warn() { printf '  ! %s\n' "$1" >&2; }

    # ダウンロードしたファイルにquarantine属性を付けてからspctlで判定する。
    # curl単体はLaunchServices経由でないためquarantineが付かず、そのままだと
    # Gatekeeperの実判定(ブラウザDL相当)をすり抜けて見えてしまう(偽陽性防止)。
    app_gatekeeper_ok() {  # $1=path → 0:accepted
      /usr/bin/xattr -w com.apple.quarantine "0081;$(printf '%08x' "$(date +%s)");curl;" "$1" 2>/dev/null || true
      spctl -a -vv "$1" >/dev/null 2>&1
    }

    install_sente_app() {
      if [ -d /Applications/Sente.app ]; then ok "Sente.app は既にあります(/Applications/Sente.app)"; return 0; fi
      info "Sente.app をダウンロード中..."
      AI_TMP="$(mktemp -d "${TMPDIR:-/tmp}/sente_app_XXXXXX")" || return 1
      curl -fsSL --retry 2 -m 60 "$SENTE_APP_URL" -o "$AI_TMP/Sente.zip" 2>/dev/null || { warn "Sente.appのダウンロードに失敗"; rm -rf "$AI_TMP"; return 1; }
      ditto -x -k "$AI_TMP/Sente.zip" "$AI_TMP" 2>/dev/null
      if [ ! -d "$AI_TMP/Sente.app" ] || ! app_gatekeeper_ok "$AI_TMP/Sente.app"; then
        warn "Sente.appの検証に失敗(署名/公証を確認できませんでした)"; rm -rf "$AI_TMP"; return 1
      fi
      rm -rf /Applications/Sente.app
      cp -R "$AI_TMP/Sente.app" /Applications/Sente.app
      rm -rf "$AI_TMP"
      # app_gatekeeper_ok が検証用に付けたquarantineがそのまま残ると、次回起動時に
      # macOSのApp Translocation(隔離済みのまま/Applications外の一時パスで実行される)を
      # 誘発する実障害を実機で確認した。Koe.pkgのpostinstallと同じくインストール確定後は外す。
      /usr/bin/xattr -rd com.apple.quarantine /Applications/Sente.app 2>/dev/null || true
      ok "Sente.app を /Applications に配置しました(初回起動でマイク許可のダイアログが出ます)"
    }

    install_koe_app() {
      if [ -d /Applications/Koe.app ]; then ok "Koe.app は既にあります(/Applications/Koe.app)"; return 0; fi
      info "Koe.app をダウンロード中..."
      AI_TMP="$(mktemp -d "${TMPDIR:-/tmp}/koe_app_XXXXXX")" || return 1
      curl -fsSL --retry 2 -m 120 "$KOE_APP_DMG_URL" -o "$AI_TMP/Koe.dmg" 2>/dev/null || { warn "Koe.appのダウンロードに失敗"; rm -rf "$AI_TMP"; return 1; }
      AI_MNT="$AI_TMP/mnt"
      if ! hdiutil attach "$AI_TMP/Koe.dmg" -nobrowse -mountpoint "$AI_MNT" >/dev/null 2>&1; then
        warn "Koe-Installer.dmgのマウントに失敗"; rm -rf "$AI_TMP"; return 1
      fi
      if [ ! -d "$AI_MNT/Koe.app" ] || ! app_gatekeeper_ok "$AI_MNT/Koe.app"; then
        warn "Koe.appの検証に失敗(署名/公証を確認できませんでした)"
        hdiutil detach "$AI_MNT" -force >/dev/null 2>&1; rm -rf "$AI_TMP"; return 1
      fi
      rm -rf /Applications/Koe.app
      cp -R "$AI_MNT/Koe.app" /Applications/Koe.app
      hdiutil detach "$AI_MNT" -force >/dev/null 2>&1
      rm -rf "$AI_TMP"
      # App Translocation対策(Sente側と同じ理由。dmgマウント元は元々quarantine付きだが、
      # コピー後の/Applications上の実体からは検証用に付けた分含めて外しておく)
      /usr/bin/xattr -rd com.apple.quarantine /Applications/Koe.app 2>/dev/null || true
      ok "Koe.app を /Applications に配置しました"
    }

    case "$APP_SUB" in
      install)
        case "${1:-both}" in
          sente) install_sente_app ;;
          koe) install_koe_app ;;
          both) install_sente_app; install_koe_app ;;
          *) echo "使い方: te app install [sente|koe]" ;;
        esac ;;
      status)
        if [ -d /Applications/Sente.app ]; then echo "  Sente.app: あり"; else echo "  Sente.app: なし → te app install sente"; fi
        if [ -d /Applications/Koe.app ]; then echo "  Koe.app:   あり"; else echo "  Koe.app:   なし → te app install koe"; fi
        ;;
      *) echo "使い方: te app [install [sente|koe|both]|status]" ;;
    esac
    exit 0 ;;
  uninstall)
    TE_RD="$(cd "$(dirname "$0")" && pwd)"
    echo "以下を削除します:"
    echo "  ・$TE_RD/te ・sente ・koe(コマンド本体)"
    echo "  ・$CONFIG_DIR(設定・APIキー・録音ヘルパー)"
    echo "  ・$SENTE_DATA_DIR(録音コピー)"
    echo "  ・$SENTE_LOG_DIR(聞き取りログ)"
    echo "  ※OpenCode本体(他ツールと共用)とteai.ioのアカウントは残ります"
    printf '本当に削除しますか? [y/N] '
    read -r UN_ANS </dev/tty 2>/dev/null || read -r UN_ANS
    case "$UN_ANS" in
      y|Y|yes) ;;
      *) echo "中止しました(何も消していません)"; exit 1 ;;
    esac
    rm -f "$TE_RD/sente" "$TE_RD/koe" 2>/dev/null
    rm -rf "$CONFIG_DIR" "$SENTE_DATA_DIR" "$SENTE_LOG_DIR" 2>/dev/null
    rm -f "$TE_RD/te" 2>/dev/null
    echo "アンインストール完了。ありがとうございました 🙏(再開はいつでも: curl -fsSL https://teai.io/te | sh)"
    exit 0 ;;
  image)
    # te image "プロンプト" [--fast|--hd] [--style photo|illustration|logo|poster] [--model スラッグ] [--out 出力.png]
    # teai画像MCPゲートウェイ(api.teai.io/mcp/image)を同じAPIキーで直接叩く。
    # 既定=standard(30cr)。--fast=15cr(3.1-flash-lite級) / --hd=60cr(3-pro級)。
    shift
    IMG_TOOL="generate_image"; IMG_STYLE=""; IMG_OUT=""; IMG_MODEL=""; IMG_PROMPT=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --fast) IMG_TOOL="generate_image_fast" ;;
        --hd) IMG_TOOL="generate_image_hd" ;;
        --style) shift; IMG_STYLE="${1:-}" ;;
        --model) shift; IMG_MODEL="${1:-}" ;;
        --out) shift; IMG_OUT="${1:-}" ;;
        *) IMG_PROMPT="$IMG_PROMPT $1" ;;
      esac; shift
    done
    IMG_PROMPT="${IMG_PROMPT# }"
    [ -n "$IMG_PROMPT" ] || { echo '使い方: te image "プロンプト" [--fast|--hd] [--style photo|illustration|logo|poster] [--model fal-ai/z-image/turbo等] [--out out.png]'; exit 1; }
    [ -f "$CREDS" ] && . "$CREDS"
    [ -n "${TEAI_API_KEY:-}" ] || { echo "先に te login してください"; exit 1; }
    [ -n "$IMG_OUT" ] || IMG_OUT="te-image-$(date +%Y%m%d-%H%M%S).png"
    IMG_BODY="$(python3 -c '
import json, sys
tool, prompt, style, model = sys.argv[1:5]
a = {"prompt": prompt}
if style: a["style"] = style
if model: a["model"] = model
print(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": tool, "arguments": a}}))' "$IMG_TOOL" "$IMG_PROMPT" "$IMG_STYLE" "$IMG_MODEL")"
    echo "🎨 生成中($IMG_TOOL${IMG_MODEL:+ · $IMG_MODEL})…"
    curl -s --max-time 300 -X POST "$TEAI_API/mcp/image" -H "Authorization: Bearer $TEAI_API_KEY" -H 'content-type: application/json' -d "$IMG_BODY" | python3 -c '
import json, sys, base64
out = sys.argv[1]
d = json.load(sys.stdin)
r = d.get("result") or {}
if d.get("error") or r.get("isError"):
    detail = d.get("error", {}).get("message") or "".join(c.get("text", "") for c in r.get("content", []))
    print("❌ 失敗:", detail[:300]); sys.exit(1)
i = 0
for c in r.get("content", []):
    if c.get("type") == "image":
        i += 1
        f = out if i == 1 else out.replace(".png", f"-{i}.png")
        open(f, "wb").write(base64.b64decode(c["data"]))
        print("✅", f)
    elif c.get("type") == "text":
        print("  ", c.get("text", "")[:200])
if i == 0: print("❌ 画像が返りませんでした"); sys.exit(1)' "$IMG_OUT" && { command -v open >/dev/null && open "$IMG_OUT" || true; }
    exit $? ;;
  video)
    # te video "プロンプト" [--model スラッグ] → ジョブ投入。te video status <status_url> で確認。
    shift
    if [ "${1:-}" = "status" ]; then
      shift
      VURL="${1:-}"; [ -n "$VURL" ] || { echo "使い方: te video status <status_url>"; exit 1; }
      [ -f "$CREDS" ] && . "$CREDS"
      curl -s --max-time 60 -X POST "$TEAI_API/mcp/image" -H "Authorization: Bearer $TEAI_API_KEY" -H 'content-type: application/json'         -d "$(python3 -c 'import json,sys;print(json.dumps({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"generate_video_status","arguments":{"status_url":sys.argv[1]}}}))' "$VURL")"         | python3 -c 'import json,sys;d=json.load(sys.stdin);r=d.get("result") or {};print(chr(10).join(c.get("text","") for c in r.get("content",[])) or json.dumps(d)[:300])'
      exit 0
    fi
    VID_MODEL=""; VID_PROMPT=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --model) shift; VID_MODEL="${1:-}" ;;
        *) VID_PROMPT="$VID_PROMPT $1" ;;
      esac; shift
    done
    VID_PROMPT="${VID_PROMPT# }"
    [ -n "$VID_PROMPT" ] || { echo '使い方: te video "プロンプト" [--model fal-ai/kling-video/v2.5-turbo/pro/text-to-video]  /  te video status <status_url>'; exit 1; }
    [ -f "$CREDS" ] && . "$CREDS"
    [ -n "${TEAI_API_KEY:-}" ] || { echo "先に te login してください"; exit 1; }
    echo "🎬 動画ジョブ投入中(300cr)…"
    curl -s --max-time 60 -X POST "$TEAI_API/mcp/image" -H "Authorization: Bearer $TEAI_API_KEY" -H 'content-type: application/json'       -d "$(python3 -c '
import json, sys
a = {"prompt": sys.argv[1]}
if sys.argv[2]: a["model"] = sys.argv[2]
print(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "generate_video", "arguments": a}}))' "$VID_PROMPT" "$VID_MODEL")"       | python3 -c 'import json,sys;d=json.load(sys.stdin);r=d.get("result") or {};print(chr(10).join(c.get("text","") for c in r.get("content",[])) or json.dumps(d)[:300])'
    exit 0 ;;
  help|-h|--help)
    # 🌐 言語判定(2026-09-10 ②UX): TE_LANG > LANG環境変数。ja以外は英語helpを出す。
    TE_HELP_LANG="$(te_ui_lang)"
    if [ "$TE_HELP_LANG" = "en" ]; then
      cat <<'HELPEN'
te — teai.io coding agent (powered by OpenCode)
"Always keep sente" — the agent makes the first move for you.

  te                    interactive coding agent in current directory
  te run "prompt"       one-shot task (shows a credit estimate first)
  te v                  voice one-shot (record → Enter → run, reply spoken)
  te talk               continuous voice dialogue (speak to run, Ctrl-C to quit)
  te watch              [Alpha] watches the board, suggests on change (never executes)
  te goal ["goal"]      set the goal for te loop
  te loop ["goal"]      [Alpha] keeps working toward the goal (executes)
                        budget breaker: auto-stops at TE_BUDGET_MAX_CR credits/day (default 5000, 0=off)
  te serve              runs requests from the iPhone/voice inbox on this machine
                        (same budget breaker applies)

  te max / te lux / te auto / te fast ...   pick model tier (this run only)
  te model              show / set your default model (persists)
  te models             list available models
  te engine claude|codex|opencode           switch execution engine

  BYOK (bring your own key, no teai credits consumed):
    client (this machine): export ANTHROPIC_API_KEY / OPENAI_API_KEY / GEMINI_API_KEY /
      DEEPSEEK_API_KEY / MOONSHOT_API_KEY / DASHSCOPE_API_KEY
      then: te model openai/<model>  (provider added automatically; disable=TE_NO_BYOK=1)
    server (any device): te byok add <provider> <key>   (openai/anthropic/google/deepseek/moonshot/qwen)
    both can be used together; server keys win when both exist.

  te voice on|off       spoken replies on/off
  te voice enroll       enroll your own voice (15s recording)
  te image "prompt"     image generation (30cr; --fast=15cr / --hd=60cr)
  te video "prompt"     video generation (300cr, async)
  te start              🌱 first steps for non-developers (3-min guide)
  te stats              cost dashboard (today/30d, by model, ¥)
  te lang [ja|en]       show / set UI language (te start/stats/help)
  te topup [yen]        add credits (¥1 = 6 credits)
  te whoami             account email and remaining credits
  te register           sign up with just an email (free 100 credits)
  te login              set / replace API key
  te doctor             check installation
  te privacy            data handling + opt-out switches
  te update             update te + OpenCode + model catalog
  te uninstall          remove everything
  te help -a            all commands (Japanese)

Everything else is passed straight to OpenCode (https://opencode.ai/docs).
Docs: https://teai.io/docs  Blog: https://teai.io/blog
HELPEN
      exit 0
    fi
    if [ "${2:-}" = "-a" ]; then
      cat <<'HELPBETA'
te — [β] reference Q&A skills (RAG-backed, general information only)

  te legal "質問"        日本法(民法/労基法/会社法等)の一般的な制度説明。参考情報RAG付き
                        (個別の法的助言ではありません。弁護士等にご相談ください)
                        API直接呼び出しも可: model:"shitate/legal" で /v1/chat/completions
  te infra "質問"        クラウドインフラ運用(Fly.io/Docker/CI/DNS等)の一般的なQ&A。参考情報RAG付き
                        (本番環境固有の構成・障害対応は必ず実環境で検証してください)
                        API直接呼び出しも可: model:"shitate/infra" で /v1/chat/completions
  te security "質問"     セキュアコーディング/脆弱性対策の一般的な参考情報。参考情報RAG付き
                        (個別の脆弱性診断や監査の代替にはなりません)
                        API直接呼び出しも可: model:"shitate/security" で /v1/chat/completions
  te freelance "質問"    フリーランスエンジニア/個人事業主の実務Q&A(契約/インボイス/確定申告等)
                        (個別の税務・法律相談ではありません。税理士等にご確認ください)
                        API直接呼び出しも可: model:"shitate/freelance" で /v1/chat/completions
  te license "質問"      OSSライセンス(MIT/Apache/GPL系/互換性等)の一般的な参考情報。参考情報RAG付き
                        (法的助言ではありません。弁護士等にご相談ください)
                        API直接呼び出しも可: model:"shitate/license" で /v1/chat/completions

te help = 日常コマンド一覧に戻る
HELPBETA
      exit 0
    fi
    cat <<'HELP'
te — teai.io coding agent (powered by OpenCode)
"Always keep sente" — the agent makes the first move for you.

  te                    interactive coding agent in current directory
  te run "prompt"       one-shot task
  koe                   声モードで起動(引数なしの koe = te talk と同じ)
  koe app               Koe.app(なければ koe.live)を開く
  te app install        GUIアプリ(メニューバーのSente.app・常駐のKoe.app)を入れる(任意・macOS)
  fuseki                [Alpha] 引数なしの fuseki = te watch と同じ(常時見続ける)

  te voice on|off       読み上げのON/OFF(保存・実行中にも即効く。声「声消して/声出して」/Sente.appメニューのワンクリックでも)
  te voice [<id>|reset] 声の切替(例: te voice kentaro・保存されます)
  te voice enroll       自分の声を登録(15秒録音→ te voice <自分のID> で自分の声になる)
  te engine claude|codex|opencode  実行エンジンを切替(既定opencode)
  te v                  声で1回指示(録音→Enter→実行。返事はKOEの声で読み上げ)
  te talk               声だけで連続対話(喋ると実行・黙ると待機・Ctrl-Cで終了)
                        読み上げOFF: te voice off(一時的なら AGENT_KOE=0)/ 声の変更: te voice <id>
                        環境音が続くと自動で待機終了(既定20回・無効化=TE_NO_DEAD_AIR=1)
  te ima                [Alpha] いまの状況(3行)+次の一手をまとめて提案(実行はしない・te next はエイリアス)
  te watch              [Alpha] 呼ばれなくても盤面を見続け、変化があった時だけ提案をログ+声で通知
                        (~/.config/teai/fuseki.log・既定15分間隔=TE_FUSEKI_INTERVAL・止める=te stop)
  te goal ["やりたいこと"|clear]  te loop が向かう目標を1つ設定/表示/削除
  te loop ["目標"]       [Alpha] goalに向かって実際に手を動かし続ける(watchと違い実行する)
                        3回連続で進まなければ自動停止・止める=別端末で te stop
                        (~/.config/teai/loop.log・間隔既定30秒=TE_LOOP_INTERVAL)
  te tune               声のやりとりの記録を見て、話し終わりの待ち時間を決め直す
                        (talk起動時に自動で走る。録音を残したくない=TE_NO_RECORD=1)
  koe <url>             音声URLをkoe.live/playで開く
  koe "text"            自分の声(KOE_VOICE)で合成して鳴らす

  te max ...            maximum performance on Kimi K3 (2.8T, 1M context)
  te lux ...            Claude/OpenAI flagship tier (teai/lux → Fable 5, this run only)
  te auto ...           automatic model selection (teai/auto — this run only)
  te fast ...           cheapest model (this run only)
  te -m teai/<model>    use another model (te models = list)
  te model              show / set your default model (persists across runs)
  te claude [<model>]   launch Claude Code against teai.io (/v1/messages)
  te sec ...            セキュリティ監査特化(到達可能な脆弱性のみ・file:line+攻撃シナリオ+最小パッチ)
                        例: te sec run "src/ を監査して" / モデル変更=TE_SEC_MODEL

  te web                view sessions in your browser (session viewer)
  te -c                 continue the last session   (te -s <id> = pick one)
  te session list       list past sessions
  te start              🌱 非開発者向けはじめの3分(用語なし・声の案内)
  te stats              コストダッシュボード(今日/30日・モデル別・円換算)
  te lang [ja|en]       UI言語の表示/設定(te start/stats/help)
  te topup [yen]        add credits (¥1 = 6 credits, default ¥10000) — opens checkout

  BYOK(自前キー・teaiクレジット消費なし):
    クライアント(この端末): export ANTHROPIC_API_KEY / OPENAI_API_KEY / GEMINI_API_KEY /
      DEEPSEEK_API_KEY / MOONSHOT_API_KEY / DASHSCOPE_API_KEY
      → te model openai/<model> 等(自動で追加・無効化=TE_NO_BYOK=1)
    サーバ(どの端末でも): te byok add <provider> <key>  (openai/anthropic/google/deepseek/moonshot/qwen)
    併用可。同じプロバイダに両方あればサーバ側が優先。

  te register           メールだけで新規登録(コード確認→APIキー自動発行・ブラウザ不要)
  te redeem <コード>     クーポンコードを適用してクレジット追加
  te login              set / replace API key
  te models             list available models
  te image "プロンプト"    画像生成(標準30cr)。--fast=15cr/--hd=60cr/--model明示/--style/--out
  te video "プロンプト"    動画生成(300cr・非同期)。te video status <status_url> で完成確認
  te bench [<eval>] [<model>]  公式ベンチを自分のモデ��で実測(機械採点・コスト集計)
                        eval: jp-business(182問・既定) / jp-business-hard(難問・26問)
                        model: 指定が無ければ既定モデル。例: te bench jp-business moonshotai/kimi-k3
  te whoami             show account email and remaining credits
  te doctor             check installation(前回起動時の忠告も見返せます)
  te optimize           環境を自動で最適に整える(各項目 y/n 確認・--yes で全自動)
  te serve              iPhone/声の受信箱から届いた依頼をこの端末で実行し続ける
                        (本人確認はkoe.live側。赤=消す/送る/払うは既定で実行せず知らせるだけ)
  te schedule add "09:00" "経費集計"  毎日決まった時刻の頼み事を登録(te serve常駐中に自動実行)
  te agent list|run <name>|deploy <name> --to launchd  エージェント形式: ~/.config/sente/agent/<name>.md の sente:{runtime,schedule,cwd,task} で「どこでも同じ定義で動く」(te agent init <name> で雛形)
  te schedule list / te schedule rm <id>  予定の一覧/削除
  te clean              固まった opencode を全部停止(自動GCで消えない分の手動掃除)
  te resume             途中で止まった直前セッションを開き続きから再開(TUI内は /resume-work・/restart=コンパクトして再起動)
  te watashibi          渡し火: 前のセッションが残した種火(.sente/watashibi/latest.md)だけを読んで白紙の新セッションで続ける(TUI内は /watashibi・別名 handoff)
                        ※通常は起動のたびに孤児プロセス/古い一時ファイルを自動GC(無効化=TE_NO_GC=1)
  te update             update te + OpenCode + model catalog
  te greeting ["文言"|off|reset]  起動あいさつの確認/固定文/オフ(既定=状況からの気づき一言)
  te privacy            データの扱いを表示(声・コード・鍵がどこへ行くか+オフスイッチ一覧)
  te skill list|install <name>|publish [dir]  スキルマーケットプレイス(審査制・Phase 1は無料のみ)
  te uninstall          全部きれいに削除(本体・設定・APIキー・録音・ログ)
  te help               this help
  te help -a            all commands, including [β] reference Q&A skills
                        (legal / infra / security / freelance / license)

Everything else is passed straight to OpenCode (https://opencode.ai/docs).
HELP
    exit 0 ;;
  topup)
    shift
    AMT="${1:-10000}"
    load_key
    [ -n "$TEAI_API_KEY" ] || { echo "No API key. Run: te register (new account) or te login (paste existing key, get one at $TEAI_SITE/dashboard#api-keys)"; exit 1; }
    URL="$(curl -s --max-time 20 -X POST "$TEAI_API/api/v1/billing/topup-checkout" \
      -H "Authorization: Bearer $TEAI_API_KEY" -H "Content-Type: application/json" \
      -d "{\"amount_jpy\":${AMT}}" | sed -n 's/.*"checkout_url":"\([^"]*\)".*/\1/p')"
    if [ -n "$URL" ]; then
      echo "💳 ¥${AMT} → $((AMT * 6)) credits — opening secure checkout…"
      echo "$URL"
      { command -v open >/dev/null 2>&1 && open "$URL"; } \
        || { command -v xdg-open >/dev/null 2>&1 && xdg-open "$URL"; } || true
    else
      echo "Top-up failed (invalid amount?). See allowed amounts at $TEAI_SITE/pricing"
      exit 1
    fi
    exit 0 ;;
  byok)
    shift
    load_key
    [ -n "$TEAI_API_KEY" ] || { echo "No API key. Run: te register (new account) or te login"; exit 1; }
    case "${1:-}" in
      add)
        PROVIDER="${2:-}"
        case "$PROVIDER" in
          openai|anthropic|google|deepseek|moonshot|qwen) ;;
          *) echo "Usage: te byok add <provider> <api-key>"; echo "  providers: openai anthropic google deepseek moonshot qwen"; exit 1 ;;
        esac
        BYOK_KEY="${3:-}"
        if [ -z "$BYOK_KEY" ]; then
          printf "Paste your %s API key: " "$PROVIDER"
          BYOK_KEY="$(head -1 /dev/tty | tr -d '[:space:]')"
        fi
        [ -n "$BYOK_KEY" ] || { echo "No key entered."; exit 1; }
        BYOK_BODY="$(BYOK_KEY="$BYOK_KEY" python3 -c 'import json,os,sys;print(json.dumps({"provider":sys.argv[1],"api_key":os.environ["BYOK_KEY"]}))' "$PROVIDER")"
        unset BYOK_KEY
        RESP="$(curl -s --max-time 20 -X POST "$TEAI_API/api/v1/byok" \
          -H "Authorization: Bearer $TEAI_API_KEY" -H "Content-Type: application/json" \
          -d "$BYOK_BODY")"
        case "$RESP" in
          *'"byok_id"'*)
            printf '%s' "$RESP" | python3 -c 'import json,sys;d=json.load(sys.stdin);print("✅ BYOK key registered: {} ({} {})".format(d["byok_id"], d["provider"], d["key_hint"]))' ;;
          *)
            ERR="$(printf '%s' "$RESP" | sed -n 's/.*"error":"\([^"]*\)".*/\1/p' | head -1)"
            echo "❌ 登録に失敗しました: ${ERR:-$RESP}"; exit 1 ;;
        esac
        exit 0 ;;
      list)
        RESP="$(curl -s --max-time 20 -H "Authorization: Bearer $TEAI_API_KEY" "$TEAI_API/api/v1/byok")"
        printf '%s' "$RESP" | python3 -c '
import json,sys
try:
    keys = json.load(sys.stdin)
except Exception:
    print("❌ 一覧の取得に失敗しました"); sys.exit(1)
if isinstance(keys, dict):
    print("❌ " + str(keys.get("error", keys))); sys.exit(1)
if not keys:
    print("BYOKキーはまだありません。te byok add <provider> <key> で登録できます。"); sys.exit(0)
for k in keys:
    active = "active" if k.get("is_active") else "inactive"
    bid = k.get("byok_id", "")
    prov = k.get("provider", "")
    hint = k.get("key_hint", "")
    created = str(k.get("created_at", ""))[:10]
    print("{}  {:<10} {:<10} {}  created={}".format(bid, prov, hint, active, created))
'
        exit 0 ;;
      remove|rm|delete)
        ID="${2:-}"
        [ -n "$ID" ] || { echo "Usage: te byok remove <byok_id>"; exit 1; }
        RESP="$(curl -s --max-time 20 -X DELETE -H "Authorization: Bearer $TEAI_API_KEY" "$TEAI_API/api/v1/byok/$ID")"
        case "$RESP" in
          *'"ok":true'*) echo "✅ removed: $ID" ;;
          *) echo "❌ 削除に失敗しました: $RESP"; exit 1 ;;
        esac
        exit 0 ;;
      *)
        echo "Usage: te byok <add|list|remove>"
        echo "  te byok add <provider> <api-key>   register a provider key (openai/anthropic/google/deepseek/moonshot/qwen)"
        echo "  te byok list                       list your BYOK keys (key material is never shown)"
        echo "  te byok remove <byok_id>           remove a key"
        echo ""
        echo "  ⚠ 2 kinds of BYOK:"
        echo "    server (this command): stored encrypted on teai, works from any device, all 6 providers."
        echo "    client (env vars):     export ANTHROPIC_API_KEY / OPENAI_API_KEY / GEMINI_API_KEY /"
        echo "                           DEEPSEEK_API_KEY / MOONSHOT_API_KEY / DASHSCOPE_API_KEY — this"
        echo "                           machine only, keys never leave your shell. Disable=TE_NO_BYOK=1."
        echo "    Both can be used together; server keys win when both exist for a provider."
        exit 1 ;;
    esac ;;
  skill)
    shift
    SKILLS_DIR="$HOME/.config/sente/skills"
    case "${1:-}" in
      list)
        RESP="$(curl -s --max-time 20 "$TEAI_API/api/v1/skills/registry")"
        printf '%s' "$RESP" | python3 -c '
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("❌ 一覧の取得に失敗しました"); sys.exit(1)
skills = d.get("skills") if isinstance(d, dict) else None
if skills is None:
    print("❌ " + str(d.get("error", d))); sys.exit(1)
if not skills:
    print("まだ公開スキルがありません。"); sys.exit(0)
for s in skills:
    badge = "✓verified" if s.get("badge") == "verified" else "community"
    print(f"{s[\"name\"]:<24} v{s.get(\"version\",\"?\"):<8} [{badge}] dl={s.get(\"downloads\",0)}  {s.get(\"description\",\"\")[:60]}")
'
        exit 0 ;;
      install)
        NAME="${2:-}"
        [ -n "$NAME" ] || { echo "Usage: te skill install <name>"; exit 1; }
        RESP="$(curl -s --max-time 30 -X POST "$TEAI_API/api/v1/skills/registry/$NAME/install")"
        case "$RESP" in
          *'"skill_md"'*) ;;
          *)
            ERR="$(printf '%s' "$RESP" | sed -n 's/.*"error":"\([^"]*\)".*/\1/p' | head -1)"
            echo "❌ インストールに失敗しました: ${ERR:-$RESP}"; exit 1 ;;
        esac
        DEST="$SKILLS_DIR/$NAME"
        mkdir -p "$DEST"
        printf '%s' "$RESP" | python3 -c '
import json,sys
d = json.load(sys.stdin)
with open(sys.argv[1], "w", encoding="utf-8") as f:
    f.write(d["skill_md"])
print(f"✅ installed: {d[\"name\"]} v{d.get(\"version\",\"?\")} [{d.get(\"badge\",\"community\")}]")
' "$DEST/SKILL.md" || { echo "❌ SKILL.md の書き込みに失敗しました"; exit 1; }
        echo "  → $DEST/SKILL.md"
        exit 0 ;;
      publish)
        DIR="${2:-.}"
        SKILL_MD="$DIR/SKILL.md"
        [ -f "$SKILL_MD" ] || { echo "❌ $SKILL_MD が見つかりません"; exit 1; }
        load_key
        [ -n "$TEAI_API_KEY" ] || { echo "No API key. Run: te register (new account) or te login"; exit 1; }
        BODY="$(python3 -c '
import json,sys
with open(sys.argv[1], encoding="utf-8") as f:
    print(json.dumps({"skill_md": f.read()}))
' "$SKILL_MD")"
        RESP="$(curl -s --max-time 30 -X POST "$TEAI_API/api/v1/skills/registry" \
          -H "Authorization: Bearer $TEAI_API_KEY" -H "Content-Type: application/json" \
          -d "$BODY")"
        case "$RESP" in
          *'"status":"pending"'*)
            printf '%s' "$RESP" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(f"✅ 公開申請しました: {d[\"name\"]} (status=pending — 審査後にliveになります)")' ;;
          *)
            ERR="$(printf '%s' "$RESP" | sed -n 's/.*"error":"\([^"]*\)".*/\1/p' | head -1)"
            echo "❌ 公開申請に失敗しました: ${ERR:-$RESP}"; exit 1 ;;
        esac
        exit 0 ;;
      *)
        echo "Usage: te skill <list|install|publish>"
        echo "  te skill list              マーケットプレイスの公開スキル一覧"
        echo "  te skill install <name>    スキルを ~/.config/sente/skills/<name>/ にインストール"
        echo "  te skill publish [dir]     ディレクトリの SKILL.md を公開申請(審査後にlive)"
        exit 1 ;;
    esac ;;
esac

# `te max`/`te k3` (strongest), `te auto` (automatic selection), `te fast`
# (cheapest) — force a specific model for this run only. Everything after the
# keyword is passed through, so `te max run "..."` and `te max` (interactive)
# both work. Without any of these, a persisted `te model <id>` default (if set)
# is applied instead; with neither, the server-side /te/config default wins.
FORCE_MODEL=""
SEC_MODE=0
# `te sec` / `te security` — セキュリティ監査特化モード。
# 監査の質はモデルの判断力が天井(実測: 規律注入では誤検知が直らない)なので強いモデルを既定に。
# claude-sonnet-5は脆弱サンプルでSQLi/コマンドインジェクションを検出し、未配線のevalを
# 「到達不可」と正しく除外できた → 既定。TE_SEC_MODEL / -m で変更可。
# 📌kimi-k3も同条件で正常動作する(2026-08-05に20回以上実測)。以前「k3はSSE無応答で使えない」と
#   記録していたのは誤りで、実際はOpenCodeが稀に起動直後(セッション作成)で固まる別問題だった
#   (モデル非依存・oc_run_guarded と te clean で対処)。
if [ "${1:-}" = "sec" ] || [ "${1:-}" = "security" ]; then
  SEC_MODE=1; shift
  FORCE_MODEL="${TE_SEC_MODEL:-claude-sonnet-5}"
  echo "🛡  Sente Security — 監査モード(model: $FORCE_MODEL)" >&2
fi
case "${1:-}" in
  max|k3) FORCE_MODEL="moonshotai/kimi-k3"; shift ;;
  auto)   FORCE_MODEL="teai/auto"; shift ;;
  fast)   FORCE_MODEL="deepseek/deepseek-v4-flash"; shift ;;
  lux)    FORCE_MODEL="teai/lux"; shift ;;
esac

# `te legal "質問"` (or `te legal run "質問"`) — beta skill. Looks up the
# question against a small server-side reference corpus (general Japanese
# civil/labor/company/consumer/rental law) and splices the top matches into
# the prompt as RAG context before handing off, same as any other `te run`.
# No local embedding step, so the install stays a single curl | sh.
if [ "${1:-}" = "legal" ]; then
  shift
  [ "${1:-}" = "run" ] && shift
  LEGAL_Q="${1:-}"
  [ -n "$LEGAL_Q" ] || fail 'Usage: te legal "質問文"'
  echo "⚖️  Sente legal (β) — 参考情報を検索中..." >&2
  LEGAL_PROMPT="$(curl -fsSL -G "$TEAI_SITE/api/v1/legal/search" \
    --data-urlencode "q=${LEGAL_Q}" --data-urlencode "format=prompt" 2>/dev/null || true)"
  if [ -n "$LEGAL_PROMPT" ]; then
    set -- run "$LEGAL_PROMPT"
  else
    warn "参考情報の取得に失敗しました。通常のrunにフォールバックします。"
    set -- run "$LEGAL_Q"
  fi
fi

# `te infra "質問"` (or `te infra run "質問"`) — beta skill. Looks up the
# question against a small server-side reference corpus (Fly.io/Docker/CI/
# SQLite/DNS/TLS/incident response etc.) and splices the top matches into the
# prompt as RAG context before handing off, same as any other `te run`.
# No local embedding step, so the install stays a single curl | sh.
if [ "${1:-}" = "infra" ]; then
  shift
  [ "${1:-}" = "run" ] && shift
  INFRA_Q="${1:-}"
  [ -n "$INFRA_Q" ] || fail 'Usage: te infra "質問文"'
  echo "🛠️  Sente infra (β) — 参考情報を検索中..." >&2
  INFRA_PROMPT="$(curl -fsSL -G "$TEAI_SITE/api/v1/infra/search" \
    --data-urlencode "q=${INFRA_Q}" --data-urlencode "format=prompt" 2>/dev/null || true)"
  if [ -n "$INFRA_PROMPT" ]; then
    set -- run "$INFRA_PROMPT"
  else
    warn "参考情報の取得に失敗しました。通常のrunにフォールバックします。"
    set -- run "$INFRA_Q"
  fi
fi

# `te security "質問"` (or `te security run "質問"`) — beta skill. Looks up
# the question against a small server-side reference corpus (secure coding
# / vulnerability Q&A: injection, XSS/CSRF, auth/authz, secrets, dependency
# management, crypto basics, API security, logging, CI/CD security, file
# upload handling) and splices the top matches into the prompt as RAG
# context before handing off, same as any other `te run`. No local
# embedding step, so the install stays a single curl | sh.
if [ "${1:-}" = "security" ]; then
  shift
  [ "${1:-}" = "run" ] && shift
  SECURITY_Q="${1:-}"
  [ -n "$SECURITY_Q" ] || fail 'Usage: te security "質問文"'
  echo "🔒 Sente security (β) — 参考情報を検索中..." >&2
  SECURITY_PROMPT="$(curl -fsSL -G "$TEAI_SITE/api/v1/security/search" \
    --data-urlencode "q=${SECURITY_Q}" --data-urlencode "format=prompt" 2>/dev/null || true)"
  if [ -n "$SECURITY_PROMPT" ]; then
    set -- run "$SECURITY_PROMPT"
  else
    warn "参考情報の取得に失敗しました。通常のrunにフォールバックします。"
    set -- run "$SECURITY_Q"
  fi
fi

# `te freelance "質問"` (or `te freelance run "質問"`) — beta skill. Looks up
# the question against a small server-side reference corpus (practical
# Japanese freelance/sole-proprietor procedures: contracts, invoicing,
# tax filing, social insurance, client disputes) and splices the top matches
# into the prompt as RAG context before handing off, same as any other
# `te run`. No local embedding step, so the install stays a single curl | sh.
if [ "${1:-}" = "freelance" ]; then
  shift
  [ "${1:-}" = "run" ] && shift
  FREELANCE_Q="${1:-}"
  [ -n "$FREELANCE_Q" ] || fail 'Usage: te freelance "質問文"'
  echo "🧾 Sente freelance (β) — 参考情報を検索中..." >&2
  FREELANCE_PROMPT="$(curl -fsSL -G "$TEAI_SITE/api/v1/freelance/search" \
    --data-urlencode "q=${FREELANCE_Q}" --data-urlencode "format=prompt" 2>/dev/null || true)"
  if [ -n "$FREELANCE_PROMPT" ]; then
    set -- run "$FREELANCE_PROMPT"
  else
    warn "参考情報の取得に失敗しました。通常のrunにフォールバックします。"
    set -- run "$FREELANCE_Q"
  fi
fi

# `te license "質問"` (or `te license run "質問"`) — beta skill. Looks up the
# question against a small server-side reference corpus (general OSS license
# Q&A: MIT/Apache/GPL family/BSD/MPL/dual-licensing/compatibility/NOTICE
# practice/SaaS+AGPL/unlicensed code/dependency audits/Creative Commons) and
# splices the top matches into the prompt as RAG context before handing off,
# same as `te legal`. No local embedding step, so the install stays a single
# curl | sh.
if [ "${1:-}" = "license" ]; then
  shift
  [ "${1:-}" = "run" ] && shift
  LICENSE_Q="${1:-}"
  [ -n "$LICENSE_Q" ] || fail 'Usage: te license "質問文"'
  echo "📜 Sente license (β) — 参考情報を検索中..." >&2
  LICENSE_PROMPT="$(curl -fsSL -G "$TEAI_SITE/api/v1/license/search" \
    --data-urlencode "q=${LICENSE_Q}" --data-urlencode "format=prompt" 2>/dev/null || true)"
  if [ -n "$LICENSE_PROMPT" ]; then
    set -- run "$LICENSE_PROMPT"
  else
    warn "参考情報の取得に失敗しました。通常のrunにフォールバックします。"
    set -- run "$LICENSE_Q"
  fi
fi

# --- KOE voice input (te v / te talk) ----------------------------------------
# 録音の罠(cagent実測で確定済み・変えるな):
#  - ffmpegは必ず -nostdin(無いと「Enterで停止」のEnterをffmpegが横取りする)
#  - macのデバイスは ":default"(":0"は最初のaudio deviceでBlackHole等の仮想
#    デバイスだと無音を録る)
#  - soxのsilenceトリガーに -r を付けない(レート強制で発火しなくなる)
koe_rec_enter() {  # $1=out.wav — 録音してEnterで停止。無音なら失敗
  printf '  🎤 録音中… Enterで停止\n' >&2
  if [ "$(uname)" = "Darwin" ] && command -v ffmpeg >/dev/null 2>&1; then
    ffmpeg -nostdin -hide_banner -loglevel error -f avfoundation -i :default \
      -ac 1 -ar 16000 -y "$1" 2>/dev/null &
  elif command -v ffmpeg >/dev/null 2>&1 && [ "$(uname)" = "Linux" ]; then
    # 🐧 Linux の入力バックエンドは環境で違う。PulseAudio/PipeWire(pipewire-pulse)が動いていれば
    # -f pulse(デスクトップ既定・ALSA直だと dmix 越しにデバイス競合で "Device or resource busy" になる)、
    # 無ければ -f alsa。TE_REC_BACKEND=alsa|pulse で強制もできる。
    case "${TE_REC_BACKEND:-$(sente_linux_audio_backend)}" in
      pulse) ffmpeg -nostdin -hide_banner -loglevel error -f pulse -i default \
               -ac 1 -ar 16000 -y "$1" 2>/dev/null & ;;
      *)     ffmpeg -nostdin -hide_banner -loglevel error -f alsa -i default \
               -ac 1 -ar 16000 -y "$1" 2>/dev/null & ;;
    esac
  elif command -v rec >/dev/null 2>&1; then
    rec -q -c 1 -r 16000 "$1" >/dev/null 2>&1 &
  elif command -v parecord >/dev/null 2>&1; then
    parecord --rate=16000 --channels=1 --format=s16le --file-format=wav "$1" 2>/dev/null &
  elif command -v arecord >/dev/null 2>&1; then
    arecord -q -f S16_LE -r 16000 -c 1 "$1" 2>/dev/null &
  else
    echo "録音コマンドがありません — $(sente_pkg_hint ffmpeg) (または sox)" >&2
    return 1
  fi
  RP=$!
  head -1 >/dev/null 2>&1 || true
  kill -INT "$RP" 2>/dev/null || true
  wait "$RP" 2>/dev/null || true
  [ -f "$1" ] && [ "$(wc -c < "$1")" -gt 4000 ]  # <0.25s相当は失敗扱い
}

# 🔤 STT語彙ヒント(認識精度の自動向上・2026-08-06本人指示): よく使う固有名詞をWhisperの
# initial_prompt(/api/stt?lex=)に渡して表記を寄せる。土台の固定語彙+直近の聞き取り(ok)から
# 英字・カタカナの頻出語を自動で足す=使うほど自分の語彙に寄っていく。セッション内キャッシュ。
sente_stt_lexicon() {
  SLX_CACHE="${TMPDIR:-/tmp}/sente_stt_lex.$$"
  if [ ! -f "$SLX_CACHE" ]; then
    # 🪤 2026-08-08本人報告「スモークテストと言ってないのに(barge判定で)入っちゃう」実障害:
    # ここに固定で入れていた語がSTTへの語彙ヒント(lex=)として恒常的にモデルへ渡り、
    # 曖昧な無音/雑音でもその語へ幻聴しやすくするバイアスになっていた。
    # 「スモークテスト」は元々認識しづらい語でもなく(ヒントが要る専門用語・固有名詞とは違う)、
    # ヒントに載せる必要が無いので外す。動的学習(SLX_DYN)側は直近のheard頻出語を都度拾うので
    # 同じ理屈でどの語でも起こり得る自己強化バイアスだが、そちらはセッション内の一時的なもので
    # 実害の確証がまだ無いため今回は静的リストの明確な穴だけ直す
    SLX_BASE="Sente,先手,teai,KOE,koe-edge,jiuflow,デプロイ,リポジトリ,コミット,プルリクエスト,リファクタリング"
    # 📈 解析ループ(stt-bench/analyze_prod.py・日次)が誤認識の固有名詞をここへ自動昇格する。
    # 1行1語・#行コメント。手で足しても消してもよい(自己強化バイアス注意=よく聞き取れてる語は入れない)
    if [ -f "$CONFIG_DIR/stt-lexicon-extra" ]; then
      SLX_EXTRA="$(grep -v '^#' "$CONFIG_DIR/stt-lexicon-extra" 2>/dev/null | tr -d ' ' | grep -v '^$' | head -30 | paste -sd, -)"
      [ -n "$SLX_EXTRA" ] && SLX_BASE="$SLX_BASE,$SLX_EXTRA"
    fi
    # 🧭 用語集の (確定) 語を語彙ヒントへ(仮説のままの語は入れない=幻聴バイアス防止)
    if [ -f "$CONFIG_DIR/memory/glossary.md" ]; then
      SLX_GLOSS="$(grep -E '^- .+ → .*\(確定' "$CONFIG_DIR/memory/glossary.md" 2>/dev/null | sed -E 's/^- ([^→]+) →.*/\1/' | tr -d ' ' | grep -v '^$' | head -20 | paste -sd, -)"
      [ -n "$SLX_GLOSS" ] && SLX_BASE="$SLX_BASE,$SLX_GLOSS"
    fi
    SLX_DYN=""
    if [ -f "$SENTE_TURNS" ] && command -v python3 >/dev/null 2>&1; then
      SLX_TF="$(mktemp "${TMPDIR:-/tmp}/sente_lex_XXXXXX")"
      python3 - "$SENTE_TURNS" > "$SLX_TF" <<'PYLEX' 2>/dev/null
import json, re, sys, collections
c = collections.Counter()
try:
    lines = open(sys.argv[1], encoding="utf-8").readlines()[-400:]
except Exception:
    lines = []
for L in lines:
    try: d = json.loads(L)
    except Exception: continue
    if d.get("outcome") not in ("ok", "barge"): continue
    for w in re.findall(r"[A-Za-z][A-Za-z0-9_.-]{2,}|[ァ-ヴー]{3,}", d.get("heard") or ""):
        c[w.lower() if w.isascii() else w] += 1
print(",".join(w for w, n in c.most_common(12) if n >= 2))
PYLEX
      SLX_DYN="$(cat "$SLX_TF" 2>/dev/null)"; rm -f "$SLX_TF"
    fi
    printf '%s' "${SLX_BASE}${SLX_DYN:+,$SLX_DYN}" | cut -c1-190 > "$SLX_CACHE" 2>/dev/null || true
  fi
  cat "$SLX_CACHE" 2>/dev/null
}

koe_stt() {  # $1=wav → 聞き取ったテキストをstdoutへ(言語固定で誤判定・他言語幻聴を防ぐ)
  # ⚡ 送る前に16kHzモノラルへ落とす。
  # sox はデバイスのネイティブ設定(このMacでは48kHz)で録るため、6秒の発話が
  # 2.3MB にもなる。聞き取りに使うモデルは 16kHz で動くので、その分はまるごと
  # 無駄な転送。実測 4.06秒 → 1.26秒(3.2倍)。変換自体は0.06秒で元が取れる。
  # 🪤 mp3(32kbps)まで圧縮すると 0.95秒とさらに速いが、聞き取りが目に見えて
  #    崩れた(「暑いと」→「アツいって…ヘラヘラ」)ので wav のまま軽くする。
  STT_SRC="$1"
  if command -v ffmpeg >/dev/null 2>&1; then
    STT_TMP="${1%.wav}.16k.wav"
    if ffmpeg -hide_banner -loglevel error -y -i "$1" -ac 1 -ar 16000 "$STT_TMP" 2>/dev/null; then
      STT_SRC="$STT_TMP"
    fi
  fi
  # 👤 話者確認(2026-08-10本人指示「僕なら優貴さんっていうように」・optin限定): 16k変換済みの
  # 音をオーナー声紋照合(koe.live /api/sente/speaker)へ裏で送る。照合は数秒かかるので
  # このターンは待たず、結果は「次のターン以降」の話者タグ(sticky)に使う=会話の間を壊さない。
  # 既定off: 他ユーザーの環境では比較先がオーナーの声紋になるため(有効化=speaker-optinファイル)
  if [ -f "$CONFIG_DIR/speaker-optin" ]; then
    SPK_CP="${TMPDIR:-/tmp}/te_spk_$$_$(date +%s).wav"
    if cp "$STT_SRC" "$SPK_CP" 2>/dev/null; then
      (
        SPK_SIM="$(curl -s -m 30 -X POST "${KOE_BASE:-https://koe.live}/api/sente/speaker" \
          -H "Content-Type: audio/wav" --data-binary @"$SPK_CP" 2>/dev/null \
          | sed -n 's/.*"similarity":\([0-9.]*\).*/\1/p')"
        if [ -n "$SPK_SIM" ]; then
          printf '%s %s\n' "$(date +%s)" "$SPK_SIM" > "$CONFIG_DIR/speaker-last" 2>/dev/null
          printf '{"ts":"%s","sim":%s}\n' "$(date '+%Y%m%d-%H%M%S')" "$SPK_SIM" >> "$SENTE_LOG_DIR/speaker.jsonl" 2>/dev/null
        fi
        rm -f "$SPK_CP"
      ) >/dev/null 2>&1 &
    fi
  fi
  STT_LEX="$(sente_stt_lexicon | python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.stdin.read().strip()))' 2>/dev/null || true)"
  # 🔒 サーバ側の音声記録(src=sente→koe.live R2に30日保存・聞き取り精度の自動改善用)は
  # opt-inのみ。既定では音声は文字起こしに使われるだけでサーバに保存されない。
  # 切替= te privacy stt-log on|off(またはTE_STT_LOG=1/0が優先)
  case "${TE_STT_LOG:-}" in
    1) STT_SRCQ="&src=sente" ;;
    0) STT_SRCQ="" ;;
    *) if [ -f "$CONFIG_DIR/stt-log-optin" ]; then STT_SRCQ="&src=sente"; else STT_SRCQ=""; fi ;;
  esac
  curl -s -m 30 -X POST "${KOE_BASE:-https://koe.live}/api/stt?lang=${KOE_STT_LANG:-ja}${STT_SRCQ}${STT_LEX:+&lex=$STT_LEX}" \
    -H "Content-Type: audio/wav" --data-binary @"$STT_SRC" \
    | sed -n 's/.*"text":"\([^"]*\)".*/\1/p'
  [ "$STT_SRC" != "$1" ] && rm -f "$STT_SRC"
  return 0
}

# 🌐 幻聴は既知の定番フレーズだけでなく未知の言語/文でも起きる(2026-08-08本人報告
# 「幻聴っぽいのが多いし言語も間違える」・実例: 「Það er það, hvað er það?」というアイスランド語を
# Whisperが幻聴し、固定フレーズ一覧(ご視聴ありがとう等)に無いため素通りしてLLMまで答えてしまった)。
# koe_stt()はlang=jaを渡しているが、音声が曖昧だとWhisperは言語指定を無視することがある既知の限界。
# 日本語限定にはしない(本人指示「幻聴は多言語対応してね」): 日本語(ひらがな/カタカナ/漢字)か、
# 英語含む素のASCIIならOK。それ以外(アイスランド語のþ/ð等・キリル文字・アラビア文字等)を含む
# ものだけ幻聴とみなす。固定フレーズの追いかけっこ(モグラ叩き)にしない一般化した対策。
# TE_NO_LANG_GUARD=1で無効化できる。
sente_lang_plausible() {  # $1=文字列 → 0:日本語 or 素のASCII(英語含む) / 1:未知スクリプトを含む(幻聴の疑い)
  [ "${TE_NO_LANG_GUARD:-0}" = "1" ] && return 0
  command -v python3 >/dev/null 2>&1 || return 0
  python3 -c 'import sys
t = sys.argv[1]
has_jp = any(0x3040 <= ord(c) <= 0x30ff or 0x4e00 <= ord(c) <= 0x9fff for c in t)
is_ascii = all(ord(c) < 128 for c in t)
sys.exit(0 if (has_jp or is_ascii) else 1)' "$1" 2>/dev/null
}

# 📈 幻聴/放送常套句の追加パターン(解析ループ stt-bench/analyze_prod.py が日次で自動追記)。
# $CONFIG_DIR/stt-noise-extra: 1行1部分文字列・#行コメント。一致したら捨てる側。
# ハードコード一覧(ご視聴ありがとう等)のモグラ叩きを、実ログからの学習で補う。
sente_noise_extra_match() {  # $1=聞き取り → 0:一致(ノイズ扱い)
  [ -f "$CONFIG_DIR/stt-noise-extra" ] || return 1
  while IFS= read -r NEP; do
    case "$NEP" in ''|'#'*) continue ;; esac
    case "$1" in *"$NEP"*) return 0 ;; esac
  done < "$CONFIG_DIR/stt-noise-extra"
  return 1
}

ensure_sec_rules() {
  cat > "$CONFIG_DIR/sente-sec-rules.md" <<'SECRULES'
# Sente Security — 攻撃者の目で読む監査モード(このセッションはセキュリティ特化)

- あなたはセキュリティ監査に特化した Sente。目的は「実際に攻撃可能な欠陥」だけを見つけ、直すこと。
- **到達可能性がすべて**: 攻撃者/ユーザー入力が実行時に到達できる行だけが発見。テストコード・
  examples・未配線のコードは対象外(テスト内の unwrap は脆弱性ではない)。
- 各発見は必ず: ①file:line ②攻撃シナリオ(入力→経路→影響を1行で) ③深刻度(Critical/High/Med/Low)
  ④最小修正パッチ。この4点が揃わないものは報告しない。
- 優先順: 認証/認可バイパス > injection(SQL/コマンド/SSRF/XSS/パストラバーサル) > 秘密情報の露出 >
  暗号誤用 > レート制限/DoS。
- 秘密情報(キー/トークン/パスワード)を見つけたら値は出力せず、マスクして場所だけ報告。
- 修正を頼まれたら最小diffで直し、修正後にもう一度攻撃者視点で回帰確認する。
- 不確実なら「unverified」と明記。誇張しない。見つからなければ「見つからなかった」とはっきり言う。
SECRULES
}

oc_stale() {  # 親を失って残った opencode(argv[0]=sente) プロセスの数(自分の子は除く)。
              # OpenCodeは稀に起動直後(セッション作成)で固まり、中断すると残骸になる。
              # 🪤 pgrep -f だと自分のシェル行にマッチするので必ず -x(実行ファイル名一致)。
              # 実体はopencodeバイナリだが $CONFIG_DIR/bin/sente symlink 経由で exec するのでプロセス名は sente(sente_exec 参照)
  pgrep -x sente 2>/dev/null | wc -l | tr -d ' '
}

# 🐕 TUIウォッチドッグ(2026-08-17本人指示「たまにsente止まる。再接続とか状況見て進めて」):
# 対話TUI(sente_exec "$OC")を包み、API応答ハングを検知して再起動する。
# 検知: 子プロセスのCPU時間が TE_WATCHDOG_IDLE_S(既定180秒)増えない=無活動とみなす。
#   ・読み上げ中(/tmp/sente_speaking.lock)は誤検知防止で監視を止める
#   ・TTYあり=「再接続しますか?」と聞く / 非TTY(Sente.app等)=自動で再起動(3回まで)
# 再起動は `--continue` で直前セッションから復帰。ネットワーク断は先に疎通を確認し、
# 復帰するまで指数バックオフ(5→10→20→最大60秒)で待ってから再起動する。
# 記録: ~/Library/Logs/Sente/watchdog.jsonl。無効化=TE_NO_WATCHDOG=1
# 🩹 2026-08-17 修正: TUI本体を `(...) &` でバックグラウンドジョブ化すると、フォアグラウンド
# プロセスグループを失い raw mode 初期化が壊れ、画面にエスケープシーケンスが生で漏れる実障害
# が出た(起動直後から発生・実機で確認)。TUIは `&` を付けずフォアグラウンドのサブシェルとして
# 実行し(通常の子プロセス実行と同じ=TTY制御は不変)、監視だけを別プロセスとして先に走らせ、
# pgrep -P でTUIの子PIDを見つけて監視する形に変更。
SENTE_WD_LOG="$SENTE_LOG_DIR/watchdog.jsonl"
sente_wd_log() {  # $1=event $2=detail
  mkdir -p "$(dirname "$SENTE_WD_LOG")" 2>/dev/null || return 0
  printf '{"ts":"%s","event":"%s","detail":"%s"}\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S')" "$1" "$(printf '%s' "$2" | tr '"\n' "' ")" >> "$SENTE_WD_LOG" 2>/dev/null || true
}
# 💳 プラン(free / starter / pro / business / sente_pro)。/auth/me を 6 時間キャッシュ。取れない時は free 扱いにしない
# (fail-open="pro")=ネットワーク断で有料ユーザーを縛らないため。無料枠のゲート(声30分/日・te agent 1本)だけがこれを見る。
sente_plan() {
  SPC="$CONFIG_DIR/plan-cache"
  if [ -f "$SPC" ] && [ -n "$(find "$SPC" -mmin -360 2>/dev/null)" ]; then cat "$SPC"; return 0; fi
  [ -n "${TEAI_API_KEY:-}" ] || { echo pro; return 0; }
  SPJ="$(curl -s -m 5 -H "Authorization: Bearer $TEAI_API_KEY" "$TEAI_API/api/v1/auth/me" 2>/dev/null || true)"
  SPP="$(printf '%s' "$SPJ" | sed -n 's/.*"plan":"\([a-z_]*\)".*/\1/p' | head -1)"
  [ -n "$SPP" ] || { echo pro; return 0; }
  printf '%s' "$SPP" > "$SPC" 2>/dev/null || true
  echo "$SPP"
}
sente_voice_seconds_today() {  # 今日の声モードの発話秒数(turns.jsonl の ok/barge の dur 合計)
  [ -f "${SENTE_TURNS:-}" ] || { echo 0; return 0; }
  python3 - "$SENTE_TURNS" "$(date '+%Y%m%d')" <<'PYVQ' 2>/dev/null || echo 0
import json, sys
p, today = sys.argv[1], sys.argv[2]
tot = 0.0
try:
    for line in open(p, encoding="utf-8").readlines()[-3000:]:
        try: d = json.loads(line)
        except Exception: continue
        if not str(d.get("ts", "")).startswith(today): continue
        if d.get("outcome") not in ("ok", "barge"): continue
        try: tot += float(d.get("dur") or 0)
        except Exception: pass
except Exception:
    pass
print(int(tot))
PYVQ
}
SENTE_FREE_VOICE_SECONDS=1800   # 無料枠: 声モードは 1 日 30 分(発話時間ベース)。Sente Pro 以上は無制限
sente_voice_quota_check() {  # 声モード開始時・各ターン後に呼ぶ。超えていたら 1 回だけ告げて非0
  [ "$(sente_plan)" = "free" ] || return 0
  VQS="$(sente_voice_seconds_today)"
  [ "${VQS:-0}" -ge "$SENTE_FREE_VOICE_SECONDS" ] || return 0
  VQF="$CONFIG_DIR/voice-quota-notified-$(date '+%Y%m%d')"
  if [ ! -f "$VQF" ]; then
    : > "$VQF"
    koe_say_sync "今日の無料の音声時間、30分を使い切りました。Sente Pro なら無制限です。te pro で案内を開けます。"
    printf '  💳 無料枠の音声時間(1日30分)を使い切りました。Sente Pro=無制限: te pro\n' >&2
  fi
  return 1
}

sente_api_ok() {  # API疎通(3秒)。0=届く
  [ -n "${TEAI_API_KEY:-}" ] || return 0   # キー無し=ローカル動作のみとみなし監視対象外
  curl -s -o /dev/null -m 3 -H "Authorization: Bearer $TEAI_API_KEY" "$TEAI_API/api/v1/auth/me" 2>/dev/null
}
_sente_wd_monitor() {  # $1=親シェルPID $2=idle上限秒 $3=再起動フラグファイル。TUI本体には一切触れずpgrepで探して監視する
  WD_PARENT="$1"; WD_IDLE_MAX="$2"; WD_FLAG="$3"
  # 🪤 `pgrep -P <ppid>` は macOS の実装によっては親フィルタが無視され、名前一致する
  #   全プロセス(別セッションの sente を含む)を返す(2026-09-11 実機: `-P 1` と
  #   `-P 999999` が同じ結果)。head -1 で拾うと**別の sente を監視対象に選び**、
  #   その別プロセスを renice/kill しかねない。親は ps で自分で絞る(PPID 完全一致)。
  WD_TUI_PID=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    WD_TUI_PID="$(ps -eo pid=,ppid=,comm= 2>/dev/null | awk -v p="$WD_PARENT" -v n="${SENTE_PROC_NAME:-sente}" '
      { pid=$1; ppid=$2; c=$3; sub(/^.*\//, "", c); if (ppid==p && c==n) { print pid; exit } }')"
    [ -n "$WD_TUI_PID" ] && break
    sleep 0.5
  done
  [ -z "$WD_TUI_PID" ] && return 0
  renice -n 10 -p "$WD_TUI_PID" >/dev/null 2>&1 || true
  WD_LAST_CPU=-1; WD_IDLE=0
  while kill -0 "$WD_TUI_PID" 2>/dev/null; do
    sleep 5
    kill -0 "$WD_TUI_PID" 2>/dev/null || break
    # 読み上げ中は監視しない(自分の声をハングと誤認するため)
    if [ -f /tmp/sente_speaking.lock ]; then WD_IDLE=0; continue; fi
    WD_CPU="$(ps -o time= -p "$WD_TUI_PID" 2>/dev/null | awk -F: '{s=0;m=1;for(i=NF;i>=1;i--){s+=$i*m;m*=60};print s}' 2>/dev/null)"
    case "$WD_CPU" in ''|*[!0-9]*) WD_IDLE=0; continue ;; esac
    if [ "$WD_CPU" = "$WD_LAST_CPU" ]; then
      WD_IDLE=$((WD_IDLE + 5))
    else
      WD_IDLE=0; WD_LAST_CPU="$WD_CPU"
    fi
    if [ "$WD_IDLE" -ge "$WD_IDLE_MAX" ]; then
      sente_wd_log hang "idle=${WD_IDLE}s pid=$WD_TUI_PID"
      if [ -t 0 ] && [ -t 1 ]; then
        printf '\n  ⏳ %s秒応答がありません。再接続しますか? [Y/n]: ' "$WD_IDLE" >&2
        WD_ANS="$(head -1 /dev/tty 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
        case "$WD_ANS" in n|no) WD_IDLE=0; continue ;; esac
      else
        printf '  🔌 応答がないため自動で再接続します\n' >&2
      fi
      kill -TERM "$WD_TUI_PID" 2>/dev/null; sleep 2; kill -KILL "$WD_TUI_PID" 2>/dev/null
      rm -f /tmp/sente_speaking.lock
      # ネットワーク断なら復帰を待つ(指数バックオフ・最大60秒)
      WD_BACK=5
      while ! sente_api_ok; do
        printf '  🔌 ネットワーク待機中…(%ss)\n' "$WD_BACK" >&2
        sleep "$WD_BACK"
        WD_BACK=$((WD_BACK * 2)); [ "$WD_BACK" -gt 60 ] && WD_BACK=60
      done
      sente_wd_log restart "with --continue"
      touch "$WD_FLAG" 2>/dev/null
      return 0
    fi
  done
}
sente_tui_watchdog() {  # 以降=opencodeへの引数。戻り値=最後の子の終了コード
  # 🔁 TUIが「コンパクトして再起動」(/restart or 会話乱れ検知の2回目)を頼む時の終了コード。
  # TUIは process.exitCode にこれを立てて終了→ここで --resume 付きで再起動する
  SENTE_RESTART_EXIT_CODE="${SENTE_RESTART_EXIT_CODE:-75}"; export SENTE_RESTART_EXIT_CODE
  # 🪤 TE_NO_WATCHDOG=1 は exec で置き換える(=この関数から戻らない)。done-guard(下の非TTY run)は
  #    `{ sente_tui_watchdog; echo $? > rc; } | tee` で終了コードを拾うので、exec されると rc が書かれず
  #    常に失敗扱い(exit 1)になっていた(2026-09-10 Ubuntu systemd 実機: agent が毎回 status=1)。
  #    launchd/systemd の agent は TE_NO_WATCHDOG=1 で動くので直撃。SENTE_WD_NO_EXEC=1 なら子で走らせて戻る
  if [ "${TE_NO_WATCHDOG:-0}" = "1" ]; then
    if [ "${SENTE_WD_NO_EXEC:-0}" = "1" ]; then ( sente_exec "$@" ); return $?; fi
    sente_exec "$@"
  fi
  WD_IDLE_MAX="${TE_WATCHDOG_IDLE_S:-180}"
  WD_RETRIES=0; WD_MAX_RETRIES=3
  WD_RESTARTS=0; WD_MAX_RESTARTS=5
  WD_ARGS="$*"
  WD_FLAG="/tmp/sente_wd_restart.$$"
  while :; do
    rm -f "$WD_FLAG"
    _sente_wd_monitor "$$" "$WD_IDLE_MAX" "$WD_FLAG" & MON_PID=$!
    disown "$MON_PID" 2>/dev/null || true   # dash に disown は無い(exit 127) → set -e で死なないよう保険
    # TUI本体は `&` を付けずフォアグラウンドのサブシェルとして実行(TTY制御を一切変えない)
    ( sente_exec "$@" )
    WD_ST=$?
    kill "$MON_PID" 2>/dev/null; wait "$MON_PID" 2>/dev/null
    if [ -f "$WD_FLAG" ]; then
      rm -f "$WD_FLAG"
      if [ ! -t 0 ] || [ ! -t 1 ]; then
        WD_RETRIES=$((WD_RETRIES + 1))
        [ "$WD_RETRIES" -gt "$WD_MAX_RETRIES" ] && { sente_wd_log giveup "retries=$WD_RETRIES"; return 1; }
      fi
      # 直前セッションを開き、途中で止まっていた作業は自動で再開(--resume)
      sente_wd_relaunch_args --resume; set -- $WD_ARGS
      continue
    fi
    if [ "$WD_ST" = "$SENTE_RESTART_EXIT_CODE" ]; then
      # TUI自身の「コンパクトして再起動して続き」要求
      WD_RESTARTS=$((WD_RESTARTS + 1))
      if [ "$WD_RESTARTS" -gt "$WD_MAX_RESTARTS" ]; then sente_wd_log giveup "restarts=$WD_RESTARTS"; return 1; fi
      sente_wd_log restart "requested by tui (exit $WD_ST) → --resume"
      printf '  🔁 コンパクトしました。先手を再起動して続きから進めます…\n' >&2
      sente_wd_relaunch_args --resume; set -- $WD_ARGS
      continue
    fi
    return "$WD_ST"
  done
}
sente_wd_relaunch_args() {  # $1=付け足すフラグ。既存の -c/--continue/-r/--resume は重複しないよう落として再構成
  WD_NEXT=""
  for WD_A in $WD_ARGS; do
    case "$WD_A" in -c|--continue|-r|--resume) ;; *) WD_NEXT="$WD_NEXT $WD_A" ;; esac
  done
  set -- $WD_NEXT "$1"
  WD_ARGS="$*"
}

oc_run_guarded() {  # 声モード用: $1=上限秒、以降=opencodeへの引数。固まったら殺して1回だけやり直す
  GW="$1"; shift
  for GT in 1 2; do
    ( sente_exec "$@" ) & GP=$!
    # 🐢 バックグラウンド作業の優先度を下げて Mac 本体の応答性を守る(2026-08-16リソースガード)
    renice -n 10 -p "$GP" >/dev/null 2>&1 || true
    # 🛑 中断用: 実行中の子PIDを書き出す(sente_run_watchedが監視してkillする)。
    # 監視していない呼び出し元(te serve等)はSENTE_OC_PIDFILE未設定なので何もしない
    [ -n "${SENTE_OC_PIDFILE:-}" ] && printf '%s' "$GP" > "$SENTE_OC_PIDFILE" 2>/dev/null || true
    # ⚠watchdogのfdは必ず切り離す: te serveは OUT="$(oc_run_guarded ...)" のコマンド置換で呼ぶため、
    # ここでパイプを継承すると、opencodeが完走してもwatchdogの`sleep`がEOFを握ったまま
    # タイムアウト満了までコマンド置換がブロックする(実測: 完走後に丸5分待つ実障害)。
    ( sleep "$GW"; kill -TERM $GP 2>/dev/null; sleep 2; kill -KILL $GP 2>/dev/null ) >/dev/null 2>&1 & GK=$!
    # waitだけstderrを捨てる: 打ち切った時にシェルが出す "Terminated: 15" を見せないため。
    # opencode本体のstderrは既に端末へ直結しているのでここでは失われない。
    { wait $GP; GS=$?; } 2>/dev/null
    kill $GK 2>/dev/null; { wait $GK; } 2>/dev/null
    [ "$GS" = 0 ] && return 0
    # 打ち切ると読み上げプラグインのlockが残り、次の録音が始まらなくなる
    rm -f /tmp/sente_speaking.lock
    if [ "$GT" = 1 ]; then
      echo "  ⚠ 応答が返らないのでやり直します(1回だけ)" >&2
      koe_sfx err
      # 残骸が居ると次も固まるので、確実に終わらせてから再試行する
      pgrep -x sente 2>/dev/null | while read -r GZ; do kill -KILL "$GZ" 2>/dev/null; done
      sleep 1
    fi
  done
  return 1
}

sente_kill_filler() {  # 相槌(考え中の相槌)の再生ジョブを後片付け(中断時に呼ぶ・放置しない)
  if [ -n "${FILLER_PID:-}" ]; then
    kill -KILL "$FILLER_PID" 2>/dev/null || true
    wait "$FILLER_PID" 2>/dev/null || true
    FILLER_PID=""
  fi
  if [ -n "${CTXF_PID:-}" ]; then
    kill -KILL "$CTXF_PID" 2>/dev/null || true
    wait "$CTXF_PID" 2>/dev/null || true
    CTXF_PID=""
    rm -f /tmp/sente_ctx_playing
  fi
}

# 🛑 考え中の中断(従来パス=oc_run_guarded用): KB=1のときだけ実行を裏に回してPID監視+
# キー監視する。Enter/Esc(または任意のキー)が来たら自分が起動した子(opencodeそのもの)
# だけをkillして「⏹ やめました」で復帰する。KB=0(端末なし)では監視を入れず、
# 従来どおり同期実行する(この分岐は壊さない)。
sente_run_watched() {  # $1=秒、以降=oc_run_guardedへの引数(run ...)。中断時はRW_CANCELLED=1
  RW_CANCELLED=0
  if [ "$KB" != 1 ]; then
    oc_run_guarded "$@" || true
    return 0
  fi
  SENTE_OC_PIDFILE="${TMPDIR:-/tmp}/sente_oc_run.pid.$$"
  export SENTE_OC_PIDFILE
  rm -f "$SENTE_OC_PIDFILE"
  oc_run_guarded "$@" & RW_PID=$!
  while kill -0 "$RW_PID" 2>/dev/null; do
    sente_kb_read
    if [ -n "$K" ]; then
      case "$K" in "$SENTE_NL"|"$SENTE_CR"|"$SENTE_ESC") ;; "$SENTE_BS"|"$SENTE_DEL") PRE_KEY="${PRE_KEY%?}" ;; *) PRE_KEY="${PRE_KEY}$K" ;; esac   # 追記式: 上書きすると先に押した文字が消える(「DeepSeek」→「eepSeek」実障害)
      RW_CANCELLED=1
      break
    fi
    sleep 0.2
  done
  if [ "$RW_CANCELLED" = 1 ]; then
    RW_OC_PID="$(cat "$SENTE_OC_PIDFILE" 2>/dev/null || true)"
    kill -KILL "$RW_PID" 2>/dev/null || true
    [ -n "$RW_OC_PID" ] && kill -KILL "$RW_OC_PID" 2>/dev/null || true
    wait "$RW_PID" 2>/dev/null || true
    rm -f /tmp/sente_speaking.lock "$SENTE_OC_PIDFILE"
    sente_stop_speaking
    printf '  ⏹ やめました。どうぞ\n' >&2
    koe_sfx err
    return 1
  fi
  wait "$RW_PID" 2>/dev/null || true
  rm -f "$SENTE_OC_PIDFILE"
  return 0
}

# 音声モードの人格 =「先手」: 一歩先を読む相棒。声に向く話し方だけする
SENTE_PERSONA=" — (音声対話モード。あなたは『Sente/先手』、囲碁の先手のように一歩先を読む相棒。①結論を短い一文で言い切る ②必要なら補足を一文だけ ③最後に先回りの「次の一手」をひとつだけ提案。記号・箇条書き・URL・コード読み上げは使わず、自然な話し言葉で。知らないこと・確認していないこと(天気・時刻・ニュースなど)は、それらしく言い切らずに正直にそう言うか、調べてから答える。挨拶にはひとことで応え、頼まれていない提案や豆知識を足さない。「何ができる?」と聞かれたら具体的に: コードを書く・直す・調べる・ファイルやコマンドの操作・裏での長作業・今日の会話のまとめ、ができると答える。聞き慣れない言葉が出たら止まらず、文脈から一番ありそうな意味を一言で仮定して先に進み(「◯◯は△△のことですよね、その前提で」)、あとで確かめる。仮定のまま、送信・削除・支払いなど取り消せないことはしない。)"

# 🚄 talk常駐モード(ACP): opencode acp を1本だけ立て、毎ターンの起動コスト(~3s)と
# 「稀に起動直後で固まる」問題の構造を消す。実測: 一往復 6.7s→3.9s・文脈もセッション継続で自然。
# ドライバ(python3)とはFIFO越しの行プロトコル: 1行=1プロンプト / 返答テキスト行…\x1eOK。
# 既定ON・TE_TALK_ACP=0 か python3不在で従来のターン毎起動(oc_run_guarded)に自動フォールバック。
ensure_acp_driver() {
  cat > "$CONFIG_DIR/sente-acp.py" <<'ACPPY'
#!/usr/bin/env python3
# Sente ACP driver — opencode acp を常駐させる。stdin 1行=1プロンプト。
# 返答は文の区切りが来るたびに「SAY:<文>」を1行で即flushし、生成が終わったら
# 「END:<全文>」→ 制御行(\x1eOK / \x1eERR <理由>)。起動直後に \x1eREADY。
# ツール実行中は「NOTE:<一言>」を差し込む(長作業の実況・同種連続は抑制・8秒に1回まで)。
# (旧: 生成完了後に全文をまとめて返す方式 → 文ごとストリーミングに拡張。
#  呼び出し側shは SAY:/END:/NOTE: のプレフィックスで分岐する)
import json, subprocess, sys, os, threading, queue, time, atexit, signal

TIMEOUT = float(os.environ.get("TE_VOICE_TIMEOUT", "90"))

def out(line):
    sys.stdout.write(line + "\n"); sys.stdout.flush()

# 🔤 文の区切り(句点・感嘆符・疑問符・改行)ごとにバッファを切り出す純粋関数。
# 副作用が無いので、opencode acp を起動せずに単体テストできる(mainの外に出す)。
SENT_BOUNDARY = "。．!！?？\n"

def feed_chunk(buf, chunk):
    """buf(まだ文が確定していない残り)にchunkを足し、区切りが来るたびに文を切り出す。
    戻り値: (確定した文のリスト, 新しい残り)"""
    buf += chunk
    sentences = []
    start = 0
    for i, ch in enumerate(buf):
        if ch in SENT_BOUNDARY:
            s = buf[start:i + 1].strip()
            if s:
                sentences.append(s)
            start = i + 1
    return sentences, buf[start:]


# 🔧 ツール実行の実況(session/update の "tool_call" で来る kind → 短い一言)。
# ACPの実出力を実測して確認した対応: bash実行=execute / ファイル読み=read / grep等の検索=search /
# 書き込み・編集=edit。未知のkind(delete/move/fetch/think/other等)は「作業中」に丸める。
TOOL_KIND_NOTE = {
    "execute": "コマンド実行中",
    "read": "コード読んでます",
    "search": "コード読んでます",
    "edit": "書き換え中",
}
NOTE_DEFAULT = "作業中"
NOTE_RATE_LIMIT_S = 8.0


class ToolNoteThrottle:
    """「同種連続は抑制」+「NOTE全体で8秒に1回まで」を担う純粋なステートマシン。
    時刻はfeed()の引数で外から渡すので、opencode acpを起動せず単体テストできる。"""

    def __init__(self, min_interval=NOTE_RATE_LIMIT_S):
        self.min_interval = min_interval
        self.last_category = None
        self.last_emit_ts = None  # None = まだ一度もNOTEを出していない

    def feed(self, kind, now):
        """新しいtool_call(kind)を1件処理。通知すべきなら一言テキストを返す。抑制ならNone。"""
        category = kind if kind in TOOL_KIND_NOTE else "other"
        if category == self.last_category:
            return None  # 同種連続は抑制(種類が変わるまで黙る)
        self.last_category = category
        if self.last_emit_ts is not None and (now - self.last_emit_ts) < self.min_interval:
            return None  # レート制限(直近のNOTEから8秒経っていない)
        self.last_emit_ts = now
        return TOOL_KIND_NOTE.get(kind, NOTE_DEFAULT)


def main():
    p = subprocess.Popen(["opencode", "acp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, env=dict(os.environ))
    def _cleanup(*_):
        try: p.terminate()
        except Exception: pass
        sys.exit(0)
    atexit.register(_cleanup)
    signal.signal(signal.SIGTERM, _cleanup)

    q = queue.Queue()
    def reader():
        for line in p.stdout:
            q.put(line.decode(errors="replace").rstrip("\n"))
        q.put(None)
    threading.Thread(target=reader, daemon=True).start()

    rid = 0
    def send(obj):
        p.stdin.write((json.dumps(obj) + "\n").encode()); p.stdin.flush()

    def rpc(method, params, timeout, on_notify=None):
        nonlocal rid; rid += 1
        send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        t0 = time.time()
        while time.time() - t0 < timeout:
            try:
                line = q.get(timeout=1)
            except queue.Empty:
                continue
            if line is None:
                return None  # opencode死亡
            try:
                msg = json.loads(line)
            except Exception:
                continue
            if msg.get("id") == rid:
                return msg
            if on_notify:
                on_notify(msg)
        return {"timeout": True}

    r = rpc("initialize", {"protocolVersion": 1, "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False}}}, 30)
    r2 = rpc("session/new", {"cwd": os.getcwd(), "mcpServers": []}, 30) if (r and "result" in r) else None
    SID = ((r2 or {}).get("result") or {}).get("sessionId")
    if not SID:
        out("\x1eERR init"); sys.exit(1)
    out("\x1eREADY")

    # ⚙ ツール実況の抑制/レート制限はターンをまたいで保つ(1ターン内の連発だけでなく、
    # 前のターンの最後のツールと次のターンの最初のツールが同種でも続けて喋らせない)
    note_throttle = ToolNoteThrottle()

    for raw in sys.stdin:
        text = raw.rstrip("\n")
        if not text:
            continue
        chunks = []
        buf = {"s": ""}
        def on_n(msg):
            u = ((msg.get("params") or {}).get("update") or {})
            su = u.get("sessionUpdate")
            if su == "agent_message_chunk":
                c = (u.get("content") or {})
                if c.get("type") == "text":
                    t = c.get("text") or ""
                    if not t:
                        return
                    chunks.append(t)
                    sentences, rest = feed_chunk(buf["s"], t)
                    buf["s"] = rest
                    for s in sentences:
                        out("SAY:" + s)
            elif su == "tool_call":
                # 🔧 新しいツール呼び出しの最初の通知だけを見る(kindがここで来る。
                # 以後のtool_call_update(in_progress/completed)は同じ呼び出しの続きなので無視)
                note = note_throttle.feed(u.get("kind"), time.time())
                if note:
                    out("NOTE:" + note)
        res = rpc("session/prompt", {"sessionId": SID, "prompt": [{"type": "text", "text": text}]}, TIMEOUT, on_n)
        if res is None:
            out("\x1eERR dead"); sys.exit(1)
        if res.get("timeout"):
            # 打ち切り: 走り続けないよう割り込みを送ってから次のターンへ
            send({"jsonrpc": "2.0", "method": "session/cancel", "params": {"sessionId": SID}})
            out("\x1eERR timeout"); continue
        reply = "".join(chunks).strip()
        # 全文はEND行で渡す(改行はスペースに畳んで1行を守る)。呼び出し側の最終テキストはこれを使う
        out("END:" + reply.replace("\n", " ").replace("\r", " "))
        out("\x1eOK")


if __name__ == "__main__":
    main()
ACPPY
}

ACP_CTRL="$(printf '\036')"
ACP_ON=0; ACP_DIR=""; ACP_PID=""

# 🔊 音量を揃えて再生(2026-08-06本人指示「声のボリュームを均一にして」):
# TTS上流(RunPod=loudnorm有効 / 予備m5=無効)やキャッシュ時期で音圧が-34〜-14LUFSまでバラつく実測。
# どの経路の音でも、再生直前にmean_volumeを測って目標-20dBへ寄せる(±2dB以内は素通し・処理は~0.3s)。
# ffmpegが無い環境は従来どおり素のまま鳴らす。
sente_play() {  # $1=音声ファイル
  SEPP="afplay"; command -v afplay >/dev/null 2>&1 || SEPP="mpg123"
  if command -v ffmpeg >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    SEPM="$(ffmpeg -i "$1" -af volumedetect -f null /dev/null 2>&1 | sed -n 's/.*mean_volume: \(-\{0,1\}[0-9.]*\) dB.*/\1/p')"
    if [ -n "$SEPM" ]; then
      SEPG="$(python3 -c 'import sys;m=float(sys.argv[1]);g=-20.0-m;g=max(-12.0,min(24.0,g));print(0 if abs(g)<2.0 else round(g,1))' "$SEPM" 2>/dev/null || echo 0)"
      if [ "${SEPG:-0}" != "0" ]; then
        SEPN="${1}.norm.mp3"
        if ffmpeg -y -i "$1" -af "volume=${SEPG}dB" -c:a libmp3lame -b:a 96k "$SEPN" >/dev/null 2>&1; then
          "$SEPP" "$SEPN" >/dev/null 2>&1 || true
          rm -f "$SEPN"
          return 0
        fi
        rm -f "$SEPN"
      fi
    fi
  fi
  "$SEPP" "$1" >/dev/null 2>&1 || true
}

# 🚀 2026-09-10 並列合成(prefetch): 旧実装は文が届くたびに drainer が1文ずつ
# 「合成(8〜40s)→再生」を直列で回していた。LLMは数秒で全文を出すのに、声は
# 3文の返事で 3×合成時間 待たされていた(実測: 合成 miss 8〜11s/文)。
# 新実装は enqueue の時点で各文の合成を裏で即開始し(文ごとに1ジョブ・並列)、
# drainer は「順番に再生するだけ」。初回の待ちは1文目の合成時間だけ、2文目以降は
# 既に合成済みで即鳴る。再生は従来どおり直列=声は重ならない。
# 状態は FIFO ではなくファイルで持つ(合成ジョブと再生側で受け渡すため):
#   $SAY_DIR/seq       … 次に発番する番号
#   $SAY_DIR/q.<n>     … その文のテキスト(合成ジョブが読む)
#   $SAY_DIR/a.<n>.mp3 … 合成結果(完成したら .done を置く)
#   $SAY_DIR/turn_end  … ターン終了マーカー(空ファイル)
SENTE_SAY_DIR=""
SENTE_SAY_DRAINER_PID=""

sente_say_drainer_start() {
  # 🪤 PIDはファイルで持つ($$はサブシェルでも親のまま=セッション内で共通のパスになる)。
  # 変数だけだと、enqueueがraceのサブシェルから呼ばれた時に親へPIDが戻らず、毎ターン
  # 新しいdrainerが増殖 → 古いキューを握ったゾンビが2秒ごとに sente_speaking.lock を
  # 消し続け、読み上げ中に録音が開いて自問自答ループの温床になっていた(2026-08-06実ログの真因のひとつ)
  SD_PIDF="${TMPDIR:-/tmp}/sente_say_drainer.pid.$$"
  SD_OLD="$(cat "$SD_PIDF" 2>/dev/null)"
  [ -n "$SD_OLD" ] && kill -0 "$SD_OLD" 2>/dev/null && return 0
  SENTE_SAY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sente_say_XXXXXX")" || return 1
  printf '0\n' > "$SENTE_SAY_DIR/seq"
  (
    SDP="afplay"; command -v afplay >/dev/null 2>&1 || SDP="mpg123"
    SDN=0
    while :; do
      SDM="$SENTE_SAY_DIR/a.$SDN.mp3"
      # 次の文が来るまで最大2秒待つ(来なければキューは空=lockを外す)
      SDW=0
      while [ ! -f "$SDM.done" ] && [ ! -f "$SENTE_SAY_DIR/turn_end" ] && [ ! -f "$SENTE_SAY_DIR/stop" ]; do
        [ -f "$SENTE_SAY_DIR/q.$SDN" ] || { sleep 0.1; SDW=$((SDW+1)); [ "$SDW" -gt 20 ] && break; }
        [ -f "$SENTE_SAY_DIR/q.$SDN" ] && break
      done
      if [ -f "$SENTE_SAY_DIR/turn_end" ] && [ ! -f "$SDM.done" ] && [ ! -f "$SENTE_SAY_DIR/q.$SDN" ]; then
        rm -f /tmp/sente_turn_open "$SENTE_SAY_DIR/turn_end"
        rm -f /tmp/sente_speaking.lock
        continue
      fi
      [ -f "$SENTE_SAY_DIR/q.$SDN" ] || { rm -f /tmp/sente_speaking.lock; continue; }
      # 合成完了(.done)まで待つ。合成ジョブは enqueue 時に既に走っている=既に出来ている事が多い
      SDW=0
      while [ ! -f "$SDM.done" ] && [ ! -f "$SENTE_SAY_DIR/stop" ] && [ "$SDW" -lt 300 ]; do
        sleep 0.1; SDW=$((SDW+1))
      done
      if [ -f /tmp/sente_say_stop ] || [ -f "$SENTE_SAY_DIR/stop" ]; then
        # 停止指示: この文だけでなく、先読みで既に積まれている残りも全部捨てる
        # (次ターンで古い文が遅れて鳴る事故を防ぐ)。番号は最後まで進めて揃える
        rm -f "$SDM" "$SDM.done" "$SENTE_SAY_DIR/q.$SDN"
        SDLAST="$(cat "$SENTE_SAY_DIR/seq" 2>/dev/null || echo "$SDN")"
        while [ "$SDN" -lt "$SDLAST" ]; do
          SDN=$((SDN+1)); rm -f "$SENTE_SAY_DIR/a.$SDN.mp3" "$SENTE_SAY_DIR/a.$SDN.mp3.done" "$SENTE_SAY_DIR/q.$SDN"
        done
        rm -f "$SENTE_SAY_DIR/turn_end" /tmp/sente_turn_open /tmp/sente_speaking.lock
        continue
      fi
      if [ -s "$SDM" ]; then
        # 二段目の合いの手(文脈復唱)が鳴っている間は少し待って声を重ねない(上限5秒=詰まり防止)
        SDW2=0; while [ -f /tmp/sente_ctx_playing ] && [ "$SDW2" -lt 16 ]; do sleep 0.3; SDW2=$((SDW2+1)); done
        : > /tmp/sente_speaking.lock
        sente_play "$SDM"
      fi
      rm -f "$SDM" "$SDM.done" "$SENTE_SAY_DIR/q.$SDN"
      SDN=$((SDN+1))
    done
  ) &
  SENTE_SAY_DRAINER_PID=$!
  printf '%s\n' "$SENTE_SAY_DRAINER_PID" > "$SD_PIDF" 2>/dev/null || true
}

# 1文を裏で合成して $SAY_DIR/a.<n>.mp3 に置く(完成時に .done)。並列に何本でも走る。
sente_say_synth_job() {  # $1=番号 $2=テキスト(speakify済み)
  (
    SDT="$(printf '%s' "$2" | sente_speakify)"; [ -n "$SDT" ] || exit 0
    SDM="$SENTE_SAY_DIR/a.$1.mp3"
    if curl -s -m 40 -o "$SDM" -X POST "${KOE_BASE:-https://koe.live}/api/speak" \
         -H 'Content-Type: application/json' \
         -d "$(python3 -c 'import json,sys;print(json.dumps({"text":sys.argv[1],"user_id":sys.argv[2],"source":"sente"}))' "$SDT" "${KOE_VOICE:-yuki}")" \
       && [ -s "$SDM" ]; then
      : > "$SDM.done"
    else
      rm -f "$SDM"
    fi
  ) &
}

sente_say_enqueue() {  # $1=文 — 読み上げキューに積む(ミュート中は何もしない)
  sente_muted && return 0
  [ -n "$1" ] || return 0
  sente_say_drainer_start || return 0
  # 実セグメントを積む時にターンを開���(録音側はこれが消えるまで待つ)。停止指示中は開かない
  # (直APIが勝った後に遅れて届くセグメントがターンを開き直すと、録音が再開できなくなる)
  if [ "$1" != "@@SAY_TURN_END@@" ] && [ ! -f /tmp/sente_say_stop ]; then : > /tmp/sente_turn_open; fi
  if [ "$1" = "@@SAY_TURN_END@@" ]; then
    : > "$SENTE_SAY_DIR/turn_end"
    return 0
  fi
  SDN="$(cat "$SENTE_SAY_DIR/seq" 2>/dev/null || echo 0)"
  printf '%s\n' "$((SDN + 1))" > "$SENTE_SAY_DIR/seq"
  printf '%s\n' "$1" > "$SENTE_SAY_DIR/q.$SDN" 2>/dev/null || true
  sente_say_synth_job "$SDN" "$1"   # 🚀 即裏で合成開始(再生は待たない)
}

sente_say_turn_end() {  # 返答ターンの終わりをdrainerへ知らせる(セグメントを流していなければ何もしない)
  [ -f /tmp/sente_turn_open ] || return 0
  sente_say_enqueue "@@SAY_TURN_END@@"
}

sente_say_drainer_stop() {
  SD_PIDF="${TMPDIR:-/tmp}/sente_say_drainer.pid.$$"
  SD_OLD="$(cat "$SD_PIDF" 2>/dev/null)"
  if [ -n "$SD_OLD" ]; then
    kill "$SD_OLD" 2>/dev/null || true
    wait "$SD_OLD" 2>/dev/null || true   # 自分の子なら回収=「Terminated: 15」をターミナルに漏らさない
  fi
  SENTE_SAY_DRAINER_PID=""
  [ -n "$SENTE_SAY_DIR" ] && rm -rf "$SENTE_SAY_DIR" 2>/dev/null
  SENTE_SAY_DIR=""
  rm -f "$SD_PIDF" /tmp/sente_turn_open
}

# ⚙ ツール実行の実況を短く読む($1=一言)。応答本体の読み上げと同じlockを見るので、
# 読み上げ中(=lockが立っている)なら何もせず黙って捨てる — 実況で会話を邪魔しないため。
# 非同期(裏で1回きり合成→再生)・失敗は無視。レート制限/同種抑制はACPドライバ側で既に済んでいる
sente_note_speak() {
  sente_muted && return 0
  [ -f /tmp/sente_speaking.lock ] && return 0
  [ -n "$1" ] || return 0
  SNT="$(printf '%s' "$1" | sente_speakify)"; [ -n "$SNT" ] || return 0
  set -- "$SNT"
  (
    : > /tmp/sente_speaking.lock
    SNP="afplay"; command -v afplay >/dev/null 2>&1 || SNP="mpg123"
    SNM="$(mktemp "${TMPDIR:-/tmp}/sente_note_XXXXXX").mp3"
    if curl -s -m 15 -o "$SNM" -X POST "${KOE_BASE:-https://koe.live}/api/speak" \
         -H 'Content-Type: application/json' \
         -d "$(python3 -c 'import json,sys;print(json.dumps({"text":sys.argv[1],"user_id":sys.argv[2],"source":"sente"}))' "$1" "${KOE_VOICE:-yuki}")" \
       && [ ! -f /tmp/sente_say_stop ]; then
      sente_play "$SNM"
    fi
    rm -f "$SNM" /tmp/sente_speaking.lock
  ) &
}

acp_stop() {
  # 🪤 execはコマンド無しだとリダイレクトがこのシェル自身に「その場限りでなく」ずっと効く。
  # 以前は`exec 8>&- 2>/dev/null`と書いていて、fd8のクローズのついでにfd2(stderr)を
  # 恒久的に/dev/nullへ付け替えてしまい、以後このプロセスの>&2出力(talk終了時の
  # 「おつかれさま」含む)が全部消える実障害があった(中断→ACP作り直しで踏んだ)。
  # fd8/9はacp_start成功時のみ開くので、ここでの2>/dev/nullは不要(付けない)。
  exec 8>&-; exec 9<&-
  if [ -n "$ACP_PID" ]; then
    pkill -P "$ACP_PID" 2>/dev/null || true  # driverの子(opencode acp)を置き去りにしない
    kill "$ACP_PID" 2>/dev/null || true
    wait "$ACP_PID" 2>/dev/null || true      # waitで回収=「Terminated」をターミナルに漏らさない
  fi
  [ -n "$ACP_DIR" ] && rm -rf "$ACP_DIR" 2>/dev/null
  ACP_PID=""; ACP_ON=0
  sente_say_drainer_stop
}

# 🚀 起動高速化(2026-08-10本人指示「起動までめっちゃ早くして」): 従来のacp_startは
# opencode初期化(実測~2s)をREADYまで同期で待ち、それが起動の最長ブロックだった。
# spawn(即返り)とwait_ready(初回ターン直前で待つ)に分離 — 初回ターンまでには挨拶+
# 発話+録音+STTで数秒あるので、体感からREADY待ちがほぼ消える。
acp_spawn() {  # 常駐を起動だけして即返る(READYは待たない)
  ACP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sente_acp_XXXXXX")" || return 1
  mkfifo "$ACP_DIR/req" "$ACP_DIR/resp" 2>/dev/null || { rm -rf "$ACP_DIR"; return 1; }
  # 読み上げはte自身が行う(ACPモードではopencode側プラグインが発火しないと実測)ので、
  # 万一将来発火しても二重にならないようドライバ側はAGENT_KOE=0で立てる
  AGENT_KOE=0 python3 "$CONFIG_DIR/sente-acp.py" < "$ACP_DIR/req" > "$ACP_DIR/resp" 2>"$ACP_DIR/err.log" &
  ACP_PID=$!
  exec 8> "$ACP_DIR/req" 9< "$ACP_DIR/resp"
  return 0
}
# 🪤 READY済みの印は変数でなくファイル($ACP_DIR/ready)に置く: acp_turnはサブシェル内で走るため、
# 変数だと親に伝わらず「2ターン目が消費済みREADYを45秒待って正常な常駐を殺す」事故になる
acp_wait_ready() {  # opencode初期化完了を待つ
  [ -n "$ACP_DIR" ] && [ -f "$ACP_DIR/ready" ] && return 0
  [ -n "$ACP_PID" ] || return 1
  [ -n "$ACP_DIR" ] && [ -f "$ACP_DIR/dead" ] && return 1
  ACP_I=0
  while [ "$ACP_I" -lt 45 ]; do   # opencode初期化待ち(実測~2s・上限45s)
    if IFS= read -r -t 1 ACP_L <&9 2>/dev/null; then
      case "$ACP_L" in
        "${ACP_CTRL}READY") : > "$ACP_DIR/ready" 2>/dev/null; return 0 ;;
        "${ACP_CTRL}ERR"*) break ;;
      esac
    fi
    kill -0 "$ACP_PID" 2>/dev/null || break
    ACP_I=$((ACP_I+1))
  done
  # 失敗: acp_turn経由=サブシェル内から呼ばれるため、ここで壊すと親のACP_ON=1と食い違ったまま
  # になる → dead印だけ残して返す。掃除と作り直しは親側(sente_race_watched冒頭/acp_start)が行う
  : > "$ACP_DIR/dead" 2>/dev/null
  return 1
}
acp_start() {  # 従来互換(親プロセスの再起動経路用): spawn+READY待ち+失敗時は完全掃除
  acp_spawn || return 1
  if acp_wait_ready; then return 0; fi
  acp_stop; return 1
}

acp_turn() {  # $1=プロンプト → 返答テキスト(END:の中身)をstdoutへ。失敗/タイムアウト=非0
              # 届いた「SAY:<文>」は順に①ターミナル表示②読み上げキューへ即積む。
              # 届いた「NOTE:<一言>」はツール実行中の実況①ターミナル表示②手が空いていれば軽く読む
              # (抑制/レート制限はドライバ側で済んでいるので、ここは来たものをそのまま出すだけ)。
              # 「END:<全文>」がこの関数の返り値(sente_raceが受け取る$RC_DIR/fullの中身は
              # 従来どおり本文だけ=呼び出し側のプロトコルは変えない)
  acp_wait_ready || return 1   # 🚀 起動時はspawnのみ→初回ターンのここで初期化完了を待つ(通常は既にREADY)
  rm -f /tmp/sente_say_stop   # 新しいターンの読み上げが始まる合図(koe_speak_textと同じ流儀)
  # 🪤 絶対パス(先頭が"/")で始まる依頼は、opencode acp がスラッシュコマンドの
  # 呼び出しと誤認して黙って無視する(session/updateもagent_message_chunkも
  # 一切来ずend_turnだけ返る・実測で再現・classic run経路では起きない)。
  # 「フルパスに hello と書いて」等、絶対パス指定はごく普通に起きるので、
  # 先頭に幅を持たない中黒を1文字添えて回避する(意味は変えず"/"始まりを崩すだけ)
  case "$1" in
    /*) printf '%s\n' "・$1" >&8 2>/dev/null || return 1 ;;
    *)  printf '%s\n' "$1" >&8 2>/dev/null || return 1 ;;
  esac
  ACP_OUT=""
  ACP_DL="$(( $(date +%s) + ${TE_VOICE_TIMEOUT:-90} + 10 ))"
  while :; do
    if IFS= read -r -t 2 ACP_L <&9 2>/dev/null; then
      case "$ACP_L" in
        "${ACP_CTRL}OK") sente_say_turn_end; printf '%s\n' "$ACP_OUT"; return 0 ;;
        "${ACP_CTRL}ERR"*) sente_say_turn_end; return 1 ;;
        SAY:*)
          ACP_SENT="${ACP_L#SAY:}"
          [ -n "$ACP_SENT" ] || continue
          printf '  🗣 %s\n' "$ACP_SENT" >&2
          : > /tmp/sente_say_streamed
          sente_say_enqueue "$ACP_SENT" ;;
        NOTE:*)
          ACP_NOTE="${ACP_L#NOTE:}"
          [ -n "$ACP_NOTE" ] || continue
          printf '  ⚙ %s\n' "$ACP_NOTE" >&2
          sente_note_speak "$ACP_NOTE" ;;
        END:*) ACP_OUT="${ACP_L#END:}" ;;
        *) if [ -n "$ACP_OUT" ]; then ACP_OUT="$ACP_OUT
$ACP_L"; else ACP_OUT="$ACP_L"; fi ;;
      esac
    fi
    kill -0 "$ACP_PID" 2>/dev/null || { sente_say_turn_end; return 1; }
    [ "$(date +%s)" -gt "$ACP_DL" ] && { sente_say_turn_end; return 1; }
  done
}

# 💬 返答待ちの声かけ(2026-08-06本人指示「合いの手以外にも色々入れて、返答が返ってくるまでに」・
# 2026-08-08「ターン間ギャップの体感改善は相槌を厚く」): 相槌(即時)→文脈復唱(二段目)のあと、
# 3秒目に軽くもう一言、まだ答えが来ない8秒目にひとこと、25秒以降は30秒ごとに経過と使い方ヒントを
# 混ぜて声をかける。典型的な応答(3〜8秒)は3秒目までしか鳴らないので、そこは短い一言に留める
# (8秒目以降の長文と混同しないよう文体を変える)。答えのストリーミングが始まっていたら黙って譲る。
# TE_NO_WAIT_NOTES=1で無効。
SENTE_WAIT_NOTES_C="うん、いま考えてるよ。
ちょっと待ってね。
うーん、そうだねえ。
いま見てる。"
SENTE_WAIT_NOTES_A="いま少し深く考えています。もう少しだけ待ってくださいね。
道具を使って手元で確かめています。そのままお待ちを。
順番に確かめながら進めています。あわてず正確にいきますね。"
SENTE_WAIT_NOTES_B="まだ動いています。長くなりそうなら、裏でやって、と言ってもらえば逃がせます。
時間がかかっています。途中で、待って、と言えばいつでも止められますからね。
まだ手を動かしています。終わったらすぐ声でお知らせします。"
sente_wait_note() {  # $1=c(3秒目・短い)/a(8秒目)/b(長期戦) — 合成後にもう一度様子を見てから鳴らす(答えと重ねない)
  [ "${TE_NO_WAIT_NOTES:-0}" = "1" ] && return 0
  sente_muted && return 0
  [ -f /tmp/sente_say_streamed ] && return 0
  [ -f /tmp/sente_say_stop ] && return 0
  [ -f /tmp/sente_speaking.lock ] && return 0
  [ -f /tmp/sente_ctx_playing ] && return 0
  case "$1" in c) WNL="$SENTE_WAIT_NOTES_C" ;; a) WNL="$SENTE_WAIT_NOTES_A" ;; *) WNL="$SENTE_WAIT_NOTES_B" ;; esac
  WN="$(printf '%s\n' "$WNL" | awk 'BEGIN{srand()} NF{a[++n]=$0} END{if(n)print a[int(rand()*n)+1]}')"
  [ -n "$WN" ] || return 0
  WT="$(mktemp "${TMPDIR:-/tmp}/sente_wait_XXXXXX").mp3"
  if curl -s -m 20 -X POST "${KOE_BASE:-https://koe.live}/api/speak" -H 'Content-Type: application/json' \
       -d "$(python3 -c 'import json,sys;print(json.dumps({"text":sys.argv[1],"user_id":sys.argv[2],"source":"sente"}))' "$WN" "${KOE_VOICE:-yuki}")" \
       -o "$WT" 2>/dev/null; then
    # 合成待ちの間に答えが流れ始めたかもしれない → 鳴らす直前にもう一度だけ確認
    if [ ! -f /tmp/sente_say_streamed ] && [ ! -f /tmp/sente_say_stop ] && [ ! -f /tmp/sente_speaking.lock ] && [ ! -f /tmp/sente_ctx_playing ]; then
      printf '  💬 %s\n' "$WN" >&2
      : > /tmp/sente_ctx_playing
      sente_play "$WT"
      rm -f /tmp/sente_ctx_playing
    fi
  fi
  rm -f "$WT"
}

# 🏁 速い方を採る。
# 声の会話はほとんどが「答えるだけ」で道具が要らない。道具を持たない直APIなら
# 1〜2秒で返るのに対し、opencode 経由は3〜9秒かかる。そこで両方に同時に投げ、
# 先に返った方を使う。ただし道具が要る依頼(ファイルを直す等)を直APIが
# 「できません」と即答して勝ってしまうと台無しなので、直API側には
# 「道具が要るなら合図だけ返す」と約束させ、その合図なら採用しない。
SENTE_TOOLLESS_MARK="__NEED_TOOLS__"

# 🧠 直APIパスの会話文脈。ACP(常駐opencode)はセッション文脈を持つが、直API側は毎回まっさらで
# 「こんにちは。Senteです」と挨拶をやり直し前の話を忘れる(2026-08-06実ログ=本人指摘
# 「コンテキスト読めてなかったりする」)。talkセッション中の往復をここに残し、直APIにも渡す。
SENTE_CTX_FILE="${TMPDIR:-/tmp}/sente_ctx.$$.jsonl"
sente_ctx_append() {  # $1=聞き取り $2=返答 — 直近8往復だけ保持
  command -v python3 >/dev/null 2>&1 || return 0
  python3 -c 'import json,sys
print(json.dumps({"u":sys.argv[1][:200],"a":sys.argv[2][:300]},ensure_ascii=False))' "$1" "$2" >> "$SENTE_CTX_FILE" 2>/dev/null || true
  CTX_TMP2="$(tail -8 "$SENTE_CTX_FILE" 2>/dev/null || true)"
  [ -n "$CTX_TMP2" ] && printf '%s\n' "$CTX_TMP2" > "$SENTE_CTX_FILE" 2>/dev/null || true
}

sente_direct() {  # $1=プロンプト → 道具なしで答えられるならその答えをstdoutへ
  load_key
  [ -n "${TEAI_API_KEY:-}" ] || return 1
  # 声で使うモデルは実測で選んだ(11モデル×10問・2026-08-06)。
  #   grok-3-mini  1.26s 声向き100 事実○ 千回$0.05  ← 採用
  #   teai/auto    1.61s 声向き100 事実○ 千回$0.06  (次点)
  #   gemini-3.5-flash-lite は最速1.16sだが富士山を3077mと誤答したため不採用
  #   現行だった glm-5.2 は3.74s・声向き46.5で最下位(記号や長文が多く声に向かない)
  python3 - "$1" "${TE_VOICE_FAST_MODEL:-claude-haiku-4-5-20251001}" "$SENTE_CTX_FILE" <<'PYDIRECT' 2>/dev/null
import json, os, sys, urllib.request
prompt, model = sys.argv[1], sys.argv[2]
ctx_path = sys.argv[3] if len(sys.argv) > 3 else ""
sysmsg = ("あなたは『Sente/先手』。声で話す相棒。結論を短い一文で言い切り、"
          "必要なら補足を一文、最後に先回りの次の一手をひとつだけ。記号や箇条書きは使わない。"
          "会話は継続中なので、挨拶や自己紹介をやり直さない。"
          "ただし、ファイルを読む・書く・開く・コマンドを実行するなど手元のパソコンへの操作が必要な依頼は、"
          "何も答えず __NEED_TOOLS__ とだけ返すこと。"
          "また、統計・研究データ・ニュース・最新の出来事など、検索していないと確認できない事実は、"
          "具体的な数字や出典年をでっち上げず(検索していないので確認できない、と正直に言うか)、"
          "調べる必要があるなら __NEED_TOOLS__ とだけ返すこと。")
msgs = [{"role": "system", "content": sysmsg}]
try:
    for line in open(ctx_path, encoding="utf-8"):
        try:
            d = json.loads(line)
            if d.get("u"): msgs.append({"role": "user", "content": d["u"]})
            if d.get("a"): msgs.append({"role": "assistant", "content": d["a"]})
        except Exception:
            pass
except Exception:
    pass
msgs.append({"role": "user", "content": prompt})
body = json.dumps({"model": model, "max_tokens": 400, "messages": msgs}).encode()
req = urllib.request.Request("https://api.teai.io/v1/chat/completions", data=body,
                             headers={"Content-Type": "application/json",
                                      "Authorization": "Bearer " + os.environ.get("TEAI_API_KEY", "")})
try:
    r = json.load(urllib.request.urlopen(req, timeout=30))
    print((r["choices"][0]["message"]["content"] or "").strip())
except Exception:
    sys.exit(1)
PYDIRECT
}

# 🚧 道具要否の意味理解ゲート(2026-08-08「リサーチして」が正規表現の穴を抜けて
# ハルシネーションした実障害の再発防止・本人指示「もっと賢くして」)。
# 正規表現(RC_SKIP_FAST)は既知の言い回ししか拾えない構造的な穴があるので、
# 安全網としてhaiku 1発の判定をレースと並行(=追加の待ち時間ゼロ)で走らせ、
# 直APIが__NEED_TOOLS__を返し損ねて嘘の即答で勝った場合だけ本式の答えへ差し替える。
# JSONは要求しない(軽量LLMのJSON出力は壊れやすいと実証済み→先頭1文字だけ見る)。
sente_tool_gate() {  # $1=プロンプト → stdoutへ YES/NO(判定不能なら何も出さない)
  load_key
  [ -n "${TEAI_API_KEY:-}" ] || return 1
  python3 - "$1" "${TE_VOICE_FAST_MODEL:-claude-haiku-4-5-20251001}" <<'PYGATE' 2>/dev/null
import json, os, sys, urllib.request
prompt, model = sys.argv[1], sys.argv[2]
sysmsg = ("次の発話に答えるには、Web検索・ファイル操作・コマンド実行など手元の道具が必要か判定して。"
          "統計/研究/ニュース/最新情報など裏取りが要る話題は道具が必要とみなす。少しでも可能性があれば"
          "必要側に倒す。1文字目に Y か N とだけ書き、他には何も書かない。")
body = json.dumps({"model": model, "max_tokens": 3, "temperature": 0,
                   "messages": [{"role": "system", "content": sysmsg},
                                {"role": "user", "content": prompt}]}).encode()
req = urllib.request.Request("https://api.teai.io/v1/chat/completions", data=body,
                             headers={"Content-Type": "application/json",
                                      "Authorization": "Bearer " + os.environ.get("TEAI_API_KEY", "")})
try:
    r = json.load(urllib.request.urlopen(req, timeout=15))
    t = (r["choices"][0]["message"]["content"] or "").strip().upper()
    print("YES" if t[:1] == "Y" else "NO")
except Exception:
    pass
PYGATE
}

sente_race() {  # $1=プロンプト → 返答をstdout(先に返った方)
  rm -f /tmp/sente_say_streamed /tmp/sente_say_full_won   # このターンの「文ごとに読み上げ済みか」を仕切り直す
  RC_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sente_race_XXXXXX")" || return 1
  # 🛠 手元操作が要る依頼(開いて/実行して/作って…)は、道具なしの直APIを最初から走らせない。
  # 直APIが__NEED_TOOLS__を返し損ねて「ブラウザは操作できません」と嘘の即答で勝つ実害が出た
  # (2026-08-06実ログ: 「URL開いて」→直APIが開けないと答えた直後にACPが実際に開いた)
  RC_SKIP_FAST=0
  if [ "$ACP_ON" = 1 ]; then
    case "$1" in
      *開いて*|*ひらいて*|*実行して*|*走らせて*|*動かして*|*作って*|*つくって*|*書いて*|*直して*|*なおして*|*消して*|*削除して*|*調べて*|*デプロイ*|*コミット*|*プッシュ*|*push*|*マージ*|*テストして*|*インストール*|*ビルド*|*読んで*|*確認して*|*見てみて*|*探して*|*リサーチ*|*調査して*|*検索して*)
        RC_SKIP_FAST=1 ;;
    esac
    # ♟ 先手の一手を「やって」で打つ時は必ず本式(ACP)で(キーワードに依らず道具前提)
    [ "${SENTE_FORCE_ACP:-0}" = 1 ] && RC_SKIP_FAST=1
  fi
  if [ "$RC_SKIP_FAST" = 1 ]; then
    : > "$RC_DIR/fast"; : > "$RC_DIR/fast.done"; RC_FAST=""
  else
    ( sente_direct "$1" > "$RC_DIR/fast" 2>/dev/null; : > "$RC_DIR/fast.done" ) &
    RC_FAST=$!
  fi
  # 🚧 レースの安全網(2026-08-08): fastを止めなかった時だけ、並行して(=待ち時間を足さず)
  # ゲート判定を1つ走らせる。直APIが__NEED_TOOLS__を返し損ねて嘘の即答で勝つケースの保険。
  RC_GATE_PID=""
  if [ "$RC_SKIP_FAST" = 0 ] && [ "$ACP_ON" = 1 ]; then
    ( sente_tool_gate "$1" > "$RC_DIR/gate" 2>/dev/null; : > "$RC_DIR/gate.done" ) &
    RC_GATE_PID=$!
  fi
  # 🪤 stderrは潰さない: acp_turnの「🗣/⚙」表示はここ(バックグラウンドのレース側)からしか
  # 出せない。以前は2>/dev/nullで丸ごと消していて、SAY:の🗣表示・今回のNOTE:の⚙表示が
  # 実機では一度も画面に出ない不具合になっていた(音声/ファイル操作自体は成功するので気づきにくい)
  ( if [ "$ACP_ON" = 1 ]; then acp_turn "$1" > "$RC_DIR/full"; fi; : > "$RC_DIR/full.done" ) &
  RC_FULL=$!
  RC_DL="$(( $(date +%s) + ${TE_VOICE_TIMEOUT:-90} ))"
  RC_T0="$(date +%s)"
  RCW3=0; RCW8=0; RCWN=0
  RC_OUT=""
  RC_BACKGROUNDED=0
  while :; do
    # 💬 返答待ちの声かけ: 3秒目に軽く一言、8秒目にひとこと、25秒以降は30秒ごと(裏へ・答えが来たら関数側が譲る)
    RCE="$(( $(date +%s) - RC_T0 ))"
    if [ "$RCE" -ge 3 ] && [ "$RCW3" = 0 ]; then RCW3=1; ( sente_wait_note c ) >/dev/null 2>&1 & fi
    if [ "$RCE" -ge 8 ] && [ "$RCW8" = 0 ]; then RCW8=1; ( sente_wait_note a ) >/dev/null 2>&1 & fi
    if [ "$RCE" -ge "$(( 25 + RCWN * 30 ))" ]; then RCWN=$((RCWN+1)); ( sente_wait_note b ) >/dev/null 2>&1 & fi
    if [ -f "$RC_DIR/fast.done" ] && [ -z "$RC_OUT" ] && [ ! -f "$RC_DIR/fast_rejected" ]; then
      RC_TXT="$(cat "$RC_DIR/fast" 2>/dev/null)"
      case "$RC_TXT" in
        *"$SENTE_TOOLLESS_MARK"*|"") : ;;                 # 道具が要る/空 → 本式を待つ
        *)
           RC_GATE_TXT=""
           [ -f "$RC_DIR/gate.done" ] && RC_GATE_TXT="$(cat "$RC_DIR/gate" 2>/dev/null)"
           if [ "$RC_GATE_TXT" = "YES" ]; then
             # ゲートが「道具が要る」と判定 → 直APIの即答は信用せず本式(ACP)の答えを待つ
             : > "$RC_DIR/fast_rejected"
           else
             RC_OUT="$RC_TXT"
             # 直APIが先に勝った: 裏でACPが文ごとに読み上げ始めていたら、違う答えを鳴らさせない。
             # (呼び出し側がこのあと本当の答えをkoe_speak_textで読むときsente_say_stopを解除するので
             #  取り返しはつく — 止めるのはここだけの一時的な措置)
             : > /tmp/sente_say_stop
             rm -f /tmp/sente_turn_open   # ACP側の読み上げターンはもう続かない(マーカーはkillで届かない)
             pkill -x afplay 2>/dev/null || true
             pkill -x mpg123 2>/dev/null || true
           fi ;;
      esac
      [ -n "$RC_OUT" ] && break
      [ -f "$RC_DIR/full.done" ] && break
    fi
    if [ -f "$RC_DIR/full.done" ]; then
      RC_TXT="$(cat "$RC_DIR/full" 2>/dev/null)"
      if [ -n "$RC_TXT" ]; then
        RC_OUT="$RC_TXT"
        # 常駐モードが勝ち、かつ文ごとにもう読み上げ済みなら、呼び出し側はまとめて読み直さない
        [ -f /tmp/sente_say_streamed ] && : > /tmp/sente_say_full_won
        break
      fi
      [ -f "$RC_DIR/fast.done" ] && break
    fi
    # 📦 長引きすぎたら自動で裏へ回す(2026-08-08「作業中で会話を止めない」)。
    # ⚠acp_turnはACPドライバと1本の共有FIFO(fd8/9・リクエストID無し)で会話するので、
    # このターンの読み取りを生かしたまま次ターンを始めると応答が混線する。
    # なので裏送りの実処理(FIFOの安全な作り直し+独立プロセスでの再実行)は呼び出し側
    # (sente_race_watched)に任せ、ここでは「もう待たない」宣言と自分の後始末だけする。
    if [ "$ACP_ON" = 1 ] && [ -z "$RC_OUT" ] && [ ! -f "$RC_DIR/full.done" ] && [ "$RCE" -ge "${TE_VOICE_BG_AFTER:-40}" ]; then
      RC_BACKGROUNDED=1
      if [ ! -f /tmp/sente_say_streamed ] && [ ! -f /tmp/sente_say_stop ]; then
        koe_say_sync "時間がかかりそうなので、裏に回しました。終わったらお知らせしますね。" >/dev/null 2>&1 || true
      fi
      break
    fi
    [ "$(date +%s)" -gt "$RC_DL" ] && break
    sleep 0.1
  done
  kill "$RC_GATE_PID" 2>/dev/null || true
  wait "$RC_GATE_PID" 2>/dev/null || true
  if [ "$RC_BACKGROUNDED" = 1 ]; then
    kill "$RC_FAST" "$RC_FULL" 2>/dev/null || true
    wait "$RC_FAST" "$RC_FULL" 2>/dev/null || true
    rm -rf "$RC_DIR"
    printf '%s\n' "$SENTE_BG_MARK"
    return 0
  fi
  kill "$RC_FAST" "$RC_FULL" 2>/dev/null || true
  wait "$RC_FAST" "$RC_FULL" 2>/dev/null || true   # waitで回収しないと「Terminated: 15」がターミナルに漏れる(実ログで毎ターン発生)
  # 直APIが「道具が要る」印を返した直後にfullも仕上がっていた場合、上のループは
  # (fast側の分岐で)中身を読まずbreakすることがある → ここが実質的な受け皿
  if [ -z "$RC_OUT" ]; then
    RC_OUT="$(cat "$RC_DIR/full" 2>/dev/null)"
    [ -n "$RC_OUT" ] && [ -f /tmp/sente_say_streamed ] && : > /tmp/sente_say_full_won
  fi
  rm -rf "$RC_DIR"
  [ -n "$RC_OUT" ] || return 1
  printf '%s\n' "$RC_OUT"
}

# 🛑 考え中の中断(ACPパス=sente_race用): KB=1のときだけ裏に回してPID監視+キー監視する。
# Enter/Esc(または任意キー)が来たら、このレースの結果は捨てて常駐ACPを作り直す
# (session/cancelを個別に送るより、acp_stop→acp_startで作り直す方が簡単で確実。
#  古いfdごと閉じるので、遅れて届くSAY:/END:行を個別に読み捨てる必要が構造的に無くなる)。
# 🪤 戻り値はstdout+$()ではなく変数(ACP_REPLY・RQ_CANCELLED)で渡す(改行が剥がれるため。
#    既存sente_kb_readと同じ流儀)。KB=0(端末なし)では監視を入れず従来どおり同期実行する。
SENTE_BG_MARK="@@SENTE_BACKGROUNDED@@"
# 📦 自動裏送りの実処理: 共有FIFO(fd8/9)は使い回さず安全に作り直し(cancel時と同じ手口)、
# 元の依頼は独立プロセス(sente_bg_start=既存の「裏でやって」と同じ経路)で継続させる。
# sente_race自身(KB=1時は別subshell)からは呼ばない — exec 8>/9<の付け替えが親プロセスに
# 届かないため、必ずこのsente_race_watched(常に親プロセス側)から呼ぶこと。
sente_race_bg_handoff() {  # $1=元の依頼文(ペルソナ付き) — 報告ラベルはSENTE_BG_LABEL_HINT(素の聞き取り文)優先
  sente_stop_speaking
  if [ "$ACP_ON" = 1 ]; then
    acp_stop
    if acp_start; then ACP_ON=1; fi
  fi
  sente_bg_start "$1" "${SENTE_BG_LABEL_HINT:-$1}"
}
sente_race_watched() {  # $1=プロンプト → ACP_REPLYへ結果(中断時/裏送り時は空)、RQ_CANCELLEDへ0/1、RQ_BACKGROUNDEDへ0/1
  # 🚀 起動時spawnのREADY待ちが初回ターン(サブシェル内)で失敗していたら、dead印を見て
  # 親であるここで一度だけ作り直す(それでもだめならACP_ON=0で従来経路に落とす)
  if [ "$ACP_ON" = 1 ] && [ -n "$ACP_DIR" ] && [ -f "$ACP_DIR/dead" ]; then
    acp_stop
    if acp_start; then ACP_ON=1; else ACP_ON=0; fi
  fi
  RQ_CANCELLED=0
  RQ_BACKGROUNDED=0
  if [ "$KB" != 1 ]; then
    ACP_REPLY="$(sente_race "$1" || true)"
    if [ "$ACP_REPLY" = "$SENTE_BG_MARK" ]; then RQ_BACKGROUNDED=1; ACP_REPLY=""; sente_race_bg_handoff "$1"; fi
    return 0
  fi
  RQ_OUT="$(mktemp "${TMPDIR:-/tmp}/sente_racewatch_XXXXXX" 2>/dev/null || true)"
  if [ -z "$RQ_OUT" ]; then
    ACP_REPLY="$(sente_race "$1" || true)"
    if [ "$ACP_REPLY" = "$SENTE_BG_MARK" ]; then RQ_BACKGROUNDED=1; ACP_REPLY=""; sente_race_bg_handoff "$1"; fi
    return 0
  fi
  ( sente_race "$1" > "$RQ_OUT" ) & RQ_PID=$!
  while kill -0 "$RQ_PID" 2>/dev/null; do
    sente_kb_read
    if [ -n "$K" ]; then
      case "$K" in "$SENTE_NL"|"$SENTE_CR"|"$SENTE_ESC") ;; "$SENTE_BS"|"$SENTE_DEL") PRE_KEY="${PRE_KEY%?}" ;; *) PRE_KEY="${PRE_KEY}$K" ;; esac   # 追記式: 上書きすると先に押した文字が消える(「DeepSeek」→「eepSeek」実障害)
      RQ_CANCELLED=1
      break
    fi
    sleep 0.2
  done
  if [ "$RQ_CANCELLED" = 1 ]; then
    kill -KILL "$RQ_PID" 2>/dev/null || true
    wait "$RQ_PID" 2>/dev/null || true
    rm -f "$RQ_OUT"
    sente_stop_speaking
    printf '  ⏹ やめました。どうぞ\n' >&2
    koe_sfx err
    if [ "$ACP_ON" = 1 ]; then
      acp_stop
      if acp_start; then ACP_ON=1; fi
    fi
    ACP_REPLY=""
    return 0
  fi
  wait "$RQ_PID" 2>/dev/null || true
  ACP_REPLY="$(cat "$RQ_OUT" 2>/dev/null)"
  rm -f "$RQ_OUT"
  if [ "$ACP_REPLY" = "$SENTE_BG_MARK" ]; then RQ_BACKGROUNDED=1; ACP_REPLY=""; sente_race_bg_handoff "$1"; fi
  return 0
}

# 🫧 考えている間の相槌。
# 実測で「聞き取れた → 返事」まで3〜9秒かかる。人が相手なら必ず何か挟む間で、
# 黙って待たされると「聞こえてる?」と不安になる。短いひと言を先に返して、
# その裏で本番の返事を作る(=待ち時間そのものではなく、沈黙を消す)。
# 短いほど速く鳴る(合成はほぼ文字数比例)。二度目からはキャッシュで0.5秒。
# 相槌は場面で選び分ける。ランダムに引くだけだと「山は何ですか」に「よいしょ」の
# ような噛み合わない返しが出て、かえって機械っぽくなる(本人指摘)。
# q=聞かれた / r=頼まれた / c=それ以外(雑談・報告)
SENTE_FILLERS_Q="えーっと。
うーん、どうだろう。
ああ、それね。
なるほど、そうきたか。
ええと、たしか。
んー、そうだなあ。
あー、はいはい。
ちょっと考えるね。
お、いい質問。
ふむふむ。"

SENTE_FILLERS_R="うん、ちょっと待ってね。
はいはい、了解。
わかった。
ちょっと待って、いま見るね。
あ、わかった。
まかせて。
よいしょ。
ちょっとだけ待っててね。
はいよ。
ちょっと見てみるね。"

SENTE_FILLERS_C="うんうん。
へえ。
ああ、なるほどね。
そうだねえ。
うん、わかるよ。
なるほどねえ。
おっ。
そっか。
うん。
なるほど、そういうことね。"

SENTE_FILLERS="$SENTE_FILLERS_Q
$SENTE_FILLERS_R
$SENTE_FILLERS_C"

# 聞き取った文から場面を見分ける(日本語は文末に出るので末尾を見れば足りる)
sente_filler_kind() {
  case "$1" in
    *"?"*|*"？"*|*ですか*|*ますか*|*かな*|*何*|*なに*|*どこ*|*いつ*|*誰*|*どう*|*教えて*) printf 'q\n' ;;
    *して*|*お願い*|*やって*|*直して*|*作って*|*調べて*|*送って*|*出して*|*止めて*) printf 'r\n' ;;
    *) printf 'c\n' ;;
  esac
}

# 🌱 相槌の語彙を育てる。
# その場で作って鳴らすのは無理だった(生成1.6〜2.5秒 + 未キャッシュの合成10〜30秒)。
# なので鳴らすのは常にキャッシュ済みの言葉にして、裏で新しい言い回しをひとつ作り、
# 合成してキャッシュに載せ、次回から使えるようにする。使うほど語彙が増える。
# 育った言葉は場面ごとのファイルに貯める(q=聞かれた r=頼まれた c=雑談)。
SENTE_GROWN_DIR="$CONFIG_DIR/fillers"
SENTE_GROWN_MAX=40

ensure_filler_gen() {
  mkdir -p "$CONFIG_DIR" 2>/dev/null || return 1
  cat > "$CONFIG_DIR/sente-filler-gen.py" <<'FILLERGEN'
#!/usr/bin/env python3
"""相槌をひとつ作る。話題に依存しない短い口語だけを返す(声で使い回すため)。"""
import json, os, random, sys, urllib.request
model = os.environ.get("TE_FILLER_MODEL", "x-ai/grok-3-mini")
kind = sys.argv[1] if len(sys.argv) > 1 else "c"
tone = {"q": "聞かれて考え始めるときの", "r": "頼まれて引き受けるときの", "c": "相手の話にうなずくときの"}[kind]
seed = random.choice(["やわらかい", "軽い", "考え込む", "うれしそうな", "落ち着いた", "くだけた"])
sysmsg = ("日本語の相槌をひとつだけ作る。口をついて出るごく自然な短い言葉。"
          "条件: 12字以内・話し言葉・話題に依存しない・答えや説明を含めない・記号や引用符を使わない。"
          "例: えーっと。／あー、はいはい。／ちょっと待ってね。")
body = json.dumps({"model": model, "max_tokens": 30, "temperature": 1.0,
                   "messages": [{"role": "system", "content": sysmsg},
                                {"role": "user", "content": f"{seed}感じの、{tone}相槌をひとつ"}]}).encode()
req = urllib.request.Request("https://api.teai.io/v1/chat/completions", data=body,
                             headers={"Content-Type": "application/json",
                                      "Authorization": "Bearer " + os.environ.get("TEAI_API_KEY", "")})
try:
    r = json.load(urllib.request.urlopen(req, timeout=20))
    t = (r["choices"][0]["message"]["content"] or "").strip().replace("\n", " ").strip('"\'「」 ')
    if 2 <= len(t) <= 14 and not any(c in t for c in "*#`<>[]{}"):
        print(t)
except Exception:
    pass
FILLERGEN
}

sente_grow_fillers() {  # $1=場面(q/r/c)
  [ "${TE_NO_FILLER:-0}" = "1" ] && return 0
  [ "${TE_NO_FILLER_GROW:-0}" = "1" ] && return 0
  command -v python3 >/dev/null 2>&1 || return 0
  GK="${1:-c}"
  GF="$SENTE_GROWN_DIR/$GK.txt"
  mkdir -p "$SENTE_GROWN_DIR" 2>/dev/null || return 0
  [ "$(wc -l < "$GF" 2>/dev/null || echo 0)" -ge "$SENTE_GROWN_MAX" ] && return 0
  ensure_filler_gen || return 0
  (
    load_key
    [ -n "${TEAI_API_KEY:-}" ] || exit 0
    NEWF="$(TEAI_API_KEY="$TEAI_API_KEY" python3 "$CONFIG_DIR/sente-filler-gen.py" "$GK" 2>/dev/null)"
    [ -n "$NEWF" ] || exit 0
    grep -qxF "$NEWF" "$GF" 2>/dev/null && exit 0
    printf '%s\n%s\n' "$SENTE_FILLERS" "$(cat "$GF" 2>/dev/null)" | grep -qxF "$NEWF" && exit 0
    # 先に合成してキャッシュに載せる(次に選ばれたとき待たせない)
    curl -s -m 60 -o /dev/null -X POST "${KOE_BASE:-https://koe.live}/api/speak" \
      -H 'Content-Type: application/json' \
      -d "$(python3 -c 'import json,sys;print(json.dumps({"text":sys.argv[1],"user_id":sys.argv[2],"source":"sente"}))' "$NEWF" "${KOE_VOICE:-kentaro}")" \
      && printf '%s\n' "$NEWF" >> "$GF"
  ) >/dev/null 2>&1 &
}

sente_pick_filler() {  # $1=聞き取った文(省略可)
  [ "${TE_NO_FILLER:-0}" = "1" ] && return 0
  FP_KIND="$(sente_filler_kind "${1:-}")"
  case "$FP_KIND" in
    q) FP_LIST="$SENTE_FILLERS_Q" ;;
    r) FP_LIST="$SENTE_FILLERS_R" ;;
    *) FP_LIST="$SENTE_FILLERS_C" ;;
  esac
  # 育った言い回しも混ぜる(使うほど語彙が増えていく)
  FP_GROWN="$CONFIG_DIR/fillers/$FP_KIND.txt"
  [ -s "$FP_GROWN" ] && FP_LIST="$FP_LIST
$(cat "$FP_GROWN")"
  FP_TRY=0
  while [ "$FP_TRY" -lt 6 ]; do
    FP="$(printf '%s\n' "$FP_LIST" | awk 'BEGIN{srand()} NF{a[++n]=$0} END{if(n)print a[int(rand()*n)+1]}')"
    [ "$FP" != "${LAST_FILLER:-}" ] && break
    FP_TRY=$((FP_TRY+1))
  done
  LAST_FILLER="$FP"
  printf '%s\n' "$FP"
}

# 🕊 合いの手: エッジ(/api/aizuchi)が発話の意味に合わせて一言を選ぶ(208フレーズ・全て
# yuki声で事前合成済み=再生はキャッシュ即)。エッジ判断: 無音=黙る / 候補=その一言。
# 不通・タイムアウトは従来のローカル相槌にフォールバック。TE_NO_AIZUCHI=1で常にローカル。
# 直近2回のidをrecentとして送り、同じ一言の連発を避ける。取得〜再生まで丸ごと裏で呼ぶ前提。
SENTE_AIZ_RECENT="$CONFIG_DIR/aizuchi-recent"
sente_aizuchi_filler() {  # $1=聞き取った文 — 選んで鳴らすところまで(呼び出し側が & で裏に置く)
  AZTAB="$(printf '\t')"
  AZP=""
  if [ "${TE_NO_AIZUCHI:-0}" != "1" ] && command -v python3 >/dev/null 2>&1; then
    AZR=""
    # 🪤 `cmd < 無いファイル 2>/dev/null` はリダイレクト失敗がcmdの2>抑止より先に出る → 存在確認で回避
    [ -f "$SENTE_AIZ_RECENT" ] && AZR="$(tr '\n' ',' < "$SENTE_AIZ_RECENT" 2>/dev/null || true)"
    # 🪤 $( )の中に複数行の python3 -c '...' を書くと macOS /bin/sh(bash 3.2)がパースできず
    # スクリプト全体がsyntax errorで起動不能になる(2026-08-06実障害)→ 必ず1行で書く
    AZP="$(curl -s -m 3 -X POST "${KOE_BASE:-https://koe.live}/api/aizuchi" -H 'Content-Type: application/json' \
      -d "$(python3 -c 'import json,sys;print(json.dumps({"text":sys.argv[1],"recent":[x for x in sys.argv[2].split(",") if x]}))' "$1" "${AZR:-}" 2>/dev/null)" 2>/dev/null \
      | python3 -c 'import json,sys;d=json.load(sys.stdin);c=(d.get("candidates") or []);print("@@SILENT@@" if d.get("silence") else (c[0]["text"]+chr(9)+(c[0].get("id") or "") if c and c[0].get("text") else ""))' 2>/dev/null || true)"
  fi
  AZI=""
  case "$AZP" in
    "@@SILENT@@") return 0 ;;                              # エッジの判断: ここは黙るのが自然
    "") AZT="$(sente_pick_filler "$1")" ;;                 # 不通など → ローカル相槌
    *)  AZT="${AZP%%"$AZTAB"*}"; AZI="${AZP##*"$AZTAB"}" ;;
  esac
  [ -n "$AZT" ] || return 0
  if [ -n "$AZI" ]; then                                   # 直近2件だけ覚える(連発防止)
    { printf '%s\n' "$AZI"; head -1 "$SENTE_AIZ_RECENT" 2>/dev/null; } > "$SENTE_AIZ_RECENT.tmp" || true
    mv -f "$SENTE_AIZ_RECENT.tmp" "$SENTE_AIZ_RECENT" 2>/dev/null || true
    printf '  💬 %s\n' "$AZT" >&2
  fi
  KOE_SAY_TIMEOUT=25 koe_say_sync "$AZT" >/dev/null 2>&1 || true
}

# 🧠 二段目の合いの手=文脈復唱(本人指示2026-08-06「embedの超短い合いの手に、文脈に沿った一言を
# さらに添えて間をつなぐ。振る舞いは科学的に賢く頼りになる感じ」)。
# 一段目(埋め込み選択・キャッシュ即再生)が鳴った後、発話の主題を復唱し次の視点をひとこと添える。
# 生成モデルは既定 grok-3-mini(実測1.26s・千回$0.05)。ローカルQwen 0.8Bは同プロンプト実測で
# 「テスト完了しました!」等の虚偽が8本中3本出たため既定にしない(TE_CTX_FILLER_MODELで差し替え可)。
# 出てきた文も虚偽・断定語フィルタに通し、少しでも怪しければ黙る(間違った一言より沈黙がまし)。
# 答えの読み上げが始まっていたら鳴らさない(会話を邪魔しない)。TE_NO_CTX_FILLER=1で無効。
sente_ctx_filler() {  # $1=聞き取った文 — 生成〜再生まで丸ごと(呼び出し側が & で裏に置く)
  [ "${TE_NO_CTX_FILLER:-0}" = "1" ] && return 0
  sente_muted && return 0
  command -v python3 >/dev/null 2>&1 || return 0
  load_key
  [ -n "${TEAI_API_KEY:-}" ] || return 0
  CXTF="$(mktemp "${TMPDIR:-/tmp}/sente_ctx_XXXXXX")"
  TEAI_API_KEY="$TEAI_API_KEY" python3 - "$1" "${TE_CTX_FILLER_MODEL:-x-ai/grok-3-mini}" > "$CXTF" <<'PYCTX' 2>/dev/null
import json, os, sys, urllib.request
utter, model = sys.argv[1], sys.argv[2]
sysmsg = ("あなたは声で使うコーディングエージェントの相棒。ユーザーの発話の主題を短く受け止め、"
          "着手の視点をひとこと添える。冷静で頼れる技術者の口調。出力は28字以内の話し言葉1文だけ。"
          "まだ何もやっていないので、完了・結果・数値の報告は絶対にしない。記号・箇条書き・英語文は禁止。"
          "例:「APIが遅い」→「レスポンス遅延ですね。まず計測ポイントから見ます」")
body = json.dumps({"model": model, "max_tokens": 60, "temperature": 0.4,
                   "messages": [{"role": "system", "content": sysmsg},
                                {"role": "user", "content": utter[:200]}]}).encode()
req = urllib.request.Request("https://api.teai.io/v1/chat/completions", data=body,
                             headers={"Content-Type": "application/json",
                                      "Authorization": "Bearer " + os.environ.get("TEAI_API_KEY", "")})
try:
    r = json.load(urllib.request.urlopen(req, timeout=8))
    t = (r["choices"][0]["message"]["content"] or "").strip().replace("\n", " ").strip('"「」 ')
    bad = ("完了", "できました", "しました!", "しました！", "終わりました", "結果は", "円", "http", "`", "*", "#")
    if 6 <= len(t) <= 48 and not any(b in t for b in bad):   # 48字≈読み上げ4秒。それ以上は間つなぎでなく演説
        print(t)
except Exception:
    pass
PYCTX
  CXT="$(cat "$CXTF" 2>/dev/null)"; rm -f "$CXTF"
  [ -n "$CXT" ] || return 0
  # 一段目の相槌が鳴り終わるのを待つ(最大6秒)。その間に答えの読み上げが始まったら譲る
  CXW=0
  while [ -f /tmp/sente_speaking.lock ] && [ "$CXW" -lt 20 ]; do sleep 0.3; CXW=$((CXW+1)); done
  [ -f /tmp/sente_say_streamed ] && return 0   # 答えが文ごとに流れ始めた → 出しゃばらない
  [ -f /tmp/sente_say_stop ] && return 0
  [ -f /tmp/sente_speaking.lock ] && return 0
  printf '  💭 %s\n' "$CXT" >&2
  : > /tmp/sente_ctx_playing   # 再生中マーカー: drainer(答えの読み上げ)はこれが消えるまで少し待つ=声の重なり防止
  KOE_SAY_TIMEOUT=20 koe_say_sync "$CXT" >/dev/null 2>&1 || true
  rm -f /tmp/sente_ctx_playing
}

# 起動時に相槌を先に合成させておく(初回だけ数秒。以後はキャッシュから即)。
# 裏で静かに走らせ、鳴らしはしない。
sente_warm_fillers() {
  [ "${TE_NO_FILLER:-0}" = "1" ] && return 0
  sente_muted && return 0
  (
    printf '%s\n' "$SENTE_FILLERS" | while IFS= read -r WF; do
      [ -n "$WF" ] || continue
      curl -s -m 30 -o /dev/null -X POST "${KOE_BASE:-https://koe.live}/api/speak" \
        -H 'Content-Type: application/json' \
        -d "$(python3 -c 'import json,sys;print(json.dumps({"text":sys.argv[1],"user_id":sys.argv[2],"source":"sente"}))' "$WF" "${KOE_VOICE:-kentaro}")" || true
    done
  ) >/dev/null 2>&1 &
}

koe_speak_text() {  # $1=text — KOEの声で読み上げ(ACPモード用)。プラグインと同じ手口:
                    # 第一文を先に合成して初動を速く、合成〜再生中はlockで録音と排他。裏で走る
  sente_muted && return 0   # ミュート(te voice off/声/Sente.appワンクリック/AGENT_KOE=0)なら読み上げない
  SPK="$(printf '%s' "$1" | sente_speakify | tr '\n' ' ' | sed -e 's#https\{0,1\}://[^ ]*##g' -e 's/`//g' | cut -c1-1800)"
  [ -n "$SPK" ] || return 0
  SPK1="$(printf '%s' "$SPK" | python3 -c 'import re,sys;t=sys.stdin.read();m=re.match(r"^[\s\S]{6,80}?[。．!！?？]",t);print(m.group(0) if (m and len(m.group(0))<len(t)) else "")' 2>/dev/null)"
  SPKP="afplay"; command -v afplay >/dev/null 2>&1 || SPKP="mpg123"
  SPKB="${TMPDIR:-/tmp}/sente_say_$$_$(date +%s)"
  (
    # /tmp/sente_say_stop = 手元の停止キー(Enter)の合図。新しい読み上げを始める時に消し、
    # 立っていたら以降のセグメントは再生しない(afplay自体はsente_stop_speakingが殺す)
    rm -f /tmp/sente_say_stop
    : > /tmp/sente_speaking.lock
    spk_post() {  # $1=text $2=outfile
      curl -s -m 25 -o "$2" -X POST "${KOE_BASE:-https://koe.live}/api/speak" -H 'Content-Type: application/json' \
        -d "$(python3 -c 'import json,sys;print(json.dumps({"text":sys.argv[1],"user_id":sys.argv[2],"source":"sente"}))' "$1" "${KOE_VOICE:-yuki}")"
    }
    if [ -n "$SPK1" ]; then
      SPK2="${SPK#"$SPK1"}"
      spk_post "$SPK1" "${SPKB}a.mp3" & SPJ1=$!
      spk_post "$SPK2" "${SPKB}b.mp3" & SPJ2=$!
      wait $SPJ1; [ -f /tmp/sente_say_stop ] || sente_play "${SPKB}a.mp3"
      wait $SPJ2; [ -f /tmp/sente_say_stop ] || sente_play "${SPKB}b.mp3"
    else
      spk_post "$SPK" "${SPKB}a.mp3" && { [ -f /tmp/sente_say_stop ] || sente_play "${SPKB}a.mp3"; }
    fi
    rm -f "${SPKB}a.mp3" "${SPKB}b.mp3" /tmp/sente_speaking.lock
  ) &
}

koe_sfx() {  # 効果音: $1=ready|heard|think|err(soxで合成するモダンな純音チャイム。
             # 初回だけ生成して以後キャッシュ・soxが無ければ従来のシステム音・失敗は無視)
  [ "$(uname)" = "Darwin" ] || return 0
  SFXD="$CONFIG_DIR/sfx"
  SFXF="$SFXD/$1.wav"
  if [ ! -f "$SFXF" ] && command -v sox >/dev/null 2>&1; then
    mkdir -p "$SFXD"
    # 純音+オクターブ倍音(15%)を短いq-fadeで減衰させた柔らかい音。ready/errは2音
    sfx_note() { sox -n -r 44100 -c 1 "$1" synth "$2" sine "$3" sine "$4" remix 1v0.85,2v0.15 fade q 0.004 "$2" "$5" gain -6 2>/dev/null; }
    case "$1" in
      ready) sfx_note "$SFXD/.a.wav" 0.14 659.25 1318.50 0.10 && sfx_note "$SFXD/.b.wav" 0.26 987.77 1975.53 0.20 \
               && sox "$SFXD/.a.wav" "$SFXD/.b.wav" "$SFXF" 2>/dev/null ;;  # E5→B5 上昇(起動)
      heard) sfx_note "$SFXF" 0.09 1174.66 2349.32 0.07 ;;                   # D6 短いティック(聞こえた)
      think) sfx_note "$SFXF" 0.12 783.99 1567.98 0.09 ;;                    # G5 ひと呼吸(考え中)
      err)   sfx_note "$SFXD/.a.wav" 0.14 880.00 1760.00 0.10 && sfx_note "$SFXD/.b.wav" 0.30 587.33 1174.66 0.24 \
               && sox "$SFXD/.a.wav" "$SFXD/.b.wav" "$SFXF" 2>/dev/null ;;  # A5→D5 下降(エラーも威圧しない)
    esac
    rm -f "$SFXD/.a.wav" "$SFXD/.b.wav"
  fi
  if [ -f "$SFXF" ]; then
    { afplay -v 0.18 "$SFXF" >/dev/null 2>&1 & } 2>/dev/null
    return 0
  fi
  case "$1" in
    ready) SFX=Glass ;;
    heard) SFX=Pop ;;
    think) SFX=Tink ;;
    err)   SFX=Basso ;;
    *) return 0 ;;
  esac
  { afplay -v 0.3 "/System/Library/Sounds/${SFX}.aiff" >/dev/null 2>&1 & } 2>/dev/null
}

# 🚀 固定文の読み上げ(起動挨拶など): 一度合成したmp3をローカルに置き、次回から合成なしで即再生。
# キャッシュは声ID+本文で分け、7日で作り直す(サーバ側で声質が更新されても古い声が残らない)。
# 🪤 合成失敗時のエラーJSONをキャッシュすると次回から無音になる → 先頭が「{」ならmp3でないので捨てる
koe_say_cached() {
  sente_muted && return 0
  # mac=shasum(sha1) / linux=sha1sum。同じsha1なので既存キャッシュのキーは変わらない
  if command -v shasum >/dev/null 2>&1; then KSC_SHA=shasum; else KSC_SHA=sha1sum; fi
  KSC_KEY="$(printf '%s|%s' "${KOE_VOICE:-yuki}" "$1" | "$KSC_SHA" 2>/dev/null | cut -c1-12)"
  [ -n "$KSC_KEY" ] || { koe_say_sync "$1"; return 0; }
  KSC_F="$CONFIG_DIR/sfx/say-$KSC_KEY.mp3"
  find "$KSC_F" -mtime +7 -delete 2>/dev/null || true
  if [ ! -s "$KSC_F" ]; then
    mkdir -p "$CONFIG_DIR/sfx" 2>/dev/null
    curl -s -m "${KOE_SAY_TIMEOUT:-8}" -X POST "${KOE_BASE:-https://koe.live}/api/speak" \
      -H 'Content-Type: application/json' \
      -d "$(python3 -c 'import json,sys;print(json.dumps({"text":sys.argv[1],"user_id":sys.argv[2],"source":"sente"}))' "$1" "${KOE_VOICE:-yuki}")" \
      -o "$KSC_F" 2>/dev/null || true
    [ "$(head -c 1 "$KSC_F" 2>/dev/null)" = "{" ] && rm -f "$KSC_F"
  fi
  [ -s "$KSC_F" ] && sente_play "$KSC_F" || true
  return 0
}

koe_say_sync() {  # 短い定型文をKOEの声で同期再生(録音開始前に言い終わる=自分の声を拾わない。
                   # 初回のみ合成・以後はedgeキャッシュ~0.5s。コールドで遅い時は-m 8で諦めて先へ)
  # ⚠JSONは必ずjson.dumpsで作る: 以前は生埋め込みで、改行/引用符入りテキスト(te serveの実行結果など)が
  # JSONを壊し400→エラーJSONをafplay→失敗がset -euでスクリプトごと殺しserveの依頼がtaken孤児化する実障害。
  # 末尾の`|| true`も同じ理由(afplay失敗=読み上げ諦めでよく、死ぬ理由にはならない)。
  sente_muted && return 0   # 消音(ワンクリック/声/te voice off/AGENT_KOE=0)なら読み上げない
  GRT="$(mktemp "${TMPDIR:-/tmp}/sente_greet_XXXXXX").mp3"
  curl -s -m "${KOE_SAY_TIMEOUT:-8}" -X POST "${KOE_BASE:-https://koe.live}/api/speak" \
    -H 'Content-Type: application/json' \
    -d "$(python3 -c 'import json,sys;print(json.dumps({"text":sys.argv[1],"user_id":sys.argv[2],"source":"sente"}))' "$1" "${KOE_VOICE:-yuki}")" \
    -o "$GRT" 2>/dev/null && sente_play "$GRT" || true
  rm -f "$GRT"
}

# ── くべる(kuberu): 毎日の火の一巡を回して、結果を本人の声で詳しく報告 ──
# `te kuberu`(ターミナル)と声の「くべて」(serveが検知→裏で起動)の共通実装。
# 実体は Claude Code の /kuberu をヘッドレス実行し、最終報告を話し言葉に変換して読み上げる。
# ⚠関数定義は使用箇所(KUBERU_MODE分岐/serveループ)より前に置く(このファイル既知の並び順罠)。
sente_pick() {  # 引数からランダムに1つ返す — 毎回同じ言い回しにならないように(本人指示 2026-08-06「声バリエーションたくさん」)
  SP_N=$#
  [ "$SP_N" -gt 0 ] || return 0
  SP_R="$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -dc '0-9' || echo 1)"
  SP_I=$(( ${SP_R:-1} % SP_N + 1 ))
  eval "printf '%s' \"\${$SP_I}\""
}
sente_pay_guide() {  # $1=実行出力 — teaiクレジット切れなら支払いページを開く(0=検知した)。読み上げは呼び出し側。
  printf '%s' "$1" | grep -q "insufficient_credits" || return 1
  echo "💳 teaiクレジット不足 → $TEAI_SITE/pricing でチャージできます" >&2
  [ "$(uname)" = "Darwin" ] && open "$TEAI_SITE/pricing" 2>/dev/null || true
  return 0
}
sente_kuberu_speakify() {  # stdin=kuberu最終報告(markdown) → stdout=話し言葉チャンク(1行=1チャンク・最大6)
  python3 -c "
import sys,re
t=sys.stdin.read()
t=re.sub(r'\`\`\`.*?\`\`\`','',t,flags=re.S)          # コード塊は読まない
t=re.sub(r'\[([^\]]*)\]\([^)]*\)',r'\1',t)            # リンクはラベルだけ
t=re.sub(r'https?://\S+','',t)                        # 生URLは読まない
for a,b in [('✅','まず、完了したこと。'),('⏳','つぎに、待ちのもの。'),('🔴','注意点。'),('🎉','うれしい知らせ。'),('👉','次の一手。')]:
    t=t.replace(a,b)
t=re.sub(r'[#*_\`>|~-]',' ',t)
t=re.sub(r'[ \t]+',' ',t)
lines=[l.strip() for l in t.splitlines() if l.strip()]
text='。'.join(lines)
text=re.sub(r'。+','。',text)
# 🎯「究極の三択」(明日の選択肢)は本文がどれだけ長くても必ず最後に読む(本人指示 2026-08-06)
tail=''
mi=text.find('究極の三択')
if mi>0:
    cut=text.rfind('。',0,mi)
    cut=cut+1 if cut>0 else mi
    tail=text[cut:]; text=text[:cut]
chunks=[]
while text and len(chunks)<5:
    if len(text)<=480:
        chunks.append(text); break
    cut=text.rfind('。',0,480)
    cut=cut+1 if cut>200 else 480
    chunks.append(text[:cut]); text=text[cut:]
while tail and len(chunks)<8:
    if len(tail)<=480:
        chunks.append(tail); break
    cut=tail.rfind('。',0,480)
    cut=cut+1 if cut>200 else 480
    chunks.append(tail[:cut]); tail=tail[cut:]
for c in chunks:
    if c.strip(): print(c.strip())
"
}
te_kuberu_main() {  # $1(任意)=--from-voice(声起点: 完了を声で知らせてから詳報)
  KB_FROM_VOICE=0; [ "${1:-}" = "--from-voice" ] && KB_FROM_VOICE=1
  KB_LOG_DIR="$SENTE_LOG_DIR"; mkdir -p "$KB_LOG_DIR"
  KB_LOG="$KB_LOG_DIR/kuberu-$(date +%Y%m%d-%H%M%S).md"
  KB_PIDF=/tmp/sente_kuberu.pid
  KB_OLD="$(cat "$KB_PIDF" 2>/dev/null || true)"
  if [ -n "$KB_OLD" ] && kill -0 "$KB_OLD" 2>/dev/null; then
    koe_say_sync "$(sente_pick "いま、くべている最中です。終わったらお知らせしますね。" "もう火の前にいますよ。もうしばらくお待ちください。" "ただいま、くべている途中です。終わり次第、声をかけますね。")"
    return 0
  fi
  printf '%s' "$$" > "$KB_PIDF"
  KB_CLAUDE="$(command -v claude 2>/dev/null || true)"
  [ -n "$KB_CLAUDE" ] || KB_CLAUDE="$HOME/.local/bin/claude"
  if [ ! -x "$KB_CLAUDE" ]; then
    koe_say_sync "くべる本体の、クロードコマンドが見つかりませんでした。"
    rm -f "$KB_PIDF"; return 1
  fi
  echo "🔥 kuberu 開始(ログ: $KB_LOG)" >&2
  [ "$KB_FROM_VOICE" = 1 ] || koe_say_sync "$(sente_pick "くべ始めます。終わったら、声で詳しく報告しますね。" "はい、火を見てきます。しばらくしたら結果をお話しします。" "了解です。毎日の火、ひと回りしてきますね。" "くべますね。終わり次第、詳しくご報告します。" "今日の火を確かめてきます。少し待っていてください。")"
  if [ -n "${TE_KUBERU_CMD:-}" ]; then
    KB_OUT="$(eval "$TE_KUBERU_CMD" 2>&1 || true)"   # テスト用の差し替え口
  else
    KB_OUT="$("$KB_CLAUDE" -p --model "${TE_KUBERU_MODEL:-sonnet}" --dangerously-skip-permissions "/kuberu" 2>&1 || true)"
  fi
  printf '%s\n' "$KB_OUT" > "$KB_LOG"
  rm -f "$KB_PIDF"
  if sente_pay_guide "$KB_OUT"; then
    koe_say_sync "teaiのクレジットが切れています。チャージページを開いておきました。"
  fi
  [ "$KB_FROM_VOICE" = 1 ] && koe_say_sync "$(sente_pick "くべ終わりました。どうなったか、お伝えします。" "ただいま戻りました。火の様子をご報告しますね。" "ひと回りしてきました。今日はこんな感じでした。" "おまたせしました。くべた結果をお話しします。" "終わりましたよ。順番にご報告しますね。")"
  printf '%s\n' "$KB_OUT" | sente_kuberu_speakify | while IFS= read -r KB_CHUNK; do
    [ -n "$KB_CHUNK" ] || continue
    KOE_SAY_TIMEOUT=60 koe_say_sync "$KB_CHUNK"
  done
  koe_say_sync "$(sente_pick "以上です。全文は、センテのログに残してあります。" "報告はここまで。詳しいことはログにまとめてあります。" "今日はこんなところです。おつかれさまでした。" "ということで、ひと段落です。気になることがあれば聞いてください。" "以上、今日の火でした。またいつでも、くべてと言ってくださいね。")"
  echo "🔥 kuberu 完了 → $KB_LOG" >&2
  return 0
}

# ── te schedule: 裏実行の定期化(常駐serveの中で毎日決まった時刻に頼み事を回す) ──
# `te schedule add "09:00" "経費集計"` のように登録 → te serve 常駐中、その時刻になったら
# 通常の依頼と同じ経路(oc_run_guarded+声報告)で1日1回実行する。破壊的な語を含む予定は
# 既定では実行せず声で知らせるだけ(TE_SCHEDULE_ALLOW_RED=1で解禁・te serveのRED方針と同型)。
sente_schedule_file() { echo "$HOME/.config/teai/schedule.json"; }

sente_schedule_ensure() {
  SSF="$(sente_schedule_file)"
  if [ ! -f "$SSF" ]; then
    mkdir -p "$(dirname "$SSF")"
    printf '[]' > "$SSF"
  fi
}

sente_schedule_is_red() {  # $1=task文 → 0(危険語を含む)/1(含まない)
  printf '%s' "$1" | grep -qE '(削除|消し|消す|送信|送って|公開|払|課金|決済|退会|解約|force|rm -rf|DROP TABLE)'
}

sente_schedule_add() {  # $1=HH:MM $2=task
  sente_schedule_ensure
  SSF="$(sente_schedule_file)"
  if ! printf '%s' "$1" | grep -qE '^([01][0-9]|2[0-3]):[0-5][0-9]$'; then
    echo "時刻は HH:MM 形式で指定してください(例: 09:00)" >&2; return 1
  fi
  python3 -c '
import json, sys, uuid
sf, t, task = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(sf))
d.append({"id": uuid.uuid4().hex[:8], "time": t, "task": task, "last_run": ""})
json.dump(d, open(sf, "w"), ensure_ascii=False)
' "$SSF" "$1" "$2"
  echo "🕰 予定に追加しました: 毎日 $1 に「$2」" >&2
}

sente_schedule_list() {
  sente_schedule_ensure
  SSF="$(sente_schedule_file)"
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
if not d:
    print("(予定はまだありません — te schedule add \"09:00\" \"経費集計\" のように登録できます)")
for e in d:
    print("  %s  毎日%s  %s  (直近実行: %s)" % (e["id"], e["time"], e["task"], e["last_run"] or "未実行"))
' "$SSF"
}

sente_schedule_rm() {  # $1=id
  sente_schedule_ensure
  SSF="$(sente_schedule_file)"
  python3 -c '
import json, sys
sf, rid = sys.argv[1], sys.argv[2]
d = json.load(open(sf))
d2 = [e for e in d if e["id"] != rid]
json.dump(d2, open(sf, "w"), ensure_ascii=False)
print("removed" if len(d2) < len(d) else "not_found")
' "$SSF" "$1"
}

sente_schedule_main() {  # CLI: add/list/rm(teaiキー不要=kuberuと同様ここで完結)
  case "${1:-list}" in
    add) shift; sente_schedule_add "$1" "$2" ;;
    rm|remove) shift; sente_schedule_rm "$1" ;;
    list|"") sente_schedule_list ;;
    *) echo "使い方: te schedule add \"HH:MM\" \"頼み事\" / te schedule list / te schedule rm <id>" >&2; return 1 ;;
  esac
}

sente_schedule_due() {  # stdout: 1行=1件「id<TAB>task」(その分だけ現在時刻HH:MMに一致・今日はまだ未実行)
  sente_schedule_ensure
  SSF="$(sente_schedule_file)"
  python3 -c '
import json, sys, datetime
d = json.load(open(sys.argv[1]))
now = datetime.datetime.now()
hhmm, today = now.strftime("%H:%M"), now.strftime("%Y-%m-%d")
for e in d:
    if e.get("time") == hhmm and e.get("last_run") != today:
        print("%s\t%s" % (e["id"], e["task"]))
' "$SSF"
}

sente_schedule_mark_ran() {  # $1=id
  SSF="$(sente_schedule_file)"
  python3 -c '
import json, sys, datetime
sf, rid = sys.argv[1], sys.argv[2]
d = json.load(open(sf))
today = datetime.datetime.now().strftime("%Y-%m-%d")
for e in d:
    if e["id"] == rid:
        e["last_run"] = today
json.dump(d, open(sf, "w"), ensure_ascii=False)
' "$SSF" "$1"
}

# ── 声モードの手元操作(レベルメーター/タイピング入力/読み上げ・録音の停止) ──
# 端末がある時だけ有効。Sente.appなど端末なし起動では自動で無効=従来どおり声だけで動く。
SENTE_NL="$(printf '\nx')"; SENTE_NL="${SENTE_NL%x}"
SENTE_CR="$(printf '\rx')"; SENTE_CR="${SENTE_CR%x}"
SENTE_ESC="$(printf '\033')"
SENTE_BS="$(printf '\010')"    # Backspace(Ctrl-H)
SENTE_DEL="$(printf '\177')"   # Delete(多くの端末で物理Backspaceキーが実際に送るバイト)
SENTE_CTRLC="$(printf '\003')" # Ctrl-C: 端末がisigを失っているとSIGINTにならず生バイトで届く(→キー側でも拾って終了)
sente_kb_ok() {  # 0=キーボード操作が使える
  [ "${TE_NO_KB:-0}" = "1" ] && return 1
  [ -t 2 ] || return 1
  (: </dev/tty) 2>/dev/null || return 1
  command -v stty >/dev/null 2>&1 || return 1
  command -v dd >/dev/null 2>&1 || return 1
}
sente_kb_open() {  # 1キーずつ即読める端末モードへ(元の状態はSENTE_STTYに保存)
  [ -n "${SENTE_STTY:-}" ] || SENTE_STTY="$(stty -g </dev/tty 2>/dev/null || true)"
  # isigを明示: 子(TUI系)がrawで抜けた後などisigが切れたままだとCtrl-CがSIGINTにならない
  # (2026-08-09本人報告「Ctrl-Cが効かない」の一因)。念のため毎回有効へ戻す
  stty -icanon -echo min 0 time 0 isig </dev/tty 2>/dev/null || true
}
sente_kb_close() { [ -n "${SENTE_STTY:-}" ] && stty "$SENTE_STTY" </dev/tty 2>/dev/null || true; }
sente_kb_read() {  # 押されたキーを変数Kに入れる(無ければ空・待たない)。Enterは改行1文字。
  # 🪤 stdout+$()で返すとEnter(改行1文字)が$()の末尾改行剥がしで空になる → 変数渡し一択。
  # 番兵xも同じ理由(dd直後の$()で改行を守る)。ddの失敗(端末が閉じた等)は「キー無し」扱い
  K="$(dd if=/dev/tty bs=1 count=1 2>/dev/null || true; printf x)"; K="${K%x}"
}
sente_stop_speaking() {  # 読み上げをその場で止める(合成済みの続きのセグメントも再生しない)
  : > /tmp/sente_say_stop
  pkill -x afplay 2>/dev/null || true
  pkill -x mpg123 2>/dev/null || true
  rm -f /tmp/sente_speaking.lock /tmp/sente_turn_open
}
sente_talk_quit() {  # Ctrl-C/Escからのtalk終了。「効かない」を作らないため、遅くなりうる掃除は全部裏へ
  trap - INT TERM   # 2度目のCtrl-Cは素のSIGINT=問答無用で即死できるように先に解除
  printf '\n🎙 おつかれさま(sente終了)\n' >&2
  sente_kb_close   # 端末を返すのが最優先(これが遅れると「固まった」に見える)
  sente_stop_speaking
  # acp_stop(常駐ドライバ畳み)はwaitで待ちうる→裏へ。残骸が出ても次回起動のGCが拾う
  ( acp_stop ) >/dev/null 2>&1 &
  rm -f "$SENTE_CTX_FILE" 2>/dev/null
  # 🧹 セッション終了時は「消費済みの挨拶残骸」と「先手の提案状態」だけを消す。
  # greet-next.txt(次回起動用に準備した挨拶)は消さない=これがグリーティングの本体であり、
  # 鮮度は起動側(sente_greet_play_bg の -mmin -1200)で担保済み。古い話題が翌日起動に
  # 漏れる問題はそこで防がれているので、ここで greet-next を消すとグリーティング機能が死ぬ。
  # カスタム固定文(greeting)やオフ設定(greeting-off)はユーザーの設定なので消さない。
  rm -f "$CONFIG_DIR/greet-cur.txt" "$CONFIG_DIR/greet-cur.mp3" \
        "$CONFIG_DIR/opening-task" "$CONFIG_DIR/opening-last" "$CONFIG_DIR/opening-repeat" \
        "$CONFIG_DIR/opening-summary" "$CONFIG_DIR/opening-alert" 2>/dev/null || true
  if [ "$(cat /tmp/sente_talk.pid 2>/dev/null)" = "$$" ]; then rm -f /tmp/sente_talk.pid; fi
  exit 0
}

# 🚀 実行エンジンのランナー(claude/codex共通・2026-08-06本人指示)。
# $1=上限秒 $2=engine(claude|codex) $3=継続フラグ(0=新規/1=前ターンから継続) $4=プロンプト
# → ENGINE_REPLY(応答全文・失敗時は空) ENGINE_CANCELLED(0/1・KB中断) 戻り値=子の終了コード(0=成功)
# ⚠watchdogのfdはoc_run_guardedと同じ理由で切り離す(このランナー自体は$()で包まないが揃えておく)。
# claudeは`-p --continue`で文脈継続。codexは`exec resume --last`だが、位置引数PROMPTと`--last`が
# clap側で衝突する(実測: codex-cli 0.39.0 — `--last`と`[SESSION_ID]`は同時指定不可のエラーになる)ため、
# 継続ターンだけ標準入力でプロンプトを渡す(初回は位置引数でよい・実測で確認済み)。
# 出力抽出: claudeは`--output-format text`の標準出力がそのまま答え。codexの標準出力はタイムスタンプ付き
# ログで読み上げに使えない(実測)ため`--output-last-message`で書き出したファイルを正とする。
sente_engine_run() {
  SER_GW="$1"; SER_ENG="$2"; SER_CONT="$3"; SER_PROMPT="$4"
  ENGINE_REPLY=""; ENGINE_CANCELLED=0
  SER_OUT="$(mktemp "${TMPDIR:-/tmp}/sente_engine_out_XXXXXX")"
  SER_LASTF="$(mktemp "${TMPDIR:-/tmp}/sente_engine_last_XXXXXX")"
  # 🔓 権限の既定=opencodeエンジンと同等(承認プロンプトなしで手が動く)。
  # claudeは素の-pだとBash等の承認待ちで最大タイムアウトまで無言停止し(実挙動)、声モードでは
  # 「固まった」と区別がつかない。codexは既定read-onlyサンドボックスで「直して」が書けない。
  # どちらも本人のマシンで本人の声/手による依頼という前提なので、既定を自動実行に揃える。
  # 絞りたい時は TE_CLAUDE_ARGS / TE_CODEX_ARGS で上書き(例: TE_CLAUDE_ARGS="--permission-mode acceptEdits")
  SER_CARGS="${TE_CLAUDE_ARGS:---permission-mode bypassPermissions}"
  SER_XARGS="${TE_CODEX_ARGS:---full-auto}"
  (
    case "$SER_ENG" in
      claude)
        if [ "$SER_CONT" = 1 ]; then
          # shellcheck disable=SC2086
          claude -p --continue "$SER_PROMPT" --output-format text $SER_CARGS
        else
          # shellcheck disable=SC2086
          claude -p "$SER_PROMPT" --output-format text $SER_CARGS
        fi ;;
      codex)
        if [ "$SER_CONT" = 1 ]; then
          # shellcheck disable=SC2086
          printf '%s' "$SER_PROMPT" | codex exec --skip-git-repo-check $SER_XARGS --output-last-message "$SER_LASTF" resume --last
        else
          # shellcheck disable=SC2086
          codex exec --skip-git-repo-check $SER_XARGS --output-last-message "$SER_LASTF" "$SER_PROMPT"
        fi ;;
    esac
  ) > "$SER_OUT" 2>&1 & SER_P=$!
  ( sleep "$SER_GW"; kill -TERM $SER_P 2>/dev/null; sleep 2; kill -KILL $SER_P 2>/dev/null ) >/dev/null 2>&1 & SER_K=$!
  SER_T0="$(date +%s)"; SER_NOTE=0
  if [ "${KB:-0}" = 1 ]; then
    while kill -0 "$SER_P" 2>/dev/null; do
      sente_kb_read
      if [ -n "$K" ]; then
        case "$K" in
          "$SENTE_ESC"|"$SENTE_CTRLC")   # Esc/生Ctrl-C=終了。子エンジンとwatchdogは残さず畳む(2026-08-09本人要望)
            kill -KILL "$SER_P" 2>/dev/null || true; wait "$SER_P" 2>/dev/null || true
            kill "$SER_K" 2>/dev/null; { wait "$SER_K"; } 2>/dev/null
            rm -f "$SER_OUT" "$SER_LASTF"
            sente_talk_quit ;;
          "$SENTE_NL"|"$SENTE_CR") ;;
          "$SENTE_BS"|"$SENTE_DEL") PRE_KEY="${PRE_KEY%?}" ;;
          *) PRE_KEY="${PRE_KEY}$K" ;;
        esac   # 追記式: 上書きすると先に押した文字が消える
        ENGINE_CANCELLED=1
        break
      fi
      # 無言停止に見えないよう、20秒ごとに生存の一言(画面のみ・声は出さない)
      SER_EL=$(( $(date +%s) - SER_T0 ))
      if [ "$SER_EL" -ge $(( (SER_NOTE + 1) * 20 )) ]; then
        SER_NOTE=$((SER_NOTE+1))
        printf '  ⚙ %sで作業中…(%s秒・Enterで中断)\n' "$SER_ENG" "$SER_EL" >&2
      fi
      sleep 0.2
    done
  fi
  if [ "$ENGINE_CANCELLED" = 1 ]; then
    kill -KILL "$SER_P" 2>/dev/null || true
    wait "$SER_P" 2>/dev/null || true
    kill "$SER_K" 2>/dev/null; { wait "$SER_K"; } 2>/dev/null
    rm -f "$SER_OUT" "$SER_LASTF"
    sente_stop_speaking
    printf '  ⏹ やめました。どうぞ\n' >&2
    koe_sfx err
    return 1
  fi
  { wait "$SER_P"; SER_S=$?; } 2>/dev/null
  kill "$SER_K" 2>/dev/null; { wait "$SER_K"; } 2>/dev/null
  if [ "$SER_ENG" = "codex" ] && [ -s "$SER_LASTF" ]; then
    ENGINE_REPLY="$(cat "$SER_LASTF" 2>/dev/null)"
  else
    ENGINE_REPLY="$(sed 's/\x1b\[[0-9;]*m//g' "$SER_OUT" 2>/dev/null | grep -av '^\s*$')"
  fi
  rm -f "$SER_OUT" "$SER_LASTF"
  return "$SER_S"
}

sente_engine_missing_msg() {  # $1=engine名 → 声+画面で案内して終わる(落とさない)
  printf '  🔴 %s が見つかりません。インストールしてください\n' "$1" >&2
  koe_say_sync "${1}が見つかりませんでした。インストールしてください。"
}

sente_engine_switch() {  # $1=claude|codex|opencode — 永続保存+読み上げ+以後の会話を仕切り直す(恒久切替)
  sente_engine_set "$1"
  ENGINE_TALK_FIRST=1
  printf '  🔧 エンジンを %s にしました\n' "$1" >&2
  koe_say_sync "はい、${1}に切り替えました。"
}

sente_engine_once() {  # $1=engine $2=依頼文(空なら使い方を言う) — 恒久設定は変えずその場だけ1回実行(prefix)
  if [ -z "$2" ]; then
    printf '  使い方: 「%sで、やってほしいことを続けて言う」\n' "$1" >&2
    koe_say_sync "${1}で、のあとにやってほしいことを続けてください。"
    return 0
  fi
  if ! command -v "$1" >/dev/null 2>&1; then
    sente_engine_missing_msg "$1"
    return 0
  fi
  printf '  🔧 %s で1回だけ実行します\n' "$1" >&2
  sente_engine_run "${TE_ENGINE_TIMEOUT:-300}" "$1" 0 "$2$SENTE_PERSONA" || true
  [ "$ENGINE_CANCELLED" = 1 ] && return 0
  if [ -n "$ENGINE_REPLY" ]; then
    LAST_REPLY_NORM="$(printf '%s' "$ENGINE_REPLY" | tr -d '\n 　。、．，!！?？' | tail -c 2000)"
    LAST_REPLY_TXT="$ENGINE_REPLY"
    printf '%s\n' "$ENGINE_REPLY"
    koe_speak_text "$(printf '%s' "$ENGINE_REPLY" | grep -av '^\s*$' | tail -3)"
  else
    printf '  ⚠ %s から応答がありませんでした\n' "$1" >&2
    koe_say_sync "うまく実行できませんでした。"
  fi
  return 0
}

# 🪞 こだま率: 聞き取り$1のbigramが直前返答$2にどれだけ含まれるか(0.00〜1.00をstdoutへ)。
# STTの揺れ(「治せる」→「知せる」等)があっても大半のbigramは残るので、完全一致より頑丈。
# 2026-08-06実ログ: 複数文の返事の後半を丸ごと聞き取り→従来の「40文字未満の完全一致」を
# すり抜けて自問自答ループになった。長さ上限なしの重なり率で見るのが根治。
sente_echo_ratio() {
  command -v python3 >/dev/null 2>&1 || { printf '0\n'; return 0; }
  python3 - "$1" "$2" <<'PYECHO' 2>/dev/null || printf '0\n'
import sys, unicodedata
a = unicodedata.normalize("NFKC", sys.argv[1])
b = unicodedata.normalize("NFKC", sys.argv[2])
ga = {a[i:i+2] for i in range(len(a)-1)}
gb = {b[i:i+2] for i in range(len(b)-1)}
print("%.2f" % (len(ga & gb) / len(ga) if ga else 0.0))
PYECHO
}

# 🗣⚡ 読み上げ中の声割り込み(TE_BARGE=1・既定ON)の判定。
# 本人指示(2026-08-06):「割り込みで話は止まる。意味がわからなければやめた話を続け、
# 意味が通れば反応を返す」。AECが無いのでマイクは自分の読み上げも拾う=チャンクの大半は
# こだま。判定は3値: 採用(新しい発話・BARGE_HEARDへ) / 停止語(BARGE_STOPWORD=1) /
# 破棄(こだま・幻聴・断片=話を止めない)。こだま混じり(率0.35〜0.64)は「呼ばれたのは
# 確かだが聞き取れていない」ので止めて聞き返す(BARGE_RETRY=1)。
sente_barge_judge() {  # $1=wav → 0=何か起きた(採用/停止語/聞き返し) 1=破棄
  BARGE_HEARD=""; BARGE_STOPWORD=0; BARGE_RETRY=0
  [ -f "$1" ] || return 1
  [ "$(wc -c < "$1" 2>/dev/null || echo 0)" -gt 8000 ] || return 1
  koe_dur_ok "$1" || return 1
  BJ_T="$(koe_stt "$1")"
  [ -n "$BJ_T" ] || return 1
  BJ_N="$(printf '%s' "$BJ_T" | tr -d ' 　。、．，!！?？')"
  [ "${#BJ_N}" -ge 3 ] || return 1
  # 停止語は短い言い切りだけ(≤8文字)。自分の相槌「ちょっと待ってくださいね」等の
  # こだま(長い)が停止語に誤爆して読み上げが止まらないように
  if [ "${#BJ_N}" -le 8 ]; then
    case "$BJ_N" in
      待って*|ちょっと待って|止めて*|とめて*|やめて*|ストップ*|静かに*|しずかに*)
        BARGE_STOPWORD=1; return 0 ;;
    esac
  fi
  [ "${#BJ_N}" -ge 4 ] || return 1
  case "$BJ_T" in
    *ご視聴ありがとう*|*ご清聴ありがとう*|*チャンネル登録*|*次の動画*|*お会いしましょう*|*高評価*|*概要欄*|*最後までご覧いただき*)
      return 1 ;;
  esac
  sente_noise_extra_match "$BJ_T" && return 1
  sente_lang_plausible "$BJ_T" || return 1   # 未知スクリプト=固定フレーズ一覧に無い他言語幻聴の疑い
  if [ -n "${LAST_REPLY_NORM:-}" ]; then
    case "$LAST_REPLY_NORM" in *"$BJ_N"*) return 1 ;; esac
    BJ_R="$(sente_echo_ratio "$BJ_N" "$LAST_REPLY_NORM")"
    case "$BJ_R" in
      0.6[5-9]|0.[7-9]*|1*) return 1 ;;                     # ほぼこだま → 話を続ける
      0.3[5-9]|0.[4-5]*|0.6[0-4]) BARGE_RETRY=1; return 0 ;; # こだま混じり → 止めて聞き返す
    esac
  fi
  BARGE_HEARD="$BJ_T"
  return 0
}
sente_digest_run() {  # 📝「今日のまとめ」: turns.jsonl の当日ok分をLLMで一発要約し、
                       # ~/Library/Logs/Sente/digest-YYYYMMDD.md に保存+先頭2文だけ読み上げ+全文表示する
  DG_DATE="$(date '+%Y%m%d')"
  DG_DIR="$(dirname "$SENTE_TURNS")"
  mkdir -p "$DG_DIR" 2>/dev/null || true
  DG_FILE="$DG_DIR/digest-$DG_DATE.md"
  DG_HEARD=""
  if [ -f "$SENTE_TURNS" ] && command -v python3 >/dev/null 2>&1; then
    # tsは"YYYYMMDD-HHMMSS"(sente_log_turn参照)なので前方一致で当日分だけ拾える
    # 🪤 heredocを$( )の中に入れない: macOS /bin/sh(bash 3.2)がパースできず起動不能になる → 一時ファイル経由
    DG_TF="$(mktemp "${TMPDIR:-/tmp}/sente_dg_XXXXXX")"
    python3 - "$SENTE_TURNS" "$DG_DATE" > "$DG_TF" <<'PYDIGEST' 2>/dev/null || true
import json, sys
turns_path, today = sys.argv[1], sys.argv[2]
out = []
try:
    with open(turns_path) as f:
        for line in f:
            try:
                r = json.loads(line)
            except Exception:
                continue
            if r.get("outcome") != "ok":
                continue
            if not str(r.get("ts", "")).startswith(today):
                continue
            h = (r.get("heard") or "").strip()
            if h:
                out.append(h)
except Exception:
    pass
print("\n".join(out))
PYDIGEST
    DG_HEARD="$(cat "$DG_TF" 2>/dev/null)"; rm -f "$DG_TF"
  fi
  if [ -z "$DG_HEARD" ]; then
    printf '今日はまだ会話がありません\n'
    koe_say_sync "今日はまだ会話がありません"
    return 0
  fi
  # latency.jsonlは「往復にかかった秒数」のログ。あれば当日件数だけ添えて要約の材料にする
  # (無くても致命ではないので失敗は静かに0扱い)
  DG_LAT_N=0
  if [ -f "$SENTE_LAT" ] && command -v python3 >/dev/null 2>&1; then
    DG_TF2="$(mktemp "${TMPDIR:-/tmp}/sente_dgl_XXXXXX")"
    python3 - "$SENTE_LAT" "$DG_DATE" > "$DG_TF2" <<'PYLAT' 2>/dev/null || true
import json, sys, time
lat_path, today = sys.argv[1], sys.argv[2]
n = 0
try:
    with open(lat_path) as f:
        for line in f:
            try:
                r = json.loads(line)
            except Exception:
                continue
            ts = r.get("ts")
            if ts is None:
                continue
            if time.strftime("%Y%m%d", time.localtime(ts)) == today:
                n += 1
except Exception:
    pass
print(n)
PYLAT
    DG_LAT_N="$(cat "$DG_TF2" 2>/dev/null)"; rm -f "$DG_TF2"
    case "$DG_LAT_N" in ''|*[!0-9]*) DG_LAT_N=0 ;; esac
  fi
  printf '  📝 今日のまとめを作っています…\n' >&2
  DG_PROMPT="今日Senteとの会話で聞き取れた発話の一覧です(応答した往復:${DG_LAT_N}件)。前置きや締めの挨拶は書かず、今日のSenteとの会話の要点を3〜5行の日本語の箇条書きでまとめてください。
$DG_HEARD"
  DG_OUTF="$(mktemp "${TMPDIR:-/tmp}/sente_digest_out_XXXXXX")"
  # 🔇 プラグイン(koe-speak.js)の自動読み上げと二重にならないよう、この一発だけAGENT_KOE=0で回す
  # (sente-acp.pyのドライバと同じ流儀・読み上げは先頭2文だけこの後koe_say_syncで自分でやる)
  ( AGENT_KOE=0 sente_exec run "$DG_PROMPT" ) >"$DG_OUTF" 2>/dev/null & DG_PID=$!
  ( sleep "${TE_DIGEST_TIMEOUT:-60}"; kill -TERM "$DG_PID" 2>/dev/null; sleep 2; kill -KILL "$DG_PID" 2>/dev/null ) >/dev/null 2>&1 & DG_KILLER=$!
  { wait "$DG_PID"; DG_RC=$?; } 2>/dev/null
  kill "$DG_KILLER" 2>/dev/null; { wait "$DG_KILLER"; } 2>/dev/null
  DG_OUT="$(sed 's/\x1b\[[0-9;]*m//g' "$DG_OUTF" 2>/dev/null | sed '/^[[:space:]]*$/d')"
  rm -f "$DG_OUTF"
  if [ -z "$DG_OUT" ]; then
    printf '  ⚠ まとめの生成に失敗しました(終了コード%s)\n' "${DG_RC:-?}" >&2
    koe_say_sync "まとめの生成に失敗しました"
    return 0
  fi
  { printf '# 今日のまとめ (%s)\n\n' "$DG_DATE"; printf '%s\n' "$DG_OUT"; } > "$DG_FILE"
  printf '%s\n' "$DG_OUT"
  DG_FIRST2="$(printf '%s\n' "$DG_OUT" | head -2 | tr '\n' ' ')"
  koe_say_sync "$DG_FIRST2"
  printf '  💾 保存しました: %s\n' "$DG_FILE" >&2
}
# 🎙 会話からの声切替(2026-08-06本人指示「会話からも切り替えて」)。
# 聞き取った呼び名→声ID。既知の呼び名+英字はそのままID扱い。~/.config/teai/voice-names
# (1行=名前=id)があればそちらを先に引く=自分で呼び名を足せる。
sente_voice_name_to_id() {
  VN="$(printf '%s' "$1" | tr -d ' 　')"
  [ -n "$VN" ] || return 0
  if [ -f "$CONFIG_DIR/voice-names" ]; then
    VMAP="$(grep -m1 "^$VN=" "$CONFIG_DIR/voice-names" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]')"
    [ -n "$VMAP" ] && { printf '%s\n' "$VMAP"; return 0; }
  fi
  case "$VN" in
    ゆうき|ユウキ|優貴|ゆき|ユキ) echo "yuki" ;;
    けんたろう|ケンタロウ|健太郎|けんたろ|ケンタロ) echo "kentaro" ;;
    りょうぞう|リョウゾウ|良蔵) echo "ryozo" ;;
    のじま|ノジマ|野島) echo "nojima" ;;
    
    ばばちゃん|ばば|ババ) echo "bb" ;;
    じょせい|女性|女性の声|女の人) echo "female" ;;
    じょせい1|女性1|女性いち) echo "female1" ;;
    じょせい2|女性2|女性に) echo "female2" ;;
    じょせい3|女性3|女性さん) echo "female3" ;;
    きてい|既定|標準|デフォルト|でふぉると) echo "default" ;;
    *)
      case "$VN" in
        *[!A-Za-z0-9_-]*)
          # かな名 → ヘボン式ローマ字に変換してID候補にする(enrollした声のhandleを声で呼べる:
          # 「まおの声にして」→ mao。変換しきれない字が混ざる名前は不明扱い=正直に聞き返す)
          python3 -c '
import sys
K={"きゃ":"kya","きゅ":"kyu","きょ":"kyo","しゃ":"sha","しゅ":"shu","しょ":"sho","ちゃ":"cha","ちゅ":"chu","ちょ":"cho",
"にゃ":"nya","にゅ":"nyu","にょ":"nyo","ひゃ":"hya","ひゅ":"hyu","ひょ":"hyo","みゃ":"mya","みゅ":"myu","みょ":"myo",
"りゃ":"rya","りゅ":"ryu","りょ":"ryo","ぎゃ":"gya","ぎゅ":"gyu","ぎょ":"gyo","じゃ":"ja","じゅ":"ju","じょ":"jo",
"びゃ":"bya","びゅ":"byu","びょ":"byo","ぴゃ":"pya","ぴゅ":"pyu","ぴょ":"pyo",
"あ":"a","い":"i","う":"u","え":"e","お":"o","か":"ka","き":"ki","く":"ku","け":"ke","こ":"ko",
"さ":"sa","し":"shi","す":"su","せ":"se","そ":"so","た":"ta","ち":"chi","つ":"tsu","て":"te","と":"to",
"な":"na","に":"ni","ぬ":"nu","ね":"ne","の":"no","は":"ha","ひ":"hi","ふ":"fu","へ":"he","ほ":"ho",
"ま":"ma","み":"mi","む":"mu","め":"me","も":"mo","や":"ya","ゆ":"yu","よ":"yo",
"ら":"ra","り":"ri","る":"ru","れ":"re","ろ":"ro","わ":"wa","を":"o","ん":"n",
"が":"ga","ぎ":"gi","ぐ":"gu","げ":"ge","ご":"go","ざ":"za","じ":"ji","ず":"zu","ぜ":"ze","ぞ":"zo",
"だ":"da","ぢ":"ji","づ":"zu","で":"de","ど":"do","ば":"ba","び":"bi","ぶ":"bu","べ":"be","ぼ":"bo",
"ぱ":"pa","ぴ":"pi","ぷ":"pu","ぺ":"pe","ぽ":"po"}
s=sys.argv[1]
# カタカナ→ひらがな
s="".join(chr(ord(c)-0x60) if "ァ"<=c<="ヶ" else c for c in s)
out="";i=0;ok=True
while i<len(s):
    if s[i]=="っ" and i+1<len(s):
        nx=K.get(s[i+1:i+3]) or K.get(s[i+1])
        out+=(nx[0] if nx else "");i+=1;continue
    if s[i]=="ー":
        i+=1;continue
    hit=K.get(s[i:i+2])
    if hit: out+=hit;i+=2;continue
    hit=K.get(s[i])
    if hit: out+=hit;i+=1;continue
    ok=False;break
print(out if ok and out else "")' "$VN" 2>/dev/null ;;
        *) printf '%s\n' "$VN" ;;
      esac ;;
  esac
}

sente_voice_apply() {  # $1=声ID — 実合成で確かめてからこの場で切替+永続保存。だめなら正直に言う
  SVA="$1"
  SVT="$(mktemp "${TMPDIR:-/tmp}/te_vsw_XXXXXX").mp3"
  SVC="$(curl -s -m 30 -o "$SVT" -w '%{http_code}' -X POST "${KOE_BASE:-https://koe.live}/api/speak" \
    -H 'Content-Type: application/json' \
    -d "$(python3 -c 'import json,sys;print(json.dumps({"text":"はい、この声に変わりました。","user_id":sys.argv[1],"source":"sente"}))' "$SVA" 2>/dev/null)" 2>/dev/null)"
  if [ "$SVC" = "200" ] && [ "$(wc -c < "$SVT" 2>/dev/null || echo 0)" -gt 1000 ]; then
    KOE_VOICE="$SVA"; export KOE_VOICE
    mkdir -p "$CONFIG_DIR" 2>/dev/null; printf '%s\n' "$SVA" > "$CONFIG_DIR/voice" 2>/dev/null || true
    printf '  🎙 声を %s に切り替えました\n' "$SVA" >&2
    sente_play "$SVT"
    sente_warm_fillers   # 新しい声で相槌の作り置きを裏で貯め直す
  else
    printf '  🔴 その声(%s)は使えませんでした(HTTP %s)\n' "$SVA" "${SVC:-?}" >&2
    koe_say_sync "ごめんなさい、その声は使えませんでした。"
  fi
  rm -f "$SVT"
}

sente_intercept_command() {  # 声の割り込みコマンド: THEARDが短い定型句ならLLMには投げず即動作する
  # (「今日のまとめ」だけは例外で、内部でoc runを1回だけ使って要約する)。
  # マッチして処理済みなら0を返す(呼び出し側は turns.jsonl に積まず continue すること)。
  # 誤爆防止のため、空白/句読点を除いた正規化が14文字以下の完全一致寄りのパターンだけ拾う
  IC_NORM="$(printf '%s' "${THEARD:-}" | tr -d ' 　。、．，!！?？~〜…')"
  [ -n "$IC_NORM" ] || return 1
  # 🔀 実行エンジン(2026-08-06本人指示)。恒久切替の完全一致句(「エンジンをクロードコードにして」等)は
  # 14文字を超えるものがあり、一回だけ使うprefix(「クロードコードで◯◯」)は残りが依頼文なので長さが
  # 読めない。どちらも誤爆しにくい語(「エンジン」/「クロードコードで」等)なので長さ制限より前で判定する
  case "$IC_NORM" in
    エンジンをクロードコードにして|エンジンをクロードにして|エンジンをクロード・コードにして)
      sente_engine_switch claude; return 0 ;;
    エンジンをコデックスにして|エンジンをコーデックスにして)
      sente_engine_switch codex; return 0 ;;
    エンジンをオープンコードにして|エンジン戻して|エンジンもどして|エンジンを戻して|エンジンをもとに戻して|エンジンを元に戻して)
      sente_engine_switch opencode; return 0 ;;
    いまのエンジンは|今のエンジンは|いまのエンジン何|今のエンジン何|エンジン何|エンジンなに)
      IC_ENOW="$(sente_engine_get)"
      printf '  🔧 いまのエンジン: %s\n' "$IC_ENOW" >&2
      koe_say_sync "いまは、${IC_ENOW}です。"
      return 0 ;;
    クロードコードで*|クロード・コードで*|claudeで*|Claudeで*|CLAUDEで*)
      IC_REQ="${IC_NORM#クロードコードで}"; IC_REQ="${IC_REQ#クロード・コードで}"
      IC_REQ="${IC_REQ#claudeで}"; IC_REQ="${IC_REQ#Claudeで}"; IC_REQ="${IC_REQ#CLAUDEで}"
      sente_engine_once claude "$IC_REQ"
      return 0 ;;
    コデックスで*|コーデックスで*|codexで*|Codexで*|CODEXで*)
      IC_REQ="${IC_NORM#コデックスで}"; IC_REQ="${IC_REQ#コーデックスで}"
      IC_REQ="${IC_REQ#codexで}"; IC_REQ="${IC_REQ#Codexで}"; IC_REQ="${IC_REQ#CODEXで}"
      sente_engine_once codex "$IC_REQ"
      return 0 ;;
  esac
  [ "${#IC_NORM}" -le 14 ] || return 1
  case "$IC_NORM" in
    待って|待った|ストップ|止めて|止まって)
      sente_stop_speaking
      printf '  ⏹ はい\n' >&2
      return 0 ;;
    もう一回|もう一度|もういちど|もっかい|もう一回言って|もう一度言って|もういちど言って|もっかい言って)
      sente_stop_speaking
      if [ -n "${LAST_REPLY_TXT:-}" ]; then
        printf '%s\n' "$LAST_REPLY_TXT"   # 通常の返答表示と同じく画面にも出す(音声OFF環境でも分かる)
        koe_speak_text "$LAST_REPLY_TXT"
      else
        printf '%s\n' "まだ何も言ってません"
        koe_say_sync "まだ何も言ってません"
      fi
      return 0 ;;
    静かにして|読み上げ止めて|ミュート|声消して|声けして|声オフ)
      printf '  🔇 はい、読み上げを止めますね\n' >&2   # 音声OFF環境でも状態が分かるよう画面にも出す
      koe_say_sync "はい、読み上げを止めますね"   # ミュート前に言い切る
      : > "$SENTE_MUTE_FILE" 2>/dev/null || true   # 🔇 muteファイルが正本(sente_mutedが毎回見る)・次回起動後も無音のまま
      return 0 ;;
    喋って|声出して|読み上げして|声オン|声つけて)
      AGENT_KOE=1; export AGENT_KOE   # AGENT_KOE=0のセッションでも、声で頼まれたら戻す
      rm -f "$SENTE_MUTE_FILE" 2>/dev/null || true   # 先に解除してから言う(でないと自分の声も飲み込む)
      printf '  🔊 はい、戻しました\n' >&2
      koe_say_sync "はい、戻しました"
      return 0 ;;
    先手オフにして|先手を止めて|先手やめて|先手なしで|先手モードオフ)
      : > "$SENTE_OPENING_OFF_FILE" 2>/dev/null || true   # 次回起動後も自動発火なしのまま(能動的な「次何やる?」は引き続き応答)
      printf '  ♟ はい、先手の提案は自動では出さないようにしますね\n' >&2
      koe_say_sync "はい、先手の提案は自動では出さないようにしますね。次何やる?と聞けばいつでも答えます。"
      return 0 ;;
    先手オンにして|先手つけて|先手再開|先手モードオン)
      rm -f "$SENTE_OPENING_OFF_FILE" 2>/dev/null || true
      printf '  ♟ はい、先手の提案を再開しますね\n' >&2
      koe_say_sync "はい、先手の提案を再開しますね。"
      return 0 ;;
    まとめ|まとめして|まとめ作って|まとめて|今日のまとめ|今日のまとめして|今日のまとめ作って|議事録|議事録して|議事録作って)
      sente_digest_run
      return 0 ;;
    次何やる|次なにやる|つぎ何やる|つぎなにやる|次は何|つぎは何|次やること|何やればいい|なにやればいい|何すればいい|次どうする)
      # ♟ その場で状況を見て一手を提案(スキャン+LLMで数秒かかるので一言先に返す)
      printf '  ♟ ちょっと見てきますね\n' >&2
      koe_say_sync "ちょっと見てきますね"
      sente_opening talk
      return 0 ;;
    自分の声を登録して|自分の声を登録|声を登録したい|声を登録して|声登録|声登録して)
      # 🎙 お客様が自分の声をKOEに登録する導線(2026-08-06本人指示)。登録ページを開き、
      # 表示される一文(あとで聴き返したら宝物になる宣言文)を読むだけ。登録後は
      # 「◯◯の声にして」で自分の声がSenteの声になる
      printf '  🎙 声の登録ページを開きます → https://koe.live/enroll\n' >&2
      { command -v open >/dev/null 2>&1 && open "https://koe.live/enroll"; } || \
        { command -v xdg-open >/dev/null 2>&1 && xdg-open "https://koe.live/enroll"; } || true
      koe_say_sync "声の登録ページを開きました。好きなアイディーを決めて、表示される一文をあなたの声で読んでください。登録できたら、そのアイディーの声にして、と言えばわたしの声があなたの声に変わります。"
      return 0 ;;
    声戻して|声もどして|元の声にして|もとの声にして|元の声に戻して)
      rm -f "$CONFIG_DIR/voice" 2>/dev/null
      KOE_VOICE="yuki"; export KOE_VOICE
      printf '  🎙 既定の声に戻しました\n' >&2
      koe_say_sync "はい、この声に戻りました。"
      return 0 ;;
    いまの声は|今の声は|いまの声誰|今の声誰|いま誰の声|今誰の声)
      printf '  🎙 いまの声: %s\n' "${KOE_VOICE:-yuki}" >&2
      koe_say_sync "いまは、${KOE_VOICE:-yuki}の声です。"
      return 0 ;;
    声を*に変えて|声を*にかえて|声を*にして)
      SVN="${IC_NORM#声を}"; SVN="${SVN%に変えて}"; SVN="${SVN%にかえて}"; SVN="${SVN%にして}"
      SVID="$(sente_voice_name_to_id "$SVN")"
      if [ -n "$SVID" ]; then sente_voice_apply "$SVID"; else
        printf '  🔴 「%s」の声が分かりませんでした\n' "$SVN" >&2
        koe_say_sync "ごめんなさい、その声が分かりませんでした。"
      fi
      return 0 ;;
    *の声にして|*の声に変えて|*の声にかえて|*の声で話して)
      SVN="${IC_NORM%%の声*}"
      SVID="$(sente_voice_name_to_id "$SVN")"
      if [ -n "$SVID" ]; then sente_voice_apply "$SVID"; else
        printf '  🔴 「%s」の声が分かりませんでした\n' "$SVN" >&2
        koe_say_sync "ごめんなさい、その声が分かりませんでした。"
      fi
      return 0 ;;
  esac
  return 1
}
sente_bg_detect() {  # $1=THEARD → 0:裏タスク(「裏で/バックグラウンドで」始まり or 「やっておいて/やっといて」終わり)
  case "$1" in
    裏で*|バックグラウンドで*) return 0 ;;
    *やっておいて|*やっといて) return 0 ;;
  esac
  return 1
}
sente_bg_start() {  # $1=oc runに渡す依頼文(ペルソナ付きでも可) $2=報告用ラベルの元(素のTHEARD)
                     # → oc run をnohupで裏実行し、即戻る
  BGDIR="$CONFIG_DIR/bg"
  mkdir -p "$BGDIR" 2>/dev/null || true
  SENTE_BG_SEQ=$(( ${SENTE_BG_SEQ:-0} + 1 ))
  BGTS="$(date +%s)_${SENTE_BG_SEQ}"
  BGOUT="$BGDIR/$BGTS.out"
  # 🪤 talkループ自体は長生きするのでnohupは必須ではないが、端末が閉じても生き残るよう明示しておく
  nohup "$(sente_exec_path)" run "$1" >"$BGOUT" 2>&1 &
  BGPID=$!
  # ⚠JSONは必ずjson.dumpsで作る(koe_say_syncと同じ理由: 生埋め込みは引用符入りテキストで壊れる)
  # ラベルはペルソナ抜きの素の依頼文から取る(ペルソナ文が混ざると報告が読みづらくなる)
  BGLABEL_JSON="$(printf '%s' "${2:-$1}" | cut -c1-30 | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().rstrip()))' 2>/dev/null || echo '""')"
  printf '{"label":%s,"started":%s,"pid":%s}\n' "$BGLABEL_JSON" "$(date +%s)" "$BGPID" > "$BGDIR/$BGTS.json"
  # 声モード用の短いoc_run_guardedタイムアウトは使わず、長め上限(既定30分・TE_BG_TIMEOUTで変更可)を自前で持つ
  ( sleep "${TE_BG_TIMEOUT:-1800}"; kill -TERM "$BGPID" 2>/dev/null ) >/dev/null 2>&1 &
}
sente_bg_check() {  # bg/ を走査し、終わっているジョブがあれば1件だけ報告してdoneへリネームする(二重報告防止)
  BGDIR="$CONFIG_DIR/bg"
  [ -d "$BGDIR" ] || return 0
  for BGJ in "$BGDIR"/*.json; do
    [ -f "$BGJ" ] || continue
    case "$BGJ" in *.done.json) continue ;; esac
    BGPID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("pid",""))' "$BGJ" 2>/dev/null || true)"
    [ -n "$BGPID" ] || continue
    kill -0 "$BGPID" 2>/dev/null && continue   # まだ実行中
    BGLABEL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("label",""))' "$BGJ" 2>/dev/null || true)"
    BGOUT="${BGJ%.json}.out"
    BGTAIL="$(sed 's/\x1b\[[0-9;]*m//g' "$BGOUT" 2>/dev/null | grep -av '^\s*$' | tail -1)"
    [ -n "$BGTAIL" ] || BGTAIL="(結果なし)"
    BGMSG="さっきの『${BGLABEL}』終わりました。$BGTAIL"
    printf '  ✅ %s\n' "$BGMSG" >&2
    koe_say_sync "$BGMSG"
    mv "$BGJ" "${BGJ%.json}.done.json" 2>/dev/null || true
    return 0   # 1ターンで1件だけ報告(読み上げが重ならないように・残りは次ターンで拾う)
  done
}
sente_wake_check() {  # $1=テキスト → センテ/せんて/先手/sente(大小文字不問)で始まれば
                       # ウェイクワード+直後の区切り(、。スペース等)を剥がした残りをWAKE_RESTへ入れて0。
                       # 始まらなければ1(呼び出し側は聞き流してcontinueすること)。
                       # 🪤 stdout+$()で返すと末尾改行が剥がれて事故る→変数(WAKE_REST)渡し
  WK="$1"
  # 呼びかけ前の空白・読点は許容(剥がしてから先頭一致を見る)
  while :; do
    case "$WK" in
      [\ 　、。,.]*) WK="${WK#?}" ;;
      *) break ;;
    esac
  done
  case "$WK" in
    センテ*) WK="${WK#センテ}" ;;
    せんて*) WK="${WK#せんて}" ;;
    先手*) WK="${WK#先手}" ;;
    [Ss][Ee][Nn][Tt][Ee]*) WK="${WK#[Ss][Ee][Nn][Tt][Ee]}" ;;
    *) return 1 ;;
  esac
  # ウェイクワード直後の区切りも剥がす(「センテ、天気は」→「天気は」)
  while :; do
    case "$WK" in
      [\ 　、。,.!！?？]*) WK="${WK#?}" ;;
      *) break ;;
    esac
  done
  WAKE_REST="$WK"
  return 0
}
sente_meter_draw() {  # $1=rec(-S)のstderrログ → 最新のVUを1行メーターに描き直す。
                      # soxの進捗行は「[  ===|===  ]」のVU部を持つ(モノラルは左右対称)。
                      # 左半分の = - ! を数えて0〜6段のバーにする(!はクリップ=振り切り)
  ML="$(tail -c 200 "$1" 2>/dev/null | tr '\r' '\n' | sed -n 's/.*\[\([^][]*|[^][]*\)\].*/\1/p' | tail -1)"
  MLL="${ML%%|*}"
  MN="$(printf '%s' "$MLL" | tr -cd '=!-' | wc -c | tr -d ' ')"
  MB=""; MI=0
  while [ "$MI" -lt 6 ]; do
    if [ "$MI" -lt "${MN:-0}" ]; then MB="${MB}█"; else MB="${MB}░"; fi
    MI=$((MI+1))
  done
  # 🎨 表示だけの色付け(段数計算=上のロジックは不変)。クリップ(!が混じる)=赤・高め=黄・それ以外=緑
  case "$MLL" in
    *'!'*) MCOL="$SC_RED" ;;
    *) if [ "${MN:-0}" -ge 4 ] 2>/dev/null; then MCOL="$SC_YELLOW"; else MCOL="$SC_GREEN"; fi ;;
  esac
  # 🍎 Apple認識の途中経過をメーターの隣にリアルタイム表示(2026-08-10本人指示)。
  # 長い発話は末尾だけ(直近28文字)・ファイルが無ければ従来どおりメーターのみ
  MAP=""
  [ -n "${2:-}" ] && [ -s "$2" ] && MAP="$(tail -c 84 "$2" 2>/dev/null | tr -d '\n')"
  if [ -n "$MAP" ]; then
    printf "\r\033[K  🎙 ${MCOL}%s${SC_RESET} ${SC_DIM}%s${SC_RESET} " "$MB" "$MAP" >&2
  else
    printf "\r  🎙 ${MCOL}%s${SC_RESET} " "$MB" >&2
  fi
}
sente_meter_clear() { printf '\r\033[K' >&2; }
sente_type_line() {  # $1=打たれた最初のキー → 入力された1行をstdoutへ(Enterで送信)
  TK=""; TSUB=0
  case "$1" in
    "$SENTE_BS"|"$SENTE_DEL") ;;   # 最初のキーがBackspaceなら消す対象が無いので無視
    *) TK="$1" ;;
  esac
  # IMEの変換確定などでまとめて届いた分を先に拾う(こうしないと画面に出ないまま送られる)。
  # Backspace/Deleteは1文字消す(2026-08-08本人報告「文字入力削除できない」の実修正)
  while :; do
    sente_kb_read
    [ -n "$K" ] || break
    case "$K" in
      "$SENTE_NL"|"$SENTE_CR") TSUB=1; break ;;
      # Esc/生Ctrl-C=終了(2026-08-09本人要望)。この関数は$()内サブシェルで走るので
      # exitしても親は死なない → kill -INT $$($$はサブシェルでも親のPID)で親のtrapを発火させる
      "$SENTE_ESC"|"$SENTE_CTRLC") kill -INT "$$" 2>/dev/null; return 1 ;;
      "$SENTE_BS"|"$SENTE_DEL") TK="${TK%?}" ;;
      *) TK="$TK$K" ;;
    esac
  done
  sente_meter_clear
  if [ "$TSUB" = 1 ]; then
    printf '  ⌨ %s\n' "$TK" >&2
    printf '%s' "$TK"
    return 0
  fi
  sente_kb_close   # 行の残りは端末の行編集(削除キーなど)に任せる
  printf '  ⌨ %s' "$TK" >&2
  TLINE=""
  IFS= read -r TLINE </dev/tty 2>/dev/null || TLINE=""
  sente_kb_open
  printf '%s%s' "$TK" "$TLINE"
}

koe_vol_hint() {
  if [ "$(uname)" = "Darwin" ]; then
    IV="$(osascript -e 'input volume of (get volume settings)' 2>/dev/null || true)"
    [ -n "$IV" ] && echo "     いまのマイク入力音量: ${IV}%(システム設定→サウンド→入力で上げられます)" >&2
  fi
}

# 🎚 認識精度の自動向上(本人指示2026-08-06「声の認識精度も自動的に向上させてほしい」):
# 音が小さい時に「上げてください」と言うだけでなく、こちらで入力音量を上げる。
# 上げるだけ(下げない)・上限85%・1セッション1回まで・TE_NO_MIC_AUTOFIX=1で無効。
KOE_MIC_FIXED=0
koe_vol_autofix() {
  [ "${TE_NO_MIC_AUTOFIX:-0}" = "1" ] && { koe_vol_hint; return 0; }
  [ "$KOE_MIC_FIXED" = 1 ] && { koe_vol_hint; return 0; }
  [ "$(uname)" = "Darwin" ] || { koe_vol_hint; return 0; }
  IV="$(osascript -e 'input volume of (get volume settings)' 2>/dev/null || true)"
  if [ -n "$IV" ] && [ "$IV" -lt 70 ] 2>/dev/null; then
    if osascript -e 'set volume input volume 75' 2>/dev/null; then
      KOE_MIC_FIXED=1
      echo "  🎚 マイク入力音量を ${IV}% → 75% に上げました(聞き取り精度のため。戻す時はシステム設定→サウンド→入力)" >&2
      return 0
    fi
  fi
  koe_vol_hint
}

# 🎧 AEC録音(2026-08-06本人指示「パソコンの音は拾わないでほしい」): senterec(Voice Processing I/O)が
# あればsoxの代わりに使う。このMac自身が鳴らす音(TTS読み上げ・動画・通知音)をOSがマイク入力から差し引く。
# 実測: スピーカー再生をsoxはmean -26.6dBで拾うが、senterecは-41.7dB(15dB減・大半は録音開始もしない)。
# 別デバイスの音(ラジオ等)は物理音なので消せない=こだま判定・幻聴フィルタが引き続き受け持つ。
# TE_NO_AEC=1で常にsoxへ。senterecはインストーラがswiftc存在時に自動ビルド。
# 🔊 2026-08-08本人報告「Macの自分の音も拾っちゃう」(同じMacで動画/ポッドキャスト再生中):
# Voice ProcessingはこのAVAudioEngine自身の出力しか打ち消せず、他プロセスの音は対象外。
# senterec側でCoreAudio(既定出力デバイスが鳴っているか)を見て録音開始を抑制するゲートを
# 追加した(打ち消しではなく検知ベース・新規権限不要・実機で動作実証済み)。
# TE_NO_SYS_AUDIO_GATE=1で無効化(--no-sys-gateとしてsenterecに渡す)。
# 🔴 2026-08-10本人報告「認識精度悪くなってる」の真相=このゲートで耳が永久に塞がっていた:
# IsRunningSomewhereは「デバイス稼働中」であって「実際に音が出ている」ではない。Chromeの
# 無音タブやKoe常駐がデバイスを掴みっぱなしのMacでは常にtrue→全ターンが未録音タイムアウト
# (実ログ: 08-08 12:15のビルド以降turns.jsonlがほぼ全部empty・4KBのヘッダだけwav)。
# → ゲートは「完全ブロック」をやめ「感度低下(しきい値2.5倍)+持続する声(0.6秒)は必ず通す」に変更。
SENTE_AEC_BIN="$CONFIG_DIR/bin/senterec"
sente_rec_q() {  # $1=out.wav $2=無音打ち切り秒 $3=最長秒 [$4=開始しきい値(既定0.02=soxの2%相当)]
  if [ "${TE_NO_AEC:-0}" != "1" ] && [ -x "$SENTE_AEC_BIN" ]; then
    "$SENTE_AEC_BIN" "$1" --silence "$2" --max "$3" --start-thresh "${4:-0.02}" --stop-thresh "${4:-0.02}" ${TE_NO_SYS_AUDIO_GATE:+--no-sys-gate} $([ "${TE_APPLE_STT:-1}" = "1" ] && printf -- '--apple %s.apple' "$1") >/dev/null 2>&1
  else
    case "${4:-0.02}" in 0.05) SRQP="5%"; SRQO="0.3" ;; *) SRQP="2%"; SRQO="0.1" ;; esac
    rec -q "$1" silence 1 "$SRQO" "$SRQP" 1 "$2" "$SRQP" trim 0 "$3" >/dev/null 2>&1
  fi
}
sente_rec_meter() {  # $1=out.wav $2=無音打ち切り秒 $3=最長秒 $4=メーターログ(stderr) [$5=開始しきい値(既定0.02)]
  if [ "${TE_NO_AEC:-0}" != "1" ] && [ -x "$SENTE_AEC_BIN" ]; then
    "$SENTE_AEC_BIN" "$1" --silence "$2" --max "$3" --start-thresh "${5:-0.02}" --stop-thresh "${5:-0.02}" ${TE_NO_SYS_AUDIO_GATE:+--no-sys-gate} $([ "${TE_APPLE_STT:-1}" = "1" ] && printf -- '--apple %s.apple' "$1") --meter >/dev/null 2>"$4"
  else
    case "${5:-0.02}" in 0.05) SRMP="5%"; SRMO="0.3" ;; *) SRMP="2%"; SRMO="0.1" ;; esac
    rec -S "$1" silence 1 "$SRMO" "$SRMP" 1 "$2" "$SRMP" trim 0 "$3" >/dev/null 2>"$4"
  fi
}

koe_dur_ok() {  # $1=wav → 0:十分な長さ / 1:短すぎ(ノイズ)。Whisperは0.5秒未満の物音から
                # 「ご視聴ありがとうございました」等を幻聴するので、STTに送る前に切る
  command -v ffprobe >/dev/null 2>&1 || return 0
  D="$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$1" 2>/dev/null)"
  [ -n "$D" ] || return 0
  case "$D" in 0.[0-6]*) return 1 ;; esac
  return 0
}

koe_vol_check() {  # $1=wav → 0:OK / 1:ほぼ無音。小さい時は警告だけ出して続行
  command -v ffmpeg >/dev/null 2>&1 || return 0
  MV="$(ffmpeg -i "$1" -af volumedetect -f null /dev/null 2>&1 | sed -n 's/.*max_volume: \(-\{0,1\}[0-9.]*\) dB.*/\1/p')"
  [ -n "$MV" ] || return 0
  MVI="${MV%%.*}"
  if [ "${MVI:-0}" -le -35 ] 2>/dev/null; then
    echo "  ⚠ ほぼ無音でした(ピーク ${MV}dB)" >&2
    koe_vol_autofix
    return 1
  elif [ "${MVI:-0}" -le -18 ] 2>/dev/null; then
    echo "  ⚠ 音が小さめです(ピーク ${MV}dB)— 聞き取り精度が落ちるかも" >&2
    koe_vol_autofix
  fi
  return 0
}

# `te v` — 声で1回指示: 録音→KOE STT→そのまま run に流す(返事はkoe-speakプラグインが読み上げ)
if [ "${1:-}" = "v" ] || [ "${1:-}" = "voice" ]; then
  shift
  sente_light_env
  VW="$(mktemp "${TMPDIR:-/tmp}/te_v_XXXXXX").wav"
  koe_rec_enter "$VW" || { koe_sfx err; rm -f "$VW"; echo "録音できませんでした(マイク権限/入力音量を確認)" >&2; koe_vol_hint; exit 1; }
  koe_sfx heard
  koe_dur_ok "$VW" || { koe_sfx err; echo "  ⚠ 短すぎます(もう少し長めに話してください)" >&2; rm -f "$VW"; exit 1; }
  koe_vol_check "$VW" || { koe_sfx err; rm -f "$VW"; exit 1; }
  printf '  ⏳ 聞き取り中…\n' >&2
  VHEARD="$(koe_stt "$VW")"; rm -f "$VW"
  [ -n "$VHEARD" ] || { koe_sfx err; echo "聞き取れませんでした。もう一度どうぞ" >&2; exit 1; }
  printf '  🎤 「%s」\n' "$VHEARD" >&2
  koe_sfx think
  set -- run "$VHEARD$SENTE_PERSONA" "$@"
fi

# `te serve` — iPhoneや声の受信箱から届いた依頼を、この手元のマシンで実行する常駐モード。
# 本人確認(声紋・お題・台帳照合)は koe.live 側で済んでいて、ここに来るのは通った依頼だけ。
# 危険度は依頼と一緒に届くので、赤(消す・送る・払う)は既定で実行せず読み上げて知らせる。
# ⚠serveの実ループはここに置かない: 実行にはOC/OPENCODE_CONFIG等の共通初期化(下の load_key〜export)が
# 必要で、初期化より前で oc_run_guarded を呼ぶと `OC: unbound variable` で依頼が全滅する実障害を踏んだ
# (talkと同じ「フラグだけ立てて初期化後に分岐」方式に統一)。
# ── te agent: エージェントの「形式」= 定義1つでどこでも動かす(2026-09-05 本人GO・human-gates 00ff) ──
# 正本 = Sente(opencode)が既に読む agent Markdown(frontmatter+本文=システムプロンプト)。
#   探索順: ./.sente/agent/<name>.md → ./.opencode/agent/<name>.md → ~/.config/sente/agent/<name>.md
# そこに Sente 拡張ブロックを1キーだけ足す(LLM側は未知キーとして無視する=実測済み):
#   sente:
#     runtime: [te, launchd]        # 動かしてよい場所(te=手元CLI / launchd=定期 / serve=声の依頼 / fly / github-action / ios)
#     schedule: "30 21 * * *"       # cron 5欄(分 時 * * 曜日) — launchd の StartCalendarInterval に変換
#     cwd: ~/workspace              # 実行ディレクトリ(セッションもここに積まれる)
#     task: |                       # 無人実行で最初に渡す依頼文(本文=役割、task=今日やること)
#       今日の日報を書いて
# 使い方: te agent list / te agent run <name> ["依頼を上書き"] / te agent deploy <name> --to launchd
#         te agent undeploy <name> / te agent status [name] / te agent show <name>
# 実行は必ず `te run --agent <name>`(=普通の te run と同じ鍵・config・規律注入・watchdog)を通る。
# 🪤 mode は all(または primary)にする: subagent だと `--agent <name>` が既定エージェントへフォールバックし遠回りになる(実測)
# 🪤 frontmatter は YAML だが python3 標準に yaml は無いので、上の形(2段の key: value / [a, b] / task: |)だけ
#    読む最小パーサで済ませる。凝った YAML を書きたくなったらそれは形式の設計ミス。
sente_agent_dirs() {  # 探索順にディレクトリを出す(存在するものだけ)
  for d in "$PWD/.sente/agent" "$PWD/.opencode/agent" "$HOME/.config/sente/agent" "$HOME/.config/opencode/agent"; do
    [ -d "$d" ] && printf '%s\n' "$d"
  done
}
sente_agent_file() {  # $1=name → 定義ファイルのパス(stdout)。無ければ非0
  [ -n "${1:-}" ] || return 1
  for d in $(sente_agent_dirs); do
    [ -f "$d/$1.md" ] && { printf '%s\n' "$d/$1.md"; return 0; }
  done
  return 1
}
sente_agent_meta() {  # $1=file $2=key(runtime|schedule|cwd|task|description|model) → 値(stdout・無ければ空)
  python3 - "$1" "$2" <<'PYAGENT'
import sys, re
path, key = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
fm = m.group(1) if m else ""
lines = fm.split("\n")
top = {}
sente = {}
i = 0
while i < len(lines):
    ln = lines[i]
    if not ln.strip() or ln.lstrip().startswith("#"):
        i += 1; continue
    if not ln.startswith(" "):
        k, _, v = ln.partition(":")
        k = k.strip(); v = v.strip()
        if k == "sente":
            i += 1
            while i < len(lines) and (lines[i].startswith("  ") or not lines[i].strip()):
                sub = lines[i]
                if sub.strip():
                    sk, _, sv = sub.strip().partition(":")
                    sk = sk.strip(); sv = sv.strip()
                    if sv == "|" or sv == ">":
                        buf = []
                        i += 1
                        while i < len(lines) and (lines[i].startswith("    ") or not lines[i].strip()):
                            buf.append(lines[i][4:])
                            i += 1
                        while buf and not buf[-1].strip(): buf.pop()
                        sente[sk] = ("\n" if sv == "|" else " ").join(buf).strip()
                        continue
                    sente[sk] = sv
                i += 1
            continue
        top[k] = v
    i += 1
def clean(v):
    v = v.strip()
    if v.startswith("[") and v.endswith("]"):
        return " ".join(x.strip().strip("'\"") for x in v[1:-1].split(",") if x.strip())
    return v.strip("'\"")
if key in ("runtime", "schedule", "cwd", "task"):
    print(clean(sente.get(key, "")))
else:
    print(clean(top.get(key, "")))
PYAGENT
}
sente_agent_list() {
  FOUND=0
  for d in $(sente_agent_dirs); do
    for f in "$d"/*.md; do
      [ -f "$f" ] || continue
      FOUND=1
      NAME="$(basename "$f" .md)"
      RT="$(sente_agent_meta "$f" runtime)"; SC="$(sente_agent_meta "$f" schedule)"; DS="$(sente_agent_meta "$f" description)"
      DEP=""
      [ -f "$HOME/Library/LaunchAgents/tokyo.hamada.sente-agent-$NAME.plist" ] && DEP=" 🚀launchd"
      [ -f "$(sente_agent_unit "$NAME").timer" ] && DEP="$DEP 🚀systemd"
      printf '  %-18s %-14s %-16s%s  %s\n' "$NAME" "${RT:-te}" "${SC:-(手動)}" "$DEP" "$(printf '%s' "$DS" | cut -c1-60)"
    done
  done
  [ "$FOUND" = 1 ] || echo "  (エージェント定義がありません: ~/.config/sente/agent/<name>.md を作るか te agent init <name>)"
}
sente_agent_show() {  # $1=name
  F="$(sente_agent_file "$1")" || { echo "エージェント '$1' が見つかりません(te agent list)" >&2; return 1; }
  echo "📄 $F"
  printf '  runtime : %s\n  schedule: %s\n  cwd     : %s\n  task    : %s\n' \
    "$(sente_agent_meta "$F" runtime)" "$(sente_agent_meta "$F" schedule)" "$(sente_agent_meta "$F" cwd)" \
    "$(sente_agent_meta "$F" task | head -3 | tr '\n' ' ')"
}
sente_agent_init() {  # $1=name → ~/.config/sente/agent/<name>.md の雛形を作る(既存は触らない)
  [ -n "${1:-}" ] || { echo "使い方: te agent init <name>" >&2; return 1; }
  mkdir -p "$HOME/.config/sente/agent"
  F="$HOME/.config/sente/agent/$1.md"
  [ -f "$F" ] && { echo "既にあります: $F" >&2; return 1; }
  cat > "$F" <<EOF_AGENT
---
description: $1 エージェント(何をする人か1行)
mode: all
sente:
  runtime: [te, launchd]
  schedule: ""
  cwd: ~
  task: |
    (無人実行で最初に渡す依頼。空なら te agent run $1 "依頼" が必須)
---

あなたは $1 エージェントです。役割・守ること・出力の形をここに書く。
EOF_AGENT
  echo "✍️  雛形を作りました: $F(editして te agent run $1 で試す)"
}
sente_agent_run() {  # $1=name [$2=依頼の上書き] → te run --agent <name> "<task>" を cwd で実行
  NAME="${1:-}"; [ -n "$NAME" ] || { echo "使い方: te agent run <name> [\"依頼\"]" >&2; return 1; }
  F="$(sente_agent_file "$NAME")" || { echo "エージェント '$NAME' が見つかりません(te agent list)" >&2; return 1; }
  TASK="${2:-}"
  [ -n "$TASK" ] || TASK="$(sente_agent_meta "$F" task)"
  [ -n "$TASK" ] || { echo "依頼が空です: $F の sente.task を書くか te agent run $NAME \"依頼\"" >&2; return 1; }
  RUN_CWD="$(sente_agent_meta "$F" cwd)"
  case "$RUN_CWD" in "~"|"~/"*) RUN_CWD="$HOME${RUN_CWD#\~}" ;; esac
  [ -n "$RUN_CWD" ] && [ -d "$RUN_CWD" ] && cd "$RUN_CWD"
  LOGD="$SENTE_LOG_DIR"; mkdir -p "$LOGD" 2>/dev/null || true
  printf '{"ts":"%s","agent":"%s","event":"start","cwd":"%s"}\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$NAME" "$PWD" >> "$LOGD/agents.jsonl" 2>/dev/null || true
  # 定義ファイルは Sente 本体がグローバル/プロジェクトの agent ディレクトリから自分で読む(--agent 名指定)。
  # ここを te run に寄せることで、鍵・規律注入・watchdog・記録は普通の te と同一経路になる。
  TE_SELF="$(command -v te 2>/dev/null || echo "$HOME/.local/bin/te")"
  # --agent は Sente 本体の機能なので、engine が claude/codex に切り替わっていてもここは opencode 固定
  # 🌐 無人実行(launchd)はネットワーク断に当たりやすい(テザリング等・2026-09-05 21:30の初回定期実行が
  #    「Cannot connect to API」で落ちた実測)。API疎通を最大5分待ってから始め、接続系エラーで落ちたら
  #    60→120秒空けて最大3回やり直す。出力は一度ファイルに取り(終了コードを確実に拾うため)最後にまとめて出す。
  AG_WAIT=0
  while ! sente_api_ok; do
    if [ "$AG_WAIT" -ge 300 ]; then echo "🔌 ネットワークに届きません(5分待ちました)。そのまま試します" >&2; break; fi
    sleep 15; AG_WAIT=$((AG_WAIT + 15))
  done
  AG_TRY=1; AG_BACK=60
  while :; do
    AG_OUT="$(mktemp "${TMPDIR:-/tmp}/sente_agent_out.XXXXXX")"
    ( TE_ENGINE=opencode "$TE_SELF" run --agent "$NAME" "$TASK" ) > "$AG_OUT" 2>&1
    ST=$?
    cat "$AG_OUT"
    if [ "$ST" -ne 0 ] && [ "$AG_TRY" -lt 3 ] && grep -qiE 'Cannot connect|ECONNREFUSED|ECONNRESET|ETIMEDOUT|ENOTFOUND|fetch failed|socket hang up|network' "$AG_OUT"; then
      echo "🔌 接続エラーのため ${AG_BACK}秒後にやり直します(${AG_TRY}/3)" >&2
      printf '{"ts":"%s","agent":"%s","event":"retry","try":%s,"exit":%s}\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$NAME" "$AG_TRY" "$ST" >> "$LOGD/agents.jsonl" 2>/dev/null || true
      rm -f "$AG_OUT"; sleep "$AG_BACK"; AG_BACK=$((AG_BACK * 2)); AG_TRY=$((AG_TRY + 1))
      continue
    fi
    rm -f "$AG_OUT"; break
  done
  printf '{"ts":"%s","agent":"%s","event":"end","exit":%s,"tries":%s}\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$NAME" "$ST" "$AG_TRY" >> "$LOGD/agents.jsonl" 2>/dev/null || true
  return $ST
}
sente_agent_plist() { echo "$HOME/Library/LaunchAgents/tokyo.hamada.sente-agent-$1.plist"; }
# 🐧 Linux 側の配備先は systemd の user unit(~/.config/systemd/user/sente-agent-<name>.{service,timer})。
# launchd の StartCalendarInterval に相当するのは timer の OnCalendar。ログは journalctl --user -u に入るが、
# launchd 版と同じ場所($SENTE_LOG_DIR/agent-<name>.log)にも StandardOutput=append: で残す。
sente_agent_unit_dir() { echo "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"; }
sente_agent_unit() { echo "$(sente_agent_unit_dir)/sente-agent-$1"; }   # 拡張子なし。.service/.timer を付けて使う
sente_systemd_user_env() {  # systemctl --user が bus を見つけられるよう XDG_RUNTIME_DIR を補完
  # sudo -u / ssh コマンド実行 / cron からだと未設定で "Failed to connect to bus: No medium found"
  # になる(2026-09-10 Ubuntu 24.04 実機)。/run/user/<uid> があればそれを使う
  if [ -z "${XDG_RUNTIME_DIR:-}" ] && [ -d "/run/user/$(id -u)" ]; then
    XDG_RUNTIME_DIR="/run/user/$(id -u)"; export XDG_RUNTIME_DIR
  fi
}
sente_agent_scheduler() {  # このホストの既定スケジューラ → launchd|systemd|none
  case "$(sente_os)" in
    darwin) echo launchd ;;
    linux)  sente_systemd_user_env
            if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then echo systemd; else echo none; fi ;;
    *)      echo none ;;
  esac
}
sente_agent_deployed_count() {  # $1=除外する name。配備済み(同名以外)の本数
  case "$(sente_agent_scheduler)" in
    launchd) ls "$HOME"/Library/LaunchAgents/tokyo.hamada.sente-agent-*.plist 2>/dev/null | grep -v "sente-agent-$1.plist" | wc -l | tr -d ' ' ;;
    systemd) ls "$(sente_agent_unit_dir)"/sente-agent-*.timer 2>/dev/null | grep -v "sente-agent-$1.timer" | wc -l | tr -d ' ' ;;
    *) echo 0 ;;
  esac
}
sente_agent_deploy() {  # $1=name [--to launchd|systemd]
  NAME="${1:-}"; shift || true
  TO="$(sente_agent_scheduler)"
  while [ $# -gt 0 ]; do case "$1" in --to) TO="${2:-}"; shift 2 ;; *) shift ;; esac; done
  [ -n "$NAME" ] || { echo "使い方: te agent deploy <name> [--to launchd|systemd]" >&2; return 1; }
  F="$(sente_agent_file "$NAME")" || { echo "エージェント '$NAME' が見つかりません" >&2; return 1; }
  RT="$(sente_agent_meta "$F" runtime)"
  # runtime 欄は「launchd」で書かれている定義が多い。ホスト側スケジューラ(systemd)への配備でも
  # 意味は同じ「このマシンで定期実行」なので、launchd/systemd/local のいずれかがあれば通す。
  case " $RT " in *" $TO "*|*" launchd "*|*" systemd "*|*" local "*) ;; *) echo "🔒 $NAME の runtime に '$TO' がありません(現在: ${RT:-te})。$F の sente.runtime に足してから。" >&2; return 1 ;; esac
  case "$TO" in
    launchd) [ "$(sente_os)" = "darwin" ] || { echo "launchd は macOS のみです(このホストは $(sente_os)。--to systemd を試してください)" >&2; return 1; } ;;
    systemd) [ "$(sente_agent_scheduler)" = "systemd" ] || { echo "systemd --user が使えません(systemctl --user show-environment が失敗)。ログイン中のセッションで実行してください" >&2; return 1; } ;;
    none)    echo "このホストには対応するスケジューラがありません(macOS=launchd / Linux=systemd --user)。Linux なら: sudo loginctl enable-linger $(id -un) してログインし直す(user セッションの systemd が必要)" >&2; return 1 ;;
    fly|github-action|ios|serve) echo "⏳ --to $TO はまだ未実装です(いまは launchd / systemd のみ。形式は同じ定義を使う前提)" >&2; return 2 ;;
    *) echo "不明な実行場所: $TO" >&2; return 1 ;;
  esac
  # 💳 無料枠は定期実行エージェント 1 本まで(Sente Pro=無制限)。既に配備済みの同名は差し替えなので数えない
  if [ "$(sente_plan)" = "free" ]; then
    AGN="$(sente_agent_deployed_count "$NAME")"
    if [ "${AGN:-0}" -ge 1 ]; then
      echo "💳 無料枠では定期実行エージェントは 1 本までです(配備済み: $AGN 本)。Sente Pro なら無制限: te pro" >&2
      return 2
    fi
  fi
  SC="$(sente_agent_meta "$F" schedule)"
  [ -n "$SC" ] || { echo "schedule が空です: $F の sente.schedule に cron(例: \"30 21 * * *\")を書いてください" >&2; return 1; }
  if [ "$TO" = "systemd" ]; then sente_agent_deploy_systemd "$NAME" "$F" "$SC"; return $?; fi
  CAL="$(python3 - "$SC" <<'PYCRON'
import sys
f = sys.argv[1].split()
if len(f) != 5: sys.exit("cron は5欄(分 時 日 月 曜)で書いてください: %r" % sys.argv[1])
mi, hr, dom, mon, dow = f
def one(v, name, lo, hi):
    if not v.isdigit() or not lo <= int(v) <= hi: sys.exit("%s は %d-%d の数字のみ対応(いまは %r)" % (name, lo, hi, v))
    return int(v)
m = one(mi, "分", 0, 59); h = one(hr, "時", 0, 23)
if dom != "*" or mon != "*": sys.exit("日/月の指定は未対応です(* にしてください)")
dows = []
if dow != "*":
    for part in dow.split(","):
        if "-" in part:
            a, b = part.split("-"); dows += list(range(int(a), int(b) + 1))
        else:
            dows.append(int(part))
def block(d=None):
    s = "    <dict><key>Hour</key><integer>%d</integer><key>Minute</key><integer>%d</integer>" % (h, m)
    if d is not None: s += "<key>Weekday</key><integer>%d</integer>" % d
    return s + "</dict>"
if not dows:
    print("  <key>StartCalendarInterval</key>\n" + block().strip())
else:
    print("  <key>StartCalendarInterval</key><array>\n" + "\n".join(block(d) for d in dows) + "\n  </array>")
PYCRON
)" || return 1
  RUN_CWD="$(sente_agent_meta "$F" cwd)"
  case "$RUN_CWD" in "~"|"~/"*) RUN_CWD="$HOME${RUN_CWD#\~}" ;; esac
  [ -n "$RUN_CWD" ] || RUN_CWD="$HOME"
  LOGD="$HOME/Library/Logs/Sente"; mkdir -p "$LOGD" "$HOME/Library/LaunchAgents"
  P="$(sente_agent_plist "$NAME")"
  TE_PATH="$(command -v te 2>/dev/null || echo "$HOME/.local/bin/te")"
  cat > "$P" <<EOF_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>tokyo.hamada.sente-agent-$NAME</string>
  <key>ProgramArguments</key><array>
    <string>/bin/sh</string><string>-lc</string>
    <string>exec "$TE_PATH" agent run "$NAME"</string>
  </array>
$CAL
  <key>WorkingDirectory</key><string>$RUN_CWD</string>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>$HOME/.local/bin:$HOME/.opencode/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>HOME</key><string>$HOME</string>
    <key>TE_NO_WATCHDOG</key><string>1</string>
  </dict>
  <key>StandardOutPath</key><string>$LOGD/agent-$NAME.log</string>
  <key>StandardErrorPath</key><string>$LOGD/agent-$NAME.log</string>
</dict></plist>
EOF_PLIST
  plutil -lint "$P" >/dev/null || { echo "plist が壊れています: $P" >&2; return 1; }
  launchctl bootout "gui/$(id -u)/tokyo.hamada.sente-agent-$NAME" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$P" || { echo "launchctl bootstrap に失敗: $P" >&2; return 1; }
  echo "🚀 $NAME を launchd に配備しました: 毎日 $(echo "$SC" | awk '{printf "%02d:%02d", $2, $1}') $( [ "$(echo "$SC" | awk '{print $5}')" = "*" ] || printf '(曜日 %s)' "$(echo "$SC" | awk '{print $5}')")"
  echo "   plist=$P / log=$LOGD/agent-$NAME.log / いま試す: launchctl kickstart gui/$(id -u)/tokyo.hamada.sente-agent-$NAME"
}
sente_agent_deploy_systemd() {  # $1=name $2=定義ファイル $3=cron(5欄)。launchd 版と同じ制約(分・時・曜日のみ)
  sente_systemd_user_env
  NAME="$1"; F="$2"; SC="$3"
  # cron 5欄 → systemd OnCalendar。曜日は 0-6(日=0) → Sun..Sat。日/月は launchd 版と揃えて * のみ対応
  ONCAL="$(python3 - "$SC" <<'PYCAL'
import sys
f = sys.argv[1].split()
if len(f) != 5: sys.exit("cron は5欄(分 時 日 月 曜)で書いてください: %r" % sys.argv[1])
mi, hr, dom, mon, dow = f
def one(v, name, lo, hi):
    if not v.isdigit() or not lo <= int(v) <= hi: sys.exit("%s は %d-%d の数字のみ対応(いまは %r)" % (name, lo, hi, v))
    return int(v)
m = one(mi, "分", 0, 59); h = one(hr, "時", 0, 23)
if dom != "*" or mon != "*": sys.exit("日/月の指定は未対応です(* にしてください)")
names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
days = []
if dow != "*":
    for part in dow.split(","):
        if "-" in part:
            a, b = part.split("-"); days += list(range(int(a), int(b) + 1))
        else:
            days.append(int(part))
    days = [names[d % 7] for d in days]
prefix = (",".join(days) + " ") if days else ""
print("%s*-*-* %02d:%02d:00" % (prefix, h, m))
PYCAL
)" || return 1
  RUN_CWD="$(sente_agent_meta "$F" cwd)"
  case "$RUN_CWD" in "~"|"~/"*) RUN_CWD="$HOME${RUN_CWD#\~}" ;; esac
  [ -n "$RUN_CWD" ] || RUN_CWD="$HOME"
  LOGD="$SENTE_LOG_DIR"; UD="$(sente_agent_unit_dir)"; mkdir -p "$LOGD" "$UD"
  U="$(sente_agent_unit "$NAME")"
  TE_PATH="$(command -v te 2>/dev/null || echo "$HOME/.local/bin/te")"
  cat > "$U.service" <<EOF_SVC
[Unit]
Description=Sente agent: $NAME (te agent run)

[Service]
Type=oneshot
WorkingDirectory=$RUN_CWD
Environment=PATH=$HOME/.local/bin:$HOME/.opencode/bin:/usr/local/bin:/usr/bin:/bin
Environment=HOME=$HOME
Environment=TE_NO_WATCHDOG=1
ExecStart=/bin/sh -lc 'exec "$TE_PATH" agent run "$NAME"'
StandardOutput=append:$LOGD/agent-$NAME.log
StandardError=append:$LOGD/agent-$NAME.log
EOF_SVC
  cat > "$U.timer" <<EOF_TMR
[Unit]
Description=Sente agent timer: $NAME ($SC)

[Timer]
OnCalendar=$ONCAL
Persistent=true

[Install]
WantedBy=timers.target
EOF_TMR
  if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze --user verify "$U.service" "$U.timer" 2>&1 | grep -v '^$' | sed 's/^/   /' >&2 || true
    systemd-analyze calendar "$ONCAL" >/dev/null 2>&1 || { echo "OnCalendar が不正です: $ONCAL" >&2; return 1; }
  fi
  systemctl --user daemon-reload || { echo "systemctl --user daemon-reload に失敗" >&2; return 1; }
  systemctl --user enable --now "sente-agent-$NAME.timer" || { echo "timer の有効化に失敗: $U.timer" >&2; return 1; }
  echo "🚀 $NAME を systemd(user) に配備しました: OnCalendar=$ONCAL"
  echo "   unit=$U.{service,timer} / log=$LOGD/agent-$NAME.log / いま試す: systemctl --user start sente-agent-$NAME.service"
  echo "   ※ログアウト後も動かすには: loginctl enable-linger $(id -un)"
}
sente_agent_undeploy() {  # $1=name
  sente_systemd_user_env
  [ -n "${1:-}" ] || { echo "使い方: te agent undeploy <name>" >&2; return 1; }
  DONE=0
  if [ "$(sente_os)" = "darwin" ]; then
    P="$(sente_agent_plist "$1")"
    launchctl bootout "gui/$(id -u)/tokyo.hamada.sente-agent-$1" >/dev/null 2>&1 || true
    [ -f "$P" ] && rm -f "$P" && { echo "🧹 $1 の launchd 配備を外しました"; DONE=1; }
  fi
  U="$(sente_agent_unit "$1")"
  if [ -f "$U.timer" ] || [ -f "$U.service" ]; then
    systemctl --user disable --now "sente-agent-$1.timer" >/dev/null 2>&1 || true
    rm -f "$U.timer" "$U.service"
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    echo "🧹 $1 の systemd 配備を外しました"; DONE=1
  fi
  [ "$DONE" = 1 ] || echo "$1 は配備されていません"
}
sente_agent_status() {  # [$1=name] 配備状態+直近ログ
  sente_systemd_user_env
  FOUND=0
  for P in "$HOME"/Library/LaunchAgents/tokyo.hamada.sente-agent-*.plist; do
    [ -f "$P" ] || break
    N="$(basename "$P" .plist)"; N="${N#tokyo.hamada.sente-agent-}"
    [ -n "${1:-}" ] && [ "$N" != "$1" ] && continue
    FOUND=1
    if launchctl print "gui/$(id -u)/tokyo.hamada.sente-agent-$N" >/dev/null 2>&1; then ST="loaded"; else ST="NOT loaded"; fi
    LAST="$(grep "\"agent\":\"$N\"" "$SENTE_LOG_DIR/agents.jsonl" 2>/dev/null | tail -1)"
    printf '  %-18s launchd %-10s 直近: %s\n' "$N" "$ST" "${LAST:-(未実行)}"
  done
  for T in "$(sente_agent_unit_dir)"/sente-agent-*.timer; do
    [ -f "$T" ] || break
    N="$(basename "$T" .timer)"; N="${N#sente-agent-}"
    [ -n "${1:-}" ] && [ "$N" != "$1" ] && continue
    FOUND=1
    if systemctl --user is-active --quiet "sente-agent-$N.timer" 2>/dev/null; then ST="active"; else ST="inactive"; fi
    NEXT="$(systemctl --user show "sente-agent-$N.timer" -p NextElapseUSecRealtime --value 2>/dev/null || true)"
    LAST="$(grep "\"agent\":\"$N\"" "$SENTE_LOG_DIR/agents.jsonl" 2>/dev/null | tail -1)"
    printf '  %-18s systemd %-10s 次回: %s 直近: %s\n' "$N" "$ST" "${NEXT:-?}" "${LAST:-(未実行)}"
  done
  [ "$FOUND" = 1 ] || echo "  (配備なし: launchd / systemd)"
}
sente_agent_main() {
  case "${1:-list}" in
    list|ls|"") sente_agent_list ;;
    show) shift; sente_agent_show "${1:-}" ;;
    init|new) shift; sente_agent_init "${1:-}" ;;
    run) shift; sente_agent_run "${1:-}" "${2:-}" ;;
    deploy) shift; sente_agent_deploy "$@" ;;
    undeploy|rm) shift; sente_agent_undeploy "${1:-}" ;;
    status) shift; sente_agent_status "${1:-}" ;;
    *) echo "使い方: te agent list | show <name> | init <name> | run <name> [\"依頼\"] | deploy <name> [--to launchd|systemd] | undeploy <name> | status [name]" >&2; return 1 ;;
  esac
}

# `te schedule` — 裏実行の定期化(add/list/rm)。teaiキー不要=ここで即分岐
if [ "${1:-}" = "schedule" ]; then
  shift
  sente_schedule_main "$@"
  exit $?
fi
# `te agent` — エージェント形式(list/show/init/run/deploy/undeploy/status)。定義=agent .md の sente: ブロック
if [ "${1:-}" = "agent" ]; then
  shift
  sente_agent_main "$@"
  exit $?
fi

# `te kuberu` — 毎日の火(Claude Codeの/kuberu)を回して声で詳報。teaiキー不要=ここで即分岐
if [ "${1:-}" = "kuberu" ]; then
  shift
  te_kuberu_main "$@"
  exit $?
fi

SERVE_MODE=0
if [ "${1:-}" = "serve" ]; then
  shift
  SERVE_TOKEN="${KOE_KEY:-${KOE_ADMIN_TOKEN:-}}"
  [ -n "$SERVE_TOKEN" ] || { echo "KOE_KEY(koe.liveの運用トークン)が要ります" >&2; exit 1; }
  SERVE_MODE=1
fi

# `te talk` — 連続対話: 喋った時だけsoxのsilenceトリガーで録音→STT→run(-cで文脈継続)
TALK_MODE=0
if [ "${1:-}" = "talk" ]; then
  command -v rec >/dev/null 2>&1 || { echo "te talk には sox が必要です — $(sente_pkg_hint sox)" >&2; exit 1; }
  TALK_MODE=1; shift
fi

# `te loop` — te goalで設定した目標に向かって実行し続ける常駐モード(2026-08-24本人指示)。
# ⚠loopの実ループはここに置かない: serve/talkと同じ理由でOC/OPENCODE_CONFIG等の共通初期化が要る。
LOOP_MODE=0
if [ "${1:-}" = "loop" ]; then
  shift
  LOOP_MODE=1
  # `te loop "目標"` は te goal 設定 → 起動 のショートカット
  if [ $# -gt 0 ]; then
    mkdir -p "$CONFIG_DIR"
    printf '%s\n' "$*" > "$CONFIG_DIR/goal"
    rm -f "$CONFIG_DIR/loop.log"
  fi
fi

# 🔑 鍵が無ければ、その場で登録に案内(TTYなら「登録する?」→ te register を実行)
ensure_key || exit 1
# 🖥 Playwright MCP 常駐サーバーを自動起動(起動済みなら何もしない・冪等)。無効化=TE_NO_PLAYWRIGHT=1
if [ "${TE_NO_PLAYWRIGHT:-0}" != "1" ] && [ -x "$HOME/bin/playwright-mcp-server.sh" ]; then
  ( "$HOME/bin/playwright-mcp-server.sh" ) >/dev/null 2>&1 &
fi
# 🔄 起動時に新しい te があるか裏でチェック(1日1回・失敗は静かに諦める)。無効化=TE_NO_UPDATE_CHECK=1
if [ "${TE_NO_UPDATE_CHECK:-0}" != "1" ]; then
  (
    UC_MARK="$CONFIG_DIR/.update-check-$(date +%Y%m%d)"
    [ -f "$UC_MARK" ] && exit 0
    touch "$UC_MARK" 2>/dev/null || exit 0
    UC_LOCAL="$(cksum < "$0" 2>/dev/null | awk '{print $1}')"
    UC_REMOTE="$(curl -fsSL --max-time 4 "$TEAI_SITE/te" 2>/dev/null | cksum | awk '{print $1}')"
    if [ -n "$UC_REMOTE" ] && [ -n "$UC_LOCAL" ] && [ "$UC_REMOTE" != "$UC_LOCAL" ]; then
      printf '  🔄 te の新しいバージョンがあります → te update で更新\n' >&2
    fi
  ) >/dev/null 2>&1 &
fi
mkdir -p "$CONFIG_DIR"
# 🚀 起動速度改善(2026-08-30本人指示「文字描けるまで時間かかるから爆速して」):
# 既存configがあれば「6時間以内かどうか」を待たず常に裏で更新する。configが古くても
# 直前の内容で起動して支障は無く(次回起動から新configが効く)、curl×2(最大4秒)を
# 毎回の起動でブロッキングさせる理由が無かった。初回(config自体が無い)だけは
# 同期で取得しないと起動できないので、そこだけ待つ。
if [ -s "$CONFIG_DIR/opencode.json" ]; then
  ( refresh_config ) >/dev/null 2>&1 &
else
  refresh_config
fi
ensure_rules
ensure_memory
ensure_speakify
ensure_voiceq
[ "$SEC_MODE" = 1 ] && ensure_sec_rules
ensure_koe_plugin
[ -f "$CONFIG_DIR/opencode.json" ] || { echo "Config missing. Run: te update"; exit 1; }

OC="$(find_opencode || true)"
[ -n "$OC" ] || { echo "OpenCode not found. Run: te update"; exit 1; }

# No per-run override → fall back to the persisted `te model <id>` default (if any).
if [ -z "$FORCE_MODEL" ]; then
  if [ -f "$CONFIG_DIR/default-model" ]; then
    FORCE_MODEL="$(cat "$CONFIG_DIR/default-model" 2>/dev/null || true)"
  else
    # First run: default to teai/auto (automatic model routing)
    mkdir -p "$CONFIG_DIR"
    echo "teai/auto" > "$CONFIG_DIR/default-model"
    FORCE_MODEL="teai/auto"
  fi
fi

CFG="$CONFIG_DIR/opencode.json"
if [ -n "$FORCE_MODEL" ]; then
  # Swap only the top-level default model (the only "teai/..." value).
  # FORCE_MODEL が既に teai/ プレフィックスを持つ場合(te model teai/auto 等)は
  # 二重プレフィックス(teai/teai/auto)にしないよう、そのまま置換する。
  case "$FORCE_MODEL" in
    teai/*) sed "s#\"teai/[^\"]*\"#\"${FORCE_MODEL}\"#" "$CONFIG_DIR/opencode.json" ;;
    *)      sed "s#\"teai/[^\"]*\"#\"teai/${FORCE_MODEL}\"#" "$CONFIG_DIR/opencode.json" ;;
  esac \
    > "$CONFIG_DIR/opencode-override.json" 2>/dev/null && CFG="$CONFIG_DIR/opencode-override.json"
  if [ "$SEC_MODE" != 1 ]; then   # secモードは自前のバナーを出すので二重表示しない
    case "$FORCE_MODEL" in
      moonshotai/kimi-k3) echo "⚡ Sente max — Kimi K3 (2.8T · 1M context)" >&2 ;;
      teai/auto)          echo "🔀 Sente auto — automatic model selection" >&2 ;;
      *)                  echo "🚀 Sente — model: ${FORCE_MODEL}" >&2 ;;
    esac
  fi
fi
if [ "$SEC_MODE" = 1 ]; then
  sed 's#"instructions":\["#"instructions":["'"$CONFIG_DIR"'/sente-sec-rules.md","#' "$CFG" \
    > "$CONFIG_DIR/opencode-sec.json" 2>/dev/null && CFG="$CONFIG_DIR/opencode-sec.json"
fi
# ⚠ `sente` 起動 = ガードレールなしモード(2026-08-17本人指示)。
# permission だけ全許可に上書きした opencode-yolo.json を生成して差し替える。
# sente-rules.md(読んでから書く等の規律)は残す。失敗したら通常設定で起動(安全側に倒す)。
if [ "${SENTE_NO_GUARDRAILS:-0}" = "1" ] && command -v python3 >/dev/null 2>&1; then
  if python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    d["permission"] = "allow"
    with open(sys.argv[2], "w") as f:
        json.dump(d, f)
except Exception:
    sys.exit(1)
' "$CFG" "$CONFIG_DIR/opencode-yolo.json" 2>/dev/null; then
    CFG="$CONFIG_DIR/opencode-yolo.json"
    echo "⚠ ガードレールなしモード — 全操作が確認なしで即実行されます" >&2
  fi
fi
# 2026-08-14: OpenCode本体がSenteへ改名され設定探索が~/.config/sente/(SENTE_CONFIG)に
# 変わった。旧OPENCODE_CONFIGしか効かないビルドとの両対応で常に両方exportする。
export OPENCODE_CONFIG="$CFG"
export SENTE_CONFIG="$CFG"
# 2026-08-29: エンジン本体の自動更新を止める(Sente改名ビルドが上流stock opencodeの
# 自己更新に上書きされ、ブランドも挙動も素のopencodeへ巻き戻る事故の再発防止)。
# 更新はte update(=このインストーラ再実行)経由に一本化する。
export OPENCODE_DISABLE_AUTOUPDATE=1
export SENTE_DISABLE_AUTOUPDATE=1
# te v は sente_light_env をこの初期化より先に呼ぶため、ここで声用設定に戻し直す
# (上の export が MCP 入りの通常設定で上書きしてしまう)。serve/talk は初期化後に
# sente_light_env を呼ぶのでどちらの順でも正しくなる。
if [ "${SENTE_LIGHT:-0}" = 1 ] && [ -f "$CONFIG_DIR/opencode-voice.json" ]; then
  export OPENCODE_CONFIG="$CONFIG_DIR/opencode-voice.json"
  export SENTE_CONFIG="$CONFIG_DIR/opencode-voice.json"
fi

# 🔒 PIIスクラビング(オプトイン)。te/te run/te v/te talk/te serve のどの経路もここを通るため、
# 1箇所の分岐で全経路に効く。CFG/OPENCODE_CONFIG確定後・各モード分岐より前に置くこと。
PII_SCRUB_ON=0
[ "${TE_PII_SCRUB:-0}" = "1" ] && PII_SCRUB_ON=1
[ -f "$CONFIG_DIR/pii-scrub-optin" ] && PII_SCRUB_ON=1
if [ "$PII_SCRUB_ON" = "1" ]; then
  sente_start_scrub_proxy
  sente_apply_scrub_baseurl
fi

# 🔑 BYOK(Bring Your Own Key・2026-09-10 ペルソナ採点レポート①モデル自由度): 環境変数に
#   ANTHROPIC_API_KEY / OPENAI_API_KEY / GEMINI_API_KEY(GOOGLE_API_KEY) /
#   DEEPSEEK_API_KEY / MOONSHOT_API_KEY / DASHSCOPE_API_KEY(QWEN) があれば、
#   そのプロバイダを teai クレジット消費ゼロで直接使えるように config へ追加する。
#   使い方: export OPENAI_API_KEY=sk-... → te model openai/gpt-5 → te run "..."
#   teai プロバイダは残るので、BYOKキーが無いモデルは従来どおり teai 経由。
#   無効化=TE_NO_BYOK=1。キーはconfigに書かず {env:...} 参照のみ(秘密をファイルに残さない)。
#   ⚠ これは「クライアント側BYOK(環境変数・この端末だけ)」。サーバに暗号化保存して
#   どの端末からでも使える「サーバBYOK」は `te byok add <provider> <key>`(両者は別物・
#   併用可・詳細は te byok の usage を参照)。
if [ "${TE_NO_BYOK:-0}" != "1" ] && [ -f "$CFG" ] && command -v python3 >/dev/null 2>&1; then
  if [ -n "${ANTHROPIC_API_KEY:-}" ] || [ -n "${OPENAI_API_KEY:-}" ] || [ -n "${GEMINI_API_KEY:-}${GOOGLE_API_KEY:-}" ] \
     || [ -n "${DEEPSEEK_API_KEY:-}" ] || [ -n "${MOONSHOT_API_KEY:-}" ] || [ -n "${DASHSCOPE_API_KEY:-}" ]; then
    if python3 - "$CFG" "$CONFIG_DIR/opencode-byok.json" <<'PYBYOK' 2>/dev/null; then
import json, os, sys
src, dst = sys.argv[1], sys.argv[2]
try:
    with open(src) as f:
        d = json.load(f)
except Exception:
    sys.exit(1)
prov = d.setdefault("provider", {})
added = []
if os.environ.get("ANTHROPIC_API_KEY"):
    prov["anthropic"] = {
        "npm": "@ai-sdk/anthropic",
        "options": {"apiKey": "{env:ANTHROPIC_API_KEY}"},
        "models": {},
    }
    added.append("anthropic")
if os.environ.get("OPENAI_API_KEY"):
    prov["openai"] = {
        "npm": "@ai-sdk/openai",
        "options": {"apiKey": "{env:OPENAI_API_KEY}"},
        "models": {},
    }
    added.append("openai")
if os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY"):
    prov["google"] = {
        "npm": "@ai-sdk/google",
        "options": {"apiKey": "{env:GEMINI_API_KEY}"},
        "models": {},
    }
    added.append("google")
# deepseek/moonshot/qwen は OpenAI 互換エンドポイント。@ai-sdk/openai-compatible で baseURL を指定。
if os.environ.get("DEEPSEEK_API_KEY"):
    prov["deepseek"] = {
        "npm": "@ai-sdk/openai-compatible",
        "options": {"apiKey": "{env:DEEPSEEK_API_KEY}", "baseURL": "https://api.deepseek.com/v1"},
        "models": {},
    }
    added.append("deepseek")
if os.environ.get("MOONSHOT_API_KEY"):
    prov["moonshot"] = {
        "npm": "@ai-sdk/openai-compatible",
        "options": {"apiKey": "{env:MOONSHOT_API_KEY}", "baseURL": "https://api.moonshot.cn/v1"},
        "models": {},
    }
    added.append("moonshot")
if os.environ.get("DASHSCOPE_API_KEY"):
    prov["qwen"] = {
        "npm": "@ai-sdk/openai-compatible",
        "options": {"apiKey": "{env:DASHSCOPE_API_KEY}", "baseURL": "https://dashscope.aliyuncs.com/compatible-mode/v1"},
        "models": {},
    }
    added.append("qwen")
if not added:
    sys.exit(1)
with open(dst, "w") as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
print(",".join(added))
PYBYOK
      BYOK_PROVIDERS="added"
      CFG="$CONFIG_DIR/opencode-byok.json"
      export OPENCODE_CONFIG="$CFG"
      export SENTE_CONFIG="$CFG"
      echo "🔑 BYOK有効: 自前キーのプロバイダを追加しました(te model openai/<model> 等で指定・teaiクレジット消費なし)" >&2
      echo "   ※ これは端末の環境変数を使うクライアント側BYOK。サーバ保存版は te byok list" >&2
    fi
  fi
fi

# 🛡 予算ブレーカー(2026-09-10 ペルソナ採点レポート⑤信頼性・既定ON): 常駐モード(loop/serve)が
#   起動時点の残高から一定クレジットを燃やしたら自動停止する。launchd×te run ループ事故
#   (12,912回再起動・1日430万cr消費)の再発防止。既定は1日5,000cr(約¥830)。
#   変更=TE_BUDGET_MAX_CR(0=無効)・TE_BUDGET_WINDOW_S(既定86400=1日)。
#   残高は /api/v1/auth/me を起動時+各イテレーション後に取得(3秒上限・取れなければスキップ=誤停止しない)。
BUDGET_START_BAL=""
BUDGET_START_TS=0
BUDGET_MAX_CR="${TE_BUDGET_MAX_CR:-5000}"
BUDGET_WINDOW_S="${TE_BUDGET_WINDOW_S:-86400}"
te_budget_begin() {  # 常駐モード起動時に1回呼ぶ。残高が取れたら基準値を記録
  BUDGET_START_BAL=""; BUDGET_START_TS="$(date +%s)"
  [ "${BUDGET_MAX_CR:-0}" = "0" ] && return 0
  [ -n "${TEAI_API_KEY:-}" ] || return 0
  local BB
  BB="$(curl -s -m 3 -H "Authorization: Bearer $TEAI_API_KEY" "$TEAI_API/api/v1/auth/me" 2>/dev/null \
      | sed -n 's/.*"credits_remaining":\([0-9.]*\).*/\1/p' | head -1)"
  [ -n "$BB" ] && BUDGET_START_BAL="$BB"
  return 0
}
te_budget_check() {  # 各イテレーション後に呼ぶ。超過ならメッセージを出して return 1(=止める)
  [ "${BUDGET_MAX_CR:-0}" = "0" ] && return 0
  [ -n "$BUDGET_START_BAL" ] || return 0
  [ -n "${TEAI_API_KEY:-}" ] || return 0
  local NOW_TS NOW_BAL USED
  NOW_TS="$(date +%s)"
  # ウィンドウ(既定1日)を過ぎたら基準を取り直す(=1日あたりの上限として機能させる)
  if [ $(( NOW_TS - BUDGET_START_TS )) -ge "$BUDGET_WINDOW_S" ]; then
    te_budget_begin
    return 0
  fi
  NOW_BAL="$(curl -s -m 3 -H "Authorization: Bearer $TEAI_API_KEY" "$TEAI_API/api/v1/auth/me" 2>/dev/null \
      | sed -n 's/.*"credits_remaining":\([0-9.]*\).*/\1/p' | head -1)"
  [ -n "$NOW_BAL" ] || return 0   # 取得失敗時は止めない(誤停止しない・フェイルオープン)
  USED="$(awk "BEGIN{u=$BUDGET_START_BAL - $NOW_BAL; if(u<0)u=0; printf \"%d\", u}")"
  if [ "$USED" -ge "$BUDGET_MAX_CR" ]; then
    echo "🛡 予算ブレーカー: 起動時から ${USED}cr 消費(上限 ${BUDGET_MAX_CR}cr/日)のため自動停止しました。続けるなら TE_BUDGET_MAX_CR を上げて再起動してください(0=無効)。" >&2
    koe_say_sync "予算の上限に達したので、常駐モードを止めました。確認をお願いします。" 2>/dev/null || true
    return 1
  fi
  return 0
}

# `te loop` — te goalの目標に向かって、実際に手を動かす一手を繰り返し実行する常駐モード。
# fuseki/te watch(提案のみ・何も実行しない)との違いはここ: loopは本当に実行する唯一の常駐モード。
# 暴走させないための3つの安全弁: ①goal未設定なら起動しない ②3回連続で失敗したら自動停止して声で知らせる
# ③別端末からいつでも `te stop` で止められる(fuseki-STOPと共用のSTOPファイル方式)。
# ④予算ブレーカー(te_budget_check・既定5,000cr/日で自動停止)も全イテレーションで効く。
# 各回はoc_run_guarded(既存のserve/talkと同じハング対策付き実行)を使うので、権限モデル(通常=確認あり/
# sente=ガードレールなし)もserve/talkとまったく同じものを引き継ぐ(このモード専用の特例は作らない)。
if [ "$LOOP_MODE" = 1 ]; then
  GOAL_FILE="$CONFIG_DIR/goal"
  if [ ! -f "$GOAL_FILE" ]; then
    echo "🎯 goalが未設定です。先に: te goal \"やりたいこと\"" >&2
    exit 1
  fi
  LOOP_GOAL="$(cat "$GOAL_FILE")"
  LOOP_LOG="$CONFIG_DIR/loop.log"
  LOOP_STOP="$CONFIG_DIR/loop-STOP"
  LOOP_GAP="${TE_LOOP_INTERVAL:-30}"          # 各イテレーション後の最短待ち(秒・既定30秒)
  LOOP_TIMEOUT="${TE_LOOP_TIMEOUT:-1800}"     # 1イテレーションの上限(秒・既定30分・ハングはoc_run_guardedが処理)
  LOOP_MAXFAIL="${TE_LOOP_MAX_CONSECUTIVE_FAIL:-3}"
  rm -f "$LOOP_STOP"
  sente_light_env
  FAILS=0
  ITER=0
  te_budget_begin
  echo "🔁 te loop — goal: $LOOP_GOAL" >&2
  echo "   ${LOOP_GAP}秒間隔・1回${LOOP_TIMEOUT}秒上限・${LOOP_MAXFAIL}回連続失敗で自動停止・予算${BUDGET_MAX_CR}cr/日でブレーカー。止める= 別端末で te stop" >&2
  trap 'echo; echo "🔁 loopを止めました(${ITER}回実行)"; exit 0' INT TERM
  while :; do
    if [ -f "$LOOP_STOP" ]; then rm -f "$LOOP_STOP"; echo "🛑 停止指示を検知しました(${ITER}回実行)。"; break; fi
    ITER=$((ITER + 1))
    LOOP_CTX=""
    [ -f "$LOOP_LOG" ] && LOOP_CTX="$(tail -8 "$LOOP_LOG" 2>/dev/null)"
    LOOP_PROMPT="達成したいgoal: ${LOOP_GOAL}

これは自律ループの${ITER}回目の実行です。このディレクトリの現状を確認し、goalに向かって実際に
前進する一手(実装・修正・コミット等)をひとつ実行してください。goalが既に完全に達成済みなら
何も変更せず、出力の最後の行に必ず『LOOP_GOAL_DONE』と書いてください(このマーカーが出たらループを止めます)。
まだ途中なら、今回やったことと次回への引き継ぎを短く書いてください(次回はそれを読んで続きをやります)。

直近の実行ログ(古い順・引き継ぎ用・無ければ初回):
${LOOP_CTX:-(まだ履歴なし)}"
    OUT="$(oc_run_guarded "$LOOP_TIMEOUT" run "$LOOP_PROMPT" 2>&1)"; RC=$?
    SUMMARY="$(printf '%s' "$OUT" | sed 's/\x1b\[[0-9;]*m//g' | grep -av '^\s*$' | tail -5)"
    printf '[%s] #%s rc=%s %s\n' "$(date '+%Y-%m-%d %H:%M')" "$ITER" "$RC" "$(printf '%s' "$SUMMARY" | tr '\n' ' ' | cut -c1-400)" >> "$LOOP_LOG"
    if [ "$RC" = 0 ]; then
      FAILS=0
      if printf '%s' "$OUT" | grep -q 'LOOP_GOAL_DONE'; then
        echo "✅ goal達成と判定されました(${ITER}回目)。$LOOP_LOG を確認してください。" >&2
        koe_say_sync "goalが達成できました。${ITER}回目の実行で完了と判定しています。" 2>/dev/null || true
        rm -f "$GOAL_FILE"
        break
      fi
    else
      FAILS=$((FAILS + 1))
      echo "  ⚠ ${ITER}回目が失敗しました(rc=$RC・連続${FAILS}回)" >&2
      if [ "$FAILS" -ge "$LOOP_MAXFAIL" ]; then
        echo "🔴 ${LOOP_MAXFAIL}回連続で失敗したので自動停止しました。goalは残したままです(te loopで再開可)。$LOOP_LOG を確認してください。" >&2
        koe_say_sync "loopが${LOOP_MAXFAIL}回連続で失敗したので、止まっています。確認をお願いします。" 2>/dev/null || true
        break
      fi
    fi
    sleep "$LOOP_GAP" &
    wait $! 2>/dev/null
    te_budget_check || break
  done
  exit 0
fi

# `te serve` — iPhoneや声の受信箱から届いた依頼を、この手元のマシンで実行する常駐モード。
# 本人確認(声紋・お題・台帳照合)は koe.live 側で済んでいて、ここに来るのは通った依頼だけ。
# 危険度は依頼と一緒に届くので、赤(消す・送る・払う)は既定で実行せず読み上げて知らせる。
if [ "$SERVE_MODE" = 1 ]; then
  SERVE_BASE="${KOE_BASE:-https://koe.live}"
  SERVE_EVERY="${TE_SERVE_INTERVAL:-10}"
  SCHEDULE_LAST_CHECK=0
  sente_light_env
  te_budget_begin
  echo "🕊 Sente serve — 声で届いた依頼を待っています(Ctrl-Cで終了・予算${BUDGET_MAX_CR}cr/日でブレーカー)" >&2
  trap 'printf "\n🕊 おつかれさま(serve終了)\n" >&2; exit 0' INT
  while :; do
    # 🕰 予定の定期実行(毎分1回だけ評価・te scheduleで登録した頼み事をここで拾う)
    NOW_TS="$(date +%s)"
    if [ $((NOW_TS - SCHEDULE_LAST_CHECK)) -ge 55 ]; then
      SCHEDULE_LAST_CHECK="$NOW_TS"
      sente_schedule_due | while IFS="$(printf '\t')" read -r SID STASK; do
        [ -n "$SID" ] || continue
        if sente_schedule_is_red "$STASK" && [ "${TE_SCHEDULE_ALLOW_RED:-0}" != "1" ]; then
          koe_say_sync "予定の時間になりましたが、「$STASK」は取り返しがつかない可能性があるので実行していません。"
        else
          printf '  🕰 [予定実行] %s\n' "$STASK" >&2
          SOUT="$(oc_run_guarded "${TE_SERVE_TIMEOUT:-300}" run "$STASK$SENTE_PERSONA" 2>&1 || true)"
          if sente_pay_guide "$SOUT"; then
            koe_say_sync "予定していた「$STASK」を実行しようとしましたが、teaiのクレジットが切れていました。チャージページを開いておきました。"
          else
            SREPLY="$(printf '%s' "$SOUT" | sed 's/\x1b\[[0-9;]*m//g' | grep -av '^\s*$' | tail -3)"
            koe_say_sync "予定していた「$STASK」をやっておきました。$SREPLY"
          fi
        fi
        sente_schedule_mark_ran "$SID"
      done
    fi
    JOB="$(curl -s -m 20 "$SERVE_BASE/api/sente/next" -H "X-Koe-Admin: $SERVE_TOKEN" 2>/dev/null || true)"
    ID="$(printf '%s' "$JOB" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
    if [ -z "$ID" ]; then sleep "$SERVE_EVERY"; continue; fi
    TASK="$(printf '%s' "$JOB" | sed -n 's/.*"text":"\([^"]*\)".*/\1/p')"
    RISK="$(printf '%s' "$JOB" | sed -n 's/.*"risk":"\([^"]*\)".*/\1/p')"
    printf '  📩 [%s] %s\n' "$RISK" "$TASK" >&2
    if printf '%s' "$TASK" | grep -qE '(くべて|くべる|くべとい|くべお願い|kuberu)'; then
      # 🔥 「くべて」: 毎日の火の一巡。長丁場(10〜30分)なので裏で回し、終わったら声で詳報する。
      KPID="$(cat /tmp/sente_kuberu.pid 2>/dev/null || true)"
      if [ -n "$KPID" ] && kill -0 "$KPID" 2>/dev/null; then
        REPLY_TXT="$(sente_pick "いま、くべている最中です。終わったら手元の声でお知らせしますね。" "もう火の前にいますよ。終わり次第、こちらから声をかけます。")"
      else
        REPLY_TXT="$(sente_pick "はい、くべ始めました。だいたい10分から30分かかります。終わったら、手元のマックからわたしの声で、どうなったか詳しくお知らせしますね。" "了解です、火をひと回りしてきます。10分から30分ほどで、結果は手元の声でお伝えします。" "くべますね。少し時間がかかるので、終わったらこちらから詳しくご報告します。" "はい、まかせてください。裏で回して、終わったら声で詳しくお知らせします。")"
        mkdir -p "$SENTE_LOG_DIR"
        nohup "$0" kuberu --from-voice >> "$SENTE_LOG_DIR/kuberu-serve.log" 2>&1 &
      fi
      koe_say_sync "$REPLY_TXT"
    elif [ "$RISK" = "red" ] && [ "${TE_SERVE_ALLOW_RED:-0}" != "1" ]; then
      # 取り返しのつかない頼みは、勝手にやらない。届いたことだけ声で知らせる。
      REPLY_TXT="こういう依頼が届きました。$TASK。取り返しがつかないことなので、わたしからは実行していません。"
      koe_say_sync "$REPLY_TXT"
    else
      OUT="$(oc_run_guarded "${TE_SERVE_TIMEOUT:-300}" run "$TASK$SENTE_PERSONA" 2>&1 || true)"
      if sente_pay_guide "$OUT"; then
        # 💳 クレジット切れ: 実行できなかったことと、支払い導線を声で案内(ページは手元で開いてある)
        REPLY_TXT="teaiのクレジットが切れていて、実行できませんでした。手元でチャージページを開いてあります。チャージすると、また動けます。"
      else
        REPLY_TXT="$(printf '%s' "$OUT" | sed 's/\x1b\[[0-9;]*m//g' | grep -av '^\s*$' | tail -3)"
      fi
      koe_say_sync "$REPLY_TXT"
    fi
    curl -s -m 20 -X POST "$SERVE_BASE/api/sente/done" -H "X-Koe-Admin: $SERVE_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$(printf '{"id":"%s","reply":%s}' "$ID" "$(printf '%s' "$REPLY_TXT" | head -c 1500 | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo '""')")" >/dev/null 2>&1 || true
    te_budget_check || break
  done
fi

if [ "$TALK_MODE" = 1 ]; then
  sente_light_env
  echo "🎙 Sente talk — 話しかけてください(Ctrl-Cで終了・返事は声で返ります)" >&2
  TALK_ENGINE="$(sente_engine_get)"
  TALK_WAKE="off"; [ "${TE_WAKE:-0}" = "1" ] && TALK_WAKE="on"
  KB=0; PRE_KEY=""; SENTE_STTY=""
  sente_kb_ok && KB=1
  if [ "$(uname)" = "Darwin" ]; then
    # 🚀 osascript(~0.3s)は裏へ。KOE_MIC_FIXEDの1セッション1回ガードはサブシェル内で完結する
    ( IV="$(osascript -e 'input volume of (get volume settings)' 2>/dev/null || true)"
      if [ -n "$IV" ] && [ "$IV" -lt 40 ] 2>/dev/null; then
        koe_vol_autofix   # 低すぎる入力音量は起動時にこちらで直す(認識精度の自動向上)
      fi ) &
  fi
  rm -f /tmp/sente_speaking.lock /tmp/sente_say_streamed /tmp/sente_say_full_won   # 前回の異常終了で残ったlock/合図で無言のまま固まらないように
  # 🔇 ミュートはsente_mutedがmuteファイルを毎回見る(起動時のコピー変数は持たない=Sente.app/te voiceの切替が実行中でも即効く)
  if [ -f "$SENTE_MUTE_FILE" ]; then printf '  🔇 読み上げOFF中(戻す: te voice on か「声出して」)\n' >&2; fi
  sente_warm_fillers               # 相槌を先に合成させておく(初回だけ・裏で静かに)
  # 🚀 自動調整の計算(python×2・~0.4s)は裏へ。apply_tuningは前回計算済みの値を読むだけなので
  # 順序依存なし(今回の計算結果は次回起動から効く=1セッション遅れで十分)
  ( sente_autotune; sente_autotune_model ) >/dev/null 2>&1 &
  sente_apply_tuning               # 前回までに決まった値をこの回から使う
  # 二重起動ガード: 既に別の sente talk が動いていたら古い方を止め、最後に起動した
  # こちらを正とする(2本が同じ声を拾って二重に応答する実害が出た: Sente.app経由+孤児の併走)。
  # 🪤 rec(sox)はTERMを無視する → 子recは-9。親shはrecが死ぬとループを抜けて自然終了する
  TALK_PIDF=/tmp/sente_talk.pid
  OPID="$(cat "$TALK_PIDF" 2>/dev/null || true)"
  # 🪤 素の`sente`起動はps上に「talk」が出ない(set -- talkはargvを変えない)ので、
  #    照合は「/sente か /te で終わる(+任意で talk)」に緩める。pidfileを書くのはtalk自身なので
  #    これで十分(PID再利用で別のte系プロセスに当たる確率だけ潰せればよい)
  if [ -n "$OPID" ] && [ "$OPID" != "$$" ] && kill -0 "$OPID" 2>/dev/null \
     && ps -o command= -p "$OPID" 2>/dev/null | grep -Eq "/(sente|te)( talk)?( |$)"; then
    echo "  ⚠ 既に動いていた sente(PID $OPID)を止めて、こちらを優先します(二重応答防止)" >&2
    pkill -9 -P "$OPID" -x rec 2>/dev/null || true
    kill -TERM "$OPID" 2>/dev/null || true
  fi
  printf '%s' "$$" > "$TALK_PIDF"
  if [ "$(oc_stale)" -gt 0 ] 2>/dev/null; then
    # 自動GCの対象外(=親が生きている/新しい)ので、他で作業中の可能性がある。殺さず知らせるだけ。
    echo "  ℹ 別の opencode が $(oc_stale) 本動いています(他の作業中ならそのままで大丈夫)" >&2
  fi
  # 🚄 常駐モード起動(ACP)。失敗してもエラーにせず従来モードで続行。
  # 🚀 READY待ち(~2s)は初回ターン(acp_turn冒頭)へ移動=起動をブロックしない
  TALK_RESIDENT="off"
  if [ "${TE_TALK_ACP:-1}" = "1" ] && command -v python3 >/dev/null 2>&1; then
    ensure_acp_driver
    if acp_spawn; then
      ACP_ON=1
      TALK_RESIDENT="on"
    else
      TALK_RESIDENT="off(未起動)"
      echo "  ℹ 常駐モードを起動できなかったので、従来モードで続けます" >&2
    fi
  fi
  # 📋 起動時の状態を1ブロックにまとめて表示(声・エンジン・常駐・ウェイクワード=
  # 従来バラバラだった行を集約。出す情報は減らさない — ウェイクワードonの案内文はこの下に残す)
  printf "  ╭─ Sente ─ 声:%s ─ エンジン:%s ─ 常駐:%s ─ ウェイクワード:%s ─╮\n" \
    "${KOE_VOICE:-yuki}" "$TALK_ENGINE" "$TALK_RESIDENT" "$TALK_WAKE" >&2
  [ "$TALK_WAKE" = "on" ] && echo "  🎧 『センテ』と呼びかけてください" >&2
  [ "$KB" = 1 ] && echo "  ⌨ 打ち始めるとタイピング入力(Enterで送信) / Enterだけ=読み上げ停止・録音やり直し / Esc・Ctrl-C=終了" >&2
  if [ "$KB" = 1 ]; then
    sente_kb_open
    # 端末モードは必ず元に戻す(EXITで正常/Ctrl-C両方をカバー・TERMは二重起動ガードで殺される側)
    trap 'sente_kb_close' EXIT
    trap 'sente_kb_close; exit 0' TERM
  fi
  koe_sfx ready
  # 🚀💬 挨拶は「前回の裏生成で用意済みの気づき一言」を再生するだけ(無ければ時間帯定型のキャッシュ)。
  # 録音ループが挨拶自体を拾わないよう、再生が始まる前にlockを主シェル側で先に置く(裏側が再生後に外す)
  : > /tmp/sente_speaking.lock
  rm -f "$SENTE_DEAD_AIR_FILE" 2>/dev/null   # 🌙 前回セッションの連続空振り件数を持ち込まない
  sente_first_run_intro sente
  sente_greet_play_bg
  # ♟ 先手の一手: 裏でパソコンの状況を見て、最初の一手をひとつ提案する(数秒後に声で届く)
  ( sente_health_check ) &   # 🩺 耳・口・脳の実測1行(裏で約1秒・異常時だけ声でも知らせる)
  ( sente_opening talk auto ) >/dev/null &
  : > "$SENTE_CTX_FILE" 2>/dev/null || true   # 🧠 会話文脈はセッション単位で仕切り直す
  # 🪤 旧trapはacp_stop(waitあり)を同期で回していて、詰まると「Ctrl-Cが効かない」体感になった
  # (2026-08-09本人報告)→ 掃除を裏に回すsente_talk_quitへ一本化(trap解除済みなので2度目は即死)
  trap 'sente_talk_quit' INT
  # 💳 無料枠の声モードは 1 日 30 分(発話時間)。超えていたら告げて始めない(Sente Pro=無制限)
  if ! sente_voice_quota_check; then sente_talk_quit; fi
  TALK_FIRST=1
  ENGINE_TALK_FIRST=1   # 🔧 talk起動時点でエンジンがclaude/codexなら、その最初のターンは--continue/resumeせず新規で始める
  while :; do
    # 🌙 連続空振り検知: 環境音/幻聴ばかりが続く(=起動したまま席を外している可能性が高い)
    # ときは、声で一言知らせて安全終了する。実害(誤実行)はないが、無駄なSTT呼び出しと
    # ログの肥大化を止める。次にsenteを起動すれば0から再開する。TE_NO_DEAD_AIR=1で無効化。
    if [ "${TE_NO_DEAD_AIR:-0}" != "1" ] && sente_dead_air_hit; then
      printf '  🌙 応答のない音声が続いたので待機を終了します(環境音の可能性・実行はしていません)\n' >&2
      koe_say_sync "しばらく反応がなかったので、待機を終了します。また声で呼び出してください" 2>/dev/null || true
      rm -f "$SENTE_DEAD_AIR_FILE" "$TALK_PIDF" 2>/dev/null
      sente_kb_close 2>/dev/null || true
      acp_stop 2>/dev/null || true
      exit 0
    fi
    # 読み上げ(自分の声)の完了まで録音を始めない: 合成中=lock / 再生中=afplay。
    # lockはプラグインが置く。残骸で固まらないよう90秒で安全弁。
    # 🚀 初回はターンが無い(挨拶lockは起動時に主シェルが同期で置き済み)ので猶予を待たない
    [ "$TALK_FIRST" = 1 ] || sleep 0.7   # ターン直後、プラグインがlockを置くまでの猶予
    DN=0
    SPOKE=0
    BARGE_HEARD=""; BARGE_RETRY=0; BG_REC_PID=""; BGW=""
    # /tmp/sente_turn_open も待つ: LLMが次の文を考えている無音の隙間でFIFOが空になっても、
    # ターンが終わるまで録音を開かない(自分の続きのセグメントを拾う自問自答ループの根治)
    while [ -f /tmp/sente_speaking.lock ] || [ -f /tmp/sente_turn_open ] || pgrep -x afplay >/dev/null 2>&1 || pgrep -x mpg123 >/dev/null 2>&1; do
      SPOKE=1; sleep 0.3; DN=$((DN+1))
      # 読み上げ中のキー: Enter/Esc=止めるだけ / 文字=止めてそのままタイピング入力へ
      if [ "$KB" = 1 ]; then
        sente_kb_read
        if [ -n "$K" ]; then
          case "$K" in "$SENTE_ESC"|"$SENTE_CTRLC") sente_talk_quit ;; esac   # Esc/生Ctrl-C=終了(2026-08-09本人要望)
          sente_stop_speaking
          printf '  ⏹ 読み上げを止めました\n' >&2
          # Enterで止めた=話したい合図 → 即「あ、どうぞ」(文字キー=タイピング入力なので黙る)
          case "$K" in "$SENTE_NL"|"$SENTE_CR") sente_yield_say stop ;; "$SENTE_BS"|"$SENTE_DEL") PRE_KEY="${PRE_KEY%?}" ;; *) PRE_KEY="${PRE_KEY}$K" ;; esac   # 追記式: 上書きすると先に押した文字が消える(「DeepSeek」→「eepSeek」実障害)
          break
        fi
      fi
      # 🗣⚡ 声の割り込み: 読み上げ中もマイクを薄く開けておき、チャンクが録れるたびに判定。
      # 意味が通る発話だけ止めて反応し、こだま・物音なら黙って話を続ける(sente_barge_judge)
      if [ "${TE_BARGE:-1}" = "1" ] && command -v rec >/dev/null 2>&1; then
        if [ -z "$BG_REC_PID" ]; then
          BGW="$(mktemp "${TMPDIR:-/tmp}/te_barge_XXXXXX").wav"
          sente_rec_q "$BGW" 1.0 20 0.05 &
          BG_REC_PID=$!
        elif ! kill -0 "$BG_REC_PID" 2>/dev/null; then
          wait "$BG_REC_PID" 2>/dev/null || true
          BG_REC_PID=""
          if sente_barge_judge "$BGW"; then
            rm -f "$BGW"; BGW=""
            sente_stop_speaking
            # 🔁 いずれの分岐でも、直前の返答は最後まで聞かれていない(次のTPROMPT組み立てで1回だけ伝える)
            SENTE_INTERRUPTED_NOTE="(直前の自分の返答は最後まで聞かれずに遮られた。続きを知っている前提で話さないこと。) "
            if [ "$BARGE_STOPWORD" = 1 ]; then
              printf '  ⏹ はい、止めました。どうぞ\n' >&2
              koe_say_sync "はい。"
            elif [ "$BARGE_RETRY" = 1 ]; then
              printf '  ⏹(呼ばれた気がするので止めました)\n' >&2
              sente_yield_say barge   # 短い譲り(いろんなパターン・キャッシュ済みで即鳴る)
            else
              printf '  ⏹(割り込み)\n' >&2
            fi
            break
          fi
          rm -f "$BGW"; BGW=""   # こだま/物音 → 話は止めない
        fi
      fi
      # 読み上げは長くても数十秒。これを超えるのは残骸なので捨てて進む(無言で固まらせない)
      [ "$DN" -gt 100 ] && { rm -f /tmp/sente_speaking.lock /tmp/sente_turn_open; break; }
    done
    # 割り込み用の聞き耳が生きていれば畳む(waitで回収=Terminatedを画面に出さない)
    if [ -n "$BG_REC_PID" ]; then
      kill "$BG_REC_PID" 2>/dev/null || true
      wait "$BG_REC_PID" 2>/dev/null || true
      rm -f "$BGW"; BG_REC_PID=""; BGW=""
    fi
    # 再生直後は音声デバイスの残響が残り、自分の読み上げ末尾を録ってしまう(E2Eで実発生:
    # 返答末尾「すぐ動けます」を入力として拾った)→ ひと呼吸おいてから録音を開く
    [ "$SPOKE" = 1 ] && sleep 0.5
    sente_bg_check   # 📦 裏タスクの完了報告(読み上げ待ちの後・毎ターン先頭で1件だけ)
    # ⌨ 読み上げ停止と同時に打ち始めた文字があれば、録音を挟まずそのままタイピング入力へ
    TYPED=""
    if [ "$KB" = 1 ] && [ -n "$PRE_KEY" ]; then
      TYPED="$(sente_type_line "$PRE_KEY")"; PRE_KEY=""
      [ -n "$TYPED" ] || continue
    fi
    TW=""
    if [ -n "${BARGE_HEARD:-}" ]; then
      :   # 🗣⚡ 割り込みで既に意味の通る発話を聞き取っている → 録音を挟まずそのまま使う
    elif [ -z "$TYPED" ]; then
      TW="$(mktemp "${TMPDIR:-/tmp}/te_talk_XXXXXX").wav"
      # 無音の間は書き込まれない=待機中CPU/STTコストほぼゼロ。30秒で強制打ち切り
      # (2026-08-17: 90→30。長すぎると環境音/動画の常時再生を丸ごと録り続け、
      # STT幻聴とログ肥大の温床になった。TE_TALK_MAX=で調整可)。
      # 話し終わり判定は既定1.5秒(体感のテンポ優先)。考えながらゆっくり話す人は
      # TE_TALK_SILENCE=2.5 のように伸ばせる
      # 🔇 録音開始しきい値: 2026-08-08「勝手に認識しすぎる」で0.05に上げたが、
      # 🔴2026-08-10「認識されない」で実測し直した結果0.02へ戻す。根拠=正しく認識できていた
      # 08-06の録音の実音量はmean -19〜-37dB(RMS 0.014〜0.11)で、0.05(-26dB)は普通の声量の
      # 大半がしきい値未満=録音自体が始まらない。誤反応側はAEC(-41dB打ち消し)+CoreAudio
      # ゲート(鳴っている間はしきい値2.5倍)が受け持つ。TE_TALK_START_THRESH=で調整可
      if [ "$KB" = 1 ]; then
        # キーを見張りながら裏で録音し、soxの進捗(-S)からレベルメーターを描く。
        # 文字キー=録音をやめてタイピング入力 / Enter・Esc=いまの録音を捨てて聞き直し
        MLOG="${TMPDIR:-/tmp}/te_talk_meter.$$"
        : > "$MLOG"
        sente_rec_meter "$TW" "${TE_TALK_SILENCE:-1.5}" "${TE_TALK_MAX:-30}" "$MLOG" "${TE_TALK_START_THRESH:-0.02}" &
        REC_PID=$!
        KEYED=0
        while kill -0 "$REC_PID" 2>/dev/null; do
          sente_kb_read
          if [ -n "$K" ]; then
            KEYED=1
            kill -KILL "$REC_PID" 2>/dev/null || true
            wait "$REC_PID" 2>/dev/null || true
            rm -f "$TW"; TW=""
            sente_meter_clear
            case "$K" in
              "$SENTE_ESC"|"$SENTE_CTRLC") sente_talk_quit ;;   # Esc/生Ctrl-C=終了(2026-08-09本人要望)
              "$SENTE_NL"|"$SENTE_CR") printf '  ⏹ いまの録音は捨てました。どうぞ\n' >&2; sente_yield_say stop ;;
              *) TYPED="$(sente_type_line "$K")" ;;
            esac
            break
          fi
          sente_meter_draw "$MLOG" "$TW.apple"
          sleep 0.2
        done
        if [ "$KEYED" = 1 ]; then
          rm -f "$MLOG"
          [ -n "$TYPED" ] || continue
        else
          wait "$REC_PID" 2>/dev/null && REC_RC=0 || REC_RC=$?
          sente_meter_clear
          rm -f "$MLOG"
          [ "$REC_RC" = 0 ] || { rm -f "$TW"; break; }
        fi
      else
        sente_rec_q "$TW" "${TE_TALK_SILENCE:-1.5}" "${TE_TALK_MAX:-30}" "${TE_TALK_START_THRESH:-0.02}" || { rm -f "$TW"; break; }
      fi
    fi
    if [ -n "${BARGE_HEARD:-}" ]; then
      THEARD="$BARGE_HEARD"; BARGE_HEARD=""
      sente_log_turn "" barge "$THEARD"
      printf '  🎤 「%s」\n' "$THEARD" >&2
      sente_intercept_command && continue
    elif [ -n "$TYPED" ]; then
      # タイピング入力は声のターンではないので、聞き取りログ(自動調整の材料)には積まない
      THEARD="$TYPED"
      sente_intercept_command && continue
    else
      # 録音が始まらないままタイムアウト(senterecが未録音時にwavを消す)もturns.jsonlに残す。
      # 08-10の失聴障害はここが黙ってcontinueしていたため、ログから消えて発見が遅れた
      # 🍎 Apple認識の結果(最後のpartial)を回収してから判定へ。サーバSTTが空振りした時の補完に使う
      APPLE_TXT="$(head -c 400 "$TW.apple" 2>/dev/null || true)"; rm -f "$TW.apple"
      if [ ! -f "$TW" ] || [ "$(wc -c < "$TW")" -le 4000 ]; then sente_log_turn "" nostart ""; rm -f "$TW"; continue; fi
      # エコーガード: KOE読み上げ(koe-speakプラグインのafplay/mpg123)再生中に拾った
      # 音は自分の声=そのまま実行すると自問自答ループになる → 捨てる
      if pgrep -x afplay >/dev/null 2>&1 || pgrep -x mpg123 >/dev/null 2>&1; then rm -f "$TW"; continue; fi
      # 「聞こえたよ」の即時アック音(STT/LLMを待たずに反応が返る)
      koe_dur_ok "$TW" || { sente_log_turn "$TW" short ""; rm -f "$TW"; continue; }   # 一瞬の物音は音も鳴らさず黙って捨てる
      koe_sfx heard
      koe_vol_check "$TW" || { sente_log_turn "$TW" quiet ""; rm -f "$TW"; continue; }
      printf '  ⏳ 聞き取り中…\n' >&2
      THEARD="$(koe_stt "$TW")"
      # 🍎 サーバSTTが空(Scribeの取りこぼし/ノイズ判定)でも、Appleのオンデバイス認識が
      # 声を聞き取れていればそれを採用(打鍵ノイズはAppleが「No speech detected」を返すので
      # ここで復活しない=補完とノイズ排除が両立する)
      if [ -z "$THEARD" ] && [ "${#APPLE_TXT}" -ge 4 ]; then
        THEARD="$APPLE_TXT"
        printf '  🍎 (Apple音声認識で補完)\n' >&2
      fi
      # 🎧 ウェイクワードゲート: 音声由来のTHEARDだけが対象(タイピングは意図的入力なので素通し)。
      # 「センテ」が3文字=下のnoise?フィルタ(4文字未満)に食われるので、それより前で判定する。
      # ゲート落ちは黙って聞き流す(turns.jsonlに積まない=自動調整の材料を汚さない)
      if [ "${TE_WAKE:-0}" = "1" ]; then
        if sente_wake_check "$THEARD"; then
          THEARD="$WAKE_REST"
          if [ -z "$THEARD" ]; then
            koe_sfx heard
            koe_say_sync "はい"
            rm -f "$TW"; continue
          fi
        else
          printf '  💤(呼ばれてないので聞き流し)\n' >&2
          rm -f "$TW"; continue
        fi
      fi
      # 割り込みコマンド(待って/もう一回等)はここで即動作させる。短い定型句なので
      # 「noise?」の4文字未満フィルタより前に判定しないと拾えない(待って=3文字)
      if sente_intercept_command; then rm -f "$TW"; continue; fi
      if [ -z "$THEARD" ]; then sente_log_turn "$TW" empty ""; rm -f "$TW"; continue; fi
      if [ "${#THEARD}" -lt 4 ]; then sente_log_turn "$TW" noise "$THEARD"; rm -f "$TW"; printf '  (noise? 無視:「%s」)\n' "$THEARD" >&2; continue; fi
      # 数字の羅列だけの聞き取りはノイズ(通知音・BGM等の誤認。実ログ:「3 4 4 5 5 5 5 5 6 6 7 7」に
      # 分布の解説を返してしまった)。数字を全部落として中身が残らなければ捨てる
      if [ -z "$(printf '%s' "$THEARD" | tr -d '0-9０-９ 　.,、。')" ]; then
        sente_log_turn "$TW" noise "$THEARD"; rm -f "$TW"; printf '  (数字ノイズなので無視:「%s」)\n' "$THEARD" >&2; continue
      fi
      # Whisperが無音/環境ノイズから幻聴する定番フレーズと、動画/配信の常套句(部屋のYouTube等を
      # マイクが拾う実障害: 「次の動画でお会いしましょう」に返事をしていた)は実行しない
      case "$THEARD" in
        *ご視聴ありがとう*|*ご清聴ありがとう*|*チャンネル登録*|*最後までご覧いただき*|*おやすみなさい*|*次回予告*|*本編をお楽しみ*|*字幕*|*提供でお送り*|*エンディング*|*次の動画*|*お会いしましょう*|*高評価*|*概要欄*)
          sente_log_turn "$TW" hallucination "$THEARD"; rm -f "$TW"; printf '  (無音の幻聴っぽいので無視:「%s」)\n' "$THEARD" >&2; continue ;;
      esac
      if sente_noise_extra_match "$THEARD"; then
        sente_log_turn "$TW" hallucination "$THEARD"; rm -f "$TW"; printf '  (学習済みノイズパターンなので無視:「%s」)\n' "$THEARD" >&2; continue
      fi
      # 🌐 固定フレーズ一覧に無い他言語の幻聴(実例:アイスランド語を幻聴してLLMまで通し
      # 実際に答えてしまった)。日本語限定にはせず英語(素のASCII)も許可し、それ以外の
      # 未知スクリプトだけ幻聴とみなす(TE_NO_LANG_GUARD=1で無効化可)
      if ! sente_lang_plausible "$THEARD"; then
        sente_log_turn "$TW" hallucination "$THEARD"; rm -f "$TW"; printf '  (未知言語の幻聴っぽいので無視:「%s」)\n' "$THEARD" >&2; continue
      fi
      # エコー照合: 自分の直前の返答のこだま(スピーカー→マイク回り込み)は実行しない。
      # ①完全に含まれる(従来・長さ上限は撤廃) ②STTの揺れ(「治せる」→「知せる」等)を許す
      # bigram重なり率0.7以上 — 2026-08-06実ログ: 複数文の返事の後半セグメントを丸ごと
      # 拾い、40文字未満の完全一致だけではすり抜けて自問自答ループになった
      if [ -n "${LAST_REPLY_NORM:-}" ]; then
        THEARD_NORM="$(printf '%s' "$THEARD" | tr -d ' 　。、．，!！?？')"
        TE_ECHO=0
        case "$LAST_REPLY_NORM" in
          *"$THEARD_NORM"*) TE_ECHO=1 ;;
        esac
        if [ "$TE_ECHO" = 0 ] && [ "${#THEARD_NORM}" -ge 12 ]; then
          case "$(sente_echo_ratio "$THEARD_NORM" "$LAST_REPLY_NORM")" in
            0.[7-9]*|1*) TE_ECHO=1 ;;
          esac
        fi
        if [ "$TE_ECHO" = 1 ]; then
          sente_log_turn "$TW" echo "$THEARD"; rm -f "$TW"
          printf '  (自分の声のこだまなので無視:「%s」)\n' "$THEARD" >&2
          continue
        fi
      fi
      sente_log_turn "$TW" ok "$THEARD"; rm -f "$TW"
      printf '  🎤 「%s」\n' "$THEARD" >&2
      sente_voice_quota_check >/dev/null 2>&1 || true   # 💳 超えた瞬間に一度だけ告げる(このターンは続ける・次回起動で止まる)
    fi
    # 🙏 純粋な締めのあいさつはLLMに回さない: 「ありがとうございました」→「お待ちしています」
    # →そのこだま→…の礼儀正しい無限ループ(2026-08-06実ログ)を根元で断つ。短く受けて聞き直しへ
    TH_CLOSE="$(printf '%s' "$THEARD" | tr -d ' 　。、．，!！?？')"
    if [ "${#TH_CLOSE}" -le 16 ]; then
      case "$TH_CLOSE" in
        ありがとう|ありがとうございます|ありがとうございました|どうもありがとう*|おつかれさま*|お疲れ様*|お疲れさま*|よろしくおねがいします|よろしくお願いします|またね|じゃあね|バイバイ|さようなら|それではまた*|ではまた*|失礼します)
          koe_say_sync "こちらこそ。またいつでもどうぞ。"
          continue ;;
      esac
    fi
    # ♟ 「先手の一手」への返事: 提案の直後に「やって」と言われたら、その一手をそのまま打つ。
    # ローマ字(yatte)・英語(ok/yes)のタイピングも受ける(2026-08-07実障害: ⌨「yatte」が不一致
    # →提案が黙って消え、素の「yatte」だけがLLMへ渡り「何をやるんですか?」と聞き返された)。
    # 短い返事は聞き取りゆれの可能性があるので提案を保持し、長い別の話を始めた時だけ流す
    SENTE_FORCE_ACP=0
    OPENING_NOTE=""
    if [ -f "$CONFIG_DIR/opening-task" ]; then
      OP_NORM="$(printf '%s' "$THEARD" | tr -d ' 　。、．，!！?？' | tr 'A-Z' 'a-z')"
      OP_HIT=0
      case "$OP_NORM" in
        はい|うん|ええ|やって|やろう|やってみて|やってみよう|やっちゃって|それやって|やってください|やっといて|おねがい|お願い|おねがいします|お願いします|いいよ|いいね|おっけー|オッケー|すすめて|進めて|たのむ|頼む|ゴー|ok|okay|yes|go|sure|doit|yatte|yarou|hai|onegai)
          OP_HIT=1 ;;
      esac
      if [ "$OP_HIT" = 1 ]; then
        # ⚠ お金が動く・外部送信・削除等の後戻りしにくい一手(risk=confirm)は、
        # 「やって」の一言だけでは即実行しない。opening-taskは保持したまま一段確認を
        # 挟み、2回目の「やって」で初めて実行する(2026-08-29実障害の再発防止:
        # 広告キャンペーンの再開/停止判断タスクが一言で実行されかけた)。
        OP_RISK_V="$(cat "$CONFIG_DIR/opening-risk" 2>/dev/null || echo safe)"
        if [ "$OP_RISK_V" = "confirm" ] && [ ! -f "$CONFIG_DIR/opening-confirm-armed" ]; then
          : > "$CONFIG_DIR/opening-confirm-armed"
          printf '  ⚠️ 実際に影響のある操作のため確認します(2回目の「やって」で実行)\n' >&2
          koe_say_sync "これは実際に影響のある操作なので確認します。本当にやってよければ、もう一度やってと言ってください"
          continue
        fi
        rm -f "$CONFIG_DIR/opening-confirm-armed"
        THEARD="$(cat "$CONFIG_DIR/opening-task" 2>/dev/null || printf '%s' "$THEARD")"
        rm -f "$CONFIG_DIR/opening-task" "$CONFIG_DIR/opening-risk" "$CONFIG_DIR/opening-drop-armed"
        printf '  ♟ 先手、打ちます: %s\n' "$THEARD" >&2
        koe_say_sync "はい、先手打ちます"
        # 提案の一手は手元作業(ファイル/ブラウザ/コマンド)前提 → 道具なしの直APIに
        # 「できません」「何をやるんですか」と即答で勝たせない(第15弾の根治と同じ理由)
        SENTE_FORCE_ACP=1
      else
        # ♟ 提案への深掘り(「けんすうにはどんなこと送る予定?」等)は「別の話」ではない
        # (2026-08-09実障害: 質問が12字超で提案ごと黙って捨てられ、素の質問だけがLLMへ渡り
        # 「何も聞いてない」と答えた)。質問形なら提案を保持し、提案の中身をこのターンの
        # 文脈として渡す。質問でない長い別件だけ従来どおり流す(一手は一度きり)
        case "$THEARD" in
          # 🪤「どう」単体は「ありがとう」「どうぞ」に誤マッチするので、疑問の形だけを列挙する
          *\?*|*？*|*どんな*|*何*|*なに*|*なぜ*|*なんで*|*理由*|*どういう*|*どうやって*|*どうする*|*詳しく*|*くわしく*|*教えて*|*とは*) OP_ASK=1 ;;
          *) OP_ASK=0 ;;
        esac
        if [ "$OP_ASK" = 1 ] || [ "${#OP_NORM}" -le 12 ]; then
          OPN_SAY="$(tr '\n' ' ' < "$CONFIG_DIR/opening-last" 2>/dev/null || true)"
          OPN_TASK="$(tr '\n' ' ' < "$CONFIG_DIR/opening-task" 2>/dev/null || true)"
          OPENING_NOTE="(状況メモ: 直前にSente自身が先手の一手としてこう提案した→「${OPN_SAY}」。承諾されたら実行する作業内容→「${OPN_TASK}」。正本は~/workspace/tasks/human-gates.mdの該当項目。この提案について聞かれたら、この内容から具体的に答える(必要なら正本を読む)。本人が「やって」と言うまで実行はしない。) "
          # 提案に触れている(質問/短い相槌) → 誤認識ストライクはリセット
          rm -f "$CONFIG_DIR/opening-drop-armed"
        else
          # 明らかに別の話 — ただし1回で捨てない(2026-08-29実測: マイクが環境音・タイピング音を
          # 誤認識した1発話で一手が数秒で消えた)。STTの環境音注記([mouse clicking]等の
          # ブラケット行)は発話と数えず、それ以外も1回目はストライクだけ立てて保持、
          # 2回続いた時に初めて流す(確認待ちも一緒に解除)。
          case "$THEARD" in
            \[*\]|（*）|\(*\)) : ;;  # 環境音・非言語注記は別の話と数えない
            *)
              if [ ! -f "$CONFIG_DIR/opening-drop-armed" ]; then
                : > "$CONFIG_DIR/opening-drop-armed"
              else
                rm -f "$CONFIG_DIR/opening-task" "$CONFIG_DIR/opening-risk" "$CONFIG_DIR/opening-confirm-armed" "$CONFIG_DIR/opening-drop-armed"
              fi ;;
          esac
        fi
      fi
    fi
    # 📦 裏タスク検知: 「裏で/バックグラウンドで」始まり・「やっておいて/やっといて」終わりは
    # 通常のLLM往復に乗せず oc run を裏で回して即受理を返す(完了は次ターン先頭でsente_bg_checkが報告)
    if sente_bg_detect "$THEARD"; then
      sente_bg_start "$THEARD$SENTE_PERSONA" "$THEARD"
      printf '  📦 裏で始めました\n' >&2
      koe_say_sync "裏で始めました"
      continue
    fi
    koe_sfx think
    # 相槌を鳴らしながら考える(沈黙を消す)。返事を読む直前に鳴り終わりを待つので、
    # 相槌と返事が重ならない。🪤 ここで koe_speak_text を使うと、返事側の読み上げと
    # 同時に走って lock を奪い合い、どちらも鳴らなくなる(実測)
    FILLER_PID=""
    sente_grow_fillers "$(sente_filler_kind "$THEARD")"   # 裏で言い回しをひとつ増やす
    # 合いの手の選択はエッジ(意味マッチ)に任せ、選ぶ〜鳴らすを丸ごと裏へ。
    # レース開始(返事の生成)は1msも待たせない
    sente_aizuchi_filler "$THEARD" >/dev/null &
    FILLER_PID=$!
    # 🧠 二段目=文脈復唱の一言も裏で(答えが先に来たら自分から譲る設計なので投げっぱなしでよい)
    sente_ctx_filler "$THEARD" >/dev/null &
    CTXF_PID=$!
    # 🔁 直前の返答が割り込みで最後まで聞かれなかった場合、ユーザーは続きを知らない前提で
    # 答える必要がある(本人が今日探させた音声UXベストプラクティス「中断された発話は状態に
    # 残し、次のターンがそれを踏まえて続ける/やり直す/新規に答えるを判断する」を反映)。
    # 生成自体は先に完了してから読み上げる設計(Sente)なのでLLMの生成は途切れないが、
    # 「ユーザーが最後まで聞いたか」はLLM側からは分からないので一度だけ知らせる
    # 👤 話者タグ(sticky): 直近15分の声紋照合が高一致(0.8以上)の時だけ「優貴さん本人」を伝える。
    # それ未満は何も主張しない(現状の実測は本人でも0.5台に出ることがあり、別人断定は誤爆が怖い)
    SPEAKER_NOTE=""
    if [ -f "$CONFIG_DIR/speaker-last" ]; then
      SPK_TS=""; SPK_V=""
      read -r SPK_TS SPK_V < "$CONFIG_DIR/speaker-last" 2>/dev/null || true
      if [ -n "$SPK_V" ] && [ "$(( $(date +%s) - ${SPK_TS:-0} ))" -le 900 ] 2>/dev/null; then
        case "$SPK_V" in
          0.8*|0.9*|1|1.*) SPEAKER_NOTE="(声の確認: 直近の声はオーナー本人=優貴さんと高い一致。本人への呼びかけは『優貴さん』。) " ;;
        esac
      fi
    fi
    if [ -n "${SENTE_INTERRUPTED_NOTE:-}" ]; then
      TPROMPT="${SENTE_INTERRUPTED_NOTE}${SPEAKER_NOTE}${OPENING_NOTE}${THEARD}${SENTE_PERSONA}"
      SENTE_INTERRUPTED_NOTE=""
    else
      # ♟ OPENING_NOTE: 先手の提案が生きている間は提案の中身を渡す(「どんなこと送る予定?」に
      # 「聞いてない」と答えさせない)。提案が無いターンは空文字=従来と同一
      TPROMPT="${SPEAKER_NOTE}${OPENING_NOTE}${THEARD}$SENTE_PERSONA"
    fi
    SENTE_BG_LABEL_HINT="$THEARD"   # 📦 自動裏送り(sente_race_bg_handoff)の報告ラベル用(ペルソナ抜き)
    # 🔀 恒久切替でopencode以外が選ばれていれば、ACP常駐・レース(sente_race_watched)は使わず、
    # このターンの依頼をエンジンのランナーだけで完結させる(2026-08-06本人指示)
    CUR_ENGINE="$(sente_engine_get)"
    if [ "$CUR_ENGINE" != "opencode" ]; then
      if ! command -v "$CUR_ENGINE" >/dev/null 2>&1; then
        sente_kill_filler
        sente_engine_missing_msg "$CUR_ENGINE"
        continue
      fi
      ENG_CONT=0; [ "$ENGINE_TALK_FIRST" = 1 ] || ENG_CONT=1
      sente_engine_run "${TE_ENGINE_TIMEOUT:-300}" "$CUR_ENGINE" "$ENG_CONT" "$TPROMPT" || true
      ENGINE_TALK_FIRST=0
      if [ "$ENGINE_CANCELLED" = 1 ]; then
        sente_kill_filler
        continue
      fi
      [ -n "$FILLER_PID" ] && { wait "$FILLER_PID" 2>/dev/null || true; FILLER_PID=""; }
      if [ -n "$ENGINE_REPLY" ]; then
        LAST_REPLY_NORM="$(printf '%s' "$ENGINE_REPLY" | tr -d '\n 　。、．，!！?？' | tail -c 2000)"
        LAST_REPLY_TXT="$ENGINE_REPLY"
        printf '%s\n' "$ENGINE_REPLY"
        koe_speak_text "$(printf '%s' "$ENGINE_REPLY" | grep -av '^\s*$' | tail -3)"
      else
        printf '  ⚠ %s から応答がありませんでした\n' "$CUR_ENGINE" >&2
        koe_say_sync "うまく実行できませんでした。"
      fi
      continue
    fi
    # 🚄 常駐モード: FIFO越しに一往復(~4s)。落ちたら畳んで従来モードに自動切替
    if [ "$ACP_ON" = 1 ] || [ "${TE_VOICE_RACE:-1}" = "1" ]; then
      RACE_T0="$(date +%s)"
      sente_race_watched "$TPROMPT" || true
      if [ "$RQ_CANCELLED" = 1 ]; then
        # 🛑 中断: この往復の返答は使わない。相槌が鳴っていれば片付けて聞き直しへ戻る
        sente_kill_filler
        continue
      fi
      if [ "$RQ_BACKGROUNDED" = 1 ]; then
        # 📦 裏へ回した(sente_race内で本人には既に一声かけ済み)。ここでacp_stopしてしまうと
        # 常駐ドライバごと裏ジョブを巻き添えで殺してしまうので、普通に聞き直しへ戻るだけにする
        sente_kill_filler
        continue
      fi
      mkdir -p "$(dirname "$SENTE_LAT")" 2>/dev/null
      printf '{"ts":%s,"sec":%s,"model":"%s"}\n' "$RACE_T0" "$(( $(date +%s) - RACE_T0 ))" \
        "${TE_VOICE_FAST_MODEL:-claude-haiku-4-5-20251001}" >> "$SENTE_LAT" 2>/dev/null || true
      if [ -n "$ACP_REPLY" ]; then
        LAST_REPLY_NORM="$(printf '%s' "$ACP_REPLY" | tr -d '\n 　。、．，!！?？' | tail -c 2000)"   # 600だと長い返事の前半こだまを取り逃す
        LAST_REPLY_TXT="$ACP_REPLY"   # 「もう一回」用に直前の返答全文を保持
        sente_ctx_append "$THEARD" "$ACP_REPLY"   # 🧠 直APIパスにも会話の文脈を渡す(挨拶やり直し・忘却の根治)
        # 📈 この往復の賢さを裏で採点(結果は次回起動のモデル自動調整が使う)
        ( SENTE_QJ_TARGET="${TE_VOICE_FAST_MODEL:-claude-haiku-4-5-20251001}" \
          sente_quality_judge "$THEARD" "$ACP_REPLY" ) >/dev/null 2>&1 &
        [ -n "$FILLER_PID" ] && { wait "$FILLER_PID" 2>/dev/null || true; FILLER_PID=""; }
        if [ -f /tmp/sente_say_full_won ]; then
          : # 常駐モードが勝ち、文ごとに表示・読み上げ済み → まとめての表示/読み上げは重複するのでしない
        else
          printf '%s\n' "$ACP_REPLY"
          koe_speak_text "$ACP_REPLY"
        fi
        TALK_FIRST=0
        continue
      fi
      echo "  ⚠ 常駐モードが応答しないので従来モードに切り替えます" >&2
      acp_stop
    fi
    # 画面を見ていない声モードでは「固まったまま気づけない」のが一番困るので、
    # 一往復に上限を置き、超えたら殺してもう一度だけ試す(OpenCodeの間欠的な起動ハング対策)。
    # KB=1ならEnter/Escで実行中も中断できる(sente_run_watched)。KB=0では従来どおり監視なし
    if [ "$TALK_FIRST" = 1 ]; then
      sente_run_watched "${TE_VOICE_TIMEOUT:-90}" run "$TPROMPT" || true
      TALK_FIRST=0
    else
      sente_run_watched "${TE_VOICE_TIMEOUT:-90}" run -c "$TPROMPT" || true
    fi
    [ "$RW_CANCELLED" = 1 ] && sente_kill_filler
  done
  acp_stop
  rm -f "$SENTE_CTX_FILE"
  if [ "$(cat /tmp/sente_talk.pid 2>/dev/null)" = "$$" ]; then rm -f /tmp/sente_talk.pid; fi
  exit 0
fi

# 🎙 引数なしの素の `te`(対話起動)だけ、初回に使い方の声がけをする(talk/watchと同じ仕組み)
[ $# -eq 0 ] && sente_first_run_intro te

# 🪶 メモリ削減(2026-08-16): Bun の --smol モードで GC を頻繁に実行し、JS ヒープ
# (WebKit Malloc)の無制限成長を抑える。CLI ツールなので GC 頻発のレイテンシ増は許容範囲。
# ユーザーが既に BUN_OPTIONS を設定している場合はそれを尊重(上書きしない)。
export BUN_OPTIONS="${BUN_OPTIONS:---smol}"

# 🖱 2026-08-17実機確認: macOS標準Terminal.app(TERM_PROGRAM=Apple_Terminal)はSGR拡張マウス
# レポート(all-motion tracking)に完全対応しておらず、マウスを動かすとイベントレポートが
# 生のエスケープシーケンステキストとして画面に漏れる実障害を確認。ただしホイールスクロール
# 自体は正常に報告されるため、2026-09-10 からはマウス全体を切るのではなく「移動追跡だけ」
# 無効化する(SENTE_DISABLE_MOUSE_MOTION=1 → OpenTUI enableMouseMovement=false)。
# これでクリック/スクロールは効いたまま、移動時の文字化けだけ防げる。
# ユーザーが明示的に設定済みなら上書きしない。完全にマウスを切りたい場合は SENTE_DISABLE_MOUSE=1。
if [ "${TERM_PROGRAM:-}" = "Apple_Terminal" ] && [ -z "${SENTE_DISABLE_MOUSE:-}" ] && [ -z "${SENTE_DISABLE_MOUSE_MOTION:-}" ]; then
  export SENTE_DISABLE_MOUSE_MOTION=1
fi
# 💰 タスク前クレジット見積もり(2026-09-10 ペルソナ採点レポート最優先課題④コスト透明性)。
#   `te run "..."` の非TTY実行で、メッセージの入力トークン概算(4文字=1tok)×モデル単価
#   (GET /v1/models/pricing・1時間キャッシュ)+出力仮定2k tok から初回プロンプトの下限crを
#   stderr に1行表示する。残高は /api/v1/auth/me の credits_remaining。
#   エージェントループで実消費は大きく超えるため「初回分の下限」と明示。無効化=TE_NO_ESTIMATE=1
te_estimate_run() {  # $1=モデル(teai/auto等) $2=メッセージ本文。出力はstderrのみ
  [ "${TE_NO_ESTIMATE:-0}" = "1" ] && return 0
  command -v python3 >/dev/null 2>&1 || return 0
  EST_MODEL="${1:-teai/auto}"
  EST_MSG="${2:-}"
  [ -n "$EST_MSG" ] || return 0
  # 🚀 起動速度(2026-09-11 実測): 旧実装は pricing → auth/me → usage の3本を**直列**に叩き、
  #   `te run` の開始を毎回 1.7〜3.4 秒ブロックしていた(te run 7.0s vs 素の opencode 3.7s)。
  #   ① 3本を並列に投げる(直列 2.9s → 並列=最長の1本 ≈ 1.1s)
  #   ② 残高と実測平均は短TTL(既定60秒)キャッシュ → 続けて run する時は通信ゼロ
  #   ③ 単価テーブルは従来どおり1時間キャッシュ
  #   全部失敗しても黙って見積もりを出さないだけ(フェイルオープン・起動は止めない)
  EST_CACHE="$CONFIG_DIR/.pricing-cache.json"
  EST_STATE="$CONFIG_DIR/.est-state"
  EST_NOW="$(date +%s)"
  EST_AGE=99999
  # 🪤 `stat -f %m || stat -c %Y` の順は Linux で壊れる: GNU stat の -f は「ファイルシステム情報」で
  #    成功扱い(exit 0)のため fallback に落ちず、複数行の出力が算術式に入り "arithmetic expression:
  #    expecting EOF" で te run ごと死ぬ(2026-09-10 Ubuntu 24.04 実機)。OS 判定するヘルパーを使う
  [ -f "$EST_CACHE" ] && EST_AGE=$(( EST_NOW - $(sente_stat_mtime "$EST_CACHE") ))
  EST_STATE_AGE=99999
  [ -f "$EST_STATE" ] && EST_STATE_AGE=$(( EST_NOW - $(sente_stat_mtime "$EST_STATE") ))

  # --- 1) 必要な分だけ並列に取りに行く -------------------------------------
  EST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/te_est_XXXXXX")" || return 0
  EST_P1=""; EST_P2=""; EST_P3=""
  if [ "$EST_AGE" -gt 3600 ]; then
    curl -s -m 4 "$TEAI_API/v1/models/pricing" -o "$EST_TMP/pricing" 2>/dev/null &
    EST_P1=$!
  fi
  if [ -n "${TEAI_API_KEY:-}" ] && [ "$EST_STATE_AGE" -gt "${TE_EST_STATE_TTL:-60}" ]; then
    curl -s -m 3 -H "Authorization: Bearer $TEAI_API_KEY" "$TEAI_API/api/v1/auth/me" -o "$EST_TMP/me" 2>/dev/null &
    EST_P2=$!
    curl -s -m 3 -H "Authorization: Bearer $TEAI_API_KEY" "$TEAI_API/api/v1/usage" -o "$EST_TMP/usage" 2>/dev/null &
    EST_P3=$!
  fi
  # ⚠ set -e 下で `wait` が非0を返すと launcher ごと死ぬので必ず || true で受ける
  if [ -n "$EST_P1" ]; then wait "$EST_P1" 2>/dev/null || true; fi
  if [ -n "$EST_P2" ]; then wait "$EST_P2" 2>/dev/null || true; fi
  if [ -n "$EST_P3" ]; then wait "$EST_P3" 2>/dev/null || true; fi

  # --- 2) 結果の確定 -------------------------------------------------------
  if [ -s "$EST_TMP/pricing" ]; then
    mv -f "$EST_TMP/pricing" "$EST_CACHE"
  fi
  EST_BAL=""; EST_AVG=""
  if [ -s "$EST_TMP/me" ] || [ -s "$EST_TMP/usage" ]; then
    if [ -s "$EST_TMP/me" ]; then
      EST_BAL="$(sed -n 's/.*"credits_remaining":\([0-9.]*\).*/\1/p' "$EST_TMP/me" 2>/dev/null | head -1)"
    fi
    if [ -s "$EST_TMP/usage" ]; then
      EST_AVG="$(python3 -c 'import json,sys
try:
    u=(json.load(open(sys.argv[1])).get("usage") or {})
    r=u.get("requests_30d",0); c=u.get("credits_30d",0)
    print(round(c/r) if r else "")
except Exception: print("")' "$EST_TMP/usage" 2>/dev/null)"
    fi
    # 取れた分だけ次回のためにキャッシュ(片方だけ成功しても覚える)
    printf '%s %s\n' "${EST_BAL:-}" "${EST_AVG:-}" > "$EST_STATE" 2>/dev/null || true
  elif [ -f "$EST_STATE" ]; then
    read -r EST_BAL EST_AVG < "$EST_STATE" 2>/dev/null || true
  fi
  rm -rf "$EST_TMP" 2>/dev/null || true
  [ -s "$EST_CACHE" ] || return 0
  TE_EST_MODEL="$EST_MODEL" TE_EST_MSG="$EST_MSG" TE_EST_BAL="$EST_BAL" TE_EST_AVG="$EST_AVG" TE_EST_LANG="$(te_ui_lang)" python3 - "$EST_CACHE" <<'ESTPY' >&2 2>&2
import json, os, sys
try:
    with open(sys.argv[1]) as f:
        table = json.load(f).get("data", [])
    model = os.environ.get("TE_EST_MODEL", "teai/auto")
    msg = os.environ.get("TE_EST_MSG", "")
    bal = os.environ.get("TE_EST_BAL", "")
    avg = os.environ.get("TE_EST_AVG", "")
    en = os.environ.get("TE_EST_LANG") == "en"
    # teai/ プレフィックス無しは teai/ を付けて探す。見つからなければ teai/auto に倒す
    cands = [model, "teai/" + model] if not model.startswith("teai/") else [model]
    row = next((m for c in cands for m in table if m.get("id") == c), None)
    if row is None:
        row = next((m for m in table if m.get("id") == "teai/auto"), None)
    if row is None:
        sys.exit(0)
    in_tok = max(1, round(len(msg) / 4)) + 4000  # システムプロンプト+rules分の固定加算
    out_tok = 2000
    cr = in_tok / 1000 * float(row["credits_in_1k"]) + out_tok / 1000 * float(row["credits_out_1k"])
    yen = cr / 6
    bal_s = (f"balance {float(bal):,.0f}cr" if bal else "balance ?") if en else (f"残高 {float(bal):,.0f}cr" if bal else "残高 ?")
    if en:
        line = f"💰 Estimate: first turn ≈ {cr:,.0f}cr (~¥{yen:,.0f}, {row['id']}, floor) / {bal_s}"
    else:
        line = f"💰 見積もり: 初回 ≈ {cr:,.0f}cr(約¥{yen:,.0f}・{row['id']}・下限) / {bal_s}"
    if avg:
        try:
            a = float(avg)
            if en:
                line += f" · your avg {a:,.0f}cr/request (30d)"
            else:
                line += f" · 実測平均 {a:,.0f}cr/回(30日)"
        except Exception:
            pass
    if en:
        line += " · loops run many turns → real cost can be several× the floor · off=TE_NO_ESTIMATE=1"
    else:
        line += " · ループは複数ターン回るため実消費は下限の数倍になりうる · 無効化=TE_NO_ESTIMATE=1"
    print(line)
except Exception:
    sys.exit(0)
ESTPY
  return 0
}

# 🔁 launchd KeepAlive × `te run` の無限ループ防止(2026-09-10実測: wanpo写真ジョブが9/7に完了した後も
#   3日間・12,912回「全件完了・変更なし」を出力し続け、1日13,000リクエスト/430万crを燃やした)。
#   `te run` は非TTY実行で、かつカレントに .sente-done があれば即終了(exit 0)。
#   出力に完了マーカー(既定 SENTE_DONE / TE_DONE_MARKER で変更可)が含まれていたら .sente-done を作る。
#   → launchd 側は plist を変えなくても、次の再起動が一瞬で終わるようになる。
#   タスク文に「全部終わっていたら SENTE_DONE と出力して終了」と書けば完了。TE_NO_DONE_GUARD=1 で無効。
if [ "${1:-}" = "run" ] && [ ! -t 0 ] && [ "${TE_NO_DONE_GUARD:-0}" != "1" ]; then
  # 💰 見積もり(非TTYの run のみ・TTY対話はTUI側の表示に委ねる)。引数の--model/-mを拾い、
  # 残りをメッセージとして結合。フラグ引数の厳密パースはしない(粗い1行表示で十分)
  EST_MODEL_ARG="${FORCE_MODEL:-teai/auto}"
  EST_MSG_ARG=""
  EST_SKIP=0
  for EST_A in "$@"; do
    if [ "$EST_SKIP" = 1 ]; then EST_MODEL_ARG="$EST_A"; EST_SKIP=0; continue; fi
    case "$EST_A" in
      run) ;;
      --model|-m) EST_SKIP=1 ;;
      --model=*) EST_MODEL_ARG="${EST_A#--model=}" ;;
      -*) ;;
      *) EST_MSG_ARG="${EST_MSG_ARG:+$EST_MSG_ARG }$EST_A" ;;
    esac
  done
  te_estimate_run "$EST_MODEL_ARG" "$EST_MSG_ARG"
  if [ -f ".sente-done" ]; then
    printf 'te run: .sente-done があるので実行しません(前回 %s に完了)。再実行するなら rm .sente-done\n' \
      "$(cat .sente-done 2>/dev/null | head -1)" >&2
    exit 0
  fi
  DONE_MARK="${TE_DONE_MARKER:-SENTE_DONE}"
  DONE_TEE="$(mktemp "${TMPDIR:-/tmp}/te_done_XXXXXX")" || DONE_TEE=""
  if [ -n "$DONE_TEE" ]; then
    # stdout を tee で覗くだけ。終了コードは opencode 側のものを返す(パイプで潰さない)
    { SENTE_WD_NO_EXEC=1 sente_tui_watchdog "$@"; echo "$?" > "$DONE_TEE.rc"; } | tee "$DONE_TEE"
    DONE_RC="$(cat "$DONE_TEE.rc" 2>/dev/null || echo 1)"
    if [ "$DONE_RC" = 0 ] && grep -q "$DONE_MARK" "$DONE_TEE" 2>/dev/null; then
      date '+%Y-%m-%d %H:%M:%S' > .sente-done
      printf 'te run: 完了マーカー %s を検出 → .sente-done を作成(次回の te run は即終了)\n' "$DONE_MARK" >&2
    fi
    rm -f "$DONE_TEE" "$DONE_TEE.rc"
    exit "$DONE_RC"
  fi
fi
# argv[0]をsenteにしてActivity Monitor等のプロセス名をブランドに統一(実体はOpenCode)
# 🐕 対話TUIはウォッチドッグ経由で起動(応答ハングを検知して再接続)。TE_NO_WATCHDOG=1で素のexecに戻る
sente_tui_watchdog "$@"

LAUNCHER
# ランチャーに自分のバージョンを埋める(X-Sente-Client-Version の初回起動時スタンプ用)。
# sed -i は BSD/GNU で引数形式が違うので、一時ファイル経由の mv にする(両OS共通)。
sed "s/__TE_SCRIPT_VERSION__/$TE_SCRIPT_VERSION/" "$BIN_DIR/.te.new.$$" > "$BIN_DIR/.te.new.$$.v" \
  && mv -f "$BIN_DIR/.te.new.$$.v" "$BIN_DIR/.te.new.$$" || rm -f "$BIN_DIR/.te.new.$$.v"
chmod +x "$BIN_DIR/.te.new.$$"
# 🛡 自己検査: 生成したランチャーが /bin/sh(macOSはbash3.2)で構文エラーなら絶対に配置しない。
# 2026-08-06に「$()内ヒアドキュメントの引用符が奇数」で全ユーザーのsenteが起動不能になった再発防止。
if ! sh -n "$BIN_DIR/.te.new.$$" 2>/dev/null; then
  sh -n "$BIN_DIR/.te.new.$$" 2>&1 | head -3 >&2 || true
  rm -f "$BIN_DIR/.te.new.$$"
  printf '  error  生成したランチャーが /bin/sh で構文エラーです。インストールを中止しました(既存のteは無傷)\n' >&2
  exit 1
fi
mv -f "$BIN_DIR/.te.new.$$" "$BIN_DIR/te"
# 🔀 2026-08-17: `sente` symlink を復活(本人指示「senteはteのガードレールなし起動」)。
# 以前はOpenCode本体の"Sente"改名で名前衝突が起きたが、現在はOpenCode側が
# $BIN_DIR/sente を自前で張る運用ではなくなったため、te への symlink として管理する。
# launcher 側の sente 分岐が SENTE_NO_GUARDRAILS=1 を立て、permission全許可の設定で起動する。
ln -sf "$BIN_DIR/te" "$BIN_DIR/sente"
ln -sf "$BIN_DIR/te" "$BIN_DIR/koe"
ln -sf "$BIN_DIR/te" "$BIN_DIR/fuseki"
ok "Installed: $BIN_DIR/te (alias: sente[no-guardrails], koe, fuseki)"

# 🖥 Playwright MCP 常駐サーバー起動スクリプトを配置(複数 sente セッションで共有するため)
mkdir -p "$HOME/bin" 2>/dev/null || true
cat > "$HOME/bin/playwright-mcp-server.sh" <<'PWSCR'
#!/bin/sh
# Playwright MCP 常駐サーバー起動スクリプト
# sente 起動時に呼ばれる。ポート 8932 で既に起動済みなら何もしない(冪等)。
# ヘッドレスモードで起動し、複数 sente セッションが同じサーバーを共有する。

set -eu

PORT="${PLAYWRIGHT_MCP_PORT:-8932}"
LOG="${PLAYWRIGHT_MCP_LOG:-/tmp/playwright-mcp-server.log}"
PIDFILE="${PLAYWRIGHT_MCP_PIDFILE:-/tmp/playwright-mcp-server.pid}"

# ヘルスチェック用のMCP initializeリクエスト
healthcheck() {
  curl -s -m 2 -X POST "http://localhost:$PORT/mcp" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"healthcheck","version":"1.0"}}}' >/dev/null 2>&1
}

# ポートが応答していれば起動済み
if healthcheck; then
  # PIDFILE が古い/無い場合は、ポートを掴んでいる実際の PID を書き直す
  if ! kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
    REAL_PID="$(lsof -ti tcp:$PORT 2>/dev/null | head -1)"
    [ -n "$REAL_PID" ] && echo "$REAL_PID" > "$PIDFILE" 2>/dev/null || true
  fi
  exit 0
fi

# ポートが掴まれているのに応答しない(ゾンビ)場合は掃除
STALE_PID="$(lsof -ti tcp:$PORT 2>/dev/null | head -1)"
if [ -n "$STALE_PID" ]; then
  kill -KILL "$STALE_PID" 2>/dev/null || true
  sleep 1
fi

# 起動: グローバルにインストール済みの playwright-mcp を直接使う(npx より軽い)
#   グローバルに無ければ npx にフォールバック
if command -v playwright-mcp >/dev/null 2>&1; then
  PW_BIN="$(command -v playwright-mcp)"
else
  PW_BIN="npx -y @playwright/mcp@latest"
fi
nohup $PW_BIN --port "$PORT" --headless \
  > "$LOG" 2>&1 &
echo $! > "$PIDFILE"

# 起動確認 (最大5秒待つ)
for i in 1 2 3 4 5; do
  if healthcheck; then
    exit 0
  fi
  sleep 1
done

echo "⚠ Playwright MCP サーバーの起動に失敗しました ($LOG)" >&2
exit 1
PWSCR
chmod +x "$HOME/bin/playwright-mcp-server.sh" 2>/dev/null || true
ok "Playwright MCP server script: $HOME/bin/playwright-mcp-server.sh"

# Write the coding rules now so they exist before the first `te` run.
cat > "$CONFIG_DIR/sente-rules.md" <<'RULES'
# Sente coding rules — follow mechanically, not as suggestions

## Always
- Read before you write. Open the real code with a tool before you create/edit a
  file or state any finding. Never guess a line number, API, or macro name.
- Cite evidence. Every claim names a file:line you actually read. If unverified,
  write "unverified" — never invent a location or a fix.
- Finish the deliverable. If asked for a file, fix, or report, produce it before
  ending the turn. Exploring is not finishing.
- Big files: search for candidates first, then read only ~30 lines around each
  hit. Never read a 20k-line file top to bottom.
- Match the surrounding code's style, naming, and idioms.

## Memory (3 layers: shallow index / topic files / deep store)
- ~/.config/teai/memory/MEMORY.md is the auto-loaded hot index. It is an index
  only — one line per memory, each linking a topic file in the same directory.
- Before acting on an indexed topic, read its topic file first.
- When you learn a durable fact (a user preference, a project constraint, a
  trap you actually hit), save it: write ~/.config/teai/memory/<slug>.md and
  add one index line to MEMORY.md. Update an existing file instead of creating
  a duplicate; delete entries that turn out to be wrong.
- Deep store: move index lines inactive for ~2 weeks into
  ~/.config/teai/memory/MEMORY_cold.md. Grep it when older context is needed.
- Keep MEMORY.md short — it is injected into every session and costs tokens.
- Never write secrets (API keys, passwords, tokens) into memory files.

## Unknown words — provisional (abductive) reasoning
- When the user uses a word, name, or acronym you cannot resolve (not in memory,
  not in the codebase, or a likely speech-to-text mishearing), do not stop and
  do not silently guess. Check ~/.config/teai/memory/glossary.md first.
- Form the best provisional hypothesis from context: phonetic neighbours of
  names in memory/glossary, the current project, the last few turns. Prefer the
  reading that makes the request actionable.
- Say it in one short clause and proceed: 「『◯◯』は△△のことだと仮定して進めます」.
  Then continue the task under that assumption.
- Record it in glossary.md as `- ◯◯ → △△ (仮説 YYYY-MM-DD: 根拠)`. When the user
  confirms or corrects, rewrite the line as `(確定 YYYY-MM-DD)`. Confirmed terms
  are also fed to speech recognition as vocabulary hints.
- Never act on a provisional hypothesis for irreversible actions (send, delete,
  pay, publish, deploy) — confirm the word first.
RULES
ok "Coding rules written: $CONFIG_DIR/sente-rules.md"

# Create the per-user memory templates once (never overwritten — the agent's
# own persistent memory lives here, on this machine only). The launcher also
# does this on every run (ensure_memory), so this is just a first-run warm-up.
if [ ! -d "$CONFIG_DIR/memory" ] || [ ! -f "$CONFIG_DIR/memory/MEMORY.md" ]; then
  "$BIN_DIR/te" memory >/dev/null 2>&1 || true
fi
[ -f "$CONFIG_DIR/memory/MEMORY.md" ] && ok "Memory initialized: $CONFIG_DIR/memory/ (te memory で確認)"

# Write the KOE voice plugin now so it exists before the first `te` run
# (also rewritten on every `te` invocation via ensure_koe_plugin above).
mkdir -p "$CONFIG_DIR/plugins"
cat > "$CONFIG_DIR/plugins/koe-speak.js" <<'KOEPLUGIN'
// Sente KOE voice plugin — 各セッションの返答を共通キューに積むだけ。
// 実際の読み上げは単一ワーカー(~/.config/teai/voiceq.py worker)が行う。
// これで複数ターミナルが同時に idle になっても声が重ならず、まとめて端的に喋る。
export const KoeSpeak = async ({ client }) => {
  const HOME = process.env.HOME || "";
  const VOICEQ = HOME + "/.config/teai/voiceq.py";

  async function enqueue(sessionID, text) {
    if (!text) return;
    try {
      const { spawn } = await import("node:child_process");
      const proc = spawn("python3", [VOICEQ, "enqueue", sessionID || "?"], {
        stdio: ["pipe", "ignore", "ignore"],
        detached: true,
      });
      proc.stdin.write(text);
      proc.stdin.end();
      proc.unref();
    } catch (e) {
      console.error(`[koe] enqueue error: ${e && e.message}`);
    }
  }

  return {
    event: async ({ event }) => {
      if (event.type !== "session.status") return;
      if (!event.properties || !event.properties.status || event.properties.status.type !== "idle") return;
      if (process.env.AGENT_KOE === "0" || process.env.NO_KOE) return;
      // 🔇 ~/.config/teai/mute は毎回見る(te voice off/声「静かにして」/Sente.appワンクリックが実行中でも即効く)
      try { if ((await import("node:fs")).existsSync((process.env.HOME || "") + "/.config/teai/mute")) return; } catch (e) {}
      const sessionID = event.properties.sessionID;
      try {
        // 🪶 メモリ削減(2026-08-16): 全会話履歴ではなく最新1件だけ取得。
        // limit:1 でサーバは MessageV2.page(ORDER BY DESC+reverse)で最新1件のみ返す。
        const resp = await client.session.messages({ path: { id: sessionID }, query: { limit: 1 } });
        const messages = resp && resp.data ? resp.data : resp;
        if (!Array.isArray(messages) || !messages.length) return;
        const last = messages[messages.length - 1];
        if (!last || !last.info || last.info.role !== "assistant") return;
        const text = (last.parts || [])
          .filter((p) => p.type === "text")
          .map((p) => p.text)
          .join("\n");
        enqueue(sessionID, text).catch(() => {});
      } catch (e) {
        console.error(`[koe] plugin error: ${e && e.message}`);
      }
    },
  };
};
KOEPLUGIN
ok "Voice plugin written: $CONFIG_DIR/plugins/koe-speak.js (default ON — disable with AGENT_KOE=0)"

# --- 4.5 AEC録音ヘルパー senterec(macOSのみ・swiftcがあれば) ---------------------
# 「パソコンの音は拾わないでほしい」(2026-08-06本人指示)への対応。Voice Processing I/O(FaceTimeと
# 同じOS機能)で、このMac自身が鳴らす音をマイク入力から差し引く。実測: スピーカー再生をsoxは
# mean -26.6dBで拾うが、senterecは-41.7dB(15dB減)。ビルドできない環境では従来のsoxのまま。
if [ "$(uname)" = "Darwin" ] && command -v swiftc >/dev/null 2>&1; then
  mkdir -p "$CONFIG_DIR/src" "$CONFIG_DIR/bin"
  cat > "$CONFIG_DIR/src/senterec.swift" <<'SENTERECSWIFT'
// senterec — AEC(エコーキャンセル)付き録音ヘルパー(sox recの置き換え・2026-08-06本人指示
// 「パソコンの音は拾わないでほしい」)。
//
// macOSのVoice Processing I/O(FaceTimeと同じOS機能)を使い、このMac自身が鳴らしている音
// (SenteのTTS読み上げ・YouTube・通知音など、既定出力デバイスに流れる全て)をマイク入力から
// 差し引いて録音する。別デバイス(ラジオ等)の物理的な音は参照が無いので消せない=そちらは
// te側のこだま判定・幻聴フィルタが引き続き受け持つ。
//
// 🔊 2026-08-08本人報告「Macの自分の音も拾っちゃう」(同じMacで動画/ポッドキャストを再生中に
// マイクが拾ってしまう)対応: Voice ProcessingはこのAVAudioEngineインスタンス自身が鳴らす音
// しか参照信号にできず、ブラウザ等の別プロセスが鳴らす音はキャンセル対象外(既知の限界)。
// 根治(全プロセス分の音を波形ごと打ち消す)はScreenCaptureKitでシステム出力を丸ごと
// キャプチャして参照信号にする必要があり、それは実機での権限テストが要る大改修。
// ここでは軽量な代替として、CoreAudioで「既定の出力デバイスが今どこかで鳴っているか」
// (kAudioDevicePropertyDeviceIsRunningSomewhere)を見て、鳴っている間は録音の"開始"を
// 抑制するゲートを追加する(打ち消しではなく検知ベース。厳密ではないが新規権限不要で
// すぐ効く)。--no-sys-gateで無効化可(TE_NO_SYS_AUDIO_GATE=1が渡ってくる)。
//
// 🔴 2026-08-10改修「認識精度悪くなってる」: 上のゲートが完全失聴を起こしていた。
// IsRunningSomewhere=「デバイスを誰かが開いて稼働中」であり「音が実際に出ている」ではない。
// Chromeの無音タブ・Koe常駐などがデバイスを掴みっぱなしのMacでは常にtrue→録音が永久に
// 始まらず、全ターンが未録音タイムアウト(4KBのヘッダだけwav)になっていた。対策:
//   ①ゲート中も声は録る。ただし開始しきい値を2.5倍に上げる(近くで直接話す声だけ通す)
//   ②しきい値ちょうど程度でも0.6秒持続したら開始(=どんな環境でも耳が塞がりきらない保険)
//   ③未録音のままタイムアウトしたら出力wavを削除(壊れたスタブがSTTに送られていた)
//
// 使い方: senterec out.wav [--silence 1.5] [--max 90] [--meter] [--start-thresh 0.02] [--no-sys-gate]
//   - 音が来るまで書き込まない(soxのsilence先頭トリム相当)・無音がsilence秒続いたら終了
//   - --meter: soxの -S 互換のVU行([ ===|=== ])をstderrへ(teのメーター描画をそのまま使える)
//   - 常にexit 0(声ゼロでも)。呼び出し側はファイルサイズで判定する(teの既存ロジックと同じ)
// ビルド: swiftc -O -o senterec senterec.swift (te-install.shがswiftc存在時に自動ビルド)
import AVFoundation
import CoreAudio
import Foundation
import Speech

var out = ""
var silence = 1.5
var maxSec = 30.0   // 2026-08-17: 90→30(teのtalkループ既定と一致。TE_TALK_MAXが明示指定ならそちらが勝つ)
var meter = false
var startTh: Float = 0.02
var stopTh: Float = 0.02
var sysGate = true
var applePath = ""   // 🍎 Appleオンデバイス音声認識の途中経過を書き出すファイル(空=無効)
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--silence": silence = Double(args.isEmpty ? "" : args.removeFirst()) ?? 1.5
    case "--max": maxSec = Double(args.isEmpty ? "" : args.removeFirst()) ?? 90
    case "--meter": meter = true
    case "--start-thresh": startTh = Float(args.isEmpty ? "" : args.removeFirst()) ?? 0.02
    case "--stop-thresh": stopTh = Float(args.isEmpty ? "" : args.removeFirst()) ?? 0.02
    case "--no-sys-gate": sysGate = false
    case "--apple": applePath = args.isEmpty ? "" : args.removeFirst()
    default: out = a
    }
}
if out.isEmpty {
    FileHandle.standardError.write("usage: senterec out.wav [--silence s] [--max s] [--meter] [--no-sys-gate]\n".data(using: .utf8)!)
    exit(2)
}

// 🔊 既定の出力デバイスが「どこかで(=どのプロセスからでも)鳴っているか」を見るだけの軽量チェック。
// 波形は見ない(打ち消しではなく検知)ので、新規の録画/画面収録権限は不要。失敗時はfalse
// (=ゲートしない=従来どおり)を返し、この機能が無くても録音自体は今までどおり動く
func systemOutputIsRunning() -> Bool {
    var deviceID = AudioDeviceID(0)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: 0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
    guard status == noErr, deviceID != 0 else { return false }

    var running: UInt32 = 0
    var runAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: 0)
    size = UInt32(MemoryLayout<UInt32>.size)
    status = AudioObjectGetPropertyData(deviceID, &runAddr, 0, nil, &size, &running)
    guard status == noErr else { return false }
    return running != 0
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
var sysAudioPlaying = false   // 0.2秒ごとにタイマー側で更新(録音タップの実時間処理を軽く保つ)
var gatedVoiceSince: Date? = nil   // ゲート中にしきい値超えの入力が続いている起点(0.6秒で強制開始)

// 🍎 Appleオンデバイス音声認識(2026-08-10本人指示「アップルの音声認識リアルタイムで出ていい・
// それも参考に認識してほしい」): 録音と並行して同じタップの音をSFSpeechRecognizerへ流し、
// 途中経過(partial)をapplePathへ書き続ける。全てMac内で完結(requiresOnDeviceRecognition=
// 外部送信なし)。権限が無い/未対応なら黙って無効(te側はファイルが無ければ従来どおり)。
// 🪤①最終結果(isFinal)は空で来ることがあるmacOSの癖 → 常に「最後のpartial」を正とし、
//   partialのたびatomicにファイルへ書く ②コールバック既定はmainキュー=CLIでは自分が
//   ブロックして届かない(実測デッドロック) → 専用OperationQueueへ逃がす
var appleReq: SFSpeechAudioBufferRecognitionRequest? = nil
if !applePath.isEmpty, SFSpeechRecognizer.authorizationStatus() == .authorized,
   let appleRec = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP")), appleRec.isAvailable {
    let aq = OperationQueue(); aq.maxConcurrentOperationCount = 1
    appleRec.queue = aq
    let areq = SFSpeechAudioBufferRecognitionRequest()
    areq.requiresOnDeviceRecognition = true
    areq.shouldReportPartialResults = true
    appleRec.recognitionTask(with: areq) { res, _ in
        if let s = res?.bestTranscription.formattedString, !s.isEmpty {
            try? s.write(toFile: applePath, atomically: true, encoding: .utf8)
        }
    }
    appleReq = areq
}

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
        // 🔊 他アプリが既定出力デバイスを掴んでいる間は開始しきい値を2.5倍に上げる(完全ブロックはしない:
        // 無音タブ/常駐がデバイスを掴みっぱなしのMacで耳が永久に塞がった実障害があるため)。
        // ゲート中でも、しきい値超えの入力が0.6秒続いたら人が話しかけていると見なして必ず開始する
        let gated = sysGate && sysAudioPlaying
        if rms >= startTh {
            if !gated || rms >= startTh * 2.5 {
                started = true
            } else {
                if gatedVoiceSince == nil { gatedVoiceSince = Date() }
                if Date().timeIntervalSince(gatedVoiceSince!) >= 0.6 { started = true }
            }
            if started {
                recStart = Date()
                lastVoice = Date()
                gatedVoiceSince = nil
            }
        } else {
            gatedVoiceSince = nil
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
        appleReq?.append(buf)   // 🍎 録音中の音だけをApple認識にも流す(同じ耳・追加コストほぼゼロ)
    }
}

do { try engine.start() } catch {
    FileHandle.standardError.write("senterec: engine start failed\n".data(using: .utf8)!)
    exit(2)
}

let t0 = Date()
let timer = Timer(timeInterval: 0.2, repeats: true) { _ in
    if sysGate {
        let running = systemOutputIsRunning()
        lock.lock(); sysAudioPlaying = running; lock.unlock()
    }
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
        // 未録音のままの終了はヘッダだけのwav(約4KB)が残り、呼び出し側のサイズ判定(>4000)を
        // すり抜けて壊れたファイルがSTTに送られていた → ここで消して「録れなかった」を明確にする
        if !st { try? FileManager.default.removeItem(atPath: out) }
        appleReq?.endAudio()   // 🍎 最終結果は待たない(最後のpartialが既にファイルにある=遅延ゼロ)
        exit(0)
    }
}
RunLoop.main.add(timer, forMode: .common)
RunLoop.main.run()
SENTERECSWIFT
  SR_HASH="$(shasum "$CONFIG_DIR/src/senterec.swift" 2>/dev/null | cut -c1-16)"
  if [ ! -x "$CONFIG_DIR/bin/senterec" ] || [ "$(cat "$CONFIG_DIR/bin/.senterec.hash" 2>/dev/null)" != "$SR_HASH" ]; then
    if swiftc -O -o "$CONFIG_DIR/bin/senterec" "$CONFIG_DIR/src/senterec.swift" 2>/dev/null; then
      printf '%s' "$SR_HASH" > "$CONFIG_DIR/bin/.senterec.hash"
      ok "AEC recorder built: $CONFIG_DIR/bin/senterec (パソコン自身の音を拾わない録音)"
    else
      warn "senterec build failed — sox録音のまま続行(機能は損なわれません)"
    fi
  else
    ok "AEC recorder up to date: $CONFIG_DIR/bin/senterec"
  fi
fi

# --- 5. PATH check + done ----------------------------------------------------
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    SH_NAME="$(basename "${SHELL:-sh}")"
    case "$SH_NAME" in
      zsh)  RC="$HOME/.zshrc" ;;
      bash) [ "$(uname -s)" = "Darwin" ] && RC="$HOME/.bash_profile" || RC="$HOME/.bashrc" ;;
      fish) RC="$HOME/.config/fish/config.fish" ;;
      *)    RC="$HOME/.profile" ;;
    esac
    warn "$BIN_DIR is not in your PATH. Run this, then restart your shell:"
    if [ "$SH_NAME" = "fish" ]; then
      echo "      echo 'fish_add_path $BIN_DIR' >> \"$RC\" && source \"$RC\""
    else
      echo "      echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> \"$RC\" && source \"$RC\""
    fi
    ;;
esac

echo ""
printf "  ${BOLD}Done. te / sente / fuseki, ready — まず試すなら:${RESET}\n\n"
printf "  ${DIM}┌──────────────────────────────────────────────┐${RESET}\n"
echo "   ⌨  te                呼べば、動く(キーボードで対話)"
echo "   🎙 sente             話せば、先に動く(声で常時待機)"
echo "   🪨 fuseki [Alpha]    呼ばなくても、布石を打つ(盤面を見張る)"
printf "  ${DIM}├──────────────────────────────────────────────┤${RESET}\n"
echo "    te ima              状況+次の一手をまとめて今すぐ聞く"
echo "    te engine claude    エンジンを切替(claude/codex/opencode)"
echo "    koe \"text\"          自分の声で鳴らす(URLならkoe.live/playで開く)"
echo "    te doctor           セットアップを点検(起動時の忠告の見返しも)"
echo "    te optimize         環境を自動で最適に整える(確認付き・--yes で全自動)"
printf "  ${DIM}└──────────────────────────────────────────────┘${RESET}\n"
echo ""
