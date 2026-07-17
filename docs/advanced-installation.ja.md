# 高度なインストール方法

日本語 | [English](advanced-installation.md)

メインの[README](../README.ja.md)では、CLIのHomebrew導入とビルド済みメニューバー
アプリの2つを推奨しています。このページは、Homebrewを使わずCLIを導入する場合や、
未リリースのソースを試す場合の手順です。

## 単体CLIインストーラ

単体インストーラは最新のUniversal Binaryを取得し、SHA-256を検証して
`~/.local/bin`へ配置したあと、一時ファイルを削除します。

先に[`install.sh`](../install.sh)を確認してから実行してください。

```sh
curl -fsSL https://raw.githubusercontent.com/Sol-momma/capsled/main/install.sh | sh
```

配置先を`PATH`へ追加します。macOS標準のzshでは、次を一度実行してください。

```sh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zshrc"
```

`PATH`の変更後は新しいターミナルを開きます。

別の場所へ配置する場合は、スクリプトを取得・確認します。

```sh
curl -fsSL https://raw.githubusercontent.com/Sol-momma/capsled/main/install.sh \
  -o install.sh
less install.sh
```

確認後、実行時に`CAPSLED_INSTALL_DIR`を指定します。

```sh
CAPSLED_INSTALL_DIR=/usr/local/bin sh install.sh
```

`/usr/local/bin`などへの配置には管理者権限が必要な場合があります。capsled自体の
実行にroot権限は必要ありません。

更新するときは単体インストーラを再実行します。削除するときは次を実行します。

```sh
capsled auto
rm "$HOME/.local/bin/capsled"
```

配置先を変更した場合は、そのパスに置き換えてください。

## 未リリース版をビルドする

GitとSwift 6が必要です。リポジトリを取得してCLIだけをビルドし、生成した実行ファイルを
直接起動します。

```sh
git clone https://github.com/Sol-momma/capsled.git
cd capsled
swift build -c release --product capsled
.build/release/capsled watch
```

ソースコードを変更する場合や、メニューバー版・配布物を生成する場合は
[CONTRIBUTING.md](../CONTRIBUTING.md)を参照してください。
