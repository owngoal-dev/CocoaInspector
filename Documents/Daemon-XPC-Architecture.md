# CCPI Swift LaunchDaemon / XPC 架构调查

本文定义 CCPI 在 iOS 16.0+ 越狱环境中的进程边界、XPC 安全边界、按需采样生命周期和 jetsam/内存约束。已有完整实机验证基线仍是 iOS 17.3.1 + roothide；iOS 16.x 发布前必须重跑第 13 节清单。当前实现遵循“最小状态、先测量再加复杂度”：XPC connection 已提供的身份和 request/reply 关联不再用 nonce、sequence、request ID 或 CDHash policy 重复表达。

## 目标和硬约束

- Inspector 是 SwiftUI userland App，只负责请求、派生展示数据和用户交互；`cocoainspector` CLI 使用同一个 client/data 层做无 UI 验证和运维。
- Inspector daemon 是纯 Swift root LaunchDaemon，只负责特权采集和被明确请求的受控操作。
- App 和 CLI 两个 userland target 通过同一个低层 XPC Mach service 与 daemon 通信。
- 所有产品代码必须是 Swift；私有 C ABI 符号也由 Swift 声明/动态绑定，不增加 bridging header 或 C/Objective-C shim。
- App 未打开且 CLI 未连接时不采样、不订阅 NSTAT、不枚举详情、不发送 signal。
- 未经认证的连接不能触发任何采样、分配大型 buffer 或取得任何系统数据。
- daemon 只接受 deb 当前安装的 App/CLI 可执行文件，不接受“仅具有同名 entitlement”的其他进程。
- `SIGTERM` / `SIGKILL` 必须来自当前活动、已认证且 lease 有效的 session 的一次性显式请求；不排队、不重试、不跨 session 保存。
- daemon 必须以 jetsam 友好为首要约束：按需启动、固定上限、单请求、无历史、无 UI 格式化数据。
- 普通沙盒 App 不应获得 mach lookup 权限或任何公开数据通道；同时不承诺对 root、越狱 tweak 或系统级检测工具不可见。

## 1. 推荐结论：按需 LaunchDaemon + client-driven pull

不建议让 daemon 自己常驻一个 1 Hz timer 并持续向 App push。推荐由前台 Inspector 发起每次 snapshot 请求：

1. Inspector 前台建立 XPC connection。
2. daemon 只做廉价客户端认证，认证成功后仍处于 idle。
3. Inspector 根据 UI 刷新周期发起一个 `snapshot` request。
4. daemon 完成一次采样并回复；上一请求结束前不允许下一请求并发。
5. Inspector 收到回复后才安排下一次请求。
6. Inspector 进入后台或连接断开后，daemon 关闭该连接的 NSTAT 等会话资源；最后一个连接消失后主动退出。

这种 pull 模型天然满足：App 不运行就没有 request，没有 request 就没有采样；同时 request/reply 自带背压，不需要 daemon 维护推送队列。

网络统计是唯一需要跨 snapshot 保持短期状态的 collector。它只在已认证前台 session 明确请求 network capability 时打开，并受 lease 保护；最后一个合法 session 消失时立即关闭。

## 2. 总体 ASCII 架构

```text
 root/mobile platform + no-sandbox                   root / unsandboxed

 +----------------------------------+      XPC       +----------------------------------+
 | Inspector.app / cocoainspector  |<------------->| cocoainspectord (Swift)           |
 |                                  | Mach service   |                                  |
 |  +----------------------------+  |               |  +----------------------------+  |
 |  | View / sort / filter       |  |               |  | PeerAuthenticator          |  |
 |  | format / icons / history   |  |               |  | audit token + entitlement  |  |
 |  +----------------------------+  |               |  | canonical root-owned path  |  |
 |                ^                 |               |  +-------------+--------------+  |
 |                | raw snapshot    |               |                | accepted        |
 |  +-------------+--------------+  |               |  +-------------v--------------+  |
 |  | XPC client / session lease |  |               |  | RequestGate                |  |
 |  +----------------------------+  |               |  | version / operation / caps |  |
 +----------------------------------+               |  +------+------+--------------+  |
                                                    |         |      |                 |
             launchd owns service name              |   sample|      |explicit action  |
 +----------------------------------+               |  +------v--+ +-v--------------+  |
 | wiki.qaq.inspector.service       |               |  |Sampler  | |SignalGate      |  |
 | RunAtLoad: false                 |               |  |raw facts| |PID+birth check |  |
 | KeepAlive: false                 |               |  +----+----+ +-------+---------+  |
 +----------------------------------+               |       |              |            |
                                                    |  proc/Mach/NSTAT    kill(2)        |
                                                    +-------+--------------+------------+
                                                            |
                                                +-----------v-----------+
                                                | iOS kernel / processes |
                                                +-----------------------+
```

