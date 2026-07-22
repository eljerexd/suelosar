# mobile_scanner 7.2.0 only keeps the direct com.google.mlkit package.
# Barcode component registrars live in nested packages and are loaded at runtime.
-keep class com.google.mlkit.** { *; }
