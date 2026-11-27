# RS Digital Cockpit — Reglas R8 / ProGuard para compilación Release (Google Play AAB)

# Preservar Activity, NotificationListenerService y puente nativo Kotlin
-keep class com.rs.digital.cockpit.** { *; }

# Reflexión Bluetooth RFCOMM (BluetoothDevice.createRfcommSocket)
-keepclassmembers class android.bluetooth.BluetoothDevice {
    public android.bluetooth.BluetoothSocket createRfcommSocket(int);
}

# Flutter Stripe & OkHttp / Kotlin Serialization
-keep class com.stripe.** { *; }
-keep class com.flutter.stripe.** { *; }
-dontwarn com.stripe.**
-dontwarn com.google.android.gms.tapandpay.**

# RevenueCat (purchases_flutter) y dependencias opcionales de Amazon IAP
-keep class com.revenuecat.** { *; }
-dontwarn com.amazon.device.iap.**

# Anotaciones y dependencias opcionales en tiempo de compilación
-dontwarn javax.annotation.**
-dontwarn com.google.errorprone.**
-dontwarn org.codehaus.mojo.animal_sniffer.**
