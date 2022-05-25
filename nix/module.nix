{
  lib,
  pkgs,
  config,
  rootDir,
  ociRegistry,
  ...
}: let
  inherit (lib) mkOption;
  inherit (lib.types) attrsOf submodule attrs str listOf enum ints package nullOr bool oneOf either anything strMatching function path;
  inherit (builtins) concatStringsSep filter isString split toJSON typeOf;

  pp2 = a: b: __trace (__toJSON a) b;
  pp = a: __trace (__toJSON a) a;

  sanitizeServiceName = name:
    lib.pipe name [
      (split "[^[:alnum:]-]+")
      (filter isString)
      (concatStringsSep "-")
    ];

  getImageName = image: "${image.imageName}:${image.imageTag}";

  moduleConfig = config;

  writers = {
    shell = pkgs.callPackage ./writer/shell.nix {};
    elvish = pkgs.callPackage ./writer/elvish.nix {};
    ruby = pkgs.callPackage ./writer/ruby.nix {};
  };

  computeCommand = task: let
    inherit (task) commands name;

    # TODO: some writers may prefer a file path?
    getText = text:
      if builtins.isPath text
      then builtins.readFile text
      else text;

    makeCommand = idx: command:
      writers.${command.type} {
        inherit name;
        inherit (command) runtimeInputs;
        text = getText command.text;
      };

    mapCommand = idx: command: "${makeCommand idx command}/bin/${name}";

    commandsWrapped = lib.concatImapStringsSep "\n" mapCommand task.commands;
  in
    writers.shell {
      inherit name;
      text = commandsWrapped;
    };

  taskNomadType = task: (submodule {
    options = {
      driver = mkOption {
        type = enum ["exec" "nix" "docker" "podman" "java"];
        default = "podman";
      };

      config = mkOption {
        type = attrsOf anything;
        default = {};
      };

      env = mkOption {
        type = attrsOf str;
        default = {};
      };

      resources = mkOption {
        default = {};
        type = submodule {
          options = {
            cpu = mkOption {
              type = ints.positive;
              default = 100;
            };

            memory = mkOption {
              type = ints.positive;
              default = task.memory;
            };

            cores = mkOption {
              type = nullOr ints.positive;
              default = null;
            };
          };
        };
      };

      meta = mkOption {
        type = attrsOf str;
        default = {};
      };

      service = mkOption {
        type = attrsOf anything;
        default = {};
      };
    };

    config = {
      # NOTE: there has to be a better way to get the original value before `apply` ran?
      env = task.oci.env;

      config =
        if task.nomad.driver == "podman"
        then {image = lib.mkDefault (task.oci.image // {__toString = _: getImageName task.oci.image;});}
        else throw "Driver '${task.nomad.driver}' not supported yet";
    };
  });

  commandType = task:
    submodule ({config, ...}: let
      command = config;
    in {
      options = {
        type = mkOption {
          type = enum (lib.attrNames writers);
          default = "shell";
        };

        runtimeInputs = mkOption {
          type = listOf package;
          default = task.dependencies;
        };

        check = mkOption {
          type = bool;
          default = true;
        };

        text = mkOption {
          type = either str path;
        };
      };
    });

  taskType = submodule ({
    name,
    config,
    options,
    ...
  }: let
    task = config;
    presets = {
      nix = import ./preset/nix.nix;
      bash = import ./preset/bash.nix;
      github-ci = import ./preset/github-ci.nix;
    };
  in {
    imports =
      [
        {
          _module.args = {inherit pkgs;};
          preset.bash.enable = lib.mkDefault true;
        }
      ]
      ++ (lib.attrValues presets);

    options = {
      enable = mkOption {
        type = anything;
        default = true;
      };

      after = mkOption {
        type = listOf str;
        default = [];
      };

      action = mkOption {
        default = {};
        type = submodule {
          options = {
            name = mkOption {type = str;};

            id = mkOption {type = str;};

            facts = mkOption {
              default = {};
              type = attrsOf (submodule (
                {name, ...}: {
                  options = {
                    name = mkOption {
                      type = str;
                      default = name;
                    };

                    id = mkOption {type = str;};

                    binary_hash = mkOption {type = str;};

                    value = mkOption {type = attrsOf anything;};
                  };
                }
              ));
            };
          };
        };
      };

      command = mkOption {
        type = commandType task;
      };

      commands = mkOption {
        type = listOf (commandType task);
        default = [task.command];
      };

      computedCommand = mkOption {
        type = package;
        readOnly = true;
        default = computeCommand task;
      };

      closure = mkOption {
        type = attrsOf (either (listOf package) package);
        readOnly = true;
        default = pkgs.getClosure {
          script = task.computedCommand;
          env = task.env;
        };
      };

      dependencies = mkOption {
        type = listOf package;
        default = [];
      };

      env = mkOption {
        type = attrsOf str;
        default = {
          SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        };
      };

      memory = mkOption {
        type = ints.unsigned;
        default = 300;
      };

      name = mkOption {
        type = strMatching "^[[:alnum:]-]+$";
        default = name;
      };

      run = mkOption {
        type = package;
        default = task.${task.runtime}.run;
      };

      runtime = mkOption {
        type = enum ["nsjail" "podman" "unwrapped"];
        default = "nsjail";
      };

      tag = mkOption {
        type = nullOr str;
        default = null;
      };

      workingDir = mkOption {
        type = str;
        default = "/repo";
      };

      oci = mkOption {
        default = {};
        type = submodule ({
          config,
          options,
          ...
        }: let
          ociConfig = config;
          ociOptions = options;
        in {
          options = {
            image = mkOption {
              type = package;
              default = pkgs.buildImage {
                inherit (task.oci) name tag maxLayers contents config;
              };
            };

            name = mkOption {
              type = str;
              default = "${ociRegistry}/${task.name}";
            };

            tag = mkOption {
              type = nullOr str;
              default = task.tag;
            };

            layers = mkOption {
              type = listOf package;
              default = [];
              description = ''
                A list of layers built with the buildLayer function: if a store
                path in deps or contents belongs to one of these layers, this
                store path is skipped. This is pretty useful to isolate store
                paths that are often updated from more stable store paths, to
                speed up build and push time.
              '';
            };

            contents = mkOption {
              type = listOf package;
              description = ''
                A list of store paths to include in the layer root. The store
                path prefix /nix/store/hash-path is removed. The store path
                content is then located at the image /.
              '';
            };

            fromImage = mkOption {
              type = str;
              default = "";
              description = ''
                An image that is used as the base image of this image.
              '';
            };

            perms = mkOption {
              default = [];
              type = listOf (submodule {
                options = {
                  path = mkOption {
                    type = str;
                    description = "a store path";
                  };

                  regex = mkOption {
                    type = str;
                    example = ".*";
                  };

                  mode = mkOption {
                    type = str;
                    example = "0664";
                  };
                };
              });
            };

            maxLayers = mkOption {
              type = ints.positive;
              default = 30;
              description = ''
                The maximun number of layer to create. This is based on the
                store path "popularity" as described in
                https://grahamc.com/blog/nix-and-layered-docker-images Note
                this is applied on the image layers and not on layers added
                with the buildImage.layers attribute
              '';
            };

            cmd = mkOption {
              type = listOf str;
              default = [];
              description = ''
                Default arguments to the entrypoint of the
                container. These values act as defaults and may
                be replaced by any specified when creating a
                container. If an Entrypoint value is not
                specified, then the first entry of the Cmd array
                SHOULD be interpreted as the executable to run.
              '';
            };

            entrypoint = mkOption {
              type = listOf str;
              default = [];
              description = ''
                A list of arguments to use as the command to
                execute when the container starts. These values
                act as defaults and may be replaced by an
                entrypoint specified when creating a container.
              '';
            };

            exposedPorts = mkOption {
              type = attrsOf bool;
              default = {};
              description = ''
                A set of ports to expose from a container running
                this image. Its keys can be in the format of:
                port/tcp, port/udp, port with the default
                protocol being tcp if not specified. These values
                act as defaults and are merged with any specified
                when creating a container.
                NOTE: This JSON structure value is unusual
                because it is a direct JSON serialization of the
                Go type map[string]struct{} and is represented in
                JSON as an object mapping its keys to an empty
                object.
                For this config, we filter out all keys with
                false values.
              '';
            };

            env = mkOption {
              type = attrsOf str;
              default = {};
              description = ''
                Entries are in the format of VARNAME=VARVALUE.
                These values act as defaults and are merged with
                any specified when creating a container.
              '';
            };

            volumes = mkOption {
              type = attrsOf anything;
              default = {};
              description = ''
                A set of directories describing where the
                process is likely to write data specific to a
                container instance. NOTE: This JSON structure
                value is unusual because it is a direct JSON
                serialization of the Go type
                map[string]struct{} and is represented in JSON
                as an object mapping its keys to an empty
                object.
              '';
            };

            workingDir = mkOption {
              type = str;
              default = task.workingDir;
              description = ''
                Sets the current working directory of the entrypoint
                process in the container. This value acts as a default
                and may be replaced by a working directory specified when
                creating a container.
              '';
            };

            labels = mkOption {
              type = attrsOf str;
              default = {};
              description = ''
                The field contains arbitrary metadata for the container.
                This property MUST use the annotation rules.
                https://github.com/opencontainers/image-spec/blob/main/annotations.md#rules
              '';
            };

            stopSignal = mkOption {
              type = str;
              default = "";
              description = ''
                The field contains the system call signal that will be
                sent to the container to exit. The signal can be a signal
                name in the format SIGNAME, for instance SIGKILL or
                SIGRTMIN+3.
              '';
            };

            user = mkOption {
              type = str;
              default = "";
              description = ''
                The username or UID which is a platform-specific
                structure that allows specific control over which
                user the process run as. This acts as a default
                value to use when the value is not specified when
                creating a container. For Linux based systems,
                all of the following are valid: user, uid,
                user:group, uid:gid, uid:group, user:gid. If
                group/gid is not specified, the default group and
                supplementary groups of the given user/uid in
                /etc/passwd from the container are applied.
              '';
            };

            config = mkOption {
              default = {};
              type = submodule (imageConfig: {
                options = let
                  toGoStruct = m: lib.mapAttrs (k: v: {}) (lib.filterAttrs (k: v: v) m);
                in {
                  Cmd = mkOption {
                    default = ociConfig.cmd;
                    inherit (ociOptions.cmd) type description;
                  };

                  Entrypoint = mkOption {
                    default = ociConfig.entrypoint;
                    inherit (ociOptions.entrypoint) type description;
                  };

                  ExposedPorts = mkOption {
                    type = attrsOf attrs;
                    default = toGoStruct ociConfig.exposedPorts;
                    inherit (ociOptions.exposedPorts) description;
                  };

                  Env = mkOption {
                    type = listOf str;
                    default = pkgs.lib.mapAttrsToList (k: v: "${k}=${v}") ociConfig.env;
                    inherit (ociOptions.env) description;
                  };

                  User = mkOption {
                    default = ociConfig.user;
                    inherit (ociOptions.user) type description;
                  };

                  Volumes = mkOption {
                    type = attrsOf attrs;
                    default = toGoStruct ociConfig.volumes;
                    inherit (ociOptions.volumes) description;
                  };

                  WorkingDir = mkOption {
                    default = ociConfig.workingDir;
                    inherit (ociOptions.workingDir) type description;
                  };

                  Labels = mkOption {
                    default = ociConfig.labels;
                    inherit (ociOptions.labels) type description;
                  };

                  StopSignal = mkOption {
                    default = ociConfig.stopSignal;
                    inherit (ociOptions.stopSignal) type description;
                  };
                };
              });
            };
          };

          config = let
            script = computeCommand task;
            inherit (task.closure) closure;
          in {
            layers = lib.mkDefault [rootDir];

            contents = lib.mkDefault [
              (pkgs.symlinkJoin {
                name = "root";
                paths = [closure] ++ task.dependencies;
              })
            ];

            cmd = lib.mkDefault ["${script}/bin/${task.name}"];
            env = lib.mapAttrs (key: value: lib.mkDefault value) task.env;
            volumes."/local" = lib.mkDefault true;
            volumes."/tmp" = lib.mkDefault true;
          };
        });
      };

      nomad = mkOption {
        default = {};
        type = taskNomadType config;
      };

      podman = mkOption {
        default = {};
        type = submodule (podman: {
          options = {
            run = mkOption {
              type = package;
              description = ''
                Copy the task to local podman and execute it
              '';
              default = let
                flags = {
                  v = [
                    ''"$alloc:/alloc"''
                    ''"$HOME/.netrc:/local/.netrc"''
                    ''"$HOME/.docker/config.json:/local/.docker/config.json"''
                    ''"$PWD:/repo"''
                  ];
                  rmi = false;
                  rm = true;
                  # tty = false;
                  # interactive = true;
                };
                imageName = getImageName config.oci.image;
              in
                writers.shell {
                  name = "${config.name}-podman";
                  runtimeInputs = [pkgs.coreutils-full pkgs.podman config.oci.image.copyTo];
                  text = ''
                    # Podman _can_ work without new(g|u)idmap, but user
                    # mapping will be a bit wonky.
                    # The problem is that they require suid, so we have to
                    # point to the impure location of them.
                    suidDir="$(dirname "$(command -v newuidmap)")"
                    export PATH="$PATH:$suidDir"
                    alloc="''${alloc:-$(mktemp -d -t alloc.XXXXXXXXXX)}"
                    function finish {
                      rm -rf "$alloc"
                    }
                    trap finish EXIT
                    copy-to containers-storage:${imageName}
                    if tty -s; then
                      echo "" | exec podman run --tty ${toString (lib.cli.toGNUCommandLine {} flags)} ${imageName}
                    else
                      echo "" | exec podman run ${toString (lib.cli.toGNUCommandLine {} flags)} ${imageName}
                    fi
                  '';
                };
            };

            useHostStore = mkOption {
              type = bool;
              default = true;
            };
          };
        });
      };

      nsjail = mkOption {
        default = {};
        type = submodule {
          options = {
            run = mkOption {
              type = package;
              description = ''
                Execute the task in a nsjail sandbox
              '';
              default = let
                c = config.nsjail;

                toMountFlag = lib.mapAttrsToList (_: {
                  from,
                  to,
                  type,
                  options,
                }: "${from}:${to}:${type}:${lib.concatStringsSep "," (lib.mapAttrsToList (
                    n: v: let
                      converted =
                        if n == "size"
                        then v * 1024 * 1024 # megabytes to bytes
                        else v;
                    in "${n}=${toString converted}"
                  )
                  options)}");

                flags = {
                  quiet = c.quiet;
                  verbose = c.verbose;
                  time_limit = c.timeLimit;
                  disable_clone_newnet = !c.cloneNewnet;
                  rlimit_as = c.rlimit.as;
                  rlimit_core = c.rlimit.core;
                  rlimit_cpu = c.rlimit.cpu;
                  rlimit_fsize = c.rlimit.fsize;
                  rlimit_nofile = c.rlimit.nofile;
                  rlimit_nproc = c.rlimit.nproc;
                  rlimit_stack = c.rlimit.stack;
                  cgroup_cpu_ms_per_sec = c.cgroup.cpuMsPerSec;
                  cgroup_mem_max = c.cgroup.memMax;
                  cgroup_net_cls_classid = c.cgroup.netClsClassid;
                  cgroup_pids_max = c.cgroup.pidsMax;
                  skip_setsid = !c.setsid;
                  cwd = c.cwd;
                  bindmount = c.bindmount.rw;
                  bindmount_ro = c.bindmount.ro;
                  mount = toMountFlag c.mount;
                  env = lib.mapAttrsToList (k: v: lib.escapeShellArg "${k}=${v}") (config.env);
                };
              in
                writers.shell {
                  name = "${config.name}-nsjail";
                  runtimeInputs = with pkgs; [coreutils nsjail];
                  text = ''
                    # TODO: This is tied to systemd... find a way to make it cross-platform.
                    uid="''${UID:-$(id -u)}"
                    gid="''${GID:-$(id -g)}"

                    cgroupV2Mount="/sys/fs/cgroup/user.slice/user-$uid.slice/user@$uid.service"
                    if [ ! -d "$cgroupV2Mount" ]; then
                      unset cgroupV2Mount
                    fi

                    alloc="''${alloc:-$(mktemp -d -t alloc.XXXXXXXXXX)}"
                    root="$(mktemp -d -t root.XXXXXXXXXX)"
                    mkdir -p "$root"/{etc,tmp,local,bin,usr/bin}
                    ln -s ${pkgs.bashInteractive}/bin/sh "$root/bin/sh"
                    ln -s ${pkgs.coreutils}/usr/bin/env "$root/usr/bin/env"

                    function finish {
                      status="$?"
                      chmod u+w -R "$root" 2>/dev/null
                      rm -rf "$alloc" "$root"
                      exit "$status"
                    }
                    trap finish EXIT

                    echo "nixbld:x:$uid:nixbld1" > "$root/etc/group"
                    echo "nixbld1:x:$uid:$gid:nixbld 1:/local:${pkgs.shadow}/bin/nologin" > "$root/etc/passwd"
                    echo "nixbld1:$gid:100" > "$root/etc/subgid"
                    echo "nixbld1:$uid:100" > "$root/etc/subuid"

                    nsjail -Mo ${toString (lib.cli.toGNUCommandLine {} flags)} \
                      --user "$uid" \
                      --group "$gid" \
                      ''${cgroupV2Mount:+--use_cgroupv2} \
                      ''${cgroupV2Mount:+--cgroupv2_mount "$cgroupV2Mount"} \
                      -- ${lib.escapeShellArg "${computeCommand task}/bin/${config.name}"}
                  '';
                };
            };

            setsid = mkOption {
              type = bool;
              default = true;
              description = ''
                setsid runs a program in a new session.
                Disabling this allows for terminal signal handling in the
                sandboxed process which may be dangerous.
              '';
            };

            quiet = mkOption {
              type = bool;
              default = true;
            };

            verbose = mkOption {
              type = bool;
              default = false;
            };

            timeLimit = mkOption {
              type = ints.unsigned;
              default = 30;
            };

            cloneNewnet = mkOption {
              type = bool;
              default = false;
            };

            cwd = mkOption {
              type = str;
              default = task.workingDir;
              description = "change to this directory before starting the script startup";
            };

            bindmount = mkOption {
              default = {};
              type = submodule {
                options = {
                  rw = mkOption {
                    type = listOf str;
                    default = [];
                  };

                  ro = mkOption {
                    type = listOf str;
                    default = [];
                  };
                };
              };
            };

            mount = mkOption {
              default = {};

              type = attrsOf (submodule
                ({name, ...}: {
                  options = {
                    from = mkOption {
                      type = str;
                      default = "none";
                    };

                    to = mkOption {
                      type = str;
                      default = name;
                    };

                    type = mkOption {
                      type = enum ["tmpfs"];
                      default = "tmpfs";
                    };

                    options = mkOption {
                      type = attrsOf anything;
                    };
                  };
                }));
            };

            cgroup = mkOption {
              default = {};
              type = submodule {
                options = {
                  memMax = mkOption {
                    type = ints.unsigned;
                    default = task.memory * 1024 * 1024;
                    description = "Maximum number of bytes to use in the group. 0 is disabled";
                  };

                  pidsMax = mkOption {
                    type = ints.unsigned;
                    default = 0;
                    description = "Maximum number of pids in a cgroup. 0 is disabled";
                  };

                  netClsClassid = mkOption {
                    type = ints.unsigned;
                    default = 0;
                    description = "Class identifier of network packets in the group. 0 is disabled";
                  };

                  cpuMsPerSec = mkOption {
                    type = ints.unsigned;
                    default = 0;
                    description = "Number of milliseconds of CPU time per second that the process group can use. 0 is disabled";
                  };
                };
              };
            };

            rlimit = mkOption {
              default = {};
              type = submodule {
                options = {
                  as = mkOption {
                    type = oneOf [(enum ["max" "hard" "def" "soft" "inf"]) ints.unsigned];
                    default = "max";
                    description = "virtual memory size limit in MB";
                  };

                  core = mkOption {
                    type = oneOf [(enum ["max" "hard" "def" "soft" "inf"]) ints.unsigned];
                    default = "max";
                    description = "CPU time in seconds";
                  };

                  cpu = mkOption {
                    type = oneOf [(enum ["max" "hard" "def" "soft" "inf"]) ints.unsigned];
                    default = "max";
                    description = "CPU time in seconds";
                  };

                  fsize = mkOption {
                    type = oneOf [(enum ["max" "hard" "def" "soft" "inf"]) ints.unsigned];
                    default = "max";
                    description = "Maximum file size.";
                  };

                  nofile = mkOption {
                    type = oneOf [(enum ["max" "hard" "def" "soft" "inf"]) ints.unsigned];
                    default = "max";
                    description = "Maximum number of open files.";
                  };

                  nproc = mkOption {
                    type = oneOf [(enum ["max" "hard" "def" "soft" "inf"]) ints.unsigned];
                    default = "soft";
                    description = "Maximum number of processes.";
                  };

                  stack = mkOption {
                    type = oneOf [(enum ["max" "hard" "def" "soft" "inf"]) ints.unsigned];
                    default = "inf";
                    description = "Maximum size of the stack.";
                  };
                };
              };
            };
          };
        };
      };

      unwrapped = mkOption {
        default = {};
        type = submodule {
          options = {
            run = mkOption {
              type = package;
              description = ''
                Simply run the task without any container
              '';
              default = writers.shell {
                name = "${task.name}-unwrapped";
                runtimeInputs = task.dependencies;
                text = ''
                  ${lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}") config.env)}
                  ${computeCommand task}/bin/${task.name}
                '';
              };
            };
          };
        };
      };
    };

    config = {
      commands = lib.mkDefault [task.command];
    };
  });

  jobType = submodule ({name, ...}: {
    options = {
      namespace = mkOption {
        type = str;
        default = "default";
      };

      datacenters = mkOption {
        type = listOf str;
        default = ["dc1"];
      };

      type = mkOption {
        type = enum ["batch" "service" "batch" "sysbatch"];
        default = "batch";
      };

      group = mkOption {
        default = {};
        type = attrsOf (submodule ({...}: {
          options = {
            reschedule = mkOption {
              type = attrsOf anything;
              default = {};
            };

            restart = mkOption {
              type = attrsOf anything;
              default = {};
            };

            task = mkOption {
              default = {};
              # FIXME: somehow the value of this apply ends up being the
              # whole job first and thus doesn't match the type...
              # type = attrsOf taskType;
              type = attrsOf anything;
              apply = lib.mapAttrs (name: value: (value.nomad or value));
            };
          };
        }));
      };
    };
  });

  actionType = submodule ({
    name,
    config,
    ...
  }: let
    action = config;
  in {
    options = {
      io = mkOption {
        type = path;
        apply = v: let
          def = pkgs.runCommand "def.cue" {nativeBuildInputs = [pkgs.cue];} ''
            cue def --simplify > $out \
              ${../lib/prelude.cue} \
              ${../lib/github.cue} \
              ${../lib/slack.cue} \
              ${v}
          '';
        in
          lib.fileContents def;
      };

      job = mkOption {
        type = attrsOf jobType;
      };

      task = mkOption {
        type = nullOr str;
        default = null;
      };

      prepare = mkOption {
        type = anything;
        default = let
          mapped = lib.flatten (
            lib.mapAttrsToList (
              jobName: job:
                lib.mapAttrsToList (
                  groupName: group:
                    lib.mapAttrsToList (
                      taskName: task:
                        if task.config ? image
                        then {
                          type = "nix2container";
                          name = getImageName task.config.image;
                          imageDrv = task.config.image.drvPath;
                        }
                        else null
                    )
                    group.task
                )
                job.group
            )
            action.job
          );
        in
          lib.filter lib.isAttrs mapped;
      };
    };

    config = lib.mkIf (action.task != null) (let
      sname = sanitizeServiceName name;
    in {
      job.${sname}.group.tullia.task.tullia = moduleConfig.wrappedTask."${action.task}";
    });
  });
in {
  options = {
    action = mkOption {
      default = {};
      type = attrsOf actionType;
    };

    job = mkOption {
      default = {};
      type = attrsOf jobType;
    };

    task = mkOption {
      default = {};
      type = attrsOf taskType;
    };

    wrappedTask = mkOption {
      default = {};
      type = attrsOf taskType;
    };

    dag = mkOption {
      default = {};
      type = attrsOf anything;
    };
  };

  config = let
    enabledTasks = lib.filterAttrs (name: task: task.enable != null && task.enable != false) config.task;
  in {
    dag = lib.mapAttrs (name: task: task.after) enabledTasks;

    wrappedTask = let
      bin = lib.mapAttrs (n: v: "${v.unwrapped.run}/bin/${n}-unwrapped") enabledTasks;

      spec = lib.escapeShellArg (builtins.toJSON {
        inherit (config) dag;
        inherit bin;
      });
    in
      lib.mapAttrs' (
        n: v: {
          name = n;
          value = {
            dependencies = [pkgs.tullia];
            command.text = ''
              exec tullia run ${n} --run-spec ${spec} --mode passthrough --runtime unwrapped
            '';
            nsjail.setsid = true;
            oci.maxLayers = 30;
          };
        }
      )
      enabledTasks;
  };
}
