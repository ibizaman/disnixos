{nixpkgs, pkgs}:

let
  evalConfig = import "${nixpkgs}/nixos/lib/eval-config.nix";
  inherit (builtins) getAttr attrNames removeAttrs unsafeDiscardOutputDependency hashString;
in
rec {
  /**
   * Fetches the key value that is used to refer to a target machine.
   * If a target defines a 'targetProperty' then the corresponding attribute
   * is used. If no targetProperty is provided by the target, then the global
   * targetProperty is used.
   *
   * Parameters:
   * targetProperty: Attribute from the infrastructure model that is used to connect to the Disnix interface
   * target: An attributeset containing properties of a target machine
   *
   * Returns
   * A string containing the key value
   */
  getTargetProperty = targetProperty: target:
    if target ? targetProperty then getAttr (target.targetProperty) target
    else getAttr targetProperty target
  ;

  /*
   * Takes a collection of NixOS network expressions and zips them into a list of
   * NixOS modules.
   *
   * Parameters:
   * networkFiles: A list of strings containing paths to NixOS network expressions
   * nixOpsModel: Indicates whether the configuration is a NixOps model so that certain attributes are ignored.
   *
   * Returns:
   * An attribute set in which the names refer to machine names and values to lists of NixOS modules
   */
  generateMergedNetwork = networkFiles: nixOpsModel:
    let
      networks = map (networkFile: import networkFile) networkFiles;
      mergedNetwork = pkgs.lib.zipAttrs networks;
    in
    if nixOpsModel then removeAttrs mergedNetwork [ "network" "resources" ] else mergedNetwork; # A NixOps model has a reserved network attributes that cannot be machines
  
  /*
   * Takes a merged network configuration and evaluates them producing a config
   * attribute for each of them.
   *
   * Parameters:
   * enableDisnix: Indicates whether Disnix must be enabled
   * nixOpsModel: Indicates whether we should use NixOps specific settings
   * useVMTesting: Indicates whether we should enable NixOS test instrumentation and VM settings
   * useBackdoor: Indicates whether we should enable the backdoor
   * dysnomia: Path to Dysnomia
   * nixops: Path to NixOps
   *
   * Returns:
   * An attribute set with evaluated machine configuration properties
   */
  generateConfigurations = network: enableDisnix: nixOpsModel: useVMTesting: useBackdoor: dysnomia: nixops:
    pkgs.lib.mapAttrs (targetName: configuration:
      evalConfig {
        modules = configuration ++ [
          ./disnix-infrastructure-module.nix
        ] ++ [
          {
            key = "disnix-infrastructure";
            networking.hostName = pkgs.lib.mkOverride 900 targetName;
            disnixInfrastructure.enable = true;
            disnixInfrastructure.enableAuthentication = true;
            disnixInfrastructure.generateContainersExpr = "${dysnomia}/share/dysnomia/generate-containers.nix";
          }
        ]
        ++ pkgs.lib.optional enableDisnix {
          key = "enable-disnix";
          services.disnix.enable = true;
        }
        ++ pkgs.lib.optionals useVMTesting [
          "${nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix"
          "${nixpkgs}/nixos/modules/testing/test-instrumentation.nix"
        ]
        ++ pkgs.lib.optional useBackdoor {
          key = "backdoor";
          disnixInfrastructure.properties.backdoor = "TCP:${targetName}:512";
        }
        ++ pkgs.lib.optional nixOpsModel {
          key = "nixops-stuff";
          # Make NixOps's deployment.* options available.
          require = [ "${nixops}/share/nix/nixops/options.nix" ];
          # Provide a default hostname and deployment target equal
          # to the attribute name of the machine in the model.
          deployment.targetHost = pkgs.lib.mkOverride 900 targetName;
          environment.checkConfigurationOptions = false; # We assume that NixOps has already checked it
        };
        extraArgs = { nodes = generateConfigurations network enableDisnix nixOpsModel useVMTesting useBackdoor dysnomia nixops; };
      }) network;

  /*
   * Generates a list of NixOS system profiles mapped to target machines.
   *
   * Parameters:
   * configurations: An attribute set with evaluated configurations
   * targetProperty: Attribute from the infrastructure model that is used to connect to the Disnix interface
   *
   * Returns:
   * A list of attribute sets in which NixOS profiles are mapped to target machines
   */
  generateProfiles = configurations: targetProperty:
    map (targetName:
      let
        machine = getAttr targetName configurations;
        infrastructure = machine.config.disnixInfrastructure.infrastructure;
      in
      {
        profile = machine.config.system.build.toplevel.outPath;
        target = getTargetProperty targetProperty infrastructure;
      }
    ) (attrNames configurations)
  ;
  
  /*
   * Generates a list of activation items specifying on which machine to activate a NixOS configuration.
   *
   * Parameters:
   * configurations: An attribute set with evaluated configurations
   * targetProperty: Attribute from the infrastructure model that is used to connect to the Disnix interface
   *
   * Returns:
   * A list of attribute sets representing activation items
   */
  generateActivationMappings = configurations: targetProperty:
    map (targetName:
      let
        machine = getAttr targetName configurations;
        infrastructure = machine.config.disnixInfrastructure.infrastructure;
      in
      { _key = hashString "sha256" (builtins.toXML {
          service = machine.config.system.build.toplevel.outPath;
          name = targetName;
          type = "nixos-configuration";
          dependsOn = [];
        });
        name = targetName;
        service = machine.config.system.build.toplevel.outPath;
        target = getTargetProperty targetProperty infrastructure;
        container = "nixos-configuration";
        dependsOn = [];
        type = "nixos-configuration";
      }
    ) (attrNames configurations)
  ;
  
  /*
   * Generates a list of snapshot items specifying on which machines to snapshot the state of a NixOS configuration.
   *
   * Parameters:
   * configurations: An attribute set with evaluated configurations
   * targetProperty: Attribute from the infrastructure model that is used to connect to the Disnix interface
   *
   * Returns:
   * A list of attribute sets representing snapshot items
   */
  generateSnapshotMappings = configurations: targetProperty:
    map (targetName:
      let
        machine = getAttr targetName configurations;
        infrastructure = machine.config.disnixInfrastructure.infrastructure;
        service = machine.config.system.build.toplevel.outPath;
        target = getTargetProperty targetProperty infrastructure;
      in
      {
        component = builtins.substring 33 (builtins.stringLength service) (builtins.baseNameOf service);
        container = "nixos-configuration";
        type = "nixos-configuration";
        inherit service target;
      }
    ) (attrNames configurations)
  ;
  
  /*
   * Generates a list of machines that are involved in the deployment process.
   *
   * Parameters:
   * configurations: An attribute set with evaluated configurations
   * targetProperty: Attribute from the infrastructure model that is used to connect to the Disnix interface
   * clientInterface: Path to the executable used to connect to the Disnix interface
   *
   * Returns:
   * A list of strings with connection attributes of each machine that is used
   */
  generateTargetPropertyList = configurations: targetProperty: clientInterface:
    map (targetName:
      let
        machine = getAttr targetName configurations;
        infrastructure = machine.config.disnixInfrastructure.infrastructure;
      in
      infrastructure // {
        targetProperty = if infrastructure ? targetProperty then infrastructure.targetProperty else targetProperty;
        clientInterface = if infrastructure ? clientInterface then infrastructure.clientInterface else clientInterface;
        numOfCores = 1;
      }
    ) (attrNames configurations)
  ;

  /*
   * Generates a manifest file consisting of a profile mapping and
   * service activation mapping from the 3 Disnix models.
   *
   * Parameters:
   * network: An evaluated network with machine configurations
   * targetProperty: Attribute from the infrastructure model that is used to connect to the Disnix interface
   * clientInterface: Path to the executable used to connect to the Disnix interface
   * enableDisnix: Indicates whether Disnix must be enabled
   * nixOpsModel: Indicates whether we should use NixOps specific settings
   * useVMTesting: Indicates whether we should enable NixOS test instrumentation and VM settings
   * useBackdoor: Indicates whether we should enable the backdoor
   * dysnomia: Path to Dysnomia
   * nixops: Path to NixOps
   *
   * Returns:
   * An attributeset which should be exported to XML representing the manifest
   */
  generateManifest = network: targetProperty: clientInterface: enableDisnix: nixOpsModel: useVMTesting: useBackdoor: dysnomia: nixops:
    let
      configurations = generateConfigurations network enableDisnix nixOpsModel useVMTesting useBackdoor dysnomia nixops;
    in
    { profiles = generateProfiles configurations targetProperty;
      activation = generateActivationMappings configurations targetProperty;
      snapshots = generateSnapshotMappings configurations targetProperty;
      targets = generateTargetPropertyList configurations targetProperty clientInterface;
    };
  
  /*
   * Generates a distributed derivation file constisting of a mapping of store derivations
   * to machines from the 3 Disnix models.
   *
   * Parameters:
   * network: An evaluated network with machine configurations
   * targetProperty: Attribute from the infrastructure model that is used to connect to the Disnix interface
   * clientInterface: Path to the executable used to connect to the Disnix interface
   * enableDisnix: Indicates whether Disnix must be enabled
   * nixOpsModel: Indicates whether we should use NixOps specific settings
   * useVMTesting: Indicates whether we should enable NixOS test instrumentation and VM settings
   * useBackdoor: Indicates whether we should enable the backdoor
   * dysnomia: Path to Dysnomia
   * nixops: Path to NixOps
   *
   * Returns: 
   * An attributeset which should be exported to XML representing the distributed derivation
   */
  generateDistributedDerivation = network: targetProperty: clientInterface: enableDisnix: nixOpsModel: useVMTesting: useBackdoor: dysnomia: nixops:
    let
      configurations = generateConfigurations network enableDisnix nixOpsModel useVMTesting useBackdoor dysnomia nixops;
    in
    {
      build = map (targetName:
        let
          machine = getAttr targetName configurations;
          infrastructure = machine.config.disnixInfrastructure.infrastructure;
        in
        { derivation = unsafeDiscardOutputDependency (machine.config.system.build.toplevel.drvPath);
          target = getTargetProperty targetProperty infrastructure;
        }
      ) (attrNames configurations);
    
      interfaces = map (targetName:
        let
          machine = getAttr targetName configurations;
          infrastructure = machine.config.disnixInfrastructure.infrastructure;
        in
        { target = getTargetProperty targetProperty infrastructure;
          clientInterface = if infrastructure ? clientInterface then infrastructure.clientInterface else clientInterface;
        }
      ) (attrNames configurations);
    }
  ;
}
