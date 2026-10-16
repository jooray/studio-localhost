# JNI entry points and the callback the native side looks up by name
-keep class io.github.jooray.localhoststudio.yue2.Yue2Native { native <methods>; }
-keep interface io.github.jooray.localhoststudio.yue2.ProgressListener { *; }
-keep class * implements io.github.jooray.localhoststudio.yue2.ProgressListener { void onProgress(int, int, int); }
