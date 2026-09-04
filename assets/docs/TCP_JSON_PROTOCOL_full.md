# ESP32-C3 TCP JSON 接入协议

设备在 softAP 开启时提供 TCP 管理服务：

| 项目 | 值 |
|---|---|
| 地址 | `192.168.4.1:8080` |
| 编码 | UTF-8 |
| 请求 | 顶层只有一个字段的 JSON 对象 |
| 响应 | 单行 JSON，以 `\n` 结束 |
| 单条请求上限 | 2304 字节 |
| 同时连接 | 1 个管理客户端 |

客户端应按“发送一条命令，读取一条响应”的顺序工作。TCP 没有消息边界，设备
支持拆包和连续发送多个 JSON 对象。浏览器不能直接建立 TCP 连接，可使用仓库内
的 `tools/tcp_web` 调试工具。

## 数据类型规则

- 布尔参数只接受 JSON 布尔值 `true`、`false`，不接受数字 `1`、`0`。
- `scan`、`reset` 是动作型单值命令，仅在值为 `true` 时执行。
- 动作型命令传 `false`，以及所有布尔字段传 `0`/`1`，均返回：

```json
{"ok":false,"error":"invalid_value"}
```

- GPIO、端口、时间、通道号等数值参数仍使用 JSON 数字，不加引号。
- 字符串参数必须使用 JSON 字符串。

## 通用响应

```json
{"ok":true}
{"ok":false,"error":"invalid_value"}
```

| `error` | 含义 |
|---|---|
| `invalid_json` | JSON 语法或顶层结构错误 |
| `unknown_command` | 不支持的顶层命令或读取键 |
| `invalid_value` | 字段类型、取值、结构或写入配置键错误 |
| `save_failed` | 保存、扫描、测试或 OTA 操作失败 |
| `too_large` | 请求超过长度上限 |
| `forbidden` | MQTT 下发试图使用仅限本地 TCP 的命令或配置键 |

## 完整指令索引

下表列出固件当前接受的全部顶层指令组合。除特别说明外，对象字段必须完整且不应
增加无关字段；顶层始终只能有一个字段。

| 功能 | 请求格式 | TCP | MQTT | 参数限制 |
|---|---|:---:|:---:|---|
| 读取状态 | `{"get":"status"}` | 是 | 是 | 无 |
| 读取全部配置 | `{"get":"config"}` | 是 | 是 | 密码脱敏 |
| 读取单项 | `{"get":"<配置键>"}` | 是 | 是 | 可读取下表全部键 |
| 读取联动 | `{"get":"linkage"}` | 是 | 是 | 无 |
| 读取日志状态 | `{"get":"log"}` | 是 | 是 | 无 |
| 读取扫描结果 | `{"get":"scan"}` | 是 | 否 | MQTT 返回 `forbidden` |
| 读取 OTA 状态 | `{"get":"ota"}` | 是 | 否 | MQTT 返回 `forbidden` |
| 读取连接测试结果 | `{"get":"last_submit"}` | 是 | 否 | MQTT 返回 `forbidden` |
| 写入单项 | `{"set":{"key":"<键>","value":<值>}}` | 是 | 白名单 | 权限见下表 |
| 原子批量写入 | `{"patch":{"<键>":<值>,...}}` | 是 | 白名单 | 1–12 项；禁止重复键；任一项失败则全部不写入 |
| WiFi 扫描 | `{"scan":true}` | 是 | 否 | 只接受 `true` |
| 连接测试 | `{"test":"wifi"}`、`{"test":"mqtt"}` | 是 | 否 | 异步执行 |
| 日志开关 | `{"log":{"enabled":true}}` | 是 | 是 | `enabled` 为布尔值；对象只能含此字段 |
| 计数加一 | `{"counter":{"channel":0,"op":"inc"}}` | 是 | 是 | `channel` 为 0–3 |
| 计数清零 | `{"counter":{"channel":0,"op":"reset"}}` | 是 | 是 | `channel` 为 0–3 |
| 计数设为指定值 | `{"counter":{"channel":0,"op":"set","value":34}}` | 是 | 是 | `channel` 为 0–3；`value` 为 0–4294967295 |
| 全部计数清零 | `{"counter":{"op":"reset_all"}}` | 是 | 是 | 不带 `channel` |
| 手动输出 | `{"output":{"id":0,"value":true}}` | 是 | 是 | `id` 为 0–1；`value` 为布尔值 |
| 输出联动 | `{"linkage":{"output":0,"expression":"c0>=1","true":true}}` | 是 | 是 | `output` 为 0–1；表达式最多 127 字节 |
| 关闭 softAP | `{"mode":"normal"}` | 是 | 否 | 只接受 `normal` |
| 重启 | `{"reset":true}` | 是 | 否 | 只接受 `true` |
| OTA 开始 | `{"ota":{"op":"begin","size":428736}}` | 是 | 否 | `size` 为正整数且不得超过目标 OTA 分区容量 |
| OTA 分块 | `{"ota":{"op":"chunk","offset":0,"data":"E903..."}}` | 是 | 否 | 原始数据最多 1024 字节；十六进制长度必须为偶数 |
| OTA 状态 | `{"ota":{"op":"status"}}` | 是 | 否 | 无 |
| OTA 校验 | `{"ota":{"op":"finish"}}` | 是 | 否 | 必须已写满声明长度 |
| OTA 中止 | `{"ota":{"op":"abort"}}` | 是 | 否 | 无 |
| OTA 应用 | `{"ota":{"op":"apply"}}` | 是 | 否 | 仅在 `ready` 状态可用 |

