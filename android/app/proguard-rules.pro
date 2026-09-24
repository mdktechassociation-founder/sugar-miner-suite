# Flutter's own rules come from proguard-android-optimize.txt; these keep the
# pieces the app reaches by name rather than by reference.
-keep class com.mdk.sugarminer.** { *; }
-keep class id.flutter.flutter_background_service.** { *; }
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}
