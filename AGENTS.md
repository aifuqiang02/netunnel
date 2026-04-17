# Netunnel Agents

## 项目结构

```text
netunnel/
├── package.json
├── pnpm-workspace.yaml
├── deploy/                     # 部署脚本、Nginx 模板
├── src/
│   ├── netunnel-desktop-tauri/ # 桌面端（Vue 3 + Tauri）
│   ├── netunnel-docs-site/     # 官网与文档站（VuePress + Plume）
│   ├── netunnel-server/        # Go 服务端
│   └── netunnel-agent/         # Go Agent
└── designs/
```

## 常用命令

### 根目录

| 命令 | 说明 |
|------|------|
| `pnpm install` | 安装 workspace 依赖 |
| `pnpm --filter netunnel-desktop-tauri dev` | 启动桌面端开发服务器 |
| `pnpm --filter netunnel-desktop-tauri build` | 构建桌面端 |
| `pnpm --filter netunnel-desktop-tauri type-check` | 桌面端类型检查 |
| `pnpm docs:dev` | 启动官网文档站 |
| `pnpm docs:build` | 构建官网文档站 |
| `pnpm run deploy:server -- --target backend` | 部署服务端 |
| `pnpm run deploy:server -- --target docs-site` | 部署官网文档站 |

### 服务端

| 命令 | 说明 |
|------|------|
| `go build ./...` | 编译所有包 |
| `go test ./...` | 运行测试 |
| `go vet ./...` | 代码检查 |
| `go fmt ./...` | 格式化 |

## 代码约定

### Vue / TypeScript

- Prettier：`semi: false`、`singleQuote: true`、`printWidth: 120`
- 组件文件用 `PascalCase.vue`
- 组合式函数用 `useXxx.ts`
- 尽量避免 `any`
- 服务层抛具体错误，调用方负责捕获

### Go

- 使用 `go fmt` + `goimports`
- 错误用 `fmt.Errorf("...: %w", err)` 包装
- 目录约定：`internal/domain`、`repository`、`service`、`transport`、`config`
- 查询参数使用 PostgreSQL `$1`, `$2`

## 关键配置

### 桌面端

- 开发环境：`src/netunnel-desktop-tauri/.env.development`
- 生产环境：`src/netunnel-desktop-tauri/.env.production`
- 关键变量：
  - `VITE_DEFAULT_HOME_URL`
  - `VITE_DEFAULT_BRIDGE_ADDR`

### 服务端

- 运行配置：`src/netunnel-server/config.yaml`
- 生产配置源文件：`src/netunnel-server/config.production.yaml`
- 关键变量：
  - `POSTGRES_HOST`
  - `POSTGRES_PORT`
  - `POSTGRES_USER`
  - `POSTGRES_PASSWORD`
  - `POSTGRES_DB`
  - `SERVER_PORT`
  - `BRIDGE_PORT`

### 端口

| 端口 | 说明 |
|------|------|
| `40061` | HTTP API |
| `40063` | HTTPS API |
| `40062` | Agent Bridge |

## 调试

- 桌面端：登录后按 `F12`
- 服务端日志：`src/netunnel-server/server.40061.out.log`、`server.40061.err.log`
- Agent 日志：`src/netunnel-agent/agent.40061.out.log`、`agent.40061.err.log`

## 部署

### 服务端

- 部署命令：`pnpm run deploy:server -- --target backend`
- 首次需要准备：
  - `/www/wwwroot/netunnel/shared`
  - `/www/wwwroot/netunnel/releases`
  - `deploy/netunnel-server.service`
- 发布后检查：

```bash
sudo systemctl status netunnel-server --no-pager
sudo journalctl -u netunnel-server -n 100 --no-pager
curl http://127.0.0.1:40061/healthz
```

### 官网文档站

- 部署命令：`pnpm run deploy:server -- --target docs-site`
- 发布目录：`/www/wwwroot/netunnel/docs`
- 域名：`https://netunnel.tx07.cn`
- Nginx 模板：`deploy/nginx/netunnel.tx07.cn.conf`
- 同步 Nginx：`pnpm run sync:nginx:netunnel`
- 发布后检查：

```bash
curl -k -H 'Host: netunnel.tx07.cn' https://127.0.0.1/
```

## 发布版本

桌面端版本升级：

```bash
cd src/netunnel-desktop-tauri
node bump-version.cjs x.y.z
```

然后手动更新根目录 `package.json` 的 `version`。