关键边界：launchd 提供“找到 daemon”的能力；daemon 自己仍必须验证连接方身份。mach lookup entitlement 不是最终认证。

## 3. Target 和文件组织

工程包含三个 Xcode product target：

```text
Inspector.xcodeproj
|
+-- Inspector              iOS App target, Swift / SwiftUI
|   +-- UI
|   +-- shared XPC client / snapshot reducer
|
+-- CocoaInspectorCLI      iOS command-line target, Swift
|   +-- Swift Argument Parser commands
|   +-- shared XPC client / snapshot reducer
|
+-- CocoaInspectord        iOS Mach-O executable target, Swift
    +-- XPC listener
    +-- peer authentication
    +-- collectors
    +-- signal gate
```

协议常量、Codable snapshot value、XPC client 和 delta reducer 通过源文件 target membership 由 App/CLI 复用，不创建 framework。`swift-argument-parser` 只链接 CLI，不进入 daemon；App/CLI 不链接 collector，daemon 不链接 SwiftUI/UIKit 或 ArgumentParser。

建议安装位置（下列路径相对于 jailbreak root；roothide 由 dpkg 映射到随机 jbroot，rootless 打包时统一加 `/var/jb` 前缀）：

```text
/Applications/Inspector.app/Inspector
/usr/bin/cocoainspector
/usr/libexec/cocoainspectord
/Library/LaunchDaemons/wiki.qaq.cocoainspectord.plist
```

daemon 用自身 `proc_pidpath` 推导安装根目录再拼出 client 路径，因此两种 jailbreak 布局共用同一份 `InspectorProtocol.clientPaths`。

daemon、App executable 和 CLI 由 deb 以 root:wheel 安装，且不可被 group/other 写入。

## 4. LaunchDaemon 行为

推荐 plist 语义：

- `Label`: `wiki.qaq.cocoainspectord`。
- `ProgramArguments`: `<prefix>/usr/libexec/cocoainspectord`；roothide 前缀为空并在安装时映射到当前随机 jbroot，rootless 前缀为 `/var/jb`。
- `UserName`: `root`。
- `MachServices`: 只发布 `wiki.qaq.inspector.service`。
- 不设置 `RunAtLoad=true`。
- 不设置 `KeepAlive=true`。
- `ProcessType`: Background，或在实机比较后使用系统默认；不使用 Interactive 抬高 jetsam/调度影响。
- `Umask`: 077。
- `DISABLE_TWEAKS=1`，减少第三方 tweak 注入 daemon 的攻击面和额外内存。
- 不配置 TCP、UDP、Bonjour、UNIX domain socket、临时文件或共享 App Group 作为 IPC。

launchd 在 Inspector 首次 lookup Mach service 时按需启动 daemon。daemon 最后一个连接关闭后进入很短的 idle grace，然后正常退出；下次由 launchd 重启。

不要在未实机验证前照搬未公开的 `JetsamProperties` 键。控制实际 resident/phys footprint 比依赖私有 plist 参数更可靠。

## 5. 纯 Swift XPC 可行性

### 5.1 SDK 现状

本机 iPhoneOS 27 SDK 的 `XPC` module 可以由 Swift 导入，但以下低层函数被头文件显式标记为 iOS unavailable：

- `xpc_connection_create_mach_service`。
- `xpc_connection_get_pid`。

同一 SDK 的 `libSystem.B.tbd` 仍导出：

- `_xpc_connection_create_mach_service`。
- `_xpc_connection_get_audit_token`。
- `_xpc_copy_entitlement_for_token`。
- `_proc_pidpath_audittoken`。

已经用一个纯 Swift arm64 iOS 17.0 probe 验证：使用 Swift `@_silgen_name` 为前两个 XPC 符号声明私有别名，可以通过 typecheck 并生成 Mach-O arm64 object，不需要 C/Objective-C shim。

这只是编译证据。iOS 17.3.1 设备仍需验证符号存在、listener/client 激活、audit token 和 entitlement 读取的真实运行行为。

### 5.2 推荐封装

