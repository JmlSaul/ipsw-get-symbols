# ipsw-get-symbols

从 iOS IPSW 固件中提取 `dyld_shared_cache` 系统符号文件，用于逆向工程和安全研究。

提取后的符号文件可用于 IDA Pro、Hopper 等反汇编工具，帮助分析 iOS 系统框架的内部实现。

## 系统要求

> **仅支持 macOS**

- macOS 10.15+
- [Homebrew](https://brew.sh/)

## 安装依赖

```bash
brew install blacktop/tap/ipsw p7zip
```

| 依赖 | 用途 |
|------|------|
| [ipsw](https://github.com/blacktop/ipsw) | iOS 固件下载、解析、dyld 提取 |
| [p7zip](https://p7zip.sourceforge.net/) | 7z 压缩输出 |

> `python3` 用于 Mach-O load commands 修复，macOS 已内置。

## 使用方式

```bash
chmod +x ipsw_get_symbols.sh
```

### 1. 从本地 .ipsw 文件提取

```bash
./ipsw_get_symbols.sh iPhone14,2_16.0_20A362_Restore.ipsw
```

### 2. 从 dyld_shared_cache 文件提取

需要手动指定 iOS 版本：

```bash
./ipsw_get_symbols.sh dyld_shared_cache_arm64e -v 16.0
```

### 3. 从远程 URL 直接提取（分段下载）

```bash
./ipsw_get_symbols.sh -r "https://updates.cdn-apple.com/.../iPhone14,2_16.0_20A362_Restore.ipsw"
```

### 4. 列出固件地址并选择下载

```bash
# 按版本列出
./ipsw_get_symbols.sh -l -v 16.0

# 按设备列出
./ipsw_get_symbols.sh -l -d iPhone14,2

# 按 Build 号列出
./ipsw_get_symbols.sh -l -b 20A362
```

### 5. 指定设备和版本自动下载

```bash
# 按 iOS 版本
./ipsw_get_symbols.sh -d iPhone14,2 -v 16.0

# 按 Build 号
./ipsw_get_symbols.sh -d iPhone14,2 -b 20A362
```

## 参数说明

| 参数 | 说明 | 示例 |
|------|------|------|
| `<file>` | 本地 .ipsw 或 dyld_shared_cache 文件路径 | `iPhone14,2_16.0_20A362_Restore.ipsw` |
| `-v, --version` | iOS 版本号 | `16.0` |
| `-d, --device` | 设备标识符 | `iPhone14,2` |
| `-b, --build` | Build ID | `20A362` |
| `-l, --list` | 列出固件地址供选择 | |
| `-r, --remote` | 远程 IPSW 的 URL | `https://...` |

## 输出

脚本会在当前目录生成一个 `.7z` 压缩包，命名格式：

```
<iOS版本> (<Build号>) <架构>.7z
```

例如：`16.0 (20A362) arm64e.7z`

压缩包内包含从 `dyld_shared_cache` 中提取的所有系统符号（含 Objective-C 元数据）。

## 工作流程

```
IPSW 固件
  └─ ipsw extract --dyld
       └─ dyld_shared_cache_arm64e
            └─ ipsw dyld extract (带 ObjC 元数据)
                 └─ 修复损坏的 Mach-O load commands
                      └─ 7z 压缩输出
```

## 常见问题

**Q: 提示 "该版本低于 iOS 16，不支持直接提取 dyld"**
A: iOS 16 以下的固件不支持在线分段下载 dyld，脚本会自动切换为完整下载模式。

**Q: 如何查找设备标识符？**
A: 设备标识符如 `iPhone14,2` 对应 iPhone 13 Pro。可在 [The iPhone Wiki](https://www.theiphonewiki.com/wiki/Models) 查看完整列表。

## 许可证

MIT
