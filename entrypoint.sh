#!/bin/sh
# CFData-WEB 容器入口脚本
#
# 职责：把镜像内置的只读数据软链到工作目录，再交给主程序。
# 主程序按 CWD 相对路径读取 locations.json / ips-v4.txt / ips-v6.txt / GeoLite2-ASN.mmdb，
# 而工作目录要留给用户挂载卷存放导出结果（-v $(pwd):/out），所以启动时软链一次，
# 既能用预置数据避免每次联网下载，又不会把用户挂载的目录用镜像层覆盖。
set -e

DATA_DIR="${CFDATA_DATA_DIR:-/opt/cfdata-data}"
WORK_DIR="${CFDATA_WORK_DIR:-/out}"

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# 已有同名文件则跳过（用户可能自己放了更新的数据，或挂载进来的目录里已有）
for f in locations.json ips-v4.txt ips-v6.txt GeoLite2-ASN.mmdb; do
    if [ ! -e "$f" ] && [ -e "$DATA_DIR/$f" ]; then
        ln -s "$DATA_DIR/$f" "$f"
    fi
done

exec /usr/local/bin/cfdata "$@"