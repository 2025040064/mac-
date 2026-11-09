# Astrspire Serial

面向 STM32 调试的 macOS 原生串口终端与实时波形工具。支持 Apple Silicon，最低系统为 macOS 14。

## 运行与构建

源码仓库不包含构建产物。使用以下命令生成 `dist/Astrspire Serial.app`；应用使用本地临时签名，未经过 Apple 公证：

```sh
./Scripts/build-app.sh
```

开发时可用 Xcode 16 或更新版本打开 `Package.swift`，选择 `AstrspireSerial` 方案运行。ORSSerialPort 2.1.0 作为本地 Swift Package 依赖，离线即可构建。其许可证和修改说明保存在 `Vendor/ORSSerialPort`。

## 操作

- 在顶部选串口和波特率，点 **连接**。默认是 115200、8N1、无流控。自动重连要求端口路径相同，且能找到唯一匹配的 USB 序列号。
- 终端支持文本、HEX、搜索、方向筛选、暂停和清空。双击或右键日志条目打开字节分析面板。发送区支持 UTF-8、HEX、换行、历史、收藏和定时发送。
- 波形模式选择 FireWater 或 JustFloat。FireWater 示例为 `d:1.2,2.35,3.6\n`；JustFloat 使用小端 Float32 与帧尾 `00 00 80 7F`。两种模式均只解析数值采样。没有硬件时可在波形页选择内置模拟信号。
- 在波形页设置 STM32 的采样间隔。横轴显示基于间隔和有效帧序号推算的相对时间。滚轮缩放，拖动查看历史，点击绘图区设置当前选中的 A 或 B 游标。
- 窗口顶部可导出 TXT 日志和原始 RX；波形页可导出当前采集段的 CSV 与 PNG。TXT 每行记录时间、方向和 HEX。CSV 每行对应一组采样。

终端右侧调试面板可以选择串口和波特率，发送区的“快捷指令”按钮可收藏、载入或发送指令。拖动面板分隔线可调整发送区和波形区域的大小。

界面保留最近 1,600 条日志和每个采集段最近 120,000 组波形。暂停界面时仍写入采集文件。连接、切换协议或采样间隔、切换模拟源及清空波形会开启新采集段。统计按当前段的全部样本计算。采集文件保存在 `~/Library/Application Support/Astrspire Serial/Captures/`，每次运行最多写入 512 MiB，达到上限或写入失败会提示并停止采集。旧采集目录可在 Finder 中管理。

## 验证

```sh
swift test --disable-xctest
```

测试覆盖协议示例和任意分包、非法输入、缓冲上限、CRC、虚拟串口回环、重连以及 23,000 组八通道采样和无损导出。实体设备验收时，用 STM32 和所用 USB 串口驱动确认波特率、流控、拔插重连与长时间采集。

若 Command Line Tools 的 SwiftPM 未自动加载 Swift Testing 宏，可显式指定本机插件：

```sh
testing_plugin="$(xcode-select -p)/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
swift test --disable-xctest -Xswiftc -load-plugin-library -Xswiftc "$testing_plugin"
```
