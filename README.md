# 无尽之剑3 设备型号欺骗 Tweak

让游戏以为自己运行在高端设备（iPhone 5S）上，从而启用高画质和全屏渲染。

## 文件说明

| 文件 | 作用 |
|------|------|
| `IB3DeviceSpoof.m` | 主代码，hook sysctlbyname 伪装设备型号 |
| `fishhook.h` / `fishhook.c` | Facebook 的 fishhook 库，用于替换 C 函数 |
| `.github/workflows/build.yml` | GitHub Actions 自动编译配置 |

## 原理

Hook `sysctlbyname("hw.machine")`，当游戏查询设备型号时，返回 `iPhone6,2`（iPhone 5S）。

UE3（Unreal Engine 3）的设备型号解析有 bug，遇到两位数型号（如 iPhone14,2）会只截取前几位，导致新设备被误判为第一代 iPhone，从而使用低画质/低分辨率预设。

通过伪装成 iPhone 5S，游戏会匹配高端设备预设，启用高画质和全屏渲染。

---

## 编译方法

### 方法一：GitHub Actions 在线编译（Windows 用户推荐，免费）

**零成本，不需要 Mac，5 分钟搞定。**

1. 注册一个 GitHub 账号（免费）：https://github.com/join

2. 在 GitHub 上新建一个仓库（New Repository），名字随便取，比如 `IB3DeviceSpoof`

3. 把以下文件上传到仓库：
   - `IB3DeviceSpoof.m`
   - `fishhook.h`
   - `fishhook.c`
   - `.github/workflows/build.yml`（注意目录结构，要放在 `.github/workflows/` 下面）

4. 上传完成后，点击顶部的 **Actions** 标签

5. 左边选择 **"Build IB3DeviceSpoof dylib"**，右边点击 **"Run workflow"** → 绿色按钮确认

6. 等 1-2 分钟，状态变成绿色 ✓ 就完成了

7. 点进去，在页面底部 **Artifacts** 区域下载 `IB3DeviceSpoof.dylib`

### 方法二：Mac 本地编译

需要：Mac + Xcode Command Line Tools

```bash
# 安装命令行工具（如果没装）
xcode-select --install

# 编译
clang -shared -arch arm64 \
  -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
  -framework Foundation \
  -o IB3DeviceSpoof.dylib \
  IB3DeviceSpoof.m fishhook.c

# 验证
file IB3DeviceSpoof.dylib
# 输出应该包含: Mach-O 64-bit dynamically linked shared library arm64
```

---

## 使用方法（Sideloadly 注入）

1. 打开 **Sideloadly**
2. 拖入你修改过启动屏幕的 IPA（就是 v2 脚本处理过的那个）
3. 点击 **"Inject dylib/framework"** 或 **"Advanced options"** 里的注入选项
4. 选择 `IB3DeviceSpoof.dylib`
5. 正常点击 Start 签名安装
6. 安装完后启动游戏

## 验证是否生效

启动游戏后观察：

- ✅ **画面全屏**，没有黑边
- ✅ **画质提升**，纹理更清晰，阴影更细腻
- ✅ 启动时有短暂黑屏（LaunchScreen 的效果）

如果还是小屏，说明 hook 没生效，可能需要检查：
1. dylib 是否正确注入
2. 游戏是否用了其他方式获取设备型号（比如 uname）

## 修改伪装的设备型号

如果想试试其他设备型号，编辑 `IB3DeviceSpoof.m` 里的这一行：

```c
#define SPOOFED_DEVICE_MODEL "iPhone6,2"
```

改成你想要的型号，比如：
- `iPhone6,2` = iPhone 5S（推荐，最稳妥）
- `iPad4,1` = iPad Air（更高端，画质更好）
- `iPhone7,2` = iPhone 6（稍新，但不确定 UE3 认不认）

修改后重新编译即可。
