# Only the shared library is wanted here; hev-socks5-tunnel/Android.mk also
# declares a standalone executable module, which is not useful inside an APK.
APP_MODULES := hev-socks5-tunnel

APP_ABI := arm64-v8a armeabi-v7a x86_64
APP_OPTIM := release
APP_CFLAGS := -O3
APP_SUPPORT_FLEXIBLE_PAGE_SIZES := true
NDK_TOOLCHAIN_VERSION := clang
