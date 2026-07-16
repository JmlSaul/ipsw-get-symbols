#!/bin/zsh
set -e
# 依赖: ipsw python3 7z
# 安装: brew install blacktop/tap/ipsw p7zip

SCRIPT_NAME="${0:t}"

# ==================== 工具函数 ====================

die() { echo "❌ $1"; exit 1; }

print_usage() {
    echo "用法:"
    echo "  $SCRIPT_NAME <*.ipsw>                                     # 从本地 .ipsw 文件提取符号"
    echo "  $SCRIPT_NAME <目录>                                       # 从已解压目录自动提取符号"
    echo "  $SCRIPT_NAME <dyld_shared_cache_arm64e> -v <version>      # 从 dyld 文件直接提取符号"
    echo "  $SCRIPT_NAME -r <url>                                     # 从远程 URL 直接提取符号"
    echo "  $SCRIPT_NAME -d <device> <-v <version> | -b <build>>      # 下载固件并提取符号"
    echo "  $SCRIPT_NAME -l [-v <version>] [-d <device>] [-b <build>] # 列出固件地址并选择下载"
    echo ""
    echo "参数:"
    echo "  -v, --version   iOS 版本 (如 12.3.1)"
    echo "  -d, --device    设备 (如 iPhone11,2 / iPad_Pro_HFR)"
    echo "  -b, --build     Build ID (如 16F203)"
    echo "  -l, --list      列出该版本所有固件地址"
}

run_ipsw() {
    echo "$ ipsw $*"
    ipsw "$@"
}

# 查找 dyld_shared_cache 文件
find_dsc() {
    local dir="$1"
    local dsc=""
    [ -f "$dir/dyld_shared_cache_arm64e" ] && dsc="$dir/dyld_shared_cache_arm64e"
    [ -f "$dir/dyld_shared_cache_arm64" ]  && dsc="$dir/dyld_shared_cache_arm64"
    [ -z "$dsc" ] && die "无法找到 dyld_shared_cache 文件"
    echo "$dsc"
}

# 清理下载产生的临时文件
cleanup_download() {
    local version="$1" build="$2" dl_dir="$3"
    echo "🧹 清理临时文件..."
    [ "$dl_dir" = "." ] && rm -rf "./${build}__*" || rm -rf "./${dl_dir}"
    rm -rf "${version} (${build}) arm64e" "${version} (${build}) arm64"
}

# 从目录中查找 dyld 并提取符号
find_and_extract() {
    local search_dir="$1" version="$2" build="$3"
    local dsc_dir=$(find "./${search_dir}" -type d -name "${build}__*" | head -n 1)
    [ -z "$dsc_dir" ] && die "无法找到 dyld 目录: ${search_dir}/${build}__*"
    extract_symbols "$(find_dsc "$dsc_dir")" "$version" "$build"
}

# 远程 URL 提取符号 (模式 R/B 共用)
remote_extract() {
    local url="$1" version="$2" build="$3"

    echo "====================================="
    echo "🔗 远程 URL: $url"
    echo "📱 iOS 版本: $version"
    echo "🏗 Build 号: $build"
    echo "====================================="
    echo ""

    echo "🔍 从远程提取 dyld_shared_cache..."
    local dl_log=$(mktemp)
    run_ipsw extract --dyld -r "$url" -o "$version" 2>&1 | tee "$dl_log" || true

    if grep -q "does not support byte-ranged requests" "$dl_log"; then
        rm -f "$dl_log"
        echo ""
        echo "⚠️ 该文件不支持分段下载，切换为完整下载模式..."
        parse_url_info "$url"
        download_and_extract "$version" "$parsed_device" "$build"
        return
    fi
    rm -f "$dl_log"

    find_and_extract "$version" "$version" "$build"
    cleanup_download "$version" "$build" "$version"
}

