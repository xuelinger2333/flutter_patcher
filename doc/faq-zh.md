<!-- ========================================== -->
<!-- doc/faq-zh.md (简体中文)                    -->
<!-- ========================================== -->

# 常见问题

[English](faq.md) | **简体中文**

### 补丁能新增或修改图片、字体吗？

能，限于 `pubspec.yaml` 中声明的资源。补丁不能删除安装包里已有的资源（`PATCH_ASSET_DELETE_UNSUPPORTED`），删除需要发布商店版本。补丁中的资源合计超过 16 MB 时，`patch` 会给出警告 `PATCH_RESOURCE_SIZE`：这些资源在进程存活期间一直占用内存。

### 补丁能引入新的依赖包吗？

只能是纯 Dart 的包。带原生代码的包、平台插件和 FFI 包需要发布商店版本，`patch` 会报 `PATCH_NATIVE_CHANGE`。原生代码依赖的包固定为构建 App 时的版本（`PATCH_PINNED_PACKAGE_CHANGED`）。完整规则见[工作原理：能更新什么](architecture-zh.md#能更新什么)。

### 补丁有多大？

字节码补丁只包含改动的代码和资源：在示例 App 中改一行文字，补丁约 19 KB。SO 补丁包含重新编译的整个 `libapp.so`，有几 MB。补丁文件最大 320 MiB；内置下载器（`applyPatch`）需要在 2 分钟内下载完成。

### 补丁能不重启 App 就生效吗？

不能。补丁从下次冷启动开始运行，正在运行的进程保持原来的代码。插件不会替你重启 App。

### 用普通 `flutter build` 打的包能接收补丁吗？

不能。只有 `flutter_patcher build` 构建的 App 才能接收补丁。商店中已经是普通构建的，需要先发布一个用 `flutter_patcher build` 构建的版本。

### 字节码策略会不会让 App 变慢？

没有补丁时，App 与普通 release 包运行方式完全相同。有补丁时，只有改动过的函数在解释器中运行，比机器码慢；其余代码仍以机器码运行。改动的是计算密集的代码时，会明显变慢；在 Android 上，`so` 策略让补丁以原速运行，代价是补丁更大。见[工作原理：两种补丁策略](architecture-zh.md#两种补丁策略)。

### 升级 Flutter 之后怎么办？

需要构建并发布新的商店版本。补丁不能跨 Flutter 版本：为旧版本生成补丁时，使用构建它的那个 Flutter 版本，例如通过 `--flutter-sdk` 指定。

### 用户从商店升级 App 后，之前的补丁会怎样？

不再生效，启动诊断为 `droppedVersionCodeMismatch`。每个补丁只属于一个构建号；新版本需要修复时，为它单独发布补丁。

### 能同时为多个线上版本打补丁吗？

能。每个版本有各自的基线和各自的补丁文件名，以它的构建号开头，例如 `7-arm64-v8a.fptc`。切回该版本的源码，修复后运行 `patch --version-code <它的构建号>`。见[生产部署](production-playbook-zh.md)。

### 需要密钥吗？

不需要。没有密钥时，`build` 构建不签名的宿主，并打印 `WARNING: UNSIGNED`：它接受本构建的任何文件，因此能把文件交给 App 的一方就能在 App 中执行代码。要开启签名，运行 `dart run flutter_patcher keys init` 后重新构建：此后构建的宿主只接受这把补丁密钥签名的文件。已发布的宿主保持构建时的模式。见[工作原理：安全模型](architecture-zh.md#安全模型)。

### 控制了我的存储或 CDN 的人，能推送补丁吗？

签名宿主上不能。设备只安装这样的文件：由你的补丁私钥签名，目标正好是本机的 App、版本、flavor、渠道、ABI 和构建，而且序号大于本机已接受过的所有文件。没有私钥，被改动的内容只会校验失败。不签名宿主上能：谁能改动 App 收到的文件，谁就能在 App 中执行代码。

### App 能用自己的方式下载补丁吗？

能。插件不负责获取补丁。用任何方式拿到文件（自家接口、CDN、推送、随 App 内嵌、文件选择），把字节交给 `FlutterPatcher.applyPatchBytes`，或把路径交给 `applyPatchFile`。`FlutterPatcher.patchTarget` 告诉你的服务端这台设备需要哪个文件（`fileName`、版本号、flavor、渠道、ABI），以及它已接受的最大序号（`acceptedSeq`）。`checkUpdate` 和 `applyPatch` 只是一个内置下载器，用于放在某个 URL 下的文件。见[进阶操作：从自家接口下发补丁文件](advanced-zh.md#从自家接口下发补丁文件)。

### 怎么回退或撤回补丁？

- **回到安装包自带的版本**：`dart run flutter_patcher patch android --withdraw`（或 `ios`）以同一个文件名写出撤回文件；像补丁一样分发它，或改用 `publish --withdraw` 写入存储。应用它的设备在下次冷启动时不再运行补丁。
- **回到之前的某个补丁**：`dart run flutter_patcher publish --patch <那个补丁的输出目录>`，以新序号重新封装。
- **单台设备**：`FlutterPatcher.rollback()`。

重新上传旧的 `.fptc` 不会生效：它的序号不大于设备已接受的序号。删除文件只会阻止新的安装，已经装上的设备不受影响。给哪些用户哪个文件（灰度、按用户）由你的服务端决定。见[生产部署](production-playbook-zh.md)。

### 补丁导致 App 启动崩溃怎么办？

设备会停用这个补丁，从下次冷启动起运行安装包自带的版本，并把补丁拉黑。请尽快撤回或发布修复，因为还没试过它的设备仍会安装它。见[崩溃保护](crash-protection-zh.md#熔断之后怎么办)。

### 需要自己的后端吗？

不需要。补丁文件是静态文件：`patch` 把 `<fileName>` 写在输出目录中（使用 `publish` 时还写在存储的根目录下），任何支持 HTTPS 的静态托管都能提供它，例如 AWS S3、Cloudflare R2、阿里云 OSS 或 Google Cloud Storage 配合 CDN。`.fptc` 文件要设置较短的缓存时间：每个新补丁都会替换同名文件。见[生产部署](production-playbook-zh.md)。

### 我的 1.0 宿主会怎样？

照常工作：它们只安装 1.0 的签名清单，所以它们的补丁仍用 flutter_patcher 1.0.0+1 生成、发布和撤回。在 1.1 上为 1.0 的基线运行 `patch` 会报 `PATCH_BASELINE_INCOMPATIBLE`。1.0 的项目和密钥无需改动即可用于 1.1，下一次 `build` 起构建的是 1.1 宿主。存储中 1.0 的文件（`manifests/`、`objects/`、`catalog.json`）1.1 不读不写，继续为 1.0 宿主服务。见[更新日志：从 1.0 升级](../CHANGELOG-zh.md#从-10-升级)。

### 能在 Linux 或 Windows 上生成 iOS 补丁吗？

能。只有 `build ios` 需要 Apple Silicon Mac；`patch ios` 可在任一支持的电脑上运行，只要能读到 `build ios` 保存的基线。

### 支持 x86 模拟器或 32 位 Android 设备吗？

不支持。Android 上，宿主和补丁都只支持 `arm64-v8a`。

### 应用商店允许热更新吗？

各商店、各受监管行业（如金融、医疗、儿童类应用）的政策不同，有些限制下载可执行代码。请按你发布的商店和所在行业的规则自行确认。

### 为什么在 Windows 上 `patch` 提示所有文件都改了？

Git 把换行符转成了 `CRLF`，文件与用 `LF` 构建的基线逐字节不同。解决方法见[错误码与排障](troubleshooting-zh.md)。
