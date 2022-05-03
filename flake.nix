{
  description = "managed-prometheus-demo";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils, ... }@inputs:
    let
      overlays = [ ];
    in
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system overlays; };
      in
      rec {
        devShell = pkgs.mkShell rec {
          name = "managed-prometheus-demo";

          buildInputs = with pkgs; [
            terraform
            google-cloud-sdk
            kubectl
            kubernetes-helm
          ];
        };
      }
    );
}
