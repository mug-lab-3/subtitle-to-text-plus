# Subtitle to Text+

DaVinci Resolve の字幕データを Text+ クリップに変換し、ビデオトラックへ配置するスクリプトです。

## 機能

- 🔄 **クリップ変換**: 字幕クリップを1つずつ Text+ クリップに変換します。
- ⏱️ **タイミングの維持**: 字幕の開始時刻と長さを正確に反映します。
- 📍 **マーカーによる指定**: マーカー名を使用して、対象トラックと使用するテンプレートを指定可能です。
- ♻️ **再配置機能**: 配置済みの Text+ を削除してから再配置するため、修正後のやり直しが容易です。

## インストール

[subtitle-to-text-plus.lua](https://raw.githubusercontent.com/mug-lab-3/subtitle-to-text-plus/main/subtitle-to-text-plus.lua) を右クリックして「名前を付けてリンク先を保存」を選択し、以下のディレクトリに配置してください。

- **Windows**:
  ```text
  %AppData%\Blackmagic Design\DaVinci Resolve\Support\Fusion\Scripts\Comp
  ```
- **macOS**:
  ```text
  /Users/[ユーザー名]/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Comp
  ```

配置後、メニューの [Workspace] -> [Scripts] -> [Comp] から実行可能になります。

## 使い方

1. **トラック名の設定**: 変換したいビデオトラックと字幕トラックの名前に `::` を付けます（例: `::Main`）。
2. **マーカーの配置**: 変換範囲のタイムライン（または特定のトラック）に、形式 `::[トラック名]-[テンプレート名]` の名前でマーカーを置きます。
3. **テンプレートの用意**: メディアプールに、上記で指定した名前の Text+ クリップを配置します。
4. **実行**: スクリプトを実行すると、字幕が Text+ に変換されます。

## 補足
- 実行ログはコンソールから確認できます。
- 詳細なデバッグが必要な場合は、スクリプト内の `Config.DEBUG` を `true` に変更してください。

## ライセンス
[LICENSE](LICENSE) ファイルを参照してください。
