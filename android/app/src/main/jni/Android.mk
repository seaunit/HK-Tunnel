# Wrapper around the vendored hev-socks5-tunnel tree. Building "hev-socks5-tunnel"
# also builds its bundled lwip / yaml / hev-task-system static libraries.
LOCAL_PATH := $(call my-dir)

include $(LOCAL_PATH)/hev-socks5-tunnel/Android.mk
