import com.android.build.api.variant.LibraryAndroidComponentsExtension

allprojects {
    repositories {
        // Flutter 引擎工件（io.flutter:*）镜像。必须放在最前：
        // Flutter 插件默认把 storage.googleapis.com/download.flutter.io 追加到仓库列表末尾，
        // 国内网络访问会被重置；把官方中国镜像放在前面可优先命中，避免直连 Google。
        maven { url = uri("https://storage.flutter-io.cn/download.flutter.io") }
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/central") }
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// 统一将所有插件（library）子项目的 compileSdk / NDK / build-tools 覆盖为本机安装的版本：
// - jni 使用 flutter.ndkVersion（默认 28.2.13676358），本机该目录已损坏（缺 source.properties），
//   新装的是 NDK 30.0.16248370；build-tools 统一用 36.1.0。
// 时机说明：finalizeDsl 是 AGP 官方的“DSL 锁定前最后一次修改”钩子——
// 在插件脚本体（含其 ndkVersion/compileSdk 赋值）之后执行，早于 afterEvaluate 锁定，
// 因此不会出现“值被插件覆盖回去”或“too late to set”两类错误。
subprojects {
    plugins.withId("com.android.library") {
        project.extensions.configure<LibraryAndroidComponentsExtension>("androidComponents") {
            finalizeDsl { ext ->
                ext.compileSdk = 36
                ext.ndkVersion = "30.0.16248370"
                ext.buildToolsVersion = "36.1.0"
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
