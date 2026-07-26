{
  stdenv,
  buildPackages,
  buildBazelPackage,
  fetchFromGitHub,
  lib,
}:
let
  buildPlatform = stdenv.buildPlatform;
  hostPlatform = stdenv.hostPlatform;
  pythonEnv = buildPackages.python3.withPackages (
    ps: with ps; [
      distutils
      numpy
    ]
  );
  bazelDepsSha256ByBuildAndHost = {
    x86_64-linux = {
      x86_64-linux = "sha256-oKUF3551m5jUr1ER0vpBQwB3GEt3FSXxduuZguSHuy4=";
      aarch64-linux = "sha256-2DbaH+sW+QHZovuKdzhrBV2sOyqRslKVEj40Ajyf5bo=";
    };
    aarch64-linux = {
      aarch64-linux = lib.fakeHash;
    };
  };
  bazelHostConfigName.aarch64-linux = "elinux_aarch64";
  bazelDepsSha256ByHost =
    bazelDepsSha256ByBuildAndHost.${buildPlatform.system}
      or (throw "unsupported build system ${buildPlatform.system}");
  bazelDepsSha256 =
    bazelDepsSha256ByHost.${hostPlatform.system}
      or (throw "unsupported host system ${hostPlatform.system} with build system ${buildPlatform.system}");
