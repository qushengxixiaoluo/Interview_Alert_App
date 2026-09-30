import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 读取发布签名配置。文件不存在时（比如别人刚 clone 下来）不要让构建直接失败，
// 退回 debug 签名，这样开发调试不受影响。
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseSigning = keystorePropertiesFile.exists()
if (hasReleaseSigning) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.interview.calendar.interview_calendar"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.interview.calendar.interview_calendar"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    packaging {
        jniLibs {
            // 只留 arm64。光靠 --target-platform android-arm64 只让 Flutter 引擎和
            // Dart 代码走 arm64，但 jni_flutter 等插件 AAR 里预编译的 .so 仍会带出
            // armeabi-v7a、x86_64 两个「半残」目录（有目录却缺 libflutter.so/libapp.so）。
            // 这里把非 arm64 的原生库直接排除，出一个干净的 arm64 单架构包。
            excludes += setOf("lib/armeabi-v7a/**", "lib/x86_64/**")
        }
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String

                // v2/v3 都签上。v1（JAR 签名）在 minSdk >= 24 时被 AGP 强制关闭，
                // 写不写 enableV1Signing 都一样 —— API 24+ 的设备全都校验 v2，用不到 v1。
                enableV2Signing = true
                enableV3Signing = true
            }
        }
    }

    buildTypes {
        release {
            // 有正式密钥就用正式的：签名固定，以后可以直接覆盖安装升级，
            // 不需要卸载重装（卸载会清空数据库）。
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }

            // 关掉代码压缩和资源混淆。
            // 这个 App 没有引入需要 keep 规则的反射库，开了也省不了多少体积，
            // 反而容易在 release 下出现「debug 正常、release 崩溃」的诡异问题。
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

flutter {
    source = "../.."
}
