# HDR 模拟集成说明（HDR Vision → PiliPlus）

## 结论

可以加，而且不需要写原生插件。PiliPlus 本来就有一条现成的 mpv
GLSL 用户着色器管线（超分辨率 Anime4K 就是走这条路），HDR 功能
复用同一条管线即可。

## 原脚本的原理（HDR 视界 userscript）

原脚本在浏览器里用 WebGPU（WGSL 着色器）逐帧处理视频：

1. 把视频帧画到一张覆盖在原视频上的 canvas；
2. 在着色器里做逆色调映射，把 SDR 亮度范围拉开，模拟 HDR 观感；
3. 默认模式是 BT.2446a 逆 EOTF + 中间调提升，另有 power 曲线模式；
4. 辅以 OKLab 色彩空间饱和度调整、多尺度去色带（deband）、
   可选的 CAS 锐化；
5. 设置存在 localStorage，UI 是页面上的悬浮面板。

关键点：**核心是一段逐像素的颜色数学，与 WebGPU 本身无关**。
换到任何能跑自定义着色器的渲染管线里，效果都可以复现。

## PiliPlus 的播放管线为什么正好接得上

- PiliPlus 用 media_kit + libmpv 播放视频；iOS 上 media_kit 走
  OpenGL ES 的 `vo_gpu` 渲染路径（见上游 media_kit 的
  `TextureHW.swift`，`MPV_RENDER_API_TYPE_OPENGL`）。
- mpv 的 `vo_gpu` 支持 `glsl-shaders` 用户着色器；PiliPlus 已经
  用它加载 Anime4K（`change-list glsl-shaders set <路径>`），
  且 Anime4K 的着色器同样挂在 `MAIN` 钩子上——说明这条路在
  iOS 真机上是跑通过的。
- 因此移植 = 把 WGSL 翻译成 mpv 的 GLSL 用户着色器，挂在
  `MAIN` 钩子上，走 PiliPlus 现成的着色器加载逻辑。

## 本次改动

| 文件 | 改动 |
|---|---|
| `assets/shaders/HDR_Vision_BT2446a.glsl`（新增） | WGSL → GLSL 移植：BT.2446a 逆 EOTF + 中间调提升 + OKLab 饱和度 + 四尺度去色带；参数与原脚本 bt2446a 预设一致（peak 1.7、boost 1.15、midToneLift 0.35、saturation 1.1、deband 阈值 0.012）；CAS 锐化沿用原脚本默认（关闭） |
| `lib/common/assets.dart` | 新增 `mpvHdrShaders` 列表 |
| `lib/plugin/pl_player/controller.dart` | 新增 `hdrEnabled` 状态与 `setHdrEnabled()`；`setShader()` 改为组合着色器列表（超分辨率 + HDR 可叠加，HDR 在后，作为最终显示级调整）；播放器初始化时若开启 HDR 也会应用 |
| `lib/utils/storage_key.dart`、`lib/utils/storage_pref.dart` | 新增 `hdrEnabled` 持久化设置 |
| `lib/pages/video/widgets/header_control.dart` | 播放器菜单「超分辨率」下方新增「HDR 模拟」开关 |

`pubspec.yaml` 已包含 `assets/shaders/` 整个目录，新着色器
无需额外注册即会被打进安装包。

## 使用

播放页 → 右上角菜单 → 打开「HDR 模拟」。开关会持久保存，
下次打开视频自动生效；与超分辨率同时开也可以。

## 打 IPA 的方法（本机无法编译，需走 CI）

这台机器是 Linux，没有 macOS / Xcode / Flutter，所以 IPA
不能在这里直接编出来。仓库自带的 `.github/workflows/ios.yml`
已经是现成的路（macOS 26 runner + `flutter build ios
--release --no-codesign`，产出未签名 IPA，专为 AltStore
侧载设计）：

1. 把这份源码推到你自己的 fork（或直接在原仓库提 PR）；
2. GitHub → Actions → "Build for iOS" → Run workflow；
3. 跑完后在 Artifacts 里下载 `iOS-release`，得到
   `PiliPlus_ios_*.ipa`；
4. 用 AltStore / SideStore 自签安装到 iPhone（免费 Apple ID
   证书 7 天有效期，到期重签即可）。

## 限制与注意事项

- **这只是 SDR → HDR 模拟**，不是真 HDR：输出仍写进 mpv 的
  8-bit 帧缓冲，和原脚本在 SDR 屏上的效果一致。B站真正的
  HDR（杜比视界等）内容请关闭本开关。
- **着色器编译失败时 mpv 只会跳过它并记一条警告**，播放
  本身不会崩；如果开了开关画面毫无变化，先考虑是这个原因。
- 去色带每像素 32 次纹理采样 + OKLab 运算，老机型上可能
  更费电；如卡顿，可把 `HDR_Vision_BT2446a.glsl` 里的
  `DEBAND_THRESHOLD` 改大或删掉 `applyDeband` 调用。
- 着色器顺序：超分辨率在前、HDR 在后。Anime4K 先看到原始
  SDR 帧（符合其训练分布），HDR 最后做显示级调整。
- 本次 Dart 代码未在本地编译验证（本机无 Flutter SDK），
  合并前请以 CI 的编译结果为准；着色器已做括号平衡与
  WGSL 残留检查。
