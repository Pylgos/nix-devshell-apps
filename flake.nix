{
  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs =
    {
      self,
      flake-utils,
      nixpkgs,
    }:
    {
      lib =
        let
          lib = nixpkgs.lib;
        in
        rec {
          buildEnvFromDrv =
            drv:
            let
              envFile = drv.overrideAttrs {
                name = "${drv.name}-env";
                args = [ ./get-env.sh ];
              };
              envJson = builtins.readFile envFile;
              contexts = builtins.getContext envJson;
              env = (builtins.fromJSON (builtins.unsafeDiscardStringContext envJson));
            in
            env // { inherit contexts; };

          bashScriptFromEnv =
            {
              env,
              ignoreVars ? [ ],
            }:
            let
              toSkip = name: { type, ... }: type == "unknown" || lib.elem name ignoreVars;
              varToBash =
                name:
                {
                  type,
                  value,
                }:
                if type == "var" || type == "exported" then
                  "${name}=${lib.escapeShellArg value}\n" + lib.optionalString (type == "exported") "export ${name}\n"
                else if type == "array" then
                  "declare -a ${name}=(" + lib.concatStringsSep " " (map lib.escapeShellArg value) + ")\n"
                else if type == "associative" then
                  "declare -A ${name}=("
                  + lib.concatStringsSep " " (
                    map (key: "[${lib.escapeShellArg key}]=${lib.escapeShellArg value.${key}}") (lib.attrNames value)
                  )
                  + ")\n"
                else
                  throw "unsupported type ${type}";
              funcToBash = name: body: "${name} ()\n{\n${body}}\n";
              vars = lib.filterAttrs (name: value: !toSkip name value) env.variables;
              varDecls = lib.concatStrings (lib.attrValues (lib.mapAttrs varToBash vars));
              funcDecls = lib.concatStrings (lib.attrValues (lib.mapAttrs funcToBash env.bashFunctions));
              decls = varDecls + funcDecls;
              result = builtins.appendContext decls env.contexts;
            in
            result;

          rcScriptFromEnv =
            {
              env,
              createTmpDir ? false,
            }:
            let
              savedVars = [
                "PATH"
                "XDG_DATA_DIRS"
              ];
              ignoreVars = [
                "BASHOPTS"
                "HOME"
                "NIX_BUILD_TOP"
                "NIX_ENFORCE_PURITY"
                "NIX_LOG_FD"
                "NIX_REMOTE"
                "PPID"
                "SHELLOPTS"
                "SSL_CERT_FILE"
                "TEMP"
                "TEMPDIR"
                "TERM"
                "TMP"
                "TMPDIR"
                "TZ"
                "UID"
              ];
              forEach = values: f: lib.concatStrings (map f values);
              forEachSavedVars = forEach savedVars;
              # TODO: handle output redirection
              # inherit (env.variables) outputs;
              # rewrites =
              #   if env ? structuredAttrs then
              #     assert outputs.type == "associative";
              #     lib.mapAttrsToList (name: path: {
              #       from = path;
              #       to = "outputsDir/${name}";
              #     }) outputs.value
              #   else
              #     assert outputs.type == "array";
              #     map (name: {
              #       from = env.variables.${name}.value;
              #       to = "outputsDir/${name}";
              #     }) outputs.value;
              rewrites = [ ];
              script =
                ''
                  # shellcheck disable=all
                  {
                  unset shellHook
                ''
                + forEachSavedVars (name: ''
                  ${name}="''${${name}:-}"
                  nix_saved_${name}="''$${name}"
                '')
                + bashScriptFromEnv { inherit env ignoreVars; }
                + forEachSavedVars (name: ''
                  ${name}="''$${name}''${nix_saved_${name}:+:$nix_saved_${name}}"
                '')
                + lib.optionalString createTmpDir (
                  ''
                    export NIX_BUILD_TOP="$(mktemp -d -t nix-shell.XXXXXX)"
                  ''
                  + forEach [ "TMP" "TMPDIR" "TEMP" "TEMPDIR" ] (tmp: ''
                    export ${tmp}="$NIX_BUILD_TOP"
                  '')
                )
                + ''
                  eval "''${shellHook:-}"
                  }
                '';
              rewritesFrom = map ({ from, ... }: from) rewrites;
              rewritesTo = map ({ to, ... }: to) rewrites;
              result = lib.replaceStrings rewritesFrom rewritesTo script;
            in
            result;

          rcScriptFromDrv =
            { drv, ... }@args:
            rcScriptFromEnv ({ env = buildEnvFromDrv drv; } // (lib.removeAttrs args [ "drv" ]));
        };
    }
    // (flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        helloWithStructuredAttrs = pkgs.hello.overrideAttrs { __structuredAttrs = true; };
        helloShell = pkgs.mkShell { nativeBuildInputs = [ pkgs.hello ]; };
        helloBashRc = self.lib.rcScriptFromDrv { drv = helloShell; };
        helloHelp = pkgs.writeShellScriptBin "hello-help" ''
          ${helloBashRc}
          hello --help
        '';
        helloHelpApp = pkgs.writeShellApplication {
          name = "hello-help-app";
          text = ''
            ${helloBashRc}
            hello --help
          '';
        };
      in
      {
        inherit helloBashRc;
        packages = {
          inherit helloHelp helloHelpApp;
        };
      }
    ));
}
