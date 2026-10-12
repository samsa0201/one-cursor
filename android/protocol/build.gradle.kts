plugins {
    kotlin("jvm") version "2.0.21"
}

group = "dev.onecursor"
version = "0.1.0"

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    testImplementation(kotlin("test"))
    testImplementation("org.junit.jupiter:junit-jupiter:5.10.3")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

tasks.test {
    useJUnitPlatform()
    testLogging {
        events("failed")
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
    }
}

// Small debugging client: ./gradlew runDebugClient --args="host port name"
tasks.register<JavaExec>("runDebugClient") {
    group = "application"
    classpath = sourceSets["test"].runtimeClasspath
    mainClass.set("dev.onecursor.protocol.DebugClientKt")
}
