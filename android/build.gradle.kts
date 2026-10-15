import java.util.Properties

plugins {
    id("com.android.application") version "8.12.0" apply false
    id("org.jetbrains.kotlin.android") version "2.1.20" apply false
}

// The installed versionCode rises on its own with every build, so this only has
// to advance the human-readable label.
tasks.register("bumpVersion") {
    group = "versioning"
    description = "Increments versionName in version.properties"

    doLast {
        val file = file("version.properties")
        val properties = Properties()
        file.inputStream().use { properties.load(it) }
        val current = properties.getProperty("versionName", "1.0")
        val parts = current.split(".")
        val minor = parts.getOrNull(1)?.toIntOrNull() ?: 0
        val next = "${parts.firstOrNull() ?: "1"}.${minor + 1}"

        // Written by hand rather than via Properties.store() so the file keeps
        // its explaining comment and does not churn on a generated timestamp.
        file.writeText(
            "# Human-facing release label, bumped by `gradlew bumpVersion`.\n" +
                "# The versionCode rises with the build clock and needs no editing.\n" +
                "versionName=$next\n"
        )
        println("versionName: $current -> $next")
    }
}
