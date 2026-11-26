---
title: 安裝 Mac 版與第一次開啟
description: 下載 OM Photos Mac 版、拖到「應用程式」，以及第一次開啟時如何在「隱私權與安全性」允許打開。
group: start
order: 1
---

OM Photos 是免費的 Mac App，用來把 OM System／Olympus 相機裡的照片和影片匯入電腦。這篇帶你完成安裝和第一次開啟。

## 需要什麼

- 一台 Mac，系統是 **macOS 27 或更新版本**（Apple 晶片和 Intel 都可以）。
- 一台有 Wi-Fi 或 USB-C 的 OM System／Olympus 相機。目前只在 **OM-3** 上實測過，其他支援「OI.Share／OM Image Share」的機型理論上也能用。

## 1. 下載並安裝

1. 到[下載頁](/download/)按「下載 Mac 版」，會得到 `OM-Photos.dmg`。
2. 打開 DMG，把 **OM Photos** 拖到旁邊的「應用程式」資料夾。
3. 退出 DMG。

## 2. 第一次開啟

這個版本沒有 Apple 開發者簽章，所以第一次打開時，macOS 會說「無法打開」或「無法驗證開發者」。這是正常的，照下面做一次就好：

1. 在「應用程式」裡雙擊 OM Photos，看到警告時按「完成」或「取消」。
2. 打開「系統設定 › 隱私權與安全性」，往下捲到「安全性」。
3. 會看到「已阻擋 OM Photos 以保護你的 Mac」，按旁邊的 **強制打開**，再輸入密碼或用 Touch ID 確認。

之後就能像一般 App 一樣直接打開。

## 3. 會詢問的權限

| 權限 | 什麼時候問 | 用途 |
|---|---|---|
| 相機 | 第一次掃描 QR code | 用 Mac 的鏡頭讀相機螢幕上的 QR code |
| 定位服務 | 第一次自動切換 Wi-Fi | macOS 規定要有定位權限才能讀 Wi-Fi 名稱；OM Photos 不會記錄你的位置 |

拒絕也沒關係：QR code 可以改用手動輸入，Wi-Fi 可以自己從選單列切換。

## 下一步

- 用 Wi-Fi：[配對相機與 Wi-Fi 連線](/guide/pair-wifi/)
- 用線：[用 USB-C 連接相機](/guide/usb/)
