import org.gradle.api.DefaultTask
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.provider.Property
import org.gradle.api.tasks.Input
import org.gradle.api.tasks.OutputDirectory
import org.gradle.api.tasks.TaskAction
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.tasks.KotlinCompilationTask
import java.io.File
import java.util.Properties

// UI-free shared module. Hosts the Compose-free domain/data layer that both the phone
// app (composeApp) and the tvOS app (SharedCore framework) consume — single source of truth.
// Targets mirror composeApp (android + iOS) plus tvOS. No Compose / coil / navigation here.

// Generates the runtime-config classes that the migrated data layer needs, in :shared only,
// so the FQNs (com.nuvio.app.core.network.SupabaseConfig and
// com.nuvio.app.core.build.AppVersionConfig / AppBuildConfig) are produced in exactly one
// module. composeApp consumes them transitively via implementation(projects.shared). The
// remaining feature configs (trakt/debrid/tmdb/community/intro-db/imdb) stay in composeApp.
abstract class GenerateSharedRuntimeConfigsTask : DefaultTask() {
    @get:OutputDirectory
    abstract val outputDir: DirectoryProperty

    @get:Input
    abstract val appVersionName: Property<String>

    @get:Input
    abstract val appVersionCode: Property<Int>

    @get:Input
    abstract val supabaseUrl: Property<String>

    @get:Input
    abstract val supabaseAnonKey: Property<String>

    @get:Input
    abstract val supabaseFallbackUrl: Property<String>

    @get:Input
    abstract val debugBuild: Property<Boolean>

    @get:Input
    abstract val traktClientId: Property<String>

    @get:Input
    abstract val traktClientSecret: Property<String>

    @get:Input
    abstract val traktRedirectUri: Property<String>

    @get:Input
    abstract val simklClientId: Property<String>

    @get:Input
    abstract val simklAppName: Property<String>

    @get:Input
    abstract val premiumizeClientId: Property<String>

    @get:Input
    abstract val introDbUrl: Property<String>

    @get:Input
    abstract val imdbRatingsBaseUrl: Property<String>

    @get:Input
    abstract val imdbTapframeBaseUrl: Property<String>