## 状态与配置

### 读取

```json
{"get":"status"}
{"get":"config"}
{"get":"mqtt_host"}
{"get":"last_submit"}
{"get":"scan"}
{"get":"linkage"}
{"get":"ota"}
{"get":"log"}
```

`status` 返回运行模式、WiFi/MQTT 状态、计数值、输出状态和剩余堆内存。
`config` 返回当前配置；密码不返回明文，只通过 `wifi_pass_set`、
`mqtt_pass_set` 表示是否已设置。读取单个密码项同样只返回 `set`：

```json
{"ok":true,"key":"wifi_pass","set":true}
```

### 写入单项

```json
{"set":{"key":"mqtt_host","value":"192.168.1.10"}}
{"set":{"key":"mqtt_port","value":1883}}
{"set":{"key":"wifi_ssid","value":"Office"}}
{"set":{"key":"wifi_pass","value":"your-wifi-password"}}
```

### 原子批量写入

```json
{"patch":{"wifi_ssid":"Office","wifi_pass":"your-wifi-password","mqtt_host":"192.168.1.10","mqtt_port":1883}}
```

一次最多写入 12 项；任一项无效时整批不写入。

### 完整配置键与写入权限

下表中的键全部可由 TCP 或 MQTT 使用 `get` 读取。`wifi_pass`、`mqtt_pass` 仅返回
是否已设置。这里的 MQTT 写入是设备端白名单，不代表云端还会允许任意发布者写入。

| 键 | 类型与范围 | TCP 写入 | MQTT 写入 | 生效方式 |
|---|---|:---:|:---:|---|
| `wifi_ssid` | string，最多 32 字节 | 是 | 否 | `test wifi` 成功后应用 |
| `wifi_pass` | string，最多 64 字节 | 是 | 否 | `test wifi` 成功后应用 |
| `mqtt_host` | string，最多 127 字节 | 是 | 否 | `test mqtt` 成功后应用 |
| `mqtt_port` | number，1–65535 | 是 | 否 | `test mqtt` 成功后应用 |
| `mqtt_device`、`mqtt_product` | string，最多 63 字节 | 是 | 否 | 立即重载 MQTT |
| `mqtt_user`、`mqtt_pass` | string，最多 63 字节 | 是 | 否 | `test mqtt` 成功后应用 |
| `mqtt_service` | string，最多 31 字节 | 是 | 否 | 立即重载 MQTT |
| `mqtt_up_topic`、`mqtt_svc_topic` | string，最多 95 字节 | 是 | 否 | 立即重载 MQTT |
| `mqtt_prop_map` | string，最多 287 字节 | 是 | 是 | 立即重载映射；完整参数见下节 |
| `mqtt_uptime_min`、`mqtt_uptime_up` | number，500–3600000 ms | 是 | 是 | 立即生效 |
| `counterN_gpio` | number；N=0–3，可取 GPIO 4–7，最终四路不得重复；默认 7/6/5/4 | 是 | 是 | 重启后生效 |
| `counterN_level` | number；`0` 低有效，`1` 高有效 | 是 | 否 | 重启后生效 |
| `counterN_db_ms` | number，0–60000 ms；默认 50 | 是 | 是 | 立即生效 |
| `counterN_valid_ms` | number，0–60000 ms；默认 50 | 是 | 是 | 立即生效 |
| `counterN_pull` | number；`0` 悬空，`1` 上拉 | 是 | 否 | 重启后生效 |
| `counter0`–`counter3` | uint32 运行计数 | 否 | 否 | 用 `counter` 指令修改 |
| `out0_link_expr`、`out1_link_expr` | string，最多 127 字节 | 否 | 否 | 用 `linkage` 指令修改 |
| `out0_link_true`、`out1_link_true` | number，0 或 1 | 否 | 否 | 用 `linkage` 指令修改 |

