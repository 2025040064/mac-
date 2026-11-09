# GoalTracker

macOS 27+ 自用备赛与学习看板。主应用可管理赛程。玻璃倒计时卡片和桌面大号小组件显示最近截止的待完成赛事。

## 直接打开本机版

双击 `dist/GoalTracker.app`。按住玻璃卡片上方或下方的留白可拖动。点击中间内容或按 ⌘L 打开赛程窗口，新增赛事后卡片会显示标题和动态倒计时。用 `Scripts/build-local-app.sh` 可重新打包，脚本使用本机架构和 macOS SDK。

本机版使用独立的应用支持目录保存赛程，并提供可拖动的倒计时窗口。安装原生 WidgetKit 小组件请使用下面的 Xcode 工程。

## 在本机运行 WidgetKit 版

1. 使用包含 macOS 27 SDK 的完整 Xcode 打开 `GoalTracker.xcodeproj`。
2. 在两个目标的 **Signing & Capabilities** 中选择同一个可用于 App Groups 的签名团队。工程使用 macOS 的团队前缀格式 `<TeamID>.com.goaltracker`。两个目标的 entitlement 和 Info.plist 必须使用同一个展开后的标识。
3. 运行 **GoalTracker** scheme。打开 macOS 桌面的「编辑小组件」，搜索 GoalTracker 并添加大号小组件。点击小组件应打开赛程窗口。

只有 Command Line Tools 的环境不能执行 Xcode 的签名构建。签名后可用 `codesign -d --entitlements :-` 分别检查 app 和内嵌的 appex 是否带有相同的 App Group。

## 导入赛程

两个入口都接收 UTF-8 JSON 数组。必填字段为 `title`、`startDate` 和 `endDate`。日期须包含时区，支持 ISO 8601 小数秒。`id` 省略时生成新的 UUID。如需重复推送并更新原记录，每次使用相同的 UUID。其他文本字段可省略，`isArchived` 默认为 `false`。相同 ID 的导入会用完整记录更新原记录，批次内出现重复 ID 或其他无效数据时整批拒绝。

将以下内容保存为 `competitions.json`，在工具栏选择「导入 JSON」并确认。

```json
[
  {
    "id": "65538CB8-B9AD-4362-B5F3-2E82DC1FDF27",
    "title": "数学建模备赛",
    "category": "本科组",
    "startDate": "2027-03-12T09:00:00+08:00",
    "endDate": "2027-03-14T18:00:00+08:00",
    "location": "线上",
    "remarks": "提交论文和附件",
    "isArchived": false
  }
]
```

本机 AI 可在应用运行期间推送同一份 JSON。应用「设置」显示服务状态和 Bearer Token。HTTP 请求须包含 `Content-Length`，请求体上限为 1 MiB。

```sh
curl --fail-with-body http://127.0.0.1:18765/competitions \
  -H "Authorization: Bearer ${GOALTRACKER_TOKEN}" \
  -H 'Content-Type: application/json' \
  --data-binary @competitions.json
```

成功响应形如 `{"inserted":1,"updated":0}`。再次推送同一 UUID 时，响应计入 `updated`。失败返回 HTTP 错误码和 `error` 字段。

## 实机验收

- 新增、编辑、归档、恢复和删除一项赛程，退出并重新打开应用检查记录。
- 导入样例后修改标题并用 HTTP 重新推送，检查原记录更新且数量不变。推送错误令牌和一批包含无效日期的数据，检查原数据保持完整。
- 创建开始顺序与截止顺序不同的两项赛事，确认小组件优先显示截止时间最近的。检查长标题、深浅色、空状态、点击唤起和赛程到期后的切换。小组件实际重绘时间由 macOS 调度。