    @TaskAction
    fun generate() {
        val outDir = outputDir.get().asFile
        outDir.resolve("com/nuvio/app/core/network").apply {
            mkdirs()
            resolve("SupabaseConfig.kt").writeText(
                """
                |package com.nuvio.app.core.network
                |
                |object SupabaseConfig {
                |    const val URL = "${supabaseUrl.get()}"
                |    const val ANON_KEY = "${supabaseAnonKey.get()}"
                |    const val FALLBACK_URL = "${supabaseFallbackUrl.get()}"
                |}
                """.trimMargin()
            )
        }
        outDir.resolve("com/nuvio/app/core/build").apply {
            mkdirs()
            resolve("AppVersionConfig.kt").writeText(
                """
                |package com.nuvio.app.core.build
                |
                |object AppVersionConfig {
                |    const val VERSION_NAME = "${appVersionName.get()}"
                |    const val VERSION_CODE = ${appVersionCode.get()}
                |}
                """.trimMargin()
            )
            resolve("AppBuildConfig.kt").writeText(
                """
                |package com.nuvio.app.core.build
                |
                |object AppBuildConfig {
                |    const val IS_DEBUG_BUILD = ${debugBuild.get()}
                |}
                """.trimMargin()
            )
        }
        outDir.resolve("com/nuvio/app/features/trakt").apply {
            mkdirs()
            resolve("TraktConfig.kt").writeText(
                """
                |package com.nuvio.app.features.trakt
                |
                |object TraktConfig {
                |    const val CLIENT_ID = "${traktClientId.get()}"
                |    const val CLIENT_SECRET = "${traktClientSecret.get()}"
                |    const val REDIRECT_URI = "${traktRedirectUri.get()}"
                |}
                """.trimMargin()
            )
        }
        // Fork: no REDIRECT_URI. tvOS authenticates Simkl through the PIN flow (see
        // SimklAuthRepository), which takes a client id and nothing else — upstream's
        // SIMKL_REDIRECT_URI belongs to the redirect-OAuth flow the fork does not run.
        outDir.resolve("com/nuvio/app/features/simkl").apply {
            mkdirs()
            resolve("SimklConfig.kt").writeText(
                """
                |package com.nuvio.app.features.simkl
                |
                |object SimklConfig {
                |    const val CLIENT_ID = "${simklClientId.get()}"
                |    const val APP_NAME = "${simklAppName.get()}"
                |}
                """.trimMargin()
            )
        }
        outDir.resolve("com/nuvio/app/features/debrid").apply {
            mkdirs()
            resolve("PremiumizeConfig.kt").writeText(
                """
                |package com.nuvio.app.features.debrid
                |
                |object PremiumizeConfig {
                |    const val CLIENT_ID = "${premiumizeClientId.get()}"
                |}
                """.trimMargin()
            )
        }
        outDir.resolve("com/nuvio/app/features/player/skip").apply {
            mkdirs()
            resolve("IntroDbConfig.kt").writeText(
                """
                |package com.nuvio.app.features.player.skip
                |
                |object IntroDbConfig {
                |    const val URL = "${introDbUrl.get()}"
                |}
                """.trimMargin()
            )
        }
        outDir.resolve("com/nuvio/app/features/details").apply {
            mkdirs()
            resolve("ImdbEpisodeRatingsConfig.kt").writeText(
                """
                |package com.nuvio.app.features.details
                |
                |object ImdbEpisodeRatingsConfig {
                |    const val IMDB_RATINGS_API_BASE_URL = "${imdbRatingsBaseUrl.get()}"
                |    const val IMDB_TAPFRAME_API_BASE_URL = "${imdbTapframeBaseUrl.get()}"
                |}
                """.trimMargin()
            )
        }
    }
}

fun readXcconfigValue(file: File, key: String): String? {
    if (!file.exists()) return null
    return file.readLines()
        .asSequence()
        .map(String::trim)
        .filter { it.isNotEmpty() && !it.startsWith("#") && it.contains('=') }
        .map { line ->
            val separatorIndex = line.indexOf('=')
            line.substring(0, separatorIndex).trim() to line.substring(separatorIndex + 1).trim()
        }
        .firstOrNull { (entryKey, _) -> entryKey == key }
        ?.second
}

plugins {
    alias(libs.plugins.kotlinMultiplatform)
    alias(libs.plugins.androidKotlinMultiplatformLibrary)
    alias(libs.plugins.kotlinxSerialization)
}

// ---- runtime-config inputs (mirrors composeApp; reads the same root sources) ----
val sharedGeneratedConfigDir = layout.buildDirectory.dir("generated/runtime-config/kotlin")

val sharedRuntimeProps = Properties().apply {
    val file = rootProject.file("local.properties")
    if (file.exists()) file.inputStream().use(::load)
}

fun sharedRuntimeConfigValue(key: String, fallback: String = ""): String =
    sharedRuntimeProps.getProperty(key)?.trim()?.takeIf { it.isNotBlank() }
        ?: providers.environmentVariable(key).orNull?.trim()?.takeIf { it.isNotBlank() }
        ?: fallback

fun sharedBooleanConfigValue(key: String): Boolean? =
    (sharedRuntimeProps.getProperty(key)
        ?: providers.environmentVariable(key).orNull
        ?: providers.gradleProperty(key).orNull)
        ?.trim()
        ?.lowercase()
        ?.let { value ->
            when (value) {
                "1", "true", "yes", "y", "debug" -> true
                "0", "false", "no", "n", "release" -> false
                else -> null
            }
        }

val sharedVersionConfigFile = rootProject.file("iosApp/Configuration/Version.xcconfig")
val sharedAppVersionName = readXcconfigValue(sharedVersionConfigFile, "MARKETING_VERSION")
    ?: error("MARKETING_VERSION is missing from ${sharedVersionConfigFile.path}")