# 核心符号提取 + 修复 + 压缩
extract_symbols() {
    local dsc_file="$1" ios_ver="$2" build_code="$3"
    local arch
    [[ "$dsc_file" == *"arm64e"* ]] && arch="arm64e" || arch="arm64"
    local symbol_dir="${ios_ver} (${build_code}) ${arch}"

    echo "====================================="
    echo "📱 iOS 版本: $ios_ver"
    echo "🏗 Build 号: $build_code"
    echo "🔩 架构: $arch"
    echo "🗜️ 输出压缩包: ${symbol_dir}.7z"
    echo "====================================="
    echo ""

    echo "🔧 正在提取系统符号 (含 ObjC)..."
    if ! run_ipsw dyld extract "$dsc_file" --all --objc -o "$symbol_dir"; then
        echo "⚠️ 含 ObjC 提取失败，尝试不含 ObjC..."
        run_ipsw dyld extract "$dsc_file" --all -o "$symbol_dir"
    fi

    echo "🚧 修复损坏的Mach-O load commands..."
    fix_macho "$symbol_dir"

    echo "🗜️ 压缩符号文件 -> ${symbol_dir}.7z..."
    7z a -t7z -mx=6 "${symbol_dir}.7z" "$symbol_dir"

    echo ""
    echo "====================================="
    echo "✅ 全部完成！"
    echo "📄 输出文件: ${symbol_dir}.7z"
    echo "====================================="
}

# 从本地 ipsw 文件提取 dyld 并提取符号
extract_from_ipsw() {
    local ipsw_file="$1" ios_ver="$2" build_code="$3"
    local dl_dir="${ios_ver:-.}"

    echo "🔍 提取 dyld_shared_cache..."
    run_ipsw extract --dyld "$ipsw_file" -o "$dl_dir"

    find_and_extract "$dl_dir" "$ios_ver" "$build_code"
}

# 下载固件 -> 查找 dyld -> 提取符号
download_and_extract() {
    local version="$1" device="$2" build="$3"
    local dl_dir="${version:-.}"

    echo "⬇️ 正在下载固件并提取 dyld..."
    local dl_log=$(mktemp)
    local -a dl_args=(-y --dyld -o "$dl_dir" --skip-all)
    [ -n "$version" ] && dl_args+=(-v "$version") || dl_args+=(-b "$build")
    echo "$ ipsw download ipsw ${dl_args[*]}"
    ipsw download ipsw "${dl_args[@]}" 2>&1 | tee "$dl_log" || true

    if grep -q "no SystemOS DMG found" "$dl_log"; then
        rm -f "$dl_log"
        die "该版本低于 iOS 16，不支持直接提取 dyld"
    fi

    if grep -q "does not support byte-ranged requests" "$dl_log"; then
        rm -f "$dl_log"
        echo ""
        echo "⚠️ 该文件不支持分段下载，切换为完整下载模式..."
        local -a fb_args=(-y -o . --skip-all)
        [ -n "$version" ] && fb_args+=(-v "$version") || fb_args+=(-b "$build")
        run_ipsw download ipsw "${fb_args[@]}"

        local ipsw_file=$(find . -maxdepth 1 -name "*${build:-$version}*_Restore.ipsw" | head -n 1)
        [ -z "$ipsw_file" ] && die "无法找到下载的 ipsw 文件"

        echo "🔍 提取 dyld_shared_cache..."
        run_ipsw extract --dyld "$ipsw_file" -o "$dl_dir"
        rm -f "$ipsw_file"
    else
        rm -f "$dl_log"
    fi

    find_and_extract "$dl_dir" "$version" "$build"
    cleanup_download "$version" "$build" "$dl_dir"
}

# 从 URL/文件名解析 device、version、build
# 格式: *{device}_{version}_{build}_Restore.ipsw
# 支持: iPhone11,2_12.3.1_16F203_Restore.ipsw
#      iPad_Pro_HFR_17.7.1_21H216_Restore.ipsw
#      iPad17,1,iPad17,2_27.0_24A5380l_Restore.ipsw
parse_url_info() {
    local filename=$(basename "$1")
    local base="${filename%_Restore.ipsw}"
    parsed_build="${base##*_}"
    local rest="${base%_*}"
    parsed_version="${rest##*_}"
    parsed_device="${rest%_*}"
}

# ==================== Mach-O 修复脚本 ====================

