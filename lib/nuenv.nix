{
  # The Nuenv build function. Essentially a wrapper around Nix's core derivation function.
  mkNushellDerivation =
    nushell: # nixpkgs.nushell (from overlay)
    sys: # nixpkgs.system (from overlay)

    { name                            # The name of the derivation
    , src                             # The derivation's sources
    , packages ? [ ]                  # Packages provided to the realisation process
    , system ? sys                    # The build system
    , build ? ""                      # The build script itself
    , debug ? true                    # Run in debug mode
    , outputs ? [ "out" ]             # Outputs to provide
    , envFile ? ../nuenv/user-env.nu  # Nushell environment passed to build phases
    , ...                             # Catch user-supplied env vars
    }@attrs:

    let
      # Gather arbitrary user-supplied environment variables
      reservedAttrs = [
        "build"
        "debug"
        "envFile"
        "name"
        "outputs"
        "packages"
        "src"
        "system"
        "__nu_builder"
        "__nu_debug"
        "__nu_env"
        "__nu_extra_attrs"
        "__nu_nushell"
      ];

      extraAttrs = removeAttrs attrs reservedAttrs;
    in
    derivation ({
      # Core derivation info
      inherit envFile name outputs packages src system;

      # Realisation phases (just one for now)
      inherit build;

      # Build logic
      builder = "${nushell}/bin/nu"; # Use Nushell instead of Bash
      args = [ ../nuenv/bootstrap.nu ]; # Run a bootstrap script that then runs the builder

      # When this is set, Nix writes the environment to a JSON file at
      # $NIX_BUILD_TOP/.attrs.json. Because Nushell can handle JSON natively, this approach
      # is generally cleaner than parsing environment variables as strings.
      __structuredAttrs = true;

      # Attributes passed to the environment (prefaced with __nu_ to avoid naming collisions)
      __nu_builder = ../nuenv/builder.nu;
      __nu_debug = debug;
      __nu_env = [ ../nuenv/env.nu ];
      __nu_extra_attrs = extraAttrs;
      __nu_nushell = "${nushell}/bin/nu";
    } // extraAttrs);

  # An analogue to writeScriptBin but for Nushell rather than Bash scripts.
  mkNushellScript =
    nushell: # nixpkgs.nushell (from overlay)
    writeTextFile: # Utility function (from overlay)

    { name
    , script
    , bin ? name
    }:

    let
      nu = "${nushell}/bin/nu";
    in
    writeTextFile {
      inherit name;
      destination = "/bin/${bin}";
      text = ''
        #!${nu}

        ${script}
      '';
      executable = true;
    };

  # Make a Nushell command and install it
  # similar to writeShellApplication, but with Nu flavor
  mkNushellCommand =
    nushell: # nixpkgs.nushell (from overlay)
    writeTextFile: # Utility function (from overlay)
    makeBinPath: # Utility function (from overlay)

    { name
    , runtimeInputs
    , text
    , description ? null
    , args ? []
    , flags ? {}
    , bin ? name
    , subCommands ? {}
    }:

    let
      nu = "${nushell}/bin/nu";

      # If x is not null, return (f x), otherwise return an empty string
      toStringOrEmpty = x: f: if x != null then (f x) else "";

      # Prepend a string before to a string s
      prepend = before: s: "${before}${s}";

      # Maps an attrset to a newline seperated string where each item has (f name value) applied
      # Example: mapAttrsToString { a = "b"; c = "d";} (name: value: "${a}${b}")
      # would be equal "ab\ncd"
      mapAttrsToString = attrs: f: (builtins.concatStringsSep "\n"
        (map (name: (f name attrs.${name}))
        (builtins.attrNames attrs)));

      # Convert a flag to a string
      # TODO: verify type is valid type, not sure how to do that without hard coding a list though
      flagToString = name: {type ? null, short ? null, description ? null}: builtins.concatStringsSep "" [
        "  --${name}"
        (toStringOrEmpty short (s: " (-${s})"))
        (toStringOrEmpty type (prepend ": "))
        (toStringOrEmpty description (prepend " # "))
      ];

      # Convert an attrset of flags to a string
      flagsToString = flags: mapAttrsToString flags flagToString;

      # Convert an array of args to a string
      argsToString = args: builtins.concatStringsSep "\n" args;

      # Convert a command to a string
      commandToString = name: {text, description ? null, flags ? null, args ? null}: ''
        ${toStringOrEmpty description (prepend "# ")}
        def "main${toStringOrEmpty name (prepend " ")}" [
          ${toStringOrEmpty args argsToString}
          ${toStringOrEmpty flags flagsToString}
        ] {
          ${text}
        }
      '';

      # Build the list of subcommands
      subCommandsString = mapAttrsToString subCommands commandToString;

      # Build the main command
      mainCommandString = commandToString null { inherit text description flags args; };
    in
    writeTextFile {
      inherit name;
      destination = "/bin/${bin}";
      text = ''
        #!${nu}

        # Add runtimeInputs to path
        # TODO: I don't think these will really be available at runtime except by chance
        # look into stdenv magic that makes sure referenced paths are available at runtime
        let paths = ("${makeBinPath runtimeInputs}" | split row ":")
        $env.PATH = ($env.PATH | prepend $paths)

        ${builtins.toString subCommandsString}

        # --help shows main when using special main function
        # See: https://github.com/nushell/nushell/issues/8388

        ${builtins.toString mainCommandString}
      '';
      executable = true;
    };
}
