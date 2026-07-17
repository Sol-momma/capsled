# capsled

日本語 | [English](README.md)

`capsled`は、論理的なCaps Lock状態を変更せず、物理Caps Lock LEDを再利用できる
macOS用ツールです。物理Caps LockキーをControlへ割り当てつつ、LEDも活用したい
場合に使えます。

## すぐ使う

やりたい操作に合わせて、まず次の2つから選びます。

### 1. 物理Caps LockキーでLEDを切り替える

HomebrewでCLIをインストールし、監視を開始します。

```sh
brew install Sol-momma/tap/capsled
capsled watch
```

物理Caps Lockキーを押すたびにLEDが切り替わります。終了するときはControl-Cを
押してください。終了時にLED制御をmacOSへ戻します。

初回は`capsled`の**システム設定 > プライバシーとセキュリティ > 入力監視**を
許可し、`capsled watch`を再実行してください。物理キーをraw入力として監視しますが、
キー入力の変更や遮断は行いません。

### 2. メニューバーからLEDを操作する

[最新リリース](https://github.com/Sol-momma/capsled/releases/latest)から
`capsled-menu-bar-macos-universal.zip`を取得・展開し、`CapsLED.app`を
「アプリケーション」へ移動します。メニューバーのCaps Lockアイコンから
**LEDを点灯し続ける**、**LEDを消灯する**、**macOSへ制御を戻す**を選べます。

現在はad-hoc署名のみで、Developer ID署名・公証は未実施です。初回は
`CapsLED.app`をControl＋クリックして**開く**を選び、確認画面でも**開く**を
押してください。

この手順にはcapsled v0.2.0以降が必要です。既存のHomebrew版で`watch`が認識されない
場合は更新してください。

```sh
brew update
brew upgrade Sol-momma/tap/capsled
```

## 必要環境

- macOS 14以降
- macOSのHIDイベントシステムからCaps Lock LEDを操作できるキーボード
- root権限、アクセシビリティ権限は不要
- 入力監視権限が必要なのは`watch`のみ。その他のコマンドとメニューバー操作には不要

## その他のCLIコマンド

通常は`watch`から始めます。残りのコマンドは、LEDの固定や処理中表示に使います。

| コマンド | 用途 |
| --- | --- |
| `capsled on` | バックグラウンドでLEDの点灯を維持します。 |
| `capsled off` | 点灯維持を止め、LEDを一度消灯します。 |
| `capsled auto` | capsledによる制御を止め、LEDをmacOSへ戻します。 |
| `capsled run -- <コマンド>` | コマンド実行中だけLEDを点灯し、終了後にmacOSへ戻します。 |

例：

```sh
capsled run -- npm test
```

実行したコマンドの終了コードは維持されます。`on`、`run`、`watch`は互いに置き換わり、
終了後に以前のモードを復元しません。

## 困ったとき

- **`watch`が権限を求める：** **システム設定 > プライバシーとセキュリティ >
  入力監視**で`capsled`を許可し、再実行してください。
- **クラッシュや電源断のあともLEDが固定されている：** `capsled auto`を実行します。
- **`watch`が認識されない：** 「すぐ使う」にあるHomebrewの更新コマンドを実行し、
  `capsled --help`に`watch`が表示されることを確認します。
- **CapsLED.appを開けない：** 初回だけアプリをControl＋クリックして**開く**を選びます。

## 更新・削除

Homebrew版：

```sh
brew upgrade Sol-momma/tap/capsled
capsled auto
brew uninstall Sol-momma/tap/capsled
```

メニューバー版は**macOSへ制御を戻す**を選び、CapsLEDを終了してから
「アプリケーション」の`CapsLED.app`を削除します。

Homebrewを使わずCLIを導入する場合は、[高度なインストール方法](docs/advanced-installation.ja.md)
を参照してください。

## 対応環境と制限

| 環境 | キーボード | 結果 |
| --- | --- | --- |
| Apple Silicon、macOS 26.5.1 | 内蔵、Caps LockをControlへ変更 | LED制御とraw `watch`切替を実機確認済み |
| Intel Mac | 内蔵 | Universal Binary生成済み、実機未確認 |
| 外付けキーボード | 機種依存 | 未確認 |

- `watch`が使うraw物理キー検出は実験段階で、上記Apple Siliconの内蔵キーボードだけで
  実機確認済みです。
- 内蔵キーボードを識別できない場合は、すべてのキーボードサービスを対象にします。
  外付けキーボードのLEDも点灯する可能性があります。
- Apple IOHIDFamily実装の非公開`HIDCapsLockLED`プロパティを使用します。将来のmacOSで
  動作しなくなる可能性があります。
- `on`、`run`、`watch`の点灯中は10msごとに実際のLED状態を確認します。macOSによる
  上書きから再点灯まで、ごく短時間だけ消灯する可能性があります。
- SIGKILL、クラッシュ、電源断では自動復旧できない場合があります。その場合は
  `capsled auto`を実行してください。
- メニューの状態欄はアプリで最後に完了した操作を表示します。その後のCLI操作は
  常時同期されません。
- 配布バイナリはad-hoc署名済みですが、Developer ID署名・公証は未実施です。

## 開発に参加する

ビルド方法とハードウェアに触れない確認手順は[CONTRIBUTING.md](CONTRIBUTING.md)にあります。
脆弱性の報告方法は[SECURITY.md](SECURITY.md)を参照してください。IssueとPull Requestを
歓迎します。

## ライセンス

[MIT](LICENSE)