- 在一个很小的 `XPCPrivate.swift` 中集中声明/解析所有私有 ABI。
- 更重视运行时兼容时，用 Swift 调用 `dlsym` 一次并缓存 typed function pointer；找不到符号就 fail closed。
- target 只支持 iOS 17.3.1 时，可以直接使用 Swift `@_silgen_name`，但每个符号仍要有启动自检。
- 不使用 bridging header、modulemap 或 Objective-C wrapper。
- 不使用 `NSXPCConnection`；采用 `xpc_connection_t`、`xpc_dictionary_t`、`xpc_data` 的低层 request/reply。

Apple 的 header 明确说明 `xpc_connection_set_peer_code_signing_requirement` 在 embedded platform 不受支持并返回 `ENOTSUP`，因此 iOS 上不能把它当认证方案。

## 6. 客户端访问控制

### 6.1 第一层：sandbox mach lookup

Inspector App 和 `cocoainspector` CLI 签名加入：

```text
com.apple.security.exception.mach-lookup.global-name
    -> wiki.qaq.inspector.service

platform-application
    -> true

com.apple.private.security.no-sandbox
    -> true

wiki.qaq.inspector.client
    -> true
```

普通沙盒 App 没有 lookup/no-sandbox/platform entitlement，正常情况下无法 lookup 这个全局 Mach service。daemon 仍会从连接的 audit token 再次校验这些布尔 entitlement、UID 和实际 executable path。

### 6.2 第二层：audit token

daemon 必须从 XPC connection/收到的 message 取得 kernel 附带的 `audit_token_t`，不能接受 client message 中自报的 PID、UID、bundle identifier 或 path。

当前只验证不能由 message 自报的事实：audit token 中的 PID 和 effective UID（仅 root/mobile）、`platform-application`、`com.apple.private.security.no-sandbox`、自定义 client entitlement 都严格为布尔 `true`，且 live executable path 等于 deb 安装的 root-owned App 或 CLI 路径。CDHash/identifier allowlist 是未来有真实绕过证据后再加的 hardening，不是当前基础状态。

### 6.4 认证时序

```text
 Inspector               launchd              daemon                 kernel/signing
     |                       |                    |                         |
     | lookup service        |                    |                         |
     |---------------------->| on-demand spawn    |                         |
     |                       |------------------->|                         |
     | XPC connect           |                    |                         |
     |------------------------------------------->|                         |
     |                       |                    | get audit token         |
     |                       |                    |------------------------>|
     |                       |                    | UID + entitlements      |
     |                       |                    |------------------------>|
     |                       |                    | live root-owned path    |
     |                       |                    |----+                    |
     |                       |                    |    |                    |
     | hello                 |                    |<---+ accepted           |
     |------------------------------------------->|                         |
     | lease deadline        |                    |                         |
     |<-------------------------------------------|                         |
     |                       |                    |                         |
     | snapshot request      |                    | one sample only         |
     |------------------------------------------->|----+                    |
     |                       |                    |    |                    |
     | raw snapshot reply    |                    |<---+                    |
     |<-------------------------------------------|                         |
```

未经认证的 connection 立即 cancel，回复最多是固定大小的 generic unauthorized 错误；不透露哪一项校验失败。

### 6.5 威胁边界

此设计防御：

- 普通 sandbox App。
- 知道 service name、但没有 mach lookup entitlement 的 App。
- 能连接、但 entitlement 或实际 executable path 不匹配的进程。
- 客户端在 message 中伪造 PID、bundle ID 或 path。
- 非法/过大 XPC message 导致的内存和解析攻击。

此设计不承诺防御：

- 已获得 root 且能修改 daemon 或 Inspector 的攻击者。
- 注入 daemon/Inspector 的系统级 tweak 或 kernel 攻击者。
- launchd、kernel 或 jailbreak 本体被控制。

## 7. Session 与“没打开就不采样”

不保存一个容易失真的 `isSampling` 布尔量。采样资格由事实派生：

```text
maySample = authenticated connection
         && hello 握手已经完成
         && 当前存在一个合法 snapshot request
         && 当前没有另一采样正在执行
```

推荐状态机：

```text
                    launchd on-demand spawn
                             |
                             v
 +---------+   peer arrives  +----------------+
 | STOPPED |---------------->| IDLE/UNAUTH    |
 +---------+                 +-------+--------+
      ^                              |
      |                              | audit token accepted
      |                              v
      |                      +----------------+
      |      hello only      | AUTHENTICATED  |
      |   (still no sample)  | no collectors  |
      |                      +---+---------+--+
      |                          |         |
      |            snapshot req |         | network capability lease
      |                          v         v
      |                      +------+  +---------+
      |                      | SAMPLE|  | NSTAT ON|
      |                      | once  |  | bounded |
      |                      +--+---+  +----+----+
      |                         |           |
      |                 reply / error       |
      |                         +-----+-----+
      |                               v
      |                      +----------------+
      +----------------------| AUTHENTICATED  |
          disconnect         +----------------+
          / idle grace
```