fix_macho() {
    python3 -c '
import struct, os, sys

VALID = set(range(0x1, 0x33))
VALID.update([0x80000000 | i for i in range(1, 0x38)])

fixed_sig = fixed_other = checked = 0

for root, _, files in os.walk(sys.argv[1]):
    for fname in files:
        path = os.path.join(root, fname)
        checked += 1
        try:
            with open(path, "rb") as f:
                data = bytearray(f.read())
            if len(data) < 32:
                continue
            magic = struct.unpack_from("<I", data, 0)[0]
            if magic not in (0xFEEDFACE, 0xFEEDFACF):
                continue

            ncmds = struct.unpack_from("<I", data, 16)[0]
            hdr_sz = 32 if magic == 0xFEEDFACF else 28
            off = hdr_sz
            modified = False

            for _ in range(ncmds):
                if off + 8 > len(data):
                    break
                cmd, cmdsize = struct.unpack_from("<II", data, off)
                if cmd == 0 and cmdsize == 0:
                    break

                if cmd == 0x1c and (cmdsize > len(data) - off or cmdsize < 16):
                    sig_off = None
                    for p in range(len(data) - 16, max(0, len(data) - 0x200000), -16):
                        if struct.unpack_from("<I", data, p)[0] == 0xFade0C02:
                            sig_off = p
                            break
                    if sig_off is not None:
                        sig_len = struct.unpack_from("<I", data, sig_off + 4)[0]
                        if sig_len <= len(data) - sig_off:
                            struct.pack_into("<IIII", data, off, 0x1c, 16, sig_off, sig_len)
                            modified = True; fixed_sig += 1; off += 16; continue
                    struct.pack_into("<II", data, off, 0, 16)
                    modified = True; fixed_sig += 1; off += 16; continue

                if cmdsize < 8 or cmdsize > len(data) - off or cmd not in VALID:
                    struct.pack_into("<II", data, off, 0, 16)
                    modified = True; fixed_other += 1; off += 16; continue

                off += cmdsize

            if modified:
                with open(path, "wb") as f:
                    f.write(data)
        except:
            pass

print(f"Checked: {checked}, LC_CODE_SIGNATURE fixed: {fixed_sig}, other load commands fixed: {fixed_other}")
' "$1"
}

# ==================== 参数解析 ====================

[ $# -eq 0 ] && { print_usage; exit 0; }

VERSION="" DEVICE="" BUILD="" LIST_MODE=false REMOTE_URL="" POSITIONAL=""
while [ $# -gt 0 ]; do
    case "$1" in
        -v|--version) VERSION="$2"; shift 2 ;;
        -d|--device)  DEVICE="$2";  shift 2 ;;
        -b|--build)   BUILD="$2";   shift 2 ;;
        -l|--list)    LIST_MODE=true; shift ;;
        -r|--remote)  REMOTE_URL="$2"; shift 2 ;;
        -*)           die "未知参数: $1" ;;
        *)            POSITIONAL="$1"; shift ;;
    esac
done

DSC_FILE="" IPSW_FILE="" SEARCH_DIR=""
if [ -n "$POSITIONAL" ]; then
    if [[ "$POSITIONAL" == *"dyld_shared_cache_arm64"* ]]; then
        DSC_FILE="$POSITIONAL"
    elif [ -d "$POSITIONAL" ]; then
        SEARCH_DIR="$POSITIONAL"
    else
        IPSW_FILE="$POSITIONAL"
    fi
fi

# ==================== 模式 A: 本地 .ipsw 文件 ====================

if [ -n "$IPSW_FILE" ]; then
    [ ! -f "$IPSW_FILE" ] && die "文件不存在: $IPSW_FILE"

    parse_url_info "$IPSW_FILE"
    ios_ver="$parsed_version"
    build_code="$parsed_build"

    echo "====================================="
    echo "📦 IPSW 文件: $IPSW_FILE"
    echo "📱 iOS 版本: $ios_ver"
    echo "🏗 Build 号: $build_code"
    echo "====================================="
    echo ""

    extract_from_ipsw "$IPSW_FILE" "$ios_ver" "$build_code"
    exit 0
fi

# ==================== 模式 A2: dyld_shared_cache 文件 ====================

