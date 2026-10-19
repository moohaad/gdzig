{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    zig.url = "github:mitchellh/zig-overlay";
    zig.inputs.nixpkgs.follows = "nixpkgs";
    zls.url = "github:zigtools/zls?ref=0.17.0";
    zls.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      nixpkgs,
      zig,
      zls,
      ...
    }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      nixpkgsFor = forAllSystems (
        system:
        import nixpkgs {
          inherit system;
          overlays = [ ];
        }
      );
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgsFor.${system};
          zigPinned = zig.packages.${system}."0.17.0";
          zlsPinned = zls.packages.${system}.zls;
        in
        {
          default = pkgs.mkShell {
            buildInputs = [
              pkgs.lldb
              zigPinned
              zlsPinned
            ]
            ++ pkgs.lib.optionals (system == "x86_64-linux") [
              # Wine for cross-platform testing with -fwine
              pkgs.wineWowPackages.stable
            ];
          };
        }
      );
    };
}