val sharedAppVersionCode = readXcconfigValue(sharedVersionConfigFile, "CURRENT_PROJECT_VERSION")
    ?.toIntOrNull()
    ?: error("CURRENT_PROJECT_VERSION is missing or invalid in ${sharedVersionConfigFile.path}")

val sharedInferredDebugBuild = gradle.startParameter.taskNames.any { "debug" in it.lowercase() } ||
    providers.environmentVariable("CONFIGURATION").orNull?.trim()?.lowercase() == "debug" ||
    providers.environmentVariable("KOTLIN_FRAMEWORK_BUILD_TYPE").orNull?.trim()?.lowercase() == "debug"
val sharedIsDebugBuild = sharedBooleanConfigValue("NUVIO_DEBUG_BUILD")
    ?: sharedBooleanConfigValue("nuvio.debugBuild")
    ?: sharedInferredDebugBuild

val generateSharedRuntimeConfigs = tasks.register<GenerateSharedRuntimeConfigsTask>("generateSharedRuntimeConfigs") {
    outputDir.set(sharedGeneratedConfigDir)
    appVersionName.set(sharedAppVersionName)
    appVersionCode.set(sharedAppVersionCode)
    // Primary URL/key: accept both the fork's historical SUPABASE_* keys and upstream's
    // NUVIO_SUPABASE_* names so existing local.properties keep working after the
    // upstream runtime-config refactor (switchdb revert).
    supabaseUrl.set(
        sharedRuntimeConfigValue("SUPABASE_URL").ifBlank { sharedRuntimeConfigValue("NUVIO_SUPABASE_URL") }
    )
    supabaseAnonKey.set(
        sharedRuntimeConfigValue("SUPABASE_ANON_KEY").ifBlank { sharedRuntimeConfigValue("NUVIO_SUPABASE_ANON_KEY") }
    )
    supabaseFallbackUrl.set(
        sharedRuntimeConfigValue("NUVIO_SUPABASE_FALLBACK_URL").ifBlank { sharedRuntimeConfigValue("SUPABASE_FALLBACK_URL") }
    )
    debugBuild.set(sharedIsDebugBuild)
    traktClientId.set(sharedRuntimeConfigValue("TRAKT_CLIENT_ID"))
    traktClientSecret.set(sharedRuntimeConfigValue("TRAKT_CLIENT_SECRET"))
    traktRedirectUri.set(sharedRuntimeConfigValue("TRAKT_REDIRECT_URI", "nuvio://auth/trakt"))
    simklClientId.set(sharedRuntimeConfigValue("SIMKL_CLIENT_ID"))
    simklAppName.set(sharedRuntimeConfigValue("SIMKL_APP_NAME", "nuvio"))
    premiumizeClientId.set(sharedRuntimeConfigValue("PREMIUMIZE_CLIENT_ID"))
    introDbUrl.set(sharedRuntimeConfigValue("INTRODB_API_URL"))
    imdbRatingsBaseUrl.set(sharedRuntimeConfigValue("IMDB_RATINGS_API_BASE_URL"))
    imdbTapframeBaseUrl.set(sharedRuntimeConfigValue("IMDB_TAPFRAME_API_BASE_URL"))
}

tasks.withType<KotlinCompilationTask<*>>().configureEach {
    dependsOn(generateSharedRuntimeConfigs)
}

