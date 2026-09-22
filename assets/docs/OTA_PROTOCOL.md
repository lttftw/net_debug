# OTA 固件升级协议接入文档

本文档说明本应用「OTA 固件升级扩展」所使用的命令集。目标设备（固件/服务端）
按此文档实现后，即可直接配合本应用完成固件推送、校验、应用与重启；同时也给出
「设备自行按 URL 下载」通道的命令序列。

## 1. 概述

- OTA 与普通指令共用同一条通道、同一种报文格式：一个**扁平键值 JSON 对象**。
  本地 TCP 以 `\n` 结束一行，MQTT 则以一个报文承载。
- 全部 OTA 键（`ota_get` / `ota_set` / `ota_apply` / `ota_push_*`）在各通道上**逐字节
  相同**，差别只有允许的指令名单：MQTT 侧平台只用 `ota_read`（收 `ota_get`）与
  `ota_write`（收 `ota_apply`）两个物模型服务；**`ota_set` 不对用户开放**，只在
  `config` 管理员通道与本地 TCP 上可用；`ota_push_*` 分块推送仅本地 TCP，远端返回
  `forbidden`。
- 固件目录默认取平台地址（`http://<mqtt_host>:8080/iot/ota/<产品Key>/`），因此
  不做任何目录下发也能按版本升级；`ota_set` 只是本地/管理员的覆盖手段。
- 固件原始 `.bin` 内容通过十六进制字符串传输（分块推送）。
- 两条升级通道共用同一套 OTA 会话状态、同一个被动分区与同一个空闲看门狗，差别
  只在镜像从哪来：
  - **分块推送**：由本机直接推流，用于现场/救援；
  - **URL 拉取**：设备按下发的地址自行下载，用于远程常态升级。
- 建议客户端串行执行「发送一条命令 → 读取一行响应」，尤其不要并发发送 OTA
  分块与普通管理命令。

## 2. 传输约定

| 项目 | 规格 |
|---|---|
| 编码 | UTF-8 |
| 请求 | 一个顶层 JSON 对象（扁平键值对，值不嵌套对象/数组） |
| 响应 | 一行 JSON，以 `\n` 结束 |
| 单条请求最大 | 2304 字节 |
| OTA 单块原始数据最大 | 1024 字节（十六进制后 ≤ 2048 字符） |
| OTA 空闲看门狗 | 连续 120 s 没有成功写入分片即中止本次 OTA |

- TCP 没有消息边界，设备按括号深度界定一条顶层 JSON 对象，可处理拆包与粘包。
- 从 `ota_push_begin`（或 URL 下载）成功到中止、失败或 `ota_apply` 结束期间，
  OTA 独占当前管理会话：**只有 OTA 指令会被应答**，其余结构完整的指令被静默忽略。
- 分块推送期间设备会暂停与升级无关的通信；**URL 拉取不暂停 MQTT**，因此平台/工具
  可全程用 `ota_get` 观察进度。

## 3. 命令定义

### 3.1 读取状态

**请求**：

```json
{"ota_get":true}
```

**响应**：

```json
{"ok":true,"state":"receiving","source":"url","reason":"","written":1024,"total":428736,"percent":0,"running_partition":"ota_0","update_partition":"ota_1","url":"http://192.168.100.157:8088/","version":"1.0.0"}
```

| 字段 | 说明 |
|---|---|
| `state` | 当前 OTA 状态：`idle`、`receiving`、`ready`、`failed` |
| `source` | 会话来源：`tcp`（分块推送）/ `url`（设备自行下载） |
| `reason` | 失败原因，成功为空字符串（取值见第 6 节） |
| `written` | 已接收字节数，用于断点续传与进度显示 |
| `total` | 本次固件总字节数 |
| `percent` | 进度百分比（0–100） |
| `running_partition` | 当前运行分区名 |
| `update_partition` | 本次目标分区名 |
| `url` | 已保存的**固件目录**（末尾恒为 `/`，即设备补全后的实际存储值）；未设置时为空串 |
| `version` | **当前运行**镜像版本（升级后确认用；设备侧不做新旧版本比对） |

