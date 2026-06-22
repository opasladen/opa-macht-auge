# --- Flutter / Dart ---
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }
-dontwarn io.flutter.embedding.**

# --- ML Kit Text Recognition (DE/EN default; weitere Sprachpakete optional) ---
# Wir nutzen nur das Latin-Modell; R8 referenziert dennoch die anderen Optionen
# zur Compile-Zeit. Deren Klassen sind absichtlich nicht im AAR; ohne -dontwarn
# bricht der minify-Schritt mit "Missing class" ab.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
-keep class com.google.mlkit.vision.text.**           { *; }
-keep class com.google.android.gms.internal.mlkit_** { *; }
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.odml.** { *; }

# --- ONNX Runtime ---
-keep class ai.onnxruntime.** { *; }
-dontwarn ai.onnxruntime.**

# --- CameraX (via camera_android_camerax) ---
-keep class androidx.camera.** { *; }
-dontwarn androidx.camera.**

# --- Allgemein: Keep aller native Methoden + Annotationen ---
-keepclasseswithmembernames class * {
    native <methods>;
}
-keepattributes *Annotation*, Signature, InnerClasses, EnclosingMethod
