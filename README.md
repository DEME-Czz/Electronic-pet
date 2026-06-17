# Token Pet

一个无外部依赖的 macOS 桌面电子宠物，用来查看不同厂商的 token 使用量。

当前版本使用 Swift/AppKit 实现：

- 桌面无边框置顶小宠物
- 鼠标拖动移动位置
- 单击展开 / 收起用量面板
- 双击刷新用量
- 右键切换厂商或退出
- 默认每 3 秒读取本机 Codex 真实会话用量
- 支持 Codex local、mock、本地 JSON、自定义 HTTP、OpenAI organization usage adapter

## 运行

```bash
mkdir -p .build
CLANG_MODULE_CACHE_PATH=.build/ModuleCache swiftc TokenPet.swift -o .build/token-pet
.build/token-pet
```

也可以直接双击或运行：

```bash
./launch.command
```

命令行测试真实用量：

```bash
mkdir -p .build
CLANG_MODULE_CACHE_PATH=.build/ModuleCache swiftc TokenPet.swift -o .build/token-pet
.build/token-pet --print-usage
```

命令行实时观察：

```bash
.build/token-pet --watch
```

模拟 Codex `/status` 输出：

```bash
.build/token-pet --status
```

## 配置

默认读取 `providers.json`。如果文件不存在，会每 3 秒读取 `~/.codex` 下最近 7 天的 Codex 本地会话用量。

复制样例：

```bash
cp providers.example.json providers.json
```

### Provider 类型

#### codex_local

从本机 Codex 会话文件读取真实 token 用量。数据来自 `~/.codex/sessions/**/*.jsonl` 和 `~/.codex/archived_sessions/*.jsonl` 里的 `token_count` 事件。

```json
{
  "id": "codex-local",
  "name": "Codex Live",
  "type": "codex_local",
  "codex_home": "~/.codex",
  "days": 7
}
```

统计方式：每个 Codex rollout 会话取最后一次 `total_token_usage`，再汇总最近 N 天内有记录的会话。这样不会把同一个会话里递增的累计 token 重复相加。启动后会缓存每个日志文件的读取位置，后续刷新只读取增长过的 jsonl 内容。

实时性说明：这是本机 Codex 日志实时读取。Codex 当前会话写入新的 `token_count` 事件后，宠物下一次刷新就会显示；它不是 OpenAI 云端账单的实时结算数据。

#### mock

本地演示数据。

```json
{
  "id": "mock-openai",
  "name": "OpenAI Demo",
  "type": "mock",
  "input_tokens": 1432000,
  "output_tokens": 492000,
  "requests": 831
}
```

#### local_json

从本地 JSON 文件读取。适合接账单导出、代理脚本或定时任务输出。

```json
{
  "id": "local-anthropic",
  "name": "Anthropic Export",
  "type": "local_json",
  "path": "./usage/anthropic.json"
}
```

文件格式：

```json
{
  "input_tokens": 120000,
  "output_tokens": 50000,
  "requests": 300,
  "cost_usd": 2.34
}
```

#### http_json

从自定义 HTTP 接口读取，适合你已有的聚合后端。

```json
{
  "id": "gateway",
  "name": "Internal Gateway",
  "type": "http_json",
  "url": "http://127.0.0.1:8080/token-usage",
  "headers": {
    "Authorization": "Bearer ${TOKEN_USAGE_GATEWAY_KEY}"
  }
}
```

响应格式和 `local_json` 一样。

#### openai

查询 OpenAI organization usage endpoint。需要可访问组织用量的 admin key。

```json
{
  "id": "openai",
  "name": "OpenAI",
  "type": "openai",
  "api_key_env": "OPENAI_ADMIN_KEY",
  "days": 7
}
```

## 说明

不同厂商的官方 token 用量 API 差异很大，有些只提供控制台账单或云账单导出。这个项目把桌面交互和数据适配层拆开：宠物只关心统一后的 `input_tokens`、`output_tokens`、`requests`、`cost_usd`，具体厂商逻辑在 `TokenPet.swift` 的 `ProviderStore` 中。