`counterN_db_ms`：**起点间隔去抖**（单位 ms，相邻被接受脉冲的起点沿间隔）。
默认 `50`：非零时要求相邻起点间隔 ≥ 该值，用于抑制机械触点抖动造成的重复
计数；设 `0`（关闭）则每个完整脉冲（释放沿）都计数。

`counterN_valid_ms`：**最小有效脉宽过滤**（单位 ms，有效电平 = 光耦导通时
输入所处电平）。设为非零后，一次输入脉冲只有在"输入处于有效电平的持续时长
≥ 该值"时才会计数；脉宽不足的脉冲被视为毛刺丢弃，不计入计数。默认
`50`；设 `0`（关闭），此时只按 `counterN_db_ms` 的沿间隔去抖工作（若也为 0
则完全不做过滤）。修改后立即生效。

WiFi 凭据和 MQTT 服务器参数写入后，用 `test` 命令测试并应用。其他运行参数
写入后立即生效；计数器 GPIO、有效电平、上拉方式在重启后生效。

### `mqtt_prop_map` 完整映射参数

正确配置键是 `mqtt_prop_map`；`mqtt_map` 不是有效配置键。格式为逗号分隔的
`属性名=数据源`：

```text
device_runtime=runtime,input_0=counter0,output_0=output0,device_ip=ip
```

每项开头的空格或制表符会被跳过，除此之外，等号左侧属性名将原样成为属性上报
`params` 中的 JSON 键。固件最多装载 16 条有效映射，属性名最多保留 31 字节；
建议使用不重复的短名称。全部可用数据源如下：

| 数据源 | 上报类型 | 值 |
|---|---|---|
| `runtime` | number | 本次启动运行秒数 |
| `counter` | number | `counter0` 的兼容别名 |
| `counter0`、`counter1`、`counter2`、`counter3` | number | 四路 uint32 计数值 |
| `output0`、`output1` | bool | 两路继电器当前逻辑状态 |
| `heap` | number | 当前空闲堆内存字节数 |
| `minheap` | number | 本次启动以来最小空闲堆内存字节数 |
| `rssi` | number | STA RSSI，单位 dBm；未连接时通常为 `-127` |
| `linkgen` | number | WiFi 链路状态变更代数 |
| `ip` | string | STA IPv4 地址；未连接时为空字符串 |

固件默认值为：

```text
device_runtime=runtime,input_0=counter0,input_1=counter1,input_2=counter2,input_3=counter3,output_0=output0,output_1=output1,device_ip=ip
```

数据源名称区分大小写，等号两侧不要添加空格。未知数据源、空属性名和格式错误项
会在加载时被忽略，而配置写入本身仍可能返回成功；重复属性名不会被拒绝。属性
上报完整 JSON 使用固定容量缓冲区，映射较多时应保持属性名简短。

`mqtt_uptime_up` 是周期上报期望间隔，`mqtt_uptime_min` 是最小上报间隔，实际
周期为两者的较大值。映射中的计数器或输出变化可触发提前上报，但仍受
`mqtt_uptime_min` 限制；其他数据源只随周期上报。

### MQTT 主题模板参数

| 模板 | 支持的替换参数 | 说明 |
|---|---|---|
| `mqtt_up_topic` | `$(pkey)`、`$(dev)` | 分别替换产品名、设备名；不要在上行模板使用 `$(svc)` |
| `mqtt_svc_topic` | `$(pkey)`、`$(dev)`、`$(svc)` | `$(svc)` 替换当前 `mqtt_service` |
| 回复 Topic | 同服务模板 | `$(svc)` 替换为 `<mqtt_service>_reply` |

未知占位符保持原样。展开后的 Topic 必须少于 192 字节。

## MQTT 下发 TCP JSON 指令

向 MQTT 服务 Topic 直接发送与 TCP 完全相同的 JSON 指令：

```json
{"counter":{"channel":0,"op":"inc"}}
```

整个 MQTT 下行 JSON 必须小于 512 字节。

设备在对应的 `service_reply` 主题回复：

```json
{"ok":true}
```

为兼容已有 Yelink 服务调用，也接受
`{"id":"42","version":"1.0","method":"thing.service.service1","params":{...指令...}}`
外壳；这种格式的回复保留 `id`、`code` 和 `data` 外壳，且 `params` 小于 384
字节。新接入优先使用上述裸 JSON 格式。

MQTT 入口采用固件白名单：

- 顶层命令：`get`、`set`、`patch`、`counter`、`output`、`linkage`、`log`。
- `get`：`status`、`config`、`linkage`、`log` 和全部配置键；密码只返回是否已设置，
  不返回明文。
- `set`/`patch`：`mqtt_prop_map`、`mqtt_uptime_min`、`mqtt_uptime_up`、
  `counterN_gpio`、`counterN_db_ms`、`counterN_valid_ms`。