kotlin {
    android {
        namespace = "com.nuvio.app.shared"
        compileSdk {
            version = release(libs.versions.android.compileSdk.get().toInt()) {
                minorApiLevel = libs.versions.android.compileSdkMinor.get().toInt()
            }
        }
        minSdk = libs.versions.android.minSdk.get().toInt()
        compilerOptions {
            jvmTarget.set(JvmTarget.JVM_11)
        }
    }

    // beta.14 Wave 4 / docs/issue-triage-plan-2026-08-21.md §6.1 — lets `commonTest` run as
    // `:shared:jvmTest` on any host (this repo's Apple targets need a macOS simulator to test).
    // jvmMain actuals under src/jvmMain back tests only; neither app ships this target.
    jvm()

    val appleTargets = listOf(
        iosArm64(),
        iosSimulatorArm64(),
        tvosArm64(),
        tvosSimulatorArm64(),
    )

    appleTargets.forEach { target ->
        target.binaries.framework {
            baseName = "SharedCore"
            isStatic = true
        }
        // CommonCrypto shim for the tvOS plugin runtime's PluginCrypto (same def as composeApp's
        // iOS targets — CommonCrypto ships in libSystem on tvOS too).
        if (target.name.startsWith("tvos")) {
            target.compilations.getByName("main").cinterops.create("commoncrypto") {
                defFile(project.file("src/nativeInterop/cinterop/commoncrypto.def"))
                compilerOpts("-I${project.projectDir}/src/nativeInterop/cinterop")
            }
        }
    }
    // The cinterop task's up-to-date check tracks only the .def file; headers pulled in via
    // `compilerOpts -I` are invisible to Gradle, so a header-only shim change (the 2026-08-30
    // GCM oneshot declarations) left every not-cleanly-rebuilt target on a STALE klib —
    // "Unresolved reference 'CCCryptorGCMOneshotEncrypt'" on whichever slice hadn't re-run
    // cinterop, while freshly-built slices were green. Declaring the shim as an explicit task
    // input makes a header edit invalidate every target's cinterop the normal way.
    project.tasks.matching { it.name.startsWith("cinteropCommoncrypto") }.configureEach {
        inputs.file(project.file("src/nativeInterop/cinterop/commoncrypto_shim.h"))
    }

    sourceSets {
        commonMain {
            kotlin.srcDir(sharedGeneratedConfigDir)
            dependencies {
                implementation(libs.kotlinx.serialization.json)
                implementation(libs.kotlinx.atomicfu)
                implementation(libs.kermit)
                // Supabase api-exposes ktor-client-core + kotlinx-coroutines-core transitively
                // (same as composeApp, which has no explicit coroutines/ktor-core alias either).
                // `api` so public signatures (SupabaseClient, Flow<…>) resolve for composeApp.
                api(libs.supabase.postgrest)
                api(libs.supabase.auth)
                api(libs.supabase.functions)
            }
        }
        // Default hierarchy template (Kotlin 2.x) creates `appleMain` as the parent of
        // iosMain + tvosMain — the SyncBackendStorage apple actual will live here later.
        appleMain.dependencies {
            implementation(libs.ktor.client.darwin)
        }
        // JS plugin runtime (tvOS only — iOS/Android get it from composeApp's flavor source
        // sets). quickjs-kt 1.0.5-tvos is the local fork with tvOS targets: see the top-level
        // repo's scaffolding/quickjs-kt-tvos.patch + build-quickjs-tvos.sh → mavenLocal.
        tvosMain.dependencies {
            implementation("io.github.dokar3:quickjs-kt:1.0.5-tvos")
            implementation(libs.ksoup)
        }
        androidMain.dependencies {
            // Upstream's catalog dropped ktor-client-android; okhttp is the Android engine now.
            implementation(libs.ktor.client.okhttp)
            // AddonPlatform.android uses okhttp + IPv4FirstDns directly (matches composeApp).
            implementation("com.squareup.okhttp3:okhttp:4.12.0")
        }
        // Mirrors composeApp's commonTest dependency declaration — kotlin-test only. Runs via the
        // native test tasks (:shared:iosSimulatorArm64Test / :shared:tvosSimulatorArm64Test, need
        // a macOS simulator host) and, since the jvm() target above, :shared:jvmTest on any host.
        commonTest.dependencies {
            implementation(libs.kotlin.test)
        }
        // JUnit runner for kotlin-test on the jvm target (jvmMain itself needs no extra deps —
        // its actuals are plain java.* / java.time.* / java.net.*, see src/jvmMain).
        jvmTest.dependencies {
            implementation(libs.kotlin.testJunit)
        }
    }
}
