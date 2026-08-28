# OTA 固件升级协议接入文档

本文档说明本应用「OTA 固件升级扩展」所使用的 JSON 行协议。目标设备
（固件/服务端）按此文档实现后，即可直接配合本应用完成固件上传、校验、
应用与重启，无需额外开发上位机。

## 1. 概述

- OTA 与普通指令共用同一条 TCP 连接，消息格式一致：**一行 JSON**，以
  换行符 `\n` 结尾。
- 固件原始 `.bin` 内容通过十六进制字符串传输。
- 建议客户端串行执行「发送一条命令 → 读取一行响应」，尤其不要并发发送
  OTA 分块与普通管理命令。

## 2. 传输约定

| 项目 | 规格 |
|---|---|
| 编码 | UTF-8 |
| 请求 | 一个顶层 JSON 对象，顶层仅一个字段 |
| 响应 | 一行 JSON，以 `\n` 结束 |
| 单条请求最大 | 2304 字节 |
| OTA 单块原始数据最大 | 1024 字节（十六进制后 ≤ 2048 字符） |

- TCP 没有消息边界，设备应能处理拆包，也能处理一次发送的多个连续 JSON 对象。
- `ota begin` 成功后进入独占阶段，直到 `abort`、失败或 `apply` 结束；
  此期间所有非 OTA 指令都应被忽略且不返回响应。`ota` 下的 `status`、
  `chunk`、`finish`、`abort` 和 `apply` 仍正常响应。

## 3. 命令定义

### 3.1 查询状态

**请求**：

```json
{"ota":{"op":"status"}}
```

**响应**：

```json
{"ok":true,"state":"receiving","written":1024,"total":428736,"percent":0,"running":"ota_0","update":"ota_1"}
```

| 字段 | 说明 |
|---|---|
| `state` | 当前 OTA 状态：`idle`、`receiving`、`ready`、`failed` |
| `written` | 已接收字节数，用于断点续传与进度显示 |
| `total` | 本次固件总字节数 |
| `percent` | 进度百分比（0–100） |
| `running` | 当前运行分区名 |
| `update` | 本次目标分区名 |

### 3.2 开始 OTA

**请求**：

```json
{"ota":{"op":"begin","size":428736}}
```

`size` 为固件总字节数。成功后设备应擦除目标 OTA 分区并进入 `receiving`
状态，`written` 清零。

**响应**：

```json
{"ok":true,"state":"receiving","written":0,"total":428736,"percent":0,"running":"ota_0","update":"ota_1"}
```

### 3.3 发送分块

**请求**：

```json
{"ota":{"op":"chunk","offset":0,"data":"E9034A..."}}
```

| 字段 | 说明 |
|---|---|
| `offset` | 本块的起始偏移，必须严格等于设备当前 `written` |
| `data` | 偶数长度十六进制字符串，不带 `0x`、空格或分隔符 |

**响应**：

```json
{"ok":true,"state":"receiving","written":1024,"total":428736,"percent":0,"running":"ota_0","update":"ota_1"}
```

### 3.4 完成校验

**请求**：

```json
{"ota":{"op":"finish"}}
```

要求 `written == total`，成功后设备执行固件镜像校验。

**响应（成功）**：

```json
{"ok":true,"state":"ready","written":428736,"total":428736,"percent":100,"running":"ota_0","update":"ota_1"}
```

### 3.5 应用并重启

**请求**：

```json
{"ota":{"op":"apply"}}
```

设备设置启动分区并重启。

**响应**：

```json
{"ok":true,"action":"ota_rebooting"}
```

### 3.6 中止上传

**请求**：

```json
{"ota":{"op":"abort"}}
```

放弃本次 OTA，回到空闲状态。

**响应**：

```json
{"ok":true,"state":"idle","written":0,"total":0,"percent":0,"running":"ota_0","update":""}
```

## 4. 状态机

```
        begin          chunk ... finish          apply
idle ─────────► receiving ──────────► ready ──────────► 重启
       │                            │
       │ abort / 失败               │ abort
       └─────────────► idle ◄────────┘
```

## 5. 错误响应

所有命令出错时统一返回：

```json
{"ok":false,"error":"invalid_value"}
```

| 错误 | 含义 |
|---|---|
| `invalid_json` | JSON 语法错误、顶层字段不止一个或结构不符合要求 |
| `invalid_value` | `size`、`offset`、`data` 格式或值不正确 |
| `save_failed` | OTA 操作失败或当前状态不允许（例如 `receiving` 时重复 `begin`、`finish` 时 `written != total`） |

## 6. 典型升级时序

```json
{"ota":{"op":"status"}}
{"ota":{"op":"begin","size":428736}}
{"ota":{"op":"chunk","offset":0,"data":"E903..."}}
{"ota":{"op":"chunk","offset":1024,"data":"4A1F..."}}
{"ota":{"op":"chunk","offset":2048,"data":"7B00..."}}
...
{"ota":{"op":"finish"}}
{"ota":{"op":"apply"}}
```

## 7. 断点续传

应用在开始上传前会先执行一次 `status`：

- 若 `state == "receiving"` 且 `total` 等于本次固件大小，则直接从
  `written` 处继续发送剩余分块（跳过 `begin`）。
- 否则执行 `begin` 重新开始。

设备端只要保证 `offset` 严格等于当前 `written`、并拒绝重复或乱序分块，
即可支持续传。

## 8. 与本应用的行为对应

- 应用每块固定发送 1024 字节原始数据（十六进制后 2048 字符）。
- 进度显示基于响应中的 `written` / `total`。
- 上传期间应用会串行等待每条命令的响应，任何一条失败即中止本次上传。
- OTA 期间 MQTT 网络活动建议暂停，校验结束或中止后恢复。
