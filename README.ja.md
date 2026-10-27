# claude-preheat

[English](README.md) | [简体中文](README.zh-CN.md) | **日本語** | [한국어](README.ko.md)

https://github.com/user-attachments/assets/b0614c1a-fe78-4464-a11e-aaeb1794829e

Windows または macOS で Claude Code CLI を使う Claude サブスクリプションユーザー向けのツールです。5 時間の利用枠ウィンドウは、枠が空いている状態で送られた最初のメッセージにアンカーされます — スケジュールした極小のピングであなたの選んだ時刻にウィンドウをアンカーし、本番の作業を 2 つの 5 時間ウィンドウにまたがらせます。できること:

1. 週単位の定期予熱
2. 単発の予熱
3. **Codex（beta）**: 同じ予熱を OpenAI Codex にも使えます。[Codex (beta)](#codex-beta) 参照

## Web パネル

ローカルアドレス: `localhost:7878`(英語/中国語のバイリンガル、ヘッダーでワンクリック切替)

モジュール: リアルタイム利用枠バー(5 時間 + 週次、正確なリセット時刻付き — `preheat statusline on` を一度実行すると値が流れます)/ 週次リセット時刻エディタ(`schedule.json` に書き込んで適用)/ 単発予熱 / 直近 7 日のウィンドウ利用率ライン(内部は `preheat learn`) / ページ上部で Claude | Codex を切り替え（Codex は beta）

![panel](docs/panel.png)

## クイックスタート

**動作要件**: Windows 10/11 または macOS 13+（macOS は [macOS ガイド](docs/MAC-BETA.md) 参照）、[Claude Code CLI](https://code.claude.com/docs) インストール&ログイン済み、Claude サブスクリプション、PowerShell 7 (pwsh)、管理者権限は不要。Codex（beta）だけを予熱するなら Claude Code と Claude サブスクリプションは不要、[Codex (beta)](#codex-beta) 参照

**推奨: 以下を Claude Code(または他の AI コーディングツール)に貼り付けて、インストールを任せてください:**

```text
https://github.com/MagicYangG/claude-preheat をクローンしてセットアップして:
1. git clone 後、リポジトリのディレクトリ内で install.ps1 を実行
2. 毎週ウィンドウをリセットしたい時刻を私に聞いて、schedule.json に書き込む
   (reset にはリセット目標時刻を書く。予熱時刻は自動で reset − 5 時間)
3. ./test.ps1 を実行し、全ケースの成功を確認
4. preheat apply を実行し、preheat status の出力を見せて
install.ps1 と preheat apply が作るもの以外、何も登録・変更しないこと。
```

終わったらブラウザで `http://localhost:7878` を開き、あとはパネルから操作できます。

**手動インストールは 3 ステップ**: `git clone` → `./install.ps1` → 新しいターミナルで `preheat apply`。コマンド一覧は[コマンドリファレンス](#コマンドリファレンス)へ。

## 注意事項

1. **Claude Code CLI が必要**（Codex だけなら不要）: 予熱は CLI 経由で実行される極小のヘッドレスプロンプトです
2. **ピング 1 回のコスト**: 短い `haiku` プロンプト 1 回分 — Claude Code 自身のシステムプロンプトを含めるとおよそ 4 万 input トークン（API 料金で約 $0.04）。5 時間ウィンドウと週次ウィンドウの両方にカウントされるため、予熱は安いが無料ではありません。稼働中のウィンドウへのピングでアンカーは動きません。スケジュールされた予熱が稼働中のウィンドウに当たった場合、そのウィンドウが切れる分にフォローアップのピングを 1 回だけ予約します（その日は 2 回のピングになります）。ウィンドウごとに最大 1 回で、次のスケジュール予熱が先に来る場合は予約しません。`schedule.json` に `"chase": false` を書くと無効化できます。パネルにある、自分で作っていないワンショットはこのフォローアップです。週次ウィンドウはこのツールの管理対象外です。
3. **スリープからの復帰**: スケジュールした予熱が PC を起こせるのは、有効な電源プランでスリープ解除タイマーが有効な場合だけです — 無効なときは `preheat status` が警告します（これは Windows の仕組みです。launchd はスリープ中の Mac を起こせません — [macOS ガイド](docs/MAC-BETA.md) 参照）。フォローアップのピングはスリープ中の PC を起こしません。その分にスリープしていればスキップされます。
4. **ウィンドウはアカウント単位**: claude.ai・Claude デスクトップ・Claude Code の利用量は同じプールを共有するため、予熱はどのサーフェスのウィンドウにも効きます — CLI は点火針にすぎません
5. **予熱が動く時・動かない時（Windows）**: タスクはサインイン中のみ実行されます（ロック画面は問題ありませんが、サインアウト状態だとその予熱はスキップされます）。バッテリー駆動時も実行されるようになりました。この変更より前にインストール済みの場合は、`preheat apply` をもう一度実行して新しい設定を反映させてください。
6. **`preheat apply` 後にリポジトリのディレクトリを移動・リネームしない**: 登録済みタスク、launchd の plist、プロファイル内の関数はすべて絶対パスを保持しています。移動した場合は `install.ps1` と `preheat apply` を再実行してください — `preheat status` がスクリプトパスが存在しないタスクを警告します。

## Codex (beta)

Codex 対応は現在 beta です。同じ `schedule.json`・パネル・スケジュールタスクで OpenAI Codex の 5 時間ウィンドウも予熱できます。両者はそれぞれ別にスケジュールされ、互いに影響しません。ベータテストの手順と証拠の送り方は [Codex beta ガイド](docs/CODEX-BETA.md) を参照してください。

**要件**: [Codex CLI](https://learn.chatgpt.com/docs/codex/cli) または Codex デスクトップアプリをインストールし、ChatGPT アカウントでサインイン済みであること（API キーでのサインインには 5 時間ウィンドウがないため、ピングしません）。Plus など 5 時間ウィンドウのあるプランで使えます。Free / Go / Pro は 5 時間ウィンドウを読み取れないときスキップし、利用枠を消費しません（Go は実機の確認では 30 日ウィンドウのみ）。それ以外のプランで読み取れない場合はそのままピングし、利用枠を消費します。Codex だけを予熱するなら Claude Code と Claude サブスクリプションは不要です。

**有効化**: AI コーディングツールに任せるのが手軽です（「Codex の予熱を平日 15:00 リセットに設定して」と伝えるだけ）。パネルなら、ページ上部で Codex タブに切り替え、時刻を選んで適用します（Codex 側だけが変わります）。手で編集する場合は、リポジトリのディレクトリにある `schedule.json`（install.ps1 が作成）に `codex` キーを追加します。既存の `rules`・`proxy` と同じ階層に置き、直前の項目の末尾にカンマを付けてください（予熱時刻は同じく reset − 5h）:

```json
"codex": { "rules": [ { "days": ["Mon", "Tue", "Wed", "Thu", "Fri"], "reset": "15:00" } ], "chase": true }
```
その後 `preheat apply -Provider codex` を実行します。Codex だけを使う場合は、トップレベルの `rules` を `[]` にするか、常に `-Provider codex` を付けてください。そうしないと通常の `preheat apply` が claude を探し、見つからなければエラーになります。

**確認**: `preheat status -Codex` を実行します（読み取りのみで利用枠は消費しません）。プラン、5 時間ウィンドウ、登録済みの `ClaudePreheat-Codex-*` タスクが表示されれば OK です。すぐ試すなら `preheat +2m -Codex`。

**予熱のたびに**（ピングを送るかもしれない予定時刻）:
1. まず無料で利用枠を読みます。ウィンドウが稼働中ならピングせず、それが切れて約 2 分後にフォローアップ予熱を 1 回だけ予約します（`chase` と同じルール）
2. ウィンドウが空いているときだけ極小のピングを送ります。利用枠の読み取り自体が失敗した場合（ネットワーク・プロキシ・タイムアウト）もピングします
3. 2 回続けてピングしてもウィンドウが始まらなかった場合、以降の予熱はピングを止めて 1 回だけ通知します。`preheat apply` をもう一度実行するまで止まったままです

**コスト**: Codex のピングは毎回実際の利用枠を消費し、5 時間枠と週次枠の両方にカウントされます。無料なのは利用枠の読み取りだけです。

**注意**:
1. デスクトップアプリだけでも動きます: 予熱のたびに codex 実行ファイルを探し直します。見つからない場合、Windows ではユーザー環境変数 `PREHEAT_CODEX_EXE` にそのフルパスを設定し、macOS では `preheat apply` を実行するターミナルの PATH に codex のフォルダを追加してください
2. `CODEX_HOME` を変更している場合は、それが設定されたターミナルで `preheat apply` を 1 回実行すると `codex.home` に保存されます。`proxy` は両者で共用です。両方スケジュールしていると、Windows は一晩に 2 回 PC を起こすことがあります
3. やめるとき: `preheat off -Codex` は Codex のタスクだけを削除しますが、`codex` セクションが残っていると次の通常の `preheat apply` で再登録されます。完全にオフにするには `codex` セクションを削除してください（セクションなし = Codex オフ）

## relay はどこへ行った?

v0.2.0 にはウィンドウ跨ぎの自動再開(「relay」)が入っていました。Claude Code v2.1.234 から CLI が制限リセット時の自動継続を標準搭載した(デフォルトで有効、`/config` の「Continue automatically at usage limit」)ため、v0.3.0 で relay を引退させました。relay 入りの最後のリリースはタグ [v0.2.0](https://github.com/MagicYangG/claude-preheat/releases/tag/v0.2.0) に残してあります。ネイティブ機能がやらないこと — 席に着く前にウィンドウを開始すること — こそが preheat の仕事です。

## コマンドリファレンス

普段使いはパネルで足ります。以下はターミナル派とスクリプト向けです。

```powershell
preheat apply           # schedule.json から毎週の予熱タスクを登録(編集後に再実行で反映)
preheat status          # ローカル活動 + 登録タスク + 直近ログ
preheat reset 20:00     # 単発: ウィンドウを 20:00 にリセットさせる(15:00 に予熱)
preheat at 15:00        # 単発: 15:00 に予熱
preheat +2h             # 単発: 2 時間後に予熱
preheat learn           # 直近 30 日のリズムから予熱時刻を提案 + 窓利用率レポート(learn auto で適用)
                         # (集計対象は自分が送ったプロンプトの自然なリズムのみ。preheat のピングはカウントされません)
preheat statusline on   # statusline を透過タップし、正確なリセット時刻をパネルの利用枠バーへ(off で復元)
preheat off             # 予熱タスクを全削除
preheat status -Codex   # Codex の利用枠をその場で読む: アカウント・プラン・5 時間/週次ウィンドウ・リセット時刻が後ろにずれたか・直近の予熱
preheat report -Codex   # マスク済みの Codex 予熱の証拠を出力（issue に貼る用）
preheat apply -Provider codex  # Codex 側だけ登録（指定なし = 両方）
preheat at 10:00 -Codex # 単発の Codex 予熱。reset / +2h にも -Codex を付けられます
preheat off -Codex      # Codex の予熱タスクだけ削除（-Codex なし = 両方削除）
claude-panel            # ローカル Web パネルを開く
```

`schedule.json` の `reset` は**リセット目標時刻**。予熱時刻は自動で reset − 5h。`proxy` が空ならプロキシなし。

## アンインストール

```powershell
preheat off             # 予熱タスクを全削除
preheat statusline off  # 元の statusline を復元(タップを有効にしていた場合)
```

その後、PowerShell プロファイルの `# >>> claude-preheat functions >>>` から
`# <<< claude-preheat functions <<<` までの行を削除し(古いインストールでは
`claude-limit-relay` のマーカーになっている場合があります)、リポジトリのディレクトリを削除してください。

Codex の実行時ファイル（`state-ratelimits-codex.json`・`firepit-codex/`・`.fire-codex.lock`）はすべてリポジトリのディレクトリ内にあり、ディレクトリと一緒に消えます。`PREHEAT_CODEX_EXE` を設定していた場合はそれも削除してください。preheat は Codex 自身のサインインには触れません。