if [ -n "$DSC_FILE" ]; then
    [ ! -f "$DSC_FILE" ] && die "文件不存在: $DSC_FILE"
    [ -z "$VERSION" ] && die "指定 dyld 文件时必须提供 -v/--version 参数"
    extract_symbols "$DSC_FILE" "$VERSION" "${BUILD:-unknown}"
    exit 0
fi

# ==================== 模式 A3: 目录搜索 ====================

if [ -n "$SEARCH_DIR" ]; then
    SEARCH_DIR="${SEARCH_DIR%/}"
    build_dir=$(find "$SEARCH_DIR" -maxdepth 1 -type d -name "*__*" | head -n 1)
    [ -z "$build_dir" ] && die "无法在 $SEARCH_DIR 中找到固件目录 (期望 ${build}__* 格式)"

    build_name=$(basename "$build_dir")
    build_code="${build_name%%__*}"

    echo "====================================="
    echo "📁 目录: $SEARCH_DIR"
    echo "📱 iOS 版本: $SEARCH_DIR"
    echo "🏗 Build 号: $build_code"
    echo "====================================="
    echo ""

    find_and_extract "$SEARCH_DIR" "$SEARCH_DIR" "$build_code"
    exit 0
fi

# ==================== 模式 R: 远程 URL 直接提取 ====================

if [ -n "$REMOTE_URL" ]; then
    parse_url_info "$REMOTE_URL"
    [ -z "$parsed_version" ] || [ -z "$parsed_build" ] && die "无法从 URL 解析 version/build\n   URL: $REMOTE_URL"
    remote_extract "$REMOTE_URL" "${VERSION:-$parsed_version}" "${BUILD:-$parsed_build}"
    exit 0
fi

# ==================== 模式 B: 列出固件地址并选择 ====================

if [ "$LIST_MODE" = true ]; then
    [ -z "$VERSION" ] && [ -z "$DEVICE" ] && [ -z "$BUILD" ] && {
        die "列出模式至少需要指定 -v/-d/-b 中的一个"
    }

    cmd="ipsw download ipsw"
    label=""
    [ -n "$VERSION" ] && { cmd="$cmd -v $VERSION"; label="$label iOS $VERSION"; }
    [ -n "$DEVICE" ]  && { cmd="$cmd -d $DEVICE";  label="$label $DEVICE"; }
    [ -n "$BUILD" ]   && { cmd="$cmd -b $BUILD";   label="$label $BUILD"; }
    [ -z "$label" ] && label="全部"

    echo "🔍 正在获取${label} 的固件列表..."
    echo "$ $cmd --urls"
    echo ""

    urls=()
    while IFS= read -r line; do
        [[ "$line" =~ ^https:// ]] && [[ "$line" == *Restore.ipsw ]] && urls+=("$line")
    done < <(eval "$cmd --urls" 2>/dev/null)

    [ ${#urls[@]} -eq 0 ] && die "未找到固件"

    echo "找到 ${#urls[@]} 个固件:"
    echo ""
    for i in {1..${#urls[@]}}; do
        printf "%3d) %s\n" $i "${urls[$i]}"
    done
    echo ""

    read "choice?请输入序号 (1-${#urls[@]}): "

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#urls[@]} ]; then
        die "无效选择"
    fi

    selected_url="${urls[$choice]}"
    echo ""
    echo "✅ 已选择: $selected_url"
    echo ""

    parse_url_info "$selected_url"
    if [ -z "$parsed_device" ] || [ -z "$parsed_version" ] || [ -z "$parsed_build" ]; then
        die "无法从 URL 解析 device/version/build\n   URL: $selected_url"
    fi


    remote_extract "$selected_url" "${VERSION:-$parsed_version}" "$parsed_build"
    exit 0
fi

# ==================== 模式 C: 直接下载 ====================

[ -z "$DEVICE" ] && die "必须指定 -d/--device 参数"
[ -z "$VERSION" ] && [ -z "$BUILD" ] && die "必须指定 -v 或 -b 参数"
[ -n "$VERSION" ] && [ -n "$BUILD" ] && die "-v 和 -b 不能同时指定，二选一"

download_and_extract "$VERSION" "$DEVICE" "$BUILD"
