{
  sops,
  writers,
  runCommand,
  symlinkJoin,
  lib,
  nushell,
  ...
}:
with builtins; let
  writeNuWithStdin = writers.makeScriptWriter {interpreter = "${lib.getExe nushell} --no-config-file --stdin";};

  bwrap-command = writeNuWithStdin "bwrap-command" (readFile ./bwrap_command.nu);
  flatten-yaml = writeNuWithStdin "flatten_yaml" (readFile ./flatten_yaml.nu);

  explodeList = parameter: foldl' (acc: pattern: acc + " --${parameter} \"${pattern}\"") "";
  explodeAllowList = explodeList "allow-key";
  explodeStripList = explodeList "strip";

  selectVarSource = {
    allowConfig ? true,
    allowSecrets ? true,
    ...
  }:
    if allowConfig
    then
      (
        if allowSecrets
        then "$all_vars"
        else "$config_vars"
      )
    else
      (
        if allowSecrets
        then "$secrets_vars"
        else "\"\""
      );

  wrapCommandTemplate = {
    cmd,
    controlChar,
    template ? "%A%c%z%v",
    argTemplate,
    allow ? [],
    strip ? [],
    redact,
    namespaces ? [],
    ...
  } @ templateArgs: let
    finalStrip = strip ++ (map (ns: "^${replaceStrings ["."] ["__"] ns}__") namespaces);
  in
    "("
    + (concatStringsSep " " [
      (selectVarSource templateArgs)
      "|"
      "${bwrap-command}"
      "--control-char"
      "${controlChar}"
      "--cmd"
      "${cmd}"
      "--template"
      "\"${template}\""
      "--arg-template"
      "\"${argTemplate}\""
      "--redact"
      "${redact}"
    ])
    + (explodeAllowList allow)
    + (explodeStripList finalStrip)
    + ")";

  wrapAllTemplates = {
    controlChar,
    redact,
  }:
    foldl' (cmd: templateArgs:
      wrapCommandTemplate (templateArgs
        // {
          inherit cmd controlChar redact;
        }));
in rec {
  inherit bwrap-command flatten-yaml;

  wrapBinary = {
    bin,
    subcommand ? "",
    wrapperBinName ? baseNameOf bin,
    configYaml ? "",
    secretsYaml ? "",
    templates,
    ...
  }: let
    wrappedTemplates =
      wrapAllTemplates {
        controlChar = "$control_char";
        redact = "$redact";
      } "$wrapped_cmd"
      templates;
  in
    writers.writeNuBin wrapperBinName {}
    /*
    nu
    */
    ''
      def parse_encrypted [path: string] {
        if $path != "" {
          ${lib.getExe sops} decrypt $path | ${flatten-yaml}
        } else {
          null
        }
      }

      def parse_unencrypted [path: string] {
        if $path != "" {
          open -r $path | ${flatten-yaml}
        } else {
          null
        }
      }

      def --wrapped main [...args: string] {
        let config_yaml_path = "${configYaml}"
        let secrets_yaml_path = "${secretsYaml}"

        let config_vars = parse_unencrypted $config_yaml_path
        let secrets_vars = parse_encrypted $secrets_yaml_path

        let all_vars = [$config_vars $secrets_vars] | str join "\n"

        let control_char = "\u{2000}"

        let subcommand = "${subcommand}"
        let subcommand_parts = if $subcommand == "" {
          []
        } else {
          $subcommand | split row " "
        }
        let subcommand_len = $subcommand_parts | length

        let wrapped_binary = "\"${bin}\""

        let arg_types = if ($subcommand_len > 0) {
          $args | enumerate | reduce --fold { subcommand_miss: false subcommand_args: [$wrapped_binary] other_args: [] } {|command,acc|
            if $acc.subcommand_miss or $command.index >= $subcommand_len {
              $acc | upsert other_args ($acc.other_args | append $command.item)
            } else if ($subcommand_parts | get ($command.index)) == $command.item {
              $acc | upsert subcommand_args ($acc.subcommand_args | append $command.item)
            } else {
              $acc | upsert subcommand_miss true | upsert other_args ($acc.other_args | append $command.item)
            }
          }
        } else {
          { subcommand_miss: false subcommand_args: [$wrapped_binary] other_args: $args }
        }

        let subcommand_args = $arg_types.subcommand_args
        let other_args = $arg_types.other_args

        let dry_run = ($other_args | find "--sops-wrapper-dry-run" | length) > 0
        let redact = ($other_args | find "--sops-wrapper-redact" | length) > 0

        let cmd_args = $other_args | where {|value|
          $value != "--sops-wrapper-dry-run" and $value != "--sops-wrapper-redact"
        }

        let full_command = $subcommand_args | str join " "

        let wrapped_cmd = [$"($control_char)($full_command)($control_char)"] ++ $cmd_args | str join " "

        let cmd = if $arg_types.subcommand_miss {
          $wrapped_cmd
        } else {
          ${wrappedTemplates}
        } | str replace -a $control_char ""

        if $dry_run {
          "\e[1m\e[33m⚡\e[0m\e[1mWould run: \e[0m" + $cmd
        } else {
          $cmd | /bin/sh
        }
      }
    '';

  wrapApplication = {
    package,
    wrappedBin ? lib.getExe package,
    packageName ? lib.getName package,
    wrappedBinName ? baseNameOf wrappedBin,
    wrappedMainProgram ? ".${wrappedBinName}-wrapped",
    wrapperBinName ? wrappedBinName,
    ...
  } @ wrapperArgs: let
    wrappedPackage =
      runCommand "${packageName}-wrapped" {}
      /*
      bash
      */
      ''
        mkdir -p $out/bin
        cd ${package}
        for dir in ${package}/*/; do
          dir_basename=$(basename "$dir")
          if [ "$dir_basename" != "bin" ]; then
            ln -s "$dir" "$out/$dir_basename"
          else
            for node in $dir*; do
              node_basename=$(basename "$node")
              if [ "$node_basename" != "${wrappedBinName}" ]; then
                ln -s "$node" "$out/bin/$node_basename"
              else
                ln -s "$node" "$out/bin/${wrappedMainProgram}"
              fi
            done
          fi
        done
      ''
      // {
        meta = {
          mainProgram = wrappedMainProgram;
        };
      };
  in
    (symlinkJoin {
      name = "${packageName}-sops-wrapper";
      paths = [
        wrappedPackage
        (wrapBinary (wrapperArgs
          // {
            inherit wrapperBinName;
            bin = "${wrappedPackage}/bin/${wrappedMainProgram}";
          }))
      ];
    })
    // {
      meta = {
        mainProgram = wrappedBinName;
      };
    };
}
