{
  description = "A development environment for Go projects.";
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
        pkgs = import nixpkgs {
          inherit system;
        };
      in
      {
        devShells.default = pkgs.mkShell {
          hardeningDisable = [ "fortify" ]; # Needed to debug Golang code
          packages = with pkgs; [
            # --- Go Backend Dependencies ---
            go # The Go compiler and toolchain
            gopls # The official Go language server for IDE integration
          ];

          shellHook = ''
            # Set up Go environment
            export GOROOT="$(go env GOROOT)"
            export GOPATH="$HOME/go"
            export GOPROXY="https://proxy.golang.org,direct"
            export GOSUMDB="sum.golang.org"
            export PATH="$GOPATH/bin:$GOROOT/bin:$PATH"
            
            # Create GOPATH directories if they don't exist
            mkdir -p "$GOPATH"/{bin,src,pkg}
            
            echo "--------------------------------------------------"
            echo "  Entering multi-project development environment  "
            echo "--------------------------------------------------"
            echo "Available tools:"
            echo "- Go: $(go version)"
            echo "--------------------------------------------------"
          '';
        };
      }
    );
}
