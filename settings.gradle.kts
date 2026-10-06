rootProject.name = "Nuvio"
enableFeaturePreview("TYPESAFE_PROJECT_ACCESSORS")

pluginManagement {
    repositories {
        google {
            mavenContent {
                includeGroupAndSubgroups("androidx")
                includeGroupAndSubgroups("com.android")
                includeGroupAndSubgroups("com.google")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositories {
        google {
            mavenContent {
                includeGroupAndSubgroups("androidx")
                includeGroupAndSubgroups("com.android")
                includeGroupAndSubgroups("com.google")
            }
        }
        mavenCentral()
        // quickjs-kt has no published tvOS artifacts; the top-level repo's
        // scaffolding/build-quickjs-tvos.sh publishes a patched 1.0.5-tvos to mavenLocal
        // for :shared's tvOS targets.
        mavenLocal {
            content {
                includeGroup("io.github.dokar3")
            }
        }
    }
}

include(":composeApp")
include(":androidApp")
include(":shared")
