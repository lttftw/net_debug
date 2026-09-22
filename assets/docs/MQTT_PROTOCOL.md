# 调试工具协议说明（MQTT 篇）

本文档为随应用发布的演示示例。使用 MQTT 调试工具时，请结合目标
设备或服务的实际协议，自行维护指令模板与协议说明（个人完整版可通过
`--dart-define=APP_PROFILE=full` 构建时启用完整文档）。

## 通道基础

| 项目 | 值 |
|---|---|
| 传输 | 纯 TCP MQTT（无 TLS），默认端口 1883 |
| clientId | `${deviceName}&${productKey}`，由 `mqtt_device` / `mqtt_product` 配置键拼装 |
| keepalive | 60 s |
| 属性上报 QoS | 0（`retain=0`） |
| 服务订阅/回复 QoS | 1（`retain=0`） |

### Topic 模板

topic 模板保存在设备状态表，占位符 `$(pkey)` / `$(dev)` / `$(svc)` 运行时展开：

| 模板 | 默认值 | 占位符 |
|---|---|---|
| `mqtt_up_topic`（上行属性上报） | `/sys/$(pkey)/$(dev)/thing/event/property/post` | `$(pkey)`、`$(dev)` |
| `mqtt_svc_topic`（服务下行，逐服务订阅） | `/sys/$(pkey)/$(dev)/thing/service/$(svc)` | `$(pkey)`、`$(dev)`、`$(svc)` |
| 服务回复（固件发布） | 同服务模板 | `$(svc)` 替换为 `<标识>_reply` |

## 上行：属性上报

发布到 `mqtt_up_topic`，信封固定：

```json
{"id":"1","version":"1.0","method":"thing.event.property.post","params":{…}}
```

上报哪些属性由状态表键 `mqtt_prop_map` 决定（格式 `属性名=数据源,...`，
最多 16 条）。示例默认映射：

```text
device_runtime=runtime,input_0=counter0,input_1=counter1,input_2=counter2,input_3=counter3,output_0=output0,output_1=output1,di_0=di0,di_1=di1,di_2=di2,di_3=di3
```

## 下行：两种报文模式

### 信封服务调用（平台标准模式）

发布到 `/sys/<产品名>/<设备名>/thing/service/<标识>`：

```json
{"id":"42","version":"1.0","method":"thing.service.counter_write","params":{"channel":0,"value":100}}
```

回复发布到 `<标识>_reply`，信封：

```json
{"id":"42","version":"1.0","code":200,"data":{"msg":"成功","params":{"status":"成功","ok":true}}}
```

### 原生裸 JSON 模式（仅 `config` 开发者通道）

向服务 topic 发送**没有 `method` 字段的扁平 JSON 对象**。1.5.0 起只有 `config`
接受这种报文：用户面 14 个服务缺 `method` 一律以 `service_mismatch` 拒绝，
不再当作管理命令执行。`config` 的裸 JSON 由设备直接交给命令分发器，响应以
裸 JSON 回到 `config_reply`：

```json
{"get":"config"}
{"counter0":100}
```

## 变量占位符

指令与主题模板中支持 `$(变量名)` 占位符，发送时由「模板变量」自动替换：

```json
{"mqtt_uptime_min":500}
```

## 内置示例指令

应用内置少量示范指令（见「快捷指令」），用于展示指令格式与交互方式。
完整的指令模板请结合你的实际设备协议自行维护。
