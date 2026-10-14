# CFData-WEB 容器镜像
#
# 构建（在仓库根目录执行）：
#   docker build -t ghcr.io/yegetables/cfdata-web:latest .
#
# 推送：
#   docker push ghcr.io/yegetables/cfdata-web:latest
#
# 一次性使用（官方优选，IPv6）：
#   docker run --rm --network host \
#     ghcr.io/yegetables/cfdata-web:latest \
#     -cli -skipgeo -mode official -offiptype 6 \
#     -offport 2083 -offdc HKG,TPE,NRT,KIX,SIN \
#     -offurl speed.okl.abrdns.com -offspeedlimit 5 -offspeedmin 20
#
# 必须用 --network host：官方优选依赖 IPv6 出网，Docker 默认 bridge 网络
# 不提供可用的公网 IPv6，会导致扫描全部失败（"未发现任何有效IP"）。
#
# 非交互模式建议加 -skipgeo：本机若走 fakeip DNS，地区检测会失真并中止。

# ---- 构建阶段 ----
FROM docker.m.daocloud.io/library/golang:1.27.2-alpine AS builder

WORKDIR /src

# 先只拷依赖清单，命中 Docker 层缓存
COPY combined_refactor/go.mod combined_refactor/go.sum ./

# 国内网络下 proxy.golang.org 不通，改用 goproxy.cn
# GOSUMDB=off 跳过校验库直连（sum.golang.org 同样不通）
ENV GOPROXY=https://goproxy.cn,direct \
    GOSUMDB=off \
    GOFLAGS=-mod=mod

RUN go mod download

COPY combined_refactor/ ./

# CGO_ENABLED=0 产出静态二进制，可放进精简运行镜像
# -trimpath 去掉构建机路径；-s -w 去符号表和调试信息
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath -ldflags="-s -w" -o /out/cfdata .

# ---- 预取运行时数据 ----
# locations.json / ips-v4.txt / ips-v6.txt / GeoLite2-ASN.mmdb 被 .gitignore
# 排除，程序运行时才下载。烤进镜像后 docker run --rm 无需联网下载。
FROM docker.m.daocloud.io/library/alpine:3.21 AS fetcher

ARG LOCATIONS_URL=https://www.baipiao.eu.org/cloudflare/locations
ARG IPS4_URL=https://www.baipiao.eu.org/cloudflare/ips-v4
ARG IPS6_URL=https://www.baipiao.eu.org/cloudflare/ips-v6
ARG ASN_URL=https://jsd.onmicrosoft.cn/gh/seketiti/GeoLiet2@release/GeoLite2-ASN.mmdb

RUN apk add --no-cache curl \
 && mkdir -p /data \
 && curl -fsSL "$LOCATIONS_URL" -o /data/locations.json \
 && curl -fsSL "$IPS4_URL"     -o /data/ips-v4.txt \
 && curl -fsSL "$IPS6_URL"     -o /data/ips-v6.txt \
 && curl -fsSL "$ASN_URL"      -o /data/GeoLite2-ASN.mmdb \
 && ls -la /data

# ---- 运行阶段 ----
FROM docker.m.daocloud.io/library/alpine:3.21

LABEL org.opencontainers.image.title="CFData-WEB" \
      org.opencontainers.image.description="Cloudflare IPv4/IPv6 优选工具（官方/非标模式），支持数据中心多选、测速与 GitHub 自动上传" \
      org.opencontainers.image.source="https://github.com/yegetables/CFData-WEB" \
      org.opencontainers.image.licenses="MIT"

# ca-certificates 供 HTTPS；tzdata 供时区
RUN apk add --no-cache ca-certificates tzdata

COPY --from=builder /out/cfdata /usr/local/bin/cfdata

# 只读的内置数据目录：locations.json / ips-v4.txt / ips-v6.txt / GeoLite2-ASN.mmdb
# 预置它们是为了让 docker run --rm 无需联网下载。
COPY --from=fetcher /data/ /opt/cfdata-data/

# 入口脚本：把内置数据软链到工作目录。
# 程序按 CWD 相对路径读取这些文件，而工作目录需要留给用户挂载卷存放导出结果，
# 所以启动时软链一次，既能用预置数据又不污染镜像层。
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# 预置配置文件。CLI 首次运行会检测配置不存在 → 生成模板后直接退出
# （"请退出后按需编辑配置文件，再重新开始测试"），而 docker run --rm 是一次性的，
# 没有第二次机会。程序按二进制所在目录定位配置文件（defaultCLIConfigPath 用 os.Executable），
# 因此在构建期触发一次生成，之后即可开箱即用。
# 用 nsb 模式 + 空参数触发：会走到配置生成分支，且因缺输入而立即返回，不会真的开始扫描。
RUN cd /usr/local/bin \
 && ./cfdata -cli -skipgeo -mode nsb >/dev/null 2>&1 || true \
 && test -f /usr/local/bin/cfdata-config.json \
 && echo "预置配置已生成: $(wc -c < /usr/local/bin/cfdata-config.json) 字节"

# 工作目录：用户用 -v $(pwd):/out 挂载，导出结果写在这里。
# 若不挂载，结果写在容器内，--rm 结束后丢弃（等同宿主机直接跑）。
WORKDIR /out

# Web 界面默认端口；CLI 模式不受影响
EXPOSE 13335

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["-h"]