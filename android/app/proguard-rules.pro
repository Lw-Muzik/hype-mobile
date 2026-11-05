# R8 rules. Kept minimal on purpose: blanket `-keep ... { *; }` package rules
# stopped R8 from shrinking/optimizing/obfuscating ~90% of the DEX (Play Console
# warning "DEX code optimization is below our threshold"). Flutter, AndroidX,
# Firebase, GMS, audio_service etc. ship their own consumer rules.

# Native stems engine (stems_jni.cpp) calls this via GetStaticMethodID; no Java
# caller exists, so R8 would otherwise strip it.
-keepclassmembers class x.a.zix.StemEngineBridge {
    static void onNativeStatus(java.lang.String);
}

# just_audio fork (AudioPlayer.java) does Class.forName(...).getMethod("createPlayerInstance"[, String]).
# Native (JNI) methods are kept by the default Android rules, and the broadcast*/
# setTrackGainDb statics are called directly from MainActivity, so only the
# reflective lookups need rules.
-keep class x.a.zix.RoomEffectsProcessor {
    public static x.a.zix.RoomEffectsProcessor createPlayerInstance();
    public static x.a.zix.RoomEffectsProcessor createPlayerInstance(java.lang.String);
}
-keep class x.a.zix.VisualizerTapProcessor {
    public static x.a.zix.VisualizerTapProcessor createPlayerInstance();
}

# JAudioTagger builds frame-body classes by name at runtime and calls copy/default
# constructors reflectively (getConstructor, newInstance).
-keep class org.jaudiotagger.tag.id3.framebody.** { <init>(...); }
-keepclassmembers class org.jaudiotagger.** { <init>(...); }
# It references java.awt / javax.imageio, absent on Android.
-dontwarn org.jaudiotagger.**

# Flutter deferred components reference Play Core, which we do not ship.
-dontwarn com.google.android.play.core.splitcompat.SplitCompatApplication
-dontwarn com.google.android.play.core.splitinstall.**
-dontwarn com.google.android.play.core.tasks.**
