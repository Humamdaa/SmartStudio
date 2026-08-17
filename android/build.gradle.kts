import org.gradle.api.tasks.compile.JavaCompile
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.tasks.KotlinJvmCompile

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
    val newSubprojectBuildDir: Directory =
        newBuildDir.dir(project.name)

    project.layout.buildDirectory.value(
        newSubprojectBuildDir
    )
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

// These plugins leave Java and Kotlin on different JVM targets, which Gradle
// rejects: tflite_flutter declares Java 11 and tesseract_ocr declares nothing
// (so Java falls back to 1.8), while Flutter's built-in Kotlin targets 17 in
// both. Pin both sides to the Java level each plugin already compiles with.
// Every other plugin is self-consistent and must not be touched.
subprojects {
    val jvm = when (name) {
        "tflite_flutter" -> JavaVersion.VERSION_11 to JvmTarget.JVM_11
        "tesseract_ocr" -> JavaVersion.VERSION_1_8 to JvmTarget.JVM_1_8
        else -> null
    }

    if (jvm != null) {
        val (javaVersion, kotlinTarget) = jvm

        tasks.withType<JavaCompile>().configureEach {
            sourceCompatibility = javaVersion.toString()
            targetCompatibility = javaVersion.toString()
        }

        tasks.withType<KotlinJvmCompile>().configureEach {
            compilerOptions.jvmTarget.set(kotlinTarget)
        }
    }

    // tesseract_ocr 0.5.0 ships TesseractOcrPlugin twice: the real Java
    // implementation under src/main/java (the one its pubspec registers, and
    // the only one that drives TessBaseAPI) plus an unused Kotlin template stub
    // under src/main/kotlin. Older Flutter never compiled the stub because the
    // plugin applies no Kotlin plugin; Flutter's built-in Kotlin compiles it
    // now, so the two declarations collide. Drop the stub.
    if (name == "tesseract_ocr") {
        tasks.withType<KotlinJvmCompile>().configureEach {
            exclude("**/TesseractOcrPlugin.kt")
        }
    }
}