规则：

- 连接成功不自动采样。
- `hello` 成功也不自动采样。
- 每个 snapshot request 最多触发一次采样。
- 同一 connection 最多一个 in-flight request；重复请求返回 busy，不排队。
- App 收到 reply 后才安排下一次 request。
- App 进入后台先停止 schedule，再发送 `goodbye` 并关闭 XPC connection。
- App 崩溃或被强杀时，以 XPC disconnect/cancel 事件清理对应 session 和 collector。
- daemon 记录所有认证连接；连接数归零后启动 idle grace，宽限内没有新连接便主动退出。
- 当前系统调用已经进入 kernel 时不保证瞬时取消，但返回后必须丢弃结果，不启动下一阶段。
- daemon 不持久化采样计划；重启后永远从 IDLE 开始。

## 8. XPC 协议

### 8.1 通用 envelope

每条 request/reply 都包含：

- `protocolVersion`：无符号整数。
- `operation`：closed enum，不接受任意字符串命令。
- `payload`：按 operation 定义并有独立大小上限。

控制面使用 XPC dictionary 的标量值。snapshot 使用有 2 MiB 上限的 `xpc_data`，当前由系统 `JSONEncoder`/`JSONDecoder` 编码固定 Codable value；如果实机 footprint 数据证明系统 codec 不够，再替换 wire format，而不是提前维护手写 parser。

### 8.2 建议 operation

```text
hello
snapshot
prepareSignal
commitSignal
goodbye
```

不要提供一个接收任意 shell command、signal number、proc flavor、Mach API selector 或文件路径的通用 operation。

### 8.3 Snapshot 内容

daemon 发送原始事实，不发送 53 个已经格式化的字符串：

- generation、monotonic sample time、boot identity。
- 稳定进程身份：PID + process start absolute time。
- kinfo/task/rusage/FD/port/network 的请求字段。
- 每字段 availability/error 位，区分真实 0 与无法读取。
- bounded UTF-8 name/path string table。

App 负责：

- CPU/disk/system-call 等相邻 snapshot delta。
- 新建/退出比较。
- 排序、过滤、单位格式化、颜色。
- bundle metadata、图标和 UI history。

这样 daemon 不保留历史，也不为每一行创建大量 String/Dictionary/NSObject。

### 8.4 Collector mask

snapshot request 携带 closed collector mask，daemon 只运行当前页面真正需要的数据源：

- base process identity。
- task metrics。
- rusage。
- FD count。
- port count。
- network。

Threads、Open Files、Ports、Modules 不属于主 snapshot；只有用户打开对应详情页时才发单次 `processDetails`。

## 9. Signal 安全门

### 9.1 不允许直接发送任意 kill 命令

只定义两个 enum：

- terminate = `SIGTERM`。
- forceKill = `SIGKILL`。

daemon 不接受任意整数 signal，不接受 PID 0/1，不接受自身 PID，也不接受缺少稳定 birth identity 的目标。

### 9.2 两阶段一次性 ticket

```text
 Inspector UI / CLI           daemon                       target process
      |                          |                                |
      | 用户明确确认             |                                |
      | prepareSignal            |                                |
      | {pid,start,TERM/KILL}     |                                |
      |------------------------->| re-read start time/path        |
      |                          | verify exact target identity    |
      | one-time ticket, TTL     |                                |
      |<-------------------------|                                |
      | commitSignal(ticket)     |                                |
      |------------------------->| consume ticket exactly once    |
      |                          | kill(pid, selectedSignal)       |
      |                          |------------------------------->|
      | result                   |                                |
      |<-------------------------|                                |
```

ticket 必须：

- 仅存在于当前 authenticated connection 的 `SignalGate`。
- 绑定 target PID、process start time 和 action。
- 使用固定长度随机值并以 constant-time 比较。
- 只可消费一次。
- 很短 TTL；建议数秒级并由实测决定。
- connection 断开、App 后台或 daemon memory pressure 时全部清除。
- 不写磁盘、不跨 daemon restart 恢复。

commit 前再次读取 process start time，避免 PID 在两步间被复用。失败时不自动 retry；App 必须重新展示当前目标并重新确认。

