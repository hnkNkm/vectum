{
  description = "vectum - lightweight, self-hosted event router for cloud, on-premise, and edge environments";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };

        # BEAM 関連は beamPackages セットから取得する
        beamPackages = pkgs.beam.packages.erlang;
        erlang = beamPackages.erlang;
        rebar3 = beamPackages.rebar3;

        # spec.md の要件:
        #   - SQLite Persistence (esqlite / sqlight などの NIF をビルドする)
        #   - HMAC Verification / Signing (crypto NIF が OpenSSL を要求する)
        runtimeDeps = with pkgs; [
          sqlite
          openssl
        ];

        # NIF のビルドに必要なツールチェイン
        buildDeps = with pkgs; [
          stdenv.cc
          makeWrapper
        ];
      in
      {
        devShells.default = pkgs.mkShell {
          name = "vectum-dev";

          packages =
            [
              # Gleam 本体
              pkgs.gleam
              erlang
              rebar3

              # 言語サーバー
              pkgs.glas

              # フォーマッタ・ユーティリティ
              pkgs.just
            ]
            ++ runtimeDeps
            ++ buildDeps;

          env = {
            # esqlite 等の NIF ビルド時に SQLite / OpenSSL をリンクさせるためのヒント
            ERL_AFLAGS = "-kernel prevent_overlapping_partitions false";
            SQLITE_LIB_DIR = "${pkgs.sqlite.out}/lib";
            SQLITE_INC_DIR = "${pkgs.sqlite.dev}/include";
            OPENSSL_LIB_DIR = "${pkgs.openssl.out}/lib";
            OPENSSL_INC_DIR = "${pkgs.openssl.dev}/include";
            # gleam export erlang-shipment 等で Erlang ランタイムを見つけられるようにする
            ERLANG_PATH = "${erlang}";
          };

          shellHook = ''
            echo ""
            echo "=== vectum 開発環境 ==="
            echo "  Gleam : $(gleam --version 2>/dev/null || echo 'not found')"
            echo "  Erlang/OTP: $(erl -noshell -eval 'io:format("OTP ~s", [erlang:system_info(otp_release)])' -s init stop 2>/dev/null || erl +V)"
            echo ""
            echo "主なコマンド:"
            echo "  gleam test"
            echo "  gleam run -- validate --config examples/router.toml"
            echo "  gleam run -- run --config router.toml"
            echo "==================================="
          '';
        };

        packages.default =
          let
            gleamTomlExists = builtins.pathExists ./gleam.toml;
          in
          if gleamTomlExists then
            pkgs.stdenv.mkDerivation {
              pname = "vectum";
              version = "0.1.0";

              src = ./.;

              nativeBuildInputs = [
                pkgs.gleam
                erlang
                rebar3
                pkgs.makeWrapper
              ]
              ++ buildDeps;
              buildInputs = runtimeDeps;

              configurePhase = ''
                export HOME=$TMPDIR
                # Hex パッケージの取得を許可 (オフライン運用時は事前にベンダリングすること)
              '';

              buildPhase = ''
                runHook preBuild
                gleam build
                runHook postBuild
              '';

              installPhase = ''
                runHook preInstall
                mkdir -p $out/bin
                gleam export erlang-shipment
                cp -r build/erlang-shipment $out/libexec
                makeWrapper $out/libexec/entrypoint.sh $out/bin/vectum \
                  --prefix PATH : ${pkgs.lib.makeBinPath [ erlang ]}
                runHook postInstall
              '';

              meta = with pkgs.lib; {
                description = "A lightweight, reliable, self-hosted event router built with Gleam and BEAM";
                license = licenses.asl20;
                mainProgram = "vectum";
              };
            }
          else
            pkgs.runCommand "vectum-not-ready"
              {
                passthru.meta.description = "gleam.toml が存在しないため未ビルド";
              }
              ''
                echo "gleam.toml が存在しません。まず gleam プロジェクトを初期化してください" >&2
                exit 1
              '';

        apps.default = flake-utils.lib.mkApp {
          drv = self.packages.${system}.default;
        };
      }
    );
}
