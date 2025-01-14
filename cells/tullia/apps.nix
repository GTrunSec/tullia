{
  cell,
  inputs,
}: let
  inherit (inputs) self std nixpkgs;
  inherit (nixpkgs) lib;

  src = std.incl self [
    (self + /go.mod)
    (self + /go.sum)
    (self + /cli)
  ];

  package = vendorSha256:
    inputs.nixpkgs.buildGoModule rec {
      pname = "tullia";
      version = "2022.05.04.001";
      inherit src vendorSha256;

      passthru.invalidHash =
        package "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";

      postInstall = ''
        mv $out/bin/cli $out/bin/tullia
      '';

      CGO = "0";

      ldflags = [
        "-s"
        "-w"
        "-X main.buildVersion=${version}"
        "-X main.buildCommit=${inputs.self.rev or "dirty"}"
      ];
    };
in {
  tullia = package "sha256-tSdJkdKEycm4AfpCHwmDNxVnNnglgDDctEP0Qy/ujK0=";

  # Ugly wrapper script for `cue fmt` that adheres to the treefmt spec.
  # https://github.com/numtide/treefmt/issues/140
  treefmt-cue = nixpkgs.writeShellApplication {
    name = "treefmt-cue";
    text = ''
      set -euo pipefail

      PATH="$PATH:"${lib.makeBinPath [
        nixpkgs.gitMinimal
        nixpkgs.cue
      ]}

      trap 'rm -rf "$tmp"' EXIT
      tmp="$(mktemp -d)"

      root="$(git rev-parse --show-toplevel)"

      for f in "$@"; do
        fdir="$tmp"/"$(dirname "''${f#"$root"/}")"
        mkdir -p "$fdir"
        cp -a "$f" "$fdir"/
      done
      cp -ar "$root"/.git "$tmp"/

      cd "$tmp"
      cue fmt "''${@#"$root"/}"

      for f in "''${@#"$root"/}"; do
        if [ -n "$(git status --porcelain --untracked-files=no -- "$f")" ]; then
          cp "$f" "$root"/"$f"
        fi
      done
    '';
  };
}