CLI 的 `self-test` 默认只读；只有显式传入 `self-test --signal` 才会启动一个 CLI 自有子进程，并用同一 prepare/commit 路径向该子进程发送 TERM。它不会选择或终止现有系统进程。

### 9.3 “没打开不 kill”的强制保证

`maySignal` 必须由以下事实同时派生：

```text
maySignal = authenticated session
         && hello 握手已经完成
         && valid unexpired one-time ticket
         && current target identity matches ticket
```

daemon 中不存在定时 kill、queued kill、disconnect cleanup kill、startup kill 或 retry kill。

## 10. Jetsam 和内存设计

### 10.1 daemon 不应拥有的数据

- App icon、UIImage、SwiftUI/UIKit object。
- 53 列格式化字符串。
- 排序后的 UI 数组、filter 结果或选择状态。
- 无限历史、CPU graph 或日志 history。
- 全系统永久 FD/port/module cache。
- bundle Info.plist 字典。
- 多个等待发送的 snapshot。

### 10.2 内存所有权

- 一条 serial sampling queue；不为每个进程创建 Task。
- 同时最多一个 snapshot request 和一个 detail request，总体仍串行执行。
- 两阶段查询后按实际 count 精确分配，绝不按固定 4/16 MiB 为每种数据常驻预留。
- 原始记录使用 Swift value type 和有界数组；snapshot 编码在短 `autoreleasepool` 内完成。
- 字符串有单项长度、总长度和 UTF-8 校验上限。
- 旧 snapshot 回复发送完成后立即释放；App 负责保存相邻两帧。
- memory warning/critical 时立即清除 optional cache、NSTAT state、signal ticket，并拒绝新的大型详情请求。
- daemon 被 jetsam 杀死后不恢复动作；App 重新连接并显示 sample lost。

### 10.3 详情查询的内存优化

Threads：

- 两阶段取得 thread ID 数量和精确 buffer。
- 分批读取并发送；不长期保留线程名对象。

FD/UNIX peer：

- 先枚举目标进程，只保存其 pipe/UNIX object ID 集合。
- 扫描其他进程时只记录命中的 peer，不建立全系统所有 FD 的大字典。

Mach ports：

- 先保存目标的 object ID 集合。
- 扫描其他进程只保留匹配连接。
- port set 成员和连接数都设硬上限，并用 truncated 标志报告。

Modules：

- 分块读取 dyld image infos/region。
- 一条记录编码发送后即可复用临时 buffer。
- 不缓存符号、文件内容或整个 shared cache metadata。

### 10.4 Autorelease pool 和显式释放

所有 Swift ARC 对象遵循作用域所有权；不调用不存在的 ObjC 手工 `release`。需要显式管理的资源必须成对释放：

- 每条 XPC message handler 外层一个 `autoreleasepool`。
- 每次 snapshot/detail 批次一个 `autoreleasepool`；长进程扫描每固定小批再嵌套一个 pool。
- `malloc` / `UnsafeMutableRawPointer.allocate` 用 `defer` free/deallocate。
- `vm_allocate` / Mach-returned arrays 用 `vm_deallocate`。
- task/thread/port send rights 用 `mach_port_deallocate`。
- file descriptor 用 `defer { close(fd) }`。
- create/copy 得到且没有交给 ARC 管理的 CF/XPC object 用对应 release，并通过 `defer` 保证错误路径执行。
- 不把 autoreleased NSString/NSDictionary 跨 pool 保存；先转换为 bounded Swift value。

避免“多 retain 再多 release”的做法；它只会增加峰值并制造 over-release 风险。

### 10.5 背压和超时

- client-driven pull 保证最多一个 in-flight snapshot。
- daemon 不积压 timer tick；busy 时拒绝，不排队。
- 每个 collector 有 deadline，超时返回 partial/timeout，不继续无界扫描。
- XPC payload、process count、thread count、FD count、port count、module count、字符串总字节数均有独立硬上限。
- 所有 `count * stride`、offset+length、chunk index 和容量增长先检查 overflow。

## 11. 降低沙盒 App 可见面

可以做到：

- daemon 不在开机时运行，只在 Inspector lookup 时出现。
- 无合法 foreground session 时不采样，并很快退出。
- 普通 App 没有全局 mach lookup entitlement。
- 不开放 TCP/UDP/UNIX socket，不注册 URL scheme/Bonjour/notification，不写 `/tmp` marker。
- daemon 不创建共享 App Group，也不把 snapshot 写文件。
- Release 日志不输出 service 探测结果、目标进程列表、路径或 entitlement 失败细节。
- `DISABLE_TWEAKS=1`，并把 daemon 文件保持 root-owned、不可写。
- 任何未认证 probe 只得到相同失败行为，不能通过错误差异枚举功能。

