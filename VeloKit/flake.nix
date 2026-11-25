{
  description = "Velocitty development environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ... }:
    let
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          just
          zig_0_17
          gettext
          pkg-config
        ];

        shellHook = ''
          echo "Velocitty development environment loaded"
          echo "Zig version: $(zig version)"
        '';
      };
    };
}
