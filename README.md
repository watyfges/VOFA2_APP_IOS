# VOFA2 远程调参 · iOS 客户端

按 `spec/客户端开发指南.md` 与 `spec/协议手册.md` 实现的 iOS 客户端：
发现局域网里的 PC 端（UDP 47901），用 WebSocket 连上去，操作 PC 右侧调参栏里**已有**的
滑块、开关、命令按钮和一键发送。

- 纯 Swift + UIKit，无第三方依赖
- 最低 iOS 14.0，arm64，无签名产物可直接丢给 TrollStore
- 工程用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 从 `project.yml` 生成，
  `VOFA2Remote.xcodeproj` 已随仓库提供，不改工程结构时无需重跑

## 目录

```
ios/
├── project.yml                     # XcodeGen 工程定义
├── VOFA2Remote.xcodeproj           # 已生成的工程（可直接打开）
├── spec/                           # 协议手册与客户端开发指南（只读参考）
├── VOFA2Remote/
│   ├── Model/RemoteModels.swift    # 快照/控件/动作/组树模型
│   ├── Model/RemoteMessage.swift   # 协议编解码（入站解析 + 出站组帧）
│   ├── Net/DiscoveryService.swift  # UDP 广播发现（47901）
│   ├── Net/RemoteClient.swift      # WebSocket 控制通道、节流、心跳、重连
│   ├── UI/ServerListViewController.swift
│   ├── UI/TuningViewController.swift
│   ├── UI/OneClickSheet.swift      # 「一键发送数据」面板（勾选/间隔/进度）
│   ├── UI/ControlCells.swift       # 开关/按钮/滑块单元格
│   ├── UI/Theme.swift
│   └── Support/Info.plist          # 本地网络权限、ATS 本地明文
├── VOFA2RemoteTests/               # 协议单测 + 连 mock 的集成测试
├── VOFA2RemoteUITests/             # XCUITest：连接、滑块、开关、一键发送、PIN
├── tools/mock_remote_server.py     # 零依赖 PC 端模拟器（联调/自测用）
└── tools/make_icon.swift           # 生成 App 图标
```

## 构建

```bash
cd ios
# 需要 Xcode 14.3+；若 xcode-select 指向 CommandLineTools，用 DEVELOPER_DIR 指定
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# 模拟器
xcodebuild -project VOFA2Remote.xcodeproj -scheme VOFA2Remote \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 14' build

# 真机 Release（无签名）
xcodebuild -project VOFA2Remote.xcodeproj -scheme VOFA2Remote \
  -configuration Release -sdk iphoneos -derivedDataPath build_device \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
```

改过 `project.yml` 或增删源文件后：

```bash
xcodegen generate     # xcodegen 可用 brew 安装；若只装了 CommandLineTools，
                      # 直接下官方 release 的 xcodegen.zip 解压使用
```

## 打包 IPA（TrollStore）

```bash
APP=build_device/Build/Products/Release-iphoneos/VOFA2Remote.app
mkdir -p /tmp/vofa/Payload && cp -R "$APP" /tmp/vofa/Payload/
(cd /tmp/vofa && zip -qry VOFA2Remote-1.0.0-unsigned.ipa Payload)
```

产物在 `dist/VOFA2Remote-1.0.0-unsigned.ipa`（约 590 KB）。TrollStore 里
「Install IPA File」选它即可，TrollStore 会自己 ldid 签名；不需要 Apple 开发者证书。

## 测试

先起 PC 端模拟器（两路，其中一路带访问码）：

```bash
python3 tools/mock_remote_server.py --port 47900 --name "调试台 A" &
python3 tools/mock_remote_server.py --port 47910 --discovery-port 47911 \
        --name "调试台 PIN" --pin 1234 &
```

```bash
# 协议 + 网络集成（15 项）
xcodebuild -project VOFA2Remote.xcodeproj -scheme VOFA2Remote \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 14' \
  test -only-testing:VOFA2RemoteTests

# UI 自动化（5 项，含 PIN 重输）
xcodebuild ... test -only-testing:VOFA2RemoteUITests
```

集成/UI 测试在连不上 mock 时会 `XCTSkip`，不会误报失败。App 支持启动参数
`-RemoteEndpoint 127.0.0.1:47900 [-RemotePin 1234]` 直连，跳过发现页，方便调试与截图。

## 协议实现要点

| 规则 | 实现 |
| --- | --- |
| 发现：3 次探测、间隔 300 ms，先 255.255.255.255 再各网段定向广播 | `DiscoveryService` |
| 以 offer 的**来源 IP** + `port` 为准，不写死 47900 | `DiscoveryService` / `ServerOffer` |
| 同一 `(IP, port)` 去重 | 2 秒窗口内合并，键为 `host:port` |
| 握手后立刻发 `hello`（5 s 时限），带 `clientId`/`name`/`pin` | `RemoteClient.openSocket` |
| 2 秒没收到 `state` 主动发 `sync` | 定时兜底 |
| 拖动节流 33 ms/控件（≈30 次/秒），松手必发 `commit` | `RemoteClient.sendValue` 合并 + `commit` |
| 数值框输入用 `commit + exact:true`（允许超范围） | `ControlCell.fieldEditingEnded` |
| 开关设目标状态而非翻转，先乐观更新再以回声为准 | `setSwitch` / `applyAction` |
| 按钮 300 ms 防抖，收到 `flash` 做点击动效 | `CommandButtonCell` |
| 自己写入的回声不打断正在拖的滑块 | `ControlCell.applyEcho` + `isDragging` |
| 一键发送 | 点按钮弹出「一键发送数据」面板：勾选滑块、全选/全不选、改间隔、看进度、可取消（`OneClickSheet`） |
| 一键发送的两条路径 | 选中项 == PC 勾选的 `inc` 集合时走服务端 `oneclick`（互斥、PC 也显示进度）；否则按勾选逐条 `commit` | `startOneClick` |
| `busy` / `empty_plan` / `unknown_*` / `bad_value` 提示与刷新 | `handleServerError` |
| 45 s 静默判定掉线，20 s 主动 `ping` | watchdog + heartbeat |
| 重连退避 1 s→2 s→5 s，最多 5 次；4001 不自动重连 | `scheduleReconnect` |
| 4003 访问码错误 → 弹窗重输后重连 | `promptForPin` |
| `conn.connected=false` 顶部提示「PC 未连接板子」 | `updateStatusUI` |
| 多端来源 `from` 提示「PC 正在调整 / 另一台手机正在调整」 | `applyValue` |
| 组名按 `/` 分层，界面按完整路径展示并精确匹配 | `GroupNode` / 组切换条 |

## 已知限制

- 只做局域网直连，没有 TLS、账号体系、公网穿透（与协议一致）。
- 组切换用横向标签条展示完整路径（如 `底盘/PID`），没有做树形下拉。
- **勾选不落盘**：协议里没有改 `controls[].inc` 的消息，所以面板里的勾选只对本次发送有效，
  PC 的「参与一键发送数据」仍是默认值。想让某项长期参与，请到 PC 的命令编辑里勾选
  （滑块行上的「一键」标签是 PC 当前勾选状态的只读提示）。
- 勾选与 PC 计划不一致时走本地逐条 `commit`：下发效果与 PC 一键发送一致（同一套下发函数），
  但 PC 端不显示这次进度，也不占用服务端的「一键发送互斥」。
- iOS 的 WebSocket 由系统库负责回 pong；仍保留 20 s 应用层 `ping` 作为双保险。
- 首次启动会弹「本地网络」权限，拒绝后只能手动输入 IP 且连接会失败，需到系统设置里重新打开。