### 3.2 保存固件目录（只保存，不下载）

**请求**：

```json
{"ota_set":"http://192.168.100.157:8088"}
```

- **只保存目录**：不下载、不擦写任何分区，成功即返回最新状态回显；空串
  `{"ota_set":""}` 清除目录并中止来自该目录的进行中会话。
- 值是**目录**（文件名由设备按版本号拼成 `<版本>.bin`），末尾 `/` 可省略：固件补全后
  持久化，并在 `{"ota_get":true}` 的 `url` 里回显补全后的值。
- 目录约束：仅 `http://`；host 非空；含空白/控制字符或 `?`/`#` 拒绝；**补全 `/` 之后**
  总长 ≤ 192 字节。
- 下载进行中再写新目录会被拒（`ota_busy`）；写入的目录与被动分区里那张已校验
  镜像不对应时，设备会作废那张镜像，避免 `ota_apply` 装上与目录不符的固件。

### 3.3 按版本下载并应用（校验后自动重启）

**请求**：

```json
{"ota_apply":100}
```

参数是**版本号**，必须 **≥1**（`1`–`99999999`）：目标 = 已存目录 + `<版本>.bin`；
`0`（平台数值参数的默认值）不安装任何镜像并返回参数错误。

- 已有该版本的 `ready` 镜像（分块推送校验通过，或上一轮下载已完成）→ 立即切换启动
  分区，回复 `{"ok":true,"action":"ota_rebooting"}`，等回复发出后重启；
- 已有 `ready` 但版本不符（或那张镜像来自分块推送）→ 先作废它，再按本次版本下载，
  绝不会把别的版本切上去；
- 否则用目录 + 版本拼出地址启动下载，命令**秒级返回**（回状态回显，`state=receiving`），
  设备在下载完成并校验通过后**自己**切分区并重启，进度用 `{"ota_get":true}` 轮询；
- 分块推送的收尾用**仅本地 TCP** 的 `{"ota_push_apply":true}`：不开新下载，只把已
  `ready` 的镜像切为启动分区并在回复后重启；没有已 `ready` 镜像时返回参数错误。

没有已保存目录返回参数错误（1.2.0 及更早固件留下的完整文件地址也一样，需要重新下发
一次 `ota_set`）；分块推送会话占用中返回 `ota_busy`；URL 下载进行中的重复 `ota_apply`
幂等（同一版本）。

### 3.4 分块推送（仅本地 TCP）

按顺序发送：

```json
{"ota_push_begin":428736}
{"ota_push_chunk":"E903...","offset":0}
{"ota_get":true}
{"ota_push_finish":true}
{"ota_push_apply":true}
```

| 命令 | 说明 |
|---|---|
| `{"ota_push_begin":<size>}` | 值为镜像总字节数，正整数且不超过被动分区容量；收到成功的 `receiving` 后才可发分块 |
| `{"ota_push_chunk":"<HEX>","offset":N}` | 十六进制字符串不带 `0x`/空格/分隔符、长度为偶数、原始数据 ≤1024 字节；`offset` 必须严格等于设备当前 `written` |
| `{"ota_push_finish":true}` | 必须已写满声明长度；**只完成镜像校验，不切换启动分区、不触发重启** |
| `{"ota_push_apply":true}` | 本机收尾：把已校验（`ready`）的镜像切为启动分区，回复发出后重启；没有就绪镜像返回参数错误（远端 `forbidden`） |
| `{"ota_push_abort":true}` | 中止当前会话（分块推送或 URL 下载） |

`ota_push_begin` 在暂停相关通信和擦写升级分区之前，先保存计数到 NVS；前置保存全部
失败返回 `save_failed`，OTA 状态保持原样。

## 4. 状态机

```text
        ota_push_begin / ota_apply（带已保存 URL）
idle ─────────────────────────────────────► receiving ──► ready ──► 切分区 + 延迟重启
   ▲                                            │            │          （ota_apply）
   │  中止 / 失败 / 看门狗超时                    │ 中止       │ 中止
   └────────────────────────────────────────────┴────────────┘
```