in
buildBazelPackage rec {
  name = "tensorflow-lite";
  version = "2.21.0";

  src = fetchFromGitHub {
    owner = "tensorflow";
    repo = "tensorflow";
    rev = "v${version}";
    hash = "sha256-Hs3g80wSHex1ejz7H8eu6MJMzwthx58sPGDh/dG66FQ=";
  };

  # Upstream pins 7.7.0 in .bazelversion.
  bazel = buildPackages.bazel_7;

  nativeBuildInputs = [
    pythonEnv
    buildPackages.perl
    # Used from inside a Bazel repository rule, see postPatch.
    buildPackages.patchelf
  ];

  bazelTargets = [
    "//tensorflow/lite:libtensorflowlite.so"
    "//tensorflow/lite/c:tensorflowlite_c"
    "//tensorflow/lite/tools/benchmark:benchmark_model"
    "//tensorflow/lite/tools/benchmark:benchmark_model_performance_options"
  ];

  bazelFlags = [
    "--config=opt"
    # Since 2.16 the build fetches its own CPython through rules_python. Pin it,
    # otherwise the contents of the dependency archive - and with it its hash -
    # drift with whatever the toolchain resolves to.
    "--repo_env=HERMETIC_PYTHON_VERSION=3.13"
    # Read by the patch applied to rules_python in postPatch.
    "--repo_env=NIX_DYNAMIC_LINKER=${stdenv.cc.bintools.dynamicLinker}"
  ]
  ++ lib.optionals (hostPlatform.system != buildPlatform.system) [
    "--config=${bazelHostConfigName.${hostPlatform.system}}"
  ];

  bazelBuildFlags = [ "--cxxopt=--std=c++17" ];

  buildAttrs = {
    # buildAttrs wins over the top-level preConfigure, so patchShebangs has to
    # be repeated here.
    preConfigure = ''
      patchShebangs configure

      # Bazel generates Python stubs with a /usr/bin/env shebang, which does not
      # exist inside the sandbox.
      substituteInPlace $bazelOut/external/rules_python/python/private/py_runtime_info.bzl \
        --replace-fail '"#!/usr/bin/env python3"' '"#!${pythonEnv}/bin/python3"'
      substituteInPlace $bazelOut/external/rules_python/python/private/runtime_env_toolchain.bzl \
        --replace-fail '"#!/usr/bin/env python3"' '"#!${pythonEnv}/bin/python3"'
      substituteInPlace $bazelOut/external/rules_python/python/private/stage1_bootstrap_template.sh \
        --replace-fail '#!/usr/bin/env bash' '#!${stdenv.shell}'

      # fetchAttrs.preInstall blanks every store path in the archive, which also
      # blanks the interpreter patchelf wrote during the fetch. Redo it against
      # the real linker before anything tries to run the interpreter.
      for py_dir in $bazelOut/external/python_3_*; do
        [ -d "$py_dir" ] || continue
        find "$py_dir" -type f -executable -exec \
          patchelf --set-interpreter ${stdenv.cc.bintools.dynamicLinker} {} \; 2>/dev/null || true
      done
    '';

    installPhase = ''
      mkdir -p $out/{bin,lib}

      # copy the libs and binaries into the output dir
      cp ./bazel-bin/tensorflow/lite/c/libtensorflowlite_c.so $out/lib
      cp ./bazel-bin/tensorflow/lite/libtensorflowlite.so $out/lib
      cp ./bazel-bin/tensorflow/lite/tools/benchmark/benchmark_model $out/bin
      cp ./bazel-bin/tensorflow/lite/tools/benchmark/benchmark_model_performance_options $out/bin

      find . -type f -name '*.h' | while read f; do
        path="$out/include/''${f/.\//}"
        install -D "$f" "$path"

        # remove executable bit from headers
        chmod -x "$path"
      done
    '';
  };

  fetchAttrs = {
    sha256 = bazelDepsSha256;

    # The hermetic CPython that rules_python unpacks lands read-only, and
    # removing a file needs write permission on its directory - without this the
    # symlink rewriting at the end of the fetch phase dies on EACCES.
    preInstall = ''
      chmod -R u+w $bazelOut/external

      # Keeping local_* around for @local_config_android also keeps repositories
      # that bake in paths from the fetch environment. The dependency archive is
      # a fixed-output derivation with allowedRequisites = [], so it may not
      # reference the store at all.
      rm -rf $bazelOut/external/{local_jdk,\@local_jdk.marker}
      rm -rf $bazelOut/external/{local_config_python,\@local_config_python.marker}
      rm -rf $bazelOut/external/{local_execution_config_python,\@local_execution_config_python.marker}
      rm -rf $bazelOut/external/{local_config_xcode,\@local_config_xcode.marker}

      # Remaining store paths sit in generated text files. Blanking the hash part
      # drops the references and makes the archive independent of the nixpkgs
      # revision that produced it. Only the files that actually match are
      # rewritten - the tree is large enough that touching all of them costs
      # half an hour.
      grep -rlZ '/nix/store/' $bazelOut/external \
        | xargs -0 -r -P "$NIX_BUILD_CORES" -n 64 \
            sed -i 's|/nix/store/[a-z0-9]\{32\}-|/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-|g'

      # Python bytecode embeds timestamps.
      find $bazelOut/external -name '*.pyc' -delete
    '';
  };

  # ./configure is interactive and, since 2.17, insists on a clang path unless it
  # is told otherwise - answer everything up front so it never prompts.
  env = {
    PYTHON_BIN_PATH = pythonEnv.interpreter;
    USE_DEFAULT_PYTHON_LIB_PATH = "1";
    TF_NEED_CLANG = "0";
    TF_NEED_CUDA = "0";
    TF_NEED_ROCM = "0";
    TF_SET_ANDROID_WORKSPACE = "0";
    CC_OPT_FLAGS = "-O2";
  };

  dontAddBazelOpts = true;
  removeRulesCC = false;

  # tf_workspace0 loads @local_config_android//:android.bzl, so the local_*
  # repositories have to survive into the build phase.
  removeLocal = false;

  postPatch = ''
    rm .bazelversion

    # rules_ml_toolchain registers a hermetic clang whose wrapper does not
    # survive into the build phase: the dependency archive may not reference the
    # store, so the paths it points at get rewritten. Drop the registrations and
    # let toolchain resolution fall back to the compiler from stdenv.
    sed -i '/^register_toolchains("@rules_ml_toolchain/d' WORKSPACE

    # rules_python downloads a pre-built CPython that hardcodes
    # /lib64/ld-linux-x86-64.so.2 as its interpreter, which does not exist in
    # the sandbox. A later repository rule executes that binary to verify it,
    # and there is no phase of ours in between - so the fix has to happen inside
    # the download rule itself.
    cp ${./rules-python-nix-patchelf.patch} \
      third_party/xla/third_party/py/rules_python_nix_patchelf.patch
    substituteInPlace third_party/xla/third_party/py/python_init_rules.bzl \
      --replace-fail \
        '] + extra_patches,' \
        '"@xla//third_party/py:rules_python_nix_patchelf.patch",
        ] + extra_patches,'
  '';

  preConfigure = ''
    patchShebangs configure
  '';

  # configure script freaks out when parameters are passed
  dontAddPrefix = true;
  configurePlatforms = [ ];

  meta = {
    description = "Open source deep learning framework for on-device inference";
    homepage = "https://www.tensorflow.org/lite";
    license = lib.licenses.asl20;
    maintainers = with lib.maintainers; [
      mschwaig
      cpcloud
    ];
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
}
