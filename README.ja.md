# capsled

日本語 | [English](README.md)

`capsled`は、物理Caps Lock LEDを処理中インジケーターとして使う実験的な
macOS CLIです。論理的なCaps Lock状態は変更しないため、物理Caps Lockキーを
Controlへ割り当てている環境でも利用できます。

## 必要環境

- macOS 14以降
- macOSのHIDイベントシステムからCaps Lock LEDを操作できるキーボード
- root権限、アクセシビリティ権限は不要
- 入力監視権限が必要なのは実験的な`watch`だけ。`on`、`off`、`auto`、`run`には不要

## インストール

### Homebrew

Homebrewをすでに使っている場合：

```sh
brew install Sol-momma/tap/capsled
```

SwiftやXcodeを依存関係として追加せず、更新・削除をHomebrewで管理できます。

### 最小容量

容量を最小にしたい場合、またはHomebrew未導入の場合は、単体インストーラが
おすすめです。最新のUniversal Binary（Apple Silicon＋Intel）を取得し、
SHA-256を検証して`~/.local/bin`へ配置したあと、一時ファイルを削除します。
残るのは約289KiBの実行ファイルだけです。

```sh
curl -fsSL https://raw.githubusercontent.com/Sol-momma/capsled/main/install.sh | sh
```

システム共通または任意の場所へ入れる場合は、先に`install.sh`の内容を確認し、
配置先を指定してください。

```sh
CAPSLED_INSTALL_DIR=/usr/local/bin sh install.sh
```

配置先が`PATH`に含まれていることを確認してください。macOS標準のzshでは、
次を一度実行してから新しいターミナルを開きます。

```sh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zshrc"
```

`/usr/local/bin`などシステム側の場所への配置には、管理者権限が必要な場合が
あります。`capsled`自体の実行にはroot権限は不要です。

## 使い方

```sh
capsled on
capsled off
capsled auto
capsled run -- npm test
capsled watch
```

- `on`と`off`はLEDへ1回だけ書き込みます。その後macOSに上書きされる場合があります。
- `auto`はLED制御をmacOSへ戻します。
- `run`は子コマンドの実行中に点灯を維持し、macOSによる`Off`上書きを修復して、
  終了後に`auto`へ戻します。
- `watch`は最初の物理Caps Lock押下まで現在のLED状態を維持し、押すたびにLEDを
  切り替え、終了時に`auto`へ戻します。raw HIDのCaps Lock usageを読むため、
  Caps LockをControlへ変更した環境でも、対応ハードウェアでは物理Controlと
  区別できます。キー入力の変更・遮断は行いません。raw検出は実験段階です。

例：

```sh
capsled run -- sleep 30
```

ラップしたコマンドの終了コードは維持されます。

実験的な監視を使う場合はフォアグラウンドで実行し、Control-Cで終了します。

```sh
capsled watch
```

初回はmacOSが入力監視権限を求める場合があります。**システム設定 >
プライバシーとセキュリティ > 入力監視**で実行ファイルを許可してから、コマンドを
再実行してください。Caps Lockの入力値だけを非exclusiveで受け取りますが、権限は
必要です。

## 更新・アンインストール

Homebrewの場合：

```sh
brew upgrade Sol-momma/tap/capsled
capsled auto
brew uninstall Sol-momma/tap/capsled
```

単体インストーラの場合は、再実行すると更新できます。削除前にLEDを自動制御へ
戻してください。

```sh
capsled auto
rm "$HOME/.local/bin/capsled" # 任意の配置先を使った場合は、そのパスへ変更します。
```

## 互換性

| 環境 | キーボード | 結果 |
| --- | --- | --- |
| Apple Silicon、macOS 26.5.1 | 内蔵、Caps LockをControlへ変更 | 実機確認済み |
| Intel Mac | 内蔵 | Universal Binary生成済み、実機未確認 |
| 外付けキーボード | 機種依存 | 未確認 |

内蔵キーボードを識別できない場合は、すべてのキーボードサービスを対象にします。
そのため、外付けキーボードのLEDも点灯する可能性があります。

表はLED制御についての結果です。`watch`が使うraw物理キー検出は実験段階で、表の
各環境を横断した実機確認はまだ行っていません。

## 重要な制限

- Apple IOHIDFamily実装の非公開`HIDCapsLockLED`プロパティを使用します。将来の
  macOSで動作しなくなる可能性があります。
- `run`と`watch`の点灯中は10msごとに実際のLED状態を確認します。macOSによる
  上書きから再点灯まで、ごく短時間だけ消灯する可能性があります。
- SIGKILL、クラッシュ、電源断では`run`と`watch`は`auto`へ戻せません。その場合は
  `capsled auto`を実行してください。
- 配布バイナリはad-hoc署名済みですが、Developer ID署名・公証は未実施です。
  取得方法によってはmacOSが警告を表示する可能性があります。

## ソースからビルド

Swift 6が必要です。

```sh
swift build -c release
.build/release/capsled --help
```

Universal Binaryの生成と梱包：

```sh
scripts/build-release.sh
```

ハードウェアへ触れないパーサ確認：

```sh
swiftc Sources/CapsLEDCore/Command.swift Checks/CommandParserCheck.swift \
  -o .build/capsled-parser-check
.build/capsled-parser-check
```

`watch`のライフサイクル確認も、キーボードとLEDのfakeを使うため実機には触れません。

```sh
swiftc Sources/CapsLEDCore/*.swift Checks/WatchBehaviorCheck.swift \
  -o .build/capsled-watch-behavior-check
.build/capsled-watch-behavior-check
```

脆弱性の報告方法は[SECURITY.md](SECURITY.md)を参照してください。Issueと
Pull Requestによる貢献を歓迎します。

## ライセンス

[MIT](LICENSE)