- 分块推送：`receiving` 由客户端逐块推进，`ready` 由 `ota_push_finish` 产生，
  最后 `ota_apply` 切分区重启。
- URL 拉取：设备自己完成 `receiving → ready → 切分区重启`，客户端只需轮询 `ota_get`。

## 5. 断点续传

- 开始上传前先执行一次 `{"ota_get":true}`：
  - 若 `state == "receiving"`、`source == "tcp"` 且 `total` 等于本次固件大小，则从
    `written` 处继续发送剩余分块（**跳过 `ota_push_begin`**，不可重发 begin）；
  - 否则执行 `ota_push_begin` 重新开始。
- 设备端只要保证 `offset` 严格等于当前 `written`、并拒绝重复或乱序分块，即可支持
  会话内续传（断线 120 s 内有效）。
- URL 通道的续传由设备自行完成（HTTP `Range`，最多重试 3 次）；跨重启续传未实现。

## 6. 失败原因（`reason`）

| `reason` | 含义 |
|---|---|
| `device_not_connected` | 设备未联网，URL 下载无法开始（恢复在线后重新 `ota_apply` 即可重试） |
| `server_connect_failed` | 连接 HTTP 服务器失败 |
| `server_status_error` | 服务器返回非 2xx |
| `no_content_length` | 响应没有可用长度（无 Content-Length 或 chunked） |
| `range_not_supported` | 续传时服务器不支持 Range（未回 `206`） |
| `range_mismatch` | 续传响应的范围与请求偏移不一致 |
| `download_short_read` | 本次读取短于 Content-Length |
| `image_too_large` | 镜像超过被动分区容量 |
| `session_busy` | 已有其它 OTA 会话占用 |
| `connection_lost` | 连接中断且续传次数用尽 |
| `flash_write_error` | 写入 flash 失败 |
| `download_write_failed` | 下载过程中写入镜像失败 |
| `image_validate_failed` | 镜像校验失败（含**签名无效**或内容损坏） |
| `download_idle_timeout` | 连续 120 s 没有成功写入分片 |
| `image_pending_verify` / `partition_conflict` / `out_of_memory` | 准备阶段失败：运行镜像自检未确认 / 目标分区与运行分区冲突 / 内存不足 |

## 7. 错误响应

```json
{"ok":false,"error":"invalid_value"}
```

| 错误 | 含义 |
|---|---|
| `invalid_json` | JSON 语法错误、顶层字段不止一个或结构不符合要求 |
| `invalid_value` | 长度、`offset`、`data`、`size` 格式或值不正确，或缺少必需参数 |
| `save_failed` | OTA 操作失败或当前状态不允许（重复 begin、未写满就 finish 等） |
| `forbidden` | 远端通道使用分块推送，或把 OTA 指令发到 `config` 等其它通道 |
| `ota_busy` | OTA 会话期间指令被忽略 / 会话占用中重复发起 |

OTA 会话期间设备只应答 `ota_get` / `ota_set` / `ota_apply` / `ota_push_*`，其余指令
返回 `ota_busy`（本地 TCP 为静默忽略，不返回响应）。

## 8. 与本应用的行为对应

- 应用每块固定发送 1024 字节原始数据（十六进制后 2048 字符）。
- 进度显示基于响应中的 `written` / `total` / `percent`。
- 「应用并重启」在未就绪时不会重启：设备先校验通过再切分区，失败只更新 `reason`。
- 固件文件不上传、不落盘到设备之外；URL 通道可完全不选文件：
  升级面板的「URL 拉取」输入框保存地址（`ota_set`）后点「应用并重启」（`ota_apply`）
  即可，也可在「快捷指令」里直接使用这三条命令。
- 断点续传由应用自动判定：仅当设备上存在 `source=tcp` 且 `total` 与所选文件一致的
  `receiving` 会话时才跳过 `ota_push_begin` 续传，URL 拉取的会话不会被误接管。
- 升级后新镜像需通过启动自检才会被确认，失败自动回滚，此时读到的是旧版本。
