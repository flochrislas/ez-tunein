allprojects {
    repositories {
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
    // Some plugins (e.g. file_picker's flutter_plugin_android_lifecycle) require
    // consumers to compile against a newer Android API than Flutter's current
    // default (34). Each plugin module otherwise compiles against
    // flutter.compileSdkVersion, so force every Android subproject to 36 to match
    // the app (see android/app/build.gradle.kts). Register this before
    // evaluationDependsOn, which would otherwise evaluate the project first.
    afterEvaluate {
        (extensions.findByName("android") as? com.android.build.gradle.BaseExtension)
            ?.compileSdkVersion(36)
    }
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
