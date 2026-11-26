<p align="center">
  <img src="Brand/lockup-stacked-black.png" width="360" alt="OM Drop">
</p>

# OM Drop

把 OM System / Olympus 相機的照片和影片快速匯入 **Mac、iPhone、iPad**。

- **一次配對**：掃描相機螢幕上的 QR code，之後一鍵連線（Mac 會自動切換到相機 Wi-Fi，用完切回原本的網路）。
- **Wi-Fi 或 USB-C**：插上 USB 線自動偵測相機（MTP 模式），或掛載記憶卡（儲存模式）。USB 在 Mac 上實測約 35–44 MB/s，比相機 Wi-Fi（約 3 MB/s）快 10 倍以上。
- **像「照片」App 一樣瀏覽**：依日期分組，RAW+JPG 合成一張，可依照片、RAW、影片、是否已匯入篩選，點開看大圖。
- **聰明匯入**：匯入過的不會重複抓，檔案搬走也一樣。Mac 每次匯入前選擇資料夾；iPhone、iPad 存進照片圖庫。
- **刪除**：確認後刪除相機記憶卡上的檔案，沒匯入的會先提醒。

> 非官方工具，與 OM Digital Solutions 無關。只在 OM-3 上測試過。

## 系統需求

- macOS 27、iOS 27、iPadOS 27
- Xcode 27、[XcodeGen](https://github.com/yonaskolb/XcodeGen)

## 建置

```bash
xcodegen generate
open OMDrop.xcodeproj
```

在 `project.yml` 把 `DEVELOPMENT_TEAM` 換成你自己的 Team ID。

iPhone、iPad 自動切換 Wi-Fi 需要付費開發者帳號的 Hotspot Configuration 權限；免費帳號會改成引導你到「設定」手動切換。啟用方式見 `project.yml` 的註解。

## 專案結構

| 路徑 | 內容 |
|---|---|
| `Packages/OMKit` | 共用程式庫：相機 HTTP 指令、QR 配對、Wi-Fi／USB 來源、縮圖快取、匯入、刪除（含自動測試） |
| `App/Shared` | SwiftUI 介面（Mac、iPhone、iPad 共用） |
| `App/macOS`、`App/iOS` | 各平台的 Wi-Fi 切換、QR 掃描、USB 偵測 |
| `Brand` | 品牌識別（CIS）：標誌、色彩、字體、App 圖示 |
| `tools` | USB 測速工具、品牌素材產生腳本 |
| `SPEC.md` | 規格書與實測紀錄 |

```bash
cd Packages/OMKit && swift test
```

## 相機協定

透過相機自己的 Wi-Fi（`192.168.0.10`）使用 OI.Share 的 HTTP 指令，參考了這些開源專案的研究：
[olympus-wifi](https://github.com/joergmlpts/olympus-wifi)、
[olympus-view-and-delete](https://github.com/dpolarov/olympus-view-and-delete)、
[om-tether](https://github.com/n0p/om-tether)。
