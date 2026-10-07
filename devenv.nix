# A local gno.land chain with the drand realms loaded, and the relayer feeding
# it live evmnet beacons. Two processes, same lifecycle as the e2e test:
#
#   devenv up      start gnodev and the relayer
#   devenv shell   gno, gnokey, gnodev, gnoweb and the Go toolchain on PATH
{ pkgs, ... }:
let
  # `gnoFromSource` comes from the `gno` overlay in github.com/albttx/nixpkgs,
  # which devenv.yaml declares as the `albttx-nixpkgs` input and applies to
  # pkgs. That overlay also exposes a prebuilt `gno-tools`, but those are the
  # upstream release binaries: CGO-linked against a generic glibc, so they do
  # not run on NixOS. Building the same tag with CGO_ENABLED=0 instead.
  gno = pkgs.gnoFromSource {
    version = "1.5.0";
    rev = "e75fef82c02876a4df92ad6e325c5479b9532168";
    hash = "sha256-CFtt4AExDFW6mDFfZSf7gC/IVIq80E2Td1oFPba+IYE=";
    rootVendorHash = "sha256-Dq4y3OYgyPmzFUh2a5VigORju339nXr4iMaAkf4MwNc=";
    gnodevVendorHash = "sha256-jER2bMMI5wuelZJ2GaecKu3/ILZ1tm4hiwbr9/B66/g=";
  };

  drandPath = "gno.land/r/albttx/drand/v0";
  coinflipPath = "gno.land/r/albttx/demo/coinflip/v0";

  rpcHost = "127.0.0.1";
  rpcPort = 26657;
  webPort = 8888;
in
{
  packages = [ gno ];

  # go.mod asks for 1.26.8 and nixpkgs is a patch behind, so GOTOOLCHAIN
  # fetches the exact version on first build.
  languages.go.enable = true;

  env = {
    # gnodev reads the gno standard library from GNOROOT, and resolves the
    # examples/ realms r/demo/coinflip imports (p/nt/avl, p/nt/seqid,
    # p/nt/ufmt) from $GNOROOT/examples on demand.
    GNOROOT = "${gno.src}";
    CGO_ENABLED = "0";

    GNO_CHAIN_ID = "dev";
    GNO_RPC_ADDR = "${rpcHost}:${toString rpcPort}";
    GNO_WEB_ADDR = "${rpcHost}:${toString webPort}";

    # test1, the account `gnodev local` premines at genesis. Published in the
    # gno repo and worthless off a local chain: never reuse it elsewhere.
    RELAYER_MNEMONIC = "source bonus chronic canvas draft south burst lottery vacant surface solve popular case indicate oppose farm nothing bullet exhibit title speed wink action roast";
  };

  processes = {
    # The chain. `-C $DEVENV_ROOT` loads the gnowork.toml workspace, so the
    # realms under gno.land/ deploy at genesis and reload when a .gno changes.
    # Web UI on $GNO_WEB_ADDR.
    gnodev = {
      exec = ''
        exec gnodev local -C "$DEVENV_ROOT" \
          -chain-id "$GNO_CHAIN_ID" \
          -node-rpc-listener "$GNO_RPC_ADDR" \
          -web-listener "$GNO_WEB_ADDR" \
          -paths "${drandPath},${coinflipPath}"
      '';

      process-compose.readiness_probe = {
        http_get = {
          scheme = "http";
          host = rpcHost;
          # process-compose parses this with strconv.Atoi: it must be a string.
          port = toString rpcPort;
          path = "/status";
        };
        initial_delay_seconds = 3;
        period_seconds = 2;
        timeout_seconds = 2;
        failure_threshold = 60;
      };
    };

    # Submits the real evmnet beacon for every round r/drand has pending.
    # Needs outbound HTTPS to the drand mirrors.
    relayer = {
      exec = ''
        exec go run ./cmd/relayer \
          -remote "http://$GNO_RPC_ADDR" \
          -chain-id "$GNO_CHAIN_ID" \
          -pkgpath "${drandPath}"
      '';

      process-compose.depends_on.gnodev.condition = "process_healthy";
    };
  };
}