不能承诺：

- LaunchDaemon plist 和 Mach service 在具有足够权限的工具眼中完全不存在。
- root、platform、越狱 tweak 或 kernel 级检测无法看到 daemon process、文件或 launchd registration。
- 仅靠随机/伪装 service name 获得安全；名称保密不能代替认证。

这里的目标是最小暴露面和正常 sandbox 隔离，不实现对系统 API 的 hook、伪造或全局隐藏逻辑。

## 12. 失败策略

所有安全检查 fail closed：

- 私有 XPC/audit symbol 缺失：daemon 不接受连接。
- effective UID 不是 root/mobile、entitlement 类型不符、executable path 不匹配或安装文件可被非 root 改写：拒绝连接。
- entitlement 类型不是严格布尔 true：拒绝连接。
- protocol version 不支持：固定错误后断开。
- payload 过大或 operation 未知：拒绝请求。
- 采样部分失败：以 per-field availability/error 返回，不伪装成 0。
- detail 达上限：返回 truncated，而不是扩容到 jetsam 风险。
- signal target 已变化：拒绝，不 retry。
- goodbye 或断线：停止、释放、清 ticket；绝不对目标进程执行 cleanup action。

## 13. 实机验证清单

### XPC/launchd

- [x] roothide / rootless LaunchDaemon plist 能由 bootstrap 按需加载，并在 client 断开后退出。
- [x] Swift `xpc_connection_create_mach_service` alias 在 iOS 17.3.1 运行。
- [x] listener 从 audit token 取得 live PID，并只接受当前连接进程。
- [x] `xpc_copy_entitlement_for_token` 可读取自定义 entitlement。
- [x] audit-token PID 对应的 live executable path 可用；缺失时保持 fail closed。
- [x] mobile 与 root 身份运行已安装 CLI 均通过认证和完整 self-test。
- [ ] 普通 sandbox App 对 service lookup 被拒绝。
- [x] 复制同一签名 CLI 到 mobile-owned 非授权路径后得到统一断线，不能取得数据。

### 生命周期

- [ ] 开机后 daemon 不运行。
- [ ] 仅 lookup/未认证连接不触发采样。
- [ ] 认证 hello 不触发采样。
- [x] 一个 snapshot request 只执行一次采样，in-flight 时不排队第二次。
- [x] client goodbye/断线后 NSTAT 和采样停止。
- [x] idle grace 后 daemon 退出，后续能由 launchd 重启。
- [ ] daemon jetsam/crash 后不存在动作重放。

### 内存

- [x] 标准长间隔采样中 daemon footprint 实测约 1.92–1.95 MiB，低于 6 MiB jetsam 限制。
- [ ] 连续刷新至少 30 分钟没有单调增长。
- [ ] 每个 autoreleasepool 后临时对象可回落。
- [ ] 极端 count/字符串/无效 offset 不越界、不 overflow、不无界扩容。
- [ ] 详情达到 cap 时可靠返回 truncated。
- [x] 慢 client 不导致 daemon 排队多个 snapshot。

### Signal

- [ ] 未完成 hello 握手时 prepare/commit 均失败。
- [ ] ticket 跨 connection、过期、重复使用均失败。
- [ ] PID reuse/start time 不同必定失败。
- [x] PID 0、PID 1、daemon 自身和当前 client 被硬拒绝。
- [ ] daemon 断线、退出、重启不执行任何 signal。

## 14. 推荐实现顺序

1. 纯 Swift XPC runtime probe：listener/client、audit token、entitlement、executable path。
2. on-demand LaunchDaemon 生命周期：无采样，只验证启动、认证、断线和退出。
3. 固定小 payload 的 `hello` 和连接生命周期管理。
4. 单次 base process snapshot，严格内存上限和 availability。
5. client-driven 刷新与后台关闭。
6. task/rusage/FD/port 计数 collector mask。
7. 按需 Threads、FD、Ports、Modules，逐个加 cap 和 chunk。
8. NSTAT session collector。
9. 两阶段 TERM/KILL ticket。
10. iOS 17.3.1 长时间 jetsam/泄漏/未授权 client 测试。

在第 1 步实机证明 XPC audit-token 鉴权链以前，不应开始完整 collector 或 UI 对接。
