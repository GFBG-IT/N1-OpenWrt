#!/bin/bash
set -e

echo "=== Starting DIY Script ==="

# --- 1. Apply any custom patches ---
if [ -f "$(dirname "$0")/luci.patch" ]; then
    echo "Applying patch..."
    patch -p1 -f < "$(dirname "$0")/luci.patch" || true
else
    echo "No patch file found, skipping."
fi

# --- 2. Add plugins from various sources ---

# 2a. Clone and add kiddin9's kwrt-packages
echo "Adding Kwrt-Packages (Kiddin9's Source)..."
git clone --depth=1 https://github.com/kiddin9/kwrt-packages.git clone/kwrt-packages

cd clone/kwrt-packages
for dir in */; do
    dir_name=${dir%/}
    if [ -f "$dir_name/Makefile" ]; then
        echo "Processing: $dir_name"
        if [[ $dir_name == luci-app-* ]]; then
            rm -rf "../../feeds/luci/applications/$dir_name"
            mv "$dir_name" "../../feeds/luci/applications/"
        elif [[ $dir_name == luci-theme-* ]]; then
            rm -rf "../../feeds/luci/themes/$dir_name"
            mv "$dir_name" "../../feeds/luci/themes/"
        elif [[ $dir_name == luci-proto-* ]]; then
            rm -rf "../../feeds/luci/protocols/$dir_name"
            mv "$dir_name" "../../feeds/luci/protocols/"
        elif [[ $dir_name == luci-lib-* ]]; then
            rm -rf "../../feeds/luci/libs/$dir_name"
            mv "$dir_name" "../../feeds/luci/libs/"
        else
            rm -rf "../../feeds/packages/$dir_name"
            mv "$dir_name" "../../feeds/packages/"
        fi
    fi
done
cd ../..

# 2b. Clone and add other specific plugins (like amlogic, passwall2)
mkdir -p clone
echo "Cloning other specific repositories..."

# 克隆 Amlogic 插件
git clone https://github.com/ophub/luci-app-amlogic --depth=1 clone/amlogic

# 克隆 PassWall2 (注意这里是 passwall2, 不是 passwall)
git clone https://github.com/Openwrt-Passwall/openwrt-passwall2 --depth=1 clone/passwall2

# --- 3. Adjust packages from cloned repos ---
echo "Moving specific plugins..."

# 清理旧的 (如果存在)
rm -rf feeds/luci/applications/luci-app-amlogic
rm -rf feeds/luci/applications/luci-app-passwall
rm -rf feeds/luci/applications/luci-app-passwall2
# 移除了 podman 的清理命令

# 移动新插件
cp -rf clone/amlogic/luci-app-amlogic feeds/luci/applications/

# --- 关于 PassWall 的处理 ---
# 如果你希望保留 PassWall 2 的名称 (推荐)
cp -rf clone/passwall2/luci-app-passwall2 feeds/luci/applications/

# 如果你坚持要用 PassWall 2 的代码但显示为 PassWall 1 (不推荐，容易配置冲突)
# rm -rf feeds/luci/applications/luci-app-passwall
# mv feeds/luci/applications/luci-app-passwall2 feeds/luci/applications/luci-app-passwall

# 移除 attendedsysupgrade (如果存在)
sed -i '/luci-app-attendedsysupgrade/d' feeds/luci/collections/luci/Makefile

# --- 4. Clean up ---
rm -rf clone

echo "=== DIY Script Completed ==="