WiFi 配置、MQTT 服务器/认证/设备与产品身份、服务和主题模板、计数器有效电平/
上拉的写入，以及 `scan`、`test`、`mode`、`reset`、`ota` 均只能
通过本地 TCP 使用。MQTT 请求这些命令或写入键时，裸 JSON 回复返回：

```json
{"ok":false,"error":"forbidden"}
```

混合了允许键和禁止键的 `patch` 整批拒绝，不写入任何字段。MQTT 连接断开或
OTA 暂停网络期间无法接收下发指令。

通过 MQTT 启用 `log` 后，`event=log` 异步消息发布到同一个 `_reply` Topic，
采用 QoS 0；执行 `{"log":{"enabled":false}}` 可停止日志流。

## WiFi 扫描与连接测试

启动扫描：

```json
{"scan":true}
```

查询扫描结果：

```json
{"get":"scan"}
```

测试已保存的 WiFi 或 MQTT 参数：

```json
{"test":"wifi"}
{"test":"mqtt"}
```

测试是异步操作，提交成功后返回：

```json
{"ok":true,"action":"testing"}
```

随后查询结果：

```json
{"get":"last_submit"}
```

```json
{"ok":true,"last_submit":{"kind":"wifi","done":true,"result":true,"reason":"","time":23014}}
```

## 计数器、输出与联动

计数器：

计数值范围为 `0`–`4294967295`；物理脉冲和 `inc` 在达到上限后保持饱和，
不会回绕为 `0`。

```json
{"counter":{"channel":0,"op":"inc"}}
{"counter":{"channel":0,"op":"reset"}}
{"counter":{"channel":2,"op":"set","value":100}}
{"counter":{"op":"reset_all"}}
```

`channel` 范围为 0–3；`set` 的 `value` 范围为 0–4294967295，直接把该路运行值
设为指定值（可用于测试联动规则），同样触发联动重评估。设备本体 GPIO10 按键
**双击**同样会执行 `reset_all`（清除全部计数），无需管理连接；长按 3 秒则开关
softAP。

手动控制输出：

```json
{"output":{"id":0,"value":true}}
{"output":{"id":1,"value":false}}
```

`id` 范围为 0–1，`value` 必须是布尔值。

设置联动规则：

```json
{"linkage":{"output":0,"expression":"c0>=100&&c1<20","true":true}}
{"linkage":{"output":1,"expression":"c2==5","true":false}}
```

| 字段 | 说明 |
|---|---|
| `output` | 输出编号 0–1 |
| `expression` | 条件表达式；空字符串关闭该路联动 |
| `true` | 表达式成立时的输出电平，必须是布尔值 |

表达式支持 `c0`–`c3`、无符号整数、`>`、`<`、`==`、`>=`、`<=`、`!=`、
`&&`、`||` 和括号。读取当前规则使用：

```json
{"get":"linkage"}
```

## 日志、softAP 与重启

开启或关闭实时日志：

```json
{"log":{"enabled":true}}
{"log":{"enabled":false}}
```

开启后，设备会在普通响应之间发送以下事件，客户端应按 `event` 字段分流：

```json
{"event":"log","data":"I (2752) wifi_prov: got IP","dropped":0}
```

关闭 softAP：

```json
{"mode":"normal"}
```

重新开启 softAP 需长按设备按键 3 秒，STA 断链时设备也会自动开启。AP 关闭后
TCP 连接随即关闭。

重启设备：

```json
{"reset":true}
```

计数器持久化成功后，设备返回以下响应并重启：

```json
{"ok":true,"action":"rebooting"}
```

若重启前的计数器持久化连续重试失败，设备返回 `save_failed` 且不重启。
`{"reset":false}` 不执行重启，并返回 `invalid_value`。

## TCP OTA

OTA 分块中的固件数据使用十六进制字符串，每块原始数据最多 1024 字节，
`offset` 必须等于设备已经写入的字节数。

按顺序发送：

```json
{"ota":{"op":"begin","size":428736}}
{"ota":{"op":"chunk","offset":0,"data":"E903..."}}
{"ota":{"op":"status"}}
{"ota":{"op":"finish"}}
{"ota":{"op":"apply"}}
```

中止上传：

```json
{"ota":{"op":"abort"}}
```

从 `begin` 成功到 `abort`、失败或 `apply` 结束期间，OTA 独占当前管理会话。
结构完整的非 OTA JSON 指令会被忽略且不返回响应；非 JSON 数据或畸形 JSON
不会收到错误响应，但设备会关闭当前 TCP 连接。`apply` 前会先持久化计数器：
持久化失败时返回 `save_failed`，不会切换启动分区或重启；成功后返回
`{"ok":true,"action":"ota_rebooting"}`，随后设备重启。
