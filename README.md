# sops-bwrap.nix

Portable library that bubblewraps binaries with secrets from SOPS and other configuration data, without leaking anything to the environment.

Useful in dev shells, to inject configuration flags and/or environment variables into binaries like `docker`, `hurl`, `npm` etc.

## Prerequisites

Install nix with flake support.

## Getting started

### 1. Set up private/public key pairs

See corresponding documentation in the [sops-nix README](https://github.com/Mic92/sops-nix?tab=readme-ov-file#usage-example). Once this step is done you should have:

* Any number of key pairs set up for each user (or whatever organizational level suits your needs) that will be using the devshell.
* A .sops.yaml in the repository where your dev shell is defined. This .sops.yaml should include all public keys created.

For more advanced authentication schemes, for instance using Azure Key Vault, see [the sops README](https://github.com/getsops/sops?tab=readme-ov-file#usage).

### 2. Encrypt a secret YAML

Make sure `sops` is installed, either globally or in your devshell.

Then run:

```bash
sops edit secrets.yaml
```

Add some secrets. Any type of nesting is OK. The bubblewrapper will flatten everything to a format where

```yaml
foo:
  bar: baz
list:
  - 0
  - "foo"
  - a: "b"
```

will turn into:

```toml
foo__bar = "baz"
list__0 = "0"
list__1 = "foo"
list__2__a = "b"
```

### 3. Install sops-bwrap.nix into your flake or devenv

#### a. Using flakes

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    sops-bwrap-nix.url = "github:ourstudio-se/sops-bwrap.nix";
  };

  outputs = {
    nixpkgs,
    sops-bwrap-nix,
    ...
  }: {
    # For simplicity's sake, naturally you would want something like flake-utils here...
    devShells."x86_64-linux".default = let
      pkgs = import nixpkgs { system = "x86_64-linux"; };
      sops-bwrap-nix-pkgs = sops-bwrap-nix.packages."x86_64-linux";
    in with pkgs; mkShell {
# ...
    }
  };
}

```


#### b. Using devenv.sh

TODO

### 4. Wrap your target application with `wrapApplication`

```nix
let hurlSops = sops-bwrap-nix-pkgs.lib.wrapApplication {
  package = pkgs.hurl;
  secretsYaml = ./secrets.yaml; # Path to a SOPS-encrypted secrets file (optional)
  configYaml = ./config.yaml; # Path to a non-encrypted YAML file (optional)
  templates = [
    {
      template = "%c%a%r"; # Inject in order <original command> <sops injected arguments> <original command arguments>
      argTemplate = "--secret %k=%v"; # Format each argument as "--secret <key>=<value>"
      allow = [ # Filter that determines which variables will be injected in this way (all secrets beginning with `local__`)
        "^local__"
      ];
      allowConfig = true; # Allow using non-encrypted config for this template (default = true)
      allowSecrets = true; # Allow using encrypted secrets for this template (default = true)
    }
  ];
}
```

Add the wrapped application to your shell packages, build inputs, service declarations, or whatever makes sense for your use case:

```nix
mkShell {
  packages = [
    hurlSops
  ];
}
```

### 5. Enter the devshell

Entering a nix devshell can be done with `nix develop` (if using flakes, devenv.sh, etc) or `nix-shell` (if using `shell.nix`).

If you want to enter using a specific shell that is globally installed, use the `-c` parameter.

```bash
nix develop -c zsh
```


### 6. Run the wrapped command

If you added it to your shell packages, you can now use the wrapped command. Pass `--sops-wrapper-dry-run` to see the command that will actually be run:

```bash
$ hurl ./test.hurl -v --variable test_page_size=1 --sops-wrapper-dry-run
⚡Would run: "/nix/store/0c1by0mdvnv9ksr6h9cymwgw2flbg974-hurl-wrapped/bin/.hurl-wrapped" ./test.hurl -v --variable test_page_size=1 --secret local__client_secret=xxx-yyy-zzz --variable local__client_id=abc
```

## In-depth

### Templating

You can define any number of templates per application. Each template will inject a bunch of config/secrets, if the preconditions defined in `allow`, `allowConfig` and `allowSecrets` are met.

* `allow` is a list of regexes used to test the keys to be injected. For instance, by setting allow to `["^local__" "^test__"]` we define that injection should only happen for properties/items of the root local/test objects/arrays. **An empty array for `allow` means an entirely permissive filter**.
* `allowSecrets` and `allowConfig` allow you to sort from what sources that injections should draw. They correspond to the `secretsYaml` and `configYaml` paths in the `wrapApplication` config. Omitting these means that everything will be allowed.

Templates are evaluated sequentially, and the result of each template injection is passed on to the next template as the `%c` and `%a/%A/%z/%Z` parameters.

#### Template parameters

| Symbol | Description |
|--------|-------------|
| %c     |Injects the original command wrapped by sops-bwrap. Includes the wrapped executable, and any subcommands.             |
| %a     |Injects previously existing ingress arguments (any arguments that previously existed before the original command). Adds a space for padding *before* the arguments.             |
| %A     |Same as above but adds the padding *after* the arguments instead.             |
| %z     |Injects previously existing egress arguments (any arguments that previously existed after the original command). Adds a space for padding *before* the arguments.             |
| %Z     |Same as above but adds the padding *after* the arguments instead.             |
| %v     |Injects the config/secrets parameters formatted via `argTemplate`, separated by spaces. Adds a space for padding *before* the parameters.             |
| %V     |Same as above but adds the padding *after* the parameters instead.             |

The default template string value is `%A%c%z%v`. Since `%v` is placed at the end, the parameters will be added to the very end of the command string. If you want to add them directly after the original command instead, you might want to use `%A%c%v%z` (for instance if the last parameter of the original command has some special significance like a directory or a docker image). If you instead want to add environment variables you might want to use `%V%A%c%z` or `%A%V%c%z` etc...

### Subcommands

TODO: Allow multiple subcommands per application, and maybe subcommands per template?

Subcommands allow you to only apply the parameter injection for certain subcommands of the wrapped application. For instance, with docker, you might want to exclusively wrap `docker run` or `docker buildx`:

```nix
dockerSops = wrapApplication {
  package = pkgs.docker;
  subcommand = "run";
  secretsYaml = ./db.secrets.yaml;
  templates = [
    {
      template = "%A%c%v%z";
      argTemplate = ''-e \"%k=%v\"'';
    }
  ];
};
```

### Namespaces

You can define one or several namespaces per template:

```nix
wrapApplication {
  templates = [
    {
      template = "%A%c%v%z";
      argTemplate = ''-e \"%k=\"%v'';
      namespaces = ["local.db"];
    }
  ];
}
```

This translates into a strip list of regexes, which can also be specified manually. The code above is equal to:

```nix
wrapApplication {
  templates = [
    {
      template = "%A%c%v%z";
      argTemplate = ''-e \"%k=\"%v'';
      strip = ["^local__db__"];
    }
  ];
}
```

Namespaces can be combined with allow lists. Secrets variables are transformed in the following order:

1. Strip list is applied as an *exclusive* filter (any key not matching *ALL* of the patterns is removed)
2. All occurrences of each pattern in the strip list is removed from every variable key.
2. Allow list is applied as an *non-exclusive* filter (any key not matching *ANY* of the patterns is removed)


## Maintainer

Max Bolotin <max@ourstudio.se>
