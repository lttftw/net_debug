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

### 可写配置键

| 键 | 类型与范围 |
|---|---|
| `wifi_ssid` | string，最多 32 字节 |
| `wifi_pass` | string，最多 64 字节 |
| `mqtt_host` | string，最多 127 字节 |
| `mqtt_port` | number，1–65535 |
| `mqtt_device`、`mqtt_product` | string，最多 63 字节 |
| `mqtt_user`、`mqtt_pass` | string，最多 63 字节 |
| `mqtt_service` | string，最多 31 字节 |
| `mqtt_up_topic`、`mqtt_svc_topic` | string，最多 95 字节 |
| `mqtt_prop_map` | string，最多 287 字节 |
| `mqtt_uptime_min`、`mqtt_uptime_up` | number，500–3600000 ms |
| `counterN_gpio` | number；N=0–3，可取 GPIO 4–7，四路不得重复；默认依次为 7/6/5/4 |
| `counterN_level` | number；`0` 低有效，`1` 高有效 |
| `counterN_db_ms` | number，0–60000 ms（0=关闭起点间隔去抖） |
| `counterN_valid_ms` | number；0=关闭，或 1–60000 ms |
| `counterN_pull` | number；`0` 悬空，`1` 上拉 |

`counterN_db_ms`：**起点间隔去抖**（单位 ms，相邻被接受脉冲的起点沿间隔）。
默认 `0`（关闭）：每个完整脉冲（释放沿）都计数；非零时要求相邻起点间隔
≥ 该值，用于抑制机械触点抖动造成的重复计数。

`counterN_valid_ms`：**最小有效脉宽过滤**（单位 ms，有效电平 = 光耦导通时
输入所处电平）。设为非零后，一次输入脉冲只有在"输入处于有效电平的持续时长
≥ 该值"时才会计数；脉宽不足的脉冲被视为毛刺丢弃，不计入计数。默认
`0`（关闭），此时只按 `counterN_db_ms` 的沿间隔去抖工作（若也为 0 则完全
不做过滤）。修改后立即生效。

WiFi 凭据和 MQTT 服务器参数写入后，用 `test` 命令测试并应用。其他运行参数
写入后立即生效；计数器 GPIO、有效电平、上拉方式在重启后生效。

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
{"counter":{"op":"reset_all"}}
```

`channel` 范围为 0–3。

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
