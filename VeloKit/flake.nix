{
  description = "VeloKit development environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ... }:
    let
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          zig_0_16
          gettext
          pkg-config
        ];

        shellHook = ''
          echo "VeloKit development environment loaded"
          echo "Zig version: $(zig version)"
        '';
      };
    };
}
