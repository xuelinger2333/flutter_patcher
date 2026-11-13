# 常见问题

[English](faq.md) | **简体中文**

> 关于补丁能改什么、签名、下发与回滚、支持的平台的简短回答，每条都链接到负责解释的页面。

你正在判断 flutter_patcher 是否适合你的 App，或者有一个具体的问题。每个回答以“能”或“不能”开头并给出原因，细节在所链接的页面中。遇到错误码时，见[错误码与排障](troubleshooting-zh.md)。

## 补丁

### 补丁能新增或修改图片、字体吗？

能，限于 `pubspec.yaml` 中声明的资源。补丁不能删除安装包中已有的资源，因为补丁只能覆盖资源：`patch` 报 `PATCH_ASSET_DELETE_UNSUPPORTED`。见[能更新什么](architecture-zh.md#能更新什么)。

### 补丁能引入新的依赖包吗？

能，前提是这个包是纯 Dart 的。带原生代码的包、平台插件和 FFI 包报 `PATCH_NATIVE_CHANGE`，因为补丁只携带 Dart 代码和资源。见[能更新什么](architecture-zh.md#能更新什么)。

### 补丁能不重启 App 就生效吗？

不能。补丁从下次冷启动开始运行，因为正在运行的进程保持它已加载的代码。见[设备上的生命周期](architecture-zh.md#设备上的生命周期)。

### 补丁包含整个 App 吗？

字节码补丁携带变更库、必要的调用库和 part，以及改动过的资源；未改动的库、Flutter 和插件留在安装包中。循环导入仍可能带入许多未改动的调用库。SO 补丁携带重新编译的整个 `libapp.so`，有几 MB。补丁文件最大 320 MiB，内置下载器必须在 2 分钟内下载完成。见[两种补丁策略](architecture-zh.md#两种补丁策略)。

### 字节码策略会让 App 变慢吗？

会，在补丁运行期间：补丁选中的应用库由解释器执行，速度低于机器码，所以应用中计算密集的代码会明显变慢。Flutter 和插件仍以机器码运行；没有补丁时，App 与普通 release 包完全相同。在 Android 上，`--strategy so` 使补丁以原速运行，补丁文件更大。见[两种补丁策略](architecture-zh.md#两种补丁策略)。

### 用普通 `flutter build` 打的包能接收补丁吗？

不能。只有用 `dart run flutter_patcher build` 构建的 App 才能接收补丁，因为只有它们包含加载补丁的引擎和入口。先发布一个这样构建的版本。见[宿主：能接收补丁的安装包](architecture-zh.md#宿主能接收补丁的安装包)。

### 能用与发布版本不同的 Flutter 版本生成补丁吗？

不能。补丁必须用构建该版本的 Flutter 生成，所以升级 Flutter 后要发布新的商店版本；为旧版本生成补丁时，用 `--flutter-sdk` 指定它的 Flutter。见[能更新什么](architecture-zh.md#能更新什么)。

### 用户从商店升级 App 后，补丁还生效吗？

不生效。每个补丁只属于一个构建号，所以升级后补丁不再运行，启动诊断为 `droppedVersionCodeMismatch`。新构建需要这处修复时，为它生成补丁。见[其他会让补丁失效的情况](crash-protection-zh.md#其他会让补丁失效的情况)。

### 能同时为多个线上版本打补丁吗？

能。每个版本有各自的基线和各自的补丁文件名，例如 `7-arm64-v8a.fptc`：切换到该版本的源码，修复后运行 `patch android --version-code <它的构建号>`。见[5. 生成并分发补丁](production-playbook-zh.md#5-生成并分发补丁)。

## 安全与密钥

### 必须有密钥吗？

不必须。没有密钥时，`build` 输出 `WARNING: UNSIGNED`，App 安装本构建的任何完整补丁文件，所以能把文件交给 App 的一方就能在 App 中执行代码。在要上线的构建之前，在 `flutter_patcher.yaml` 中设置 `trust.enabled: true`，App 就只安装你签名的文件。见[3. 开启签名](production-playbook-zh.md#3-开启签名)。

### 控制了我的存储或 CDN 的人，能推送补丁吗？

不能，对签名的 App 不能：它只安装由你的补丁密钥签名、目标正是本构建、且序号大于它已接受的所有文件的文件。不签名的 App 安装本构建的任何完整文件。见[安全模型](architecture-zh.md#安全模型)。

## 下发与运维

### App 能用自己的方式下载补丁吗？

能。App 通过任何渠道获取文件，例如自有接口、推送消息或内置的文件，再交给 `FlutterPatcher.applyPatchBytes` 或 `applyPatchFile`。见[自定义下发](advanced-zh.md#由自家服务端自定义下发)。

### 必须有自己的后端吗？

不必须。补丁是一个静态文件，所以任何支持 HTTPS 的静态托管或 CDN 都能提供它。见[1. 确定 App 从哪里获取补丁文件](production-playbook-zh.md#1-确定-app-从哪里获取补丁文件)。

### 能回滚补丁吗？

能。下发撤回文件（`patch android --withdraw`）让设备恢复到安装包自带的版本，或者重新发布之前某个补丁的输出让设备恢复到那个补丁。重新上传旧的 `.fptc` 文件不会生效，因为设备只接受更大的序号。见[补丁下发回滚](production-playbook-zh.md#补丁下发回滚)。

### 补丁导致启动崩溃时，App 能自己恢复吗？

能。设备停用并拉黑该补丁，从下次冷启动起运行安装包自带的版本。尚未尝试该补丁的设备仍会安装它，所以要下发撤回文件或修复补丁。见[熔断之后怎么办](crash-protection-zh.md#熔断之后怎么办)。

### 用 flutter_patcher 1.0 发布的 App 还能打补丁吗？

能，用 flutter_patcher 1.0.0+1。在 1.1 上为 1.0 的基线运行 `patch` 会报 `PATCH_BASELINE_INCOMPATIBLE`；项目和密钥无需改动即可用于 1.1，下一次 `build` 生成 1.1 的 App。见[从 1.0 升级](upgrading-zh.md)。

## 平台

### 能在 Linux 或 Windows 上生成 iOS 补丁吗？

能。只有 `build ios` 需要 Apple Silicon Mac；`patch ios` 可在任何受支持、且能读到 `build ios` 所存基线的电脑上运行。见[iOS 的不同之处](getting-started-zh.md#ios-的不同之处)。

### 支持 x86 模拟器或 32 位 Android 设备吗？

不支持。在 Android 上，App 和补丁只支持 `arm64-v8a`。

### 在 Windows 上检出代码会影响 `patch` 的对比结果吗？

会，当 Git 把换行符转换成 `CRLF` 时：文件与用 `LF` 构建的基线逐字节不同，`patch` 报告所有文件都有改动。解决方法见[错误码与排障](troubleshooting-zh.md)。

### 所有应用商店都允许热更新吗？

不是。各商店以及金融、医疗、儿童类应用等受监管行业的政策不同，部分政策限制下载可执行代码。按你发布的商店和所在行业的规则确认。
