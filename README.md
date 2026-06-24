<div align="center">
  <img src="Resources/AppIcon.png" width="120" height="120" alt="Lyriam logo">

  # Lyriam

  **Apple Music 同步歌词浮窗** — macOS 菜单栏应用

  ![macOS](https://img.shields.io/badge/macOS-14.0+-blue)
  ![Swift](https://img.shields.io/badge/Swift-5.9+-orange)
  ![License](https://img.shields.io/badge/License-MIT-green)
</div>


## 特性

### 核心功能
- **实时同步歌词** — 从网易云音乐 API 获取 LRC 格式歌词，精确同步当前播放位置
- **灵动岛浮窗** — 模拟 Apple Dynamic Island 风格，浮于屏幕顶部菜单栏区域
- **两种布局模式**
  - *靠左 · 不遮挡右侧 App* — 宽左翼展示歌词，右侧留给系统图标
  - *摄像头居中 · 对称* — 紧凑设计，左右两翼围绕摄像头刘海，歌词居中显示
- **展开卡片** — 悬停灵动岛展开完整播放器界面，显示封面、歌名、艺术家、进度条、播放控制、同步歌词面板
- **自定义外观**
  - 字体选择（系统字体或已安装字体族）
  - 字号调整（12-32pt）
  - 滚动速度控制（10-80 pt/s）
  - 颜色模式（跟随封面主题色 / 自定义色）
- **菜单栏集成** — 纯菜单栏应用（无 Dock 图标），⌘, 快捷键打开设置
- **全屏自动隐藏** — 进入全屏应用或网页视频全屏时自动隐藏浮窗，退出后恢复
- **智能滚动** — 长句歌词自动横向滚动，暂停播放时停止滚动，切换到下一句时重置位置

## 安装

### 从 .dmg 安装
1. 下载最新的 `Lyriam.dmg`
2. 打开 DMG，拖动 `Lyriam.app` 到 **应用程序** 文件夹
3. 首次启动时，macOS 会要求允许 Apple Events 访问权限（用于读取 Music.app）
4. 点击菜单栏的音乐符号图标，选择**设置**或按 **⌘,** 配置选项

### 从源码编译
```bash
git clone https://github.com/yourusername/Lyriam.git
cd Lyriam
./build.sh
open build/Lyriam.app
```

**要求:**
- macOS 14.0 或更新版本
- Swift 5.9+ (通常预装于 Xcode)
- 命令行工具: `xcode-select --install`

## 使用

### 基础操作
1. **打开应用** — 双击 Lyriam.app（或从应用程序文件夹启动）
2. **启动 Apple Music** — 播放歌曲
3. **查看歌词** — 灵动岛会显示当前歌词，随着音乐进度实时更新
4. **展开卡片** — 将鼠标悬停在灵动岛上展开完整播放器
5. **固定浮窗** — 点击展开卡片右上角的图钉按钮固定浮窗（不会因鼠标移开而折叠）
6. **打开设置** — 按 **⌘,** 或点击展开卡片的齿轮⚙️按钮

## 开发

### 项目结构
```
Lyriam/
├── Sources/
│   ├── App/                    # 应用入口、菜单栏、全局热键
│   ├── Settings/               # 配置模型和持久化存储
│   ├── NowPlaying/             # Music.app 播放信息监听
│   ├── Lyrics/                 # 网易云 API、LRC 解析、缓存
│   └── UI/                     # SwiftUI 界面组件
│       ├── Notch/              # 浮窗、灵动岛布局
│       └── Settings/           # 设置界面
├── Resources/                  # 应用图标
├── Info.plist                  # 应用配置
├── build.sh                    # 编译脚本
└── README.md                   # 本文件
```

### 编译和开发
```bash
# 编译
./build.sh

# 启动（开发调试）
open build/Lyriam.app

# 安装到应用程序文件夹
cp -R build/Lyriam.app /Applications/
```

### 依赖
- **Foundation** — 网络请求、文件系统、定时器
- **AppKit** — 窗口、菜单栏、Dock 控制
- **SwiftUI** — UI 布局和动画
- **Combine** — 响应式数据绑定

### 关键组件
| 文件 | 职责 |
|------|------|
| `NowPlayingMonitor.swift` | 通过 AppleScript 轮询 Music.app 当前播放信息 |
| `RemoteLyricsSource.swift` | 查询网易云 API、获取 LRC 歌词 |
| `LyricsRepository.swift` | 内存 + 磁盘缓存、避免重复查询 |
| `LyricsSyncEngine.swift` | 驱动每 0.2s 检查当前歌词行索引 |
| `NotchPanel.swift` | NSPanel 浮窗、几何计算、全屏检测 |
| `NotchView.swift` | SwiftUI 主界面（collapsed bar + expanded card） |
