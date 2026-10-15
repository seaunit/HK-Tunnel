# The native library registers its methods against hev.htproxy.TProxyService by
# name, so that class and its members must survive shrinking.
-keep class hev.htproxy.** { *; }
