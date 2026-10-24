{
  description = "Frame Drum — Android rhythm trainer for a frame drum";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachSystem [ "x86_64-linux" ] (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
            android_sdk.accept_license = true;
          };
        };

        # Versions must match what the Flutter Gradle plugin / AGP request,
        # because the Nix-store SDK is read-only and Gradle can't install extras.
        android = pkgs.androidenv.composeAndroidPackages {
          platformVersions = [ "36" ];
          buildToolsVersions = [ "36.0.0" ];
          includeNDK = true;
          ndkVersions = [ "28.2.13676358" ]; # = flutter.ndkVersion; the Flutter Gradle plugin requires it
          includeEmulator = false;
        };
        sdk = android.androidsdk;
        sdkRoot = "${sdk}/libexec/android-sdk";

        env = {
          ANDROID_HOME = sdkRoot;
          ANDROID_SDK_ROOT = sdkRoot;
          JAVA_HOME = pkgs.jdk17.home;
          # Use aapt2 from the Nix SDK instead of the one Gradle downloads (not runnable on NixOS).
          GRADLE_OPTS = "-Dorg.gradle.project.android.aapt2FromMavenOverride=${sdkRoot}/build-tools/36.0.0/aapt2";
        };
        tools = [ pkgs.flutter pkgs.jdk17 sdk ];

        script = name: text: pkgs.writeShellApplication {
          inherit name text;
          runtimeInputs = tools;
          runtimeEnv = env;
        };

        buildApk = script "build-apk" ''
          flutter pub get
          flutter build apk --release --split-per-abi --target-platform android-arm64
          echo "APK: build/app/outputs/flutter-apk/app-arm64-v8a-release.apk"
        '';

        install = script "install-apk" ''
          ${pkgs.lib.getExe buildApk}
          adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
        '';
      in {
        devShells.default = pkgs.mkShell ({ packages = tools; } // env);

        apps = {
          default = { type = "app"; program = pkgs.lib.getExe buildApk; };
          build-apk = { type = "app"; program = pkgs.lib.getExe buildApk; };
          install = { type = "app"; program = pkgs.lib.getExe install; };
        };
      });
}
