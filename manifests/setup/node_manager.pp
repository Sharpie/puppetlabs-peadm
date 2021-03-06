# This profile is not intended to be continously enforced on PE masters.
# Rather, it describes state to enforce as a boostrap action, preparing the
# Puppet Enterprise console with a sane default environment configuration.
#
# This class will be applied during master bootstrap using e.g.
#
#     puppet apply \
#       --exec 'class { "peadm::setup::node_manager":
#                 environments => ["production", "staging", "development"],
#               }'
#
class peadm::setup::node_manager (
  # Common
  String[1] $master_host,
  String[1] $compiler_pool_address,

  # High Availability
  Optional[String[1]] $master_replica_host            = undef,

  # For the next two parameters, the default values are appropriate when
  # deploying Standard or Large architectures. These values only need to be
  # specified differently when deploying an Extra Large architecture.

  # Specify when using Extra Large
  String[1]           $puppetdb_database_host         = $master_host,

  # Specify when using Extra Large AND High Availability
  Optional[String[1]] $puppetdb_database_replica_host = $master_replica_host,
) {

  ##################################################
  # PE INFRASTRUCTURE GROUPS
  ##################################################

  # Hiera data tuning for compilers
  $compiler_data = {
    'puppet_enterprise::profile::puppetdb' => {
      'gc_interval' => '0',
    },
    'puppet_enterprise::puppetdb' => {
      'command_processing_threads' => 2,
      'write_maximum_pool_size'    => 4,
      'read_maximum_pool_size'     => 8,
    },
  }

  # We modify this group's rule such that all PE infrastructure nodes will be
  # members.
  node_group { 'PE Infrastructure Agent':
    rule => ['and', ['~', ['trusted', 'extensions', peadm::oid('peadm_role')], '^puppet/']],
  }

  # We modify this group to add, as data, the compiler_pool_address only.
  # Because the group does not have any data by default this does not impact
  # out-of-box configuration of the group.
  node_group { 'PE Master':
    parent    => 'PE Infrastructure',
    rule      => ['or',
      ['and', ['=', ['trusted', 'extensions', peadm::oid('peadm_role')], 'puppet/compiler']],
      ['=', 'name', $master_host],
    ],
    data      => {
      'pe_repo' => { 'compile_master_pool_address' => $compiler_pool_address },
    },
    variables => { 'pe_master' => true },
  }

  # Create the database group if a database host is external
  if ($puppetdb_database_host != $master_host) {
    # This class has to be included here because puppet_enterprise is declared
    # in the console with parameters. It is therefore not possible to include
    # puppet_enterprise::profile::database in code without causing a conflict.
    node_group { 'PE Database':
      ensure               => present,
      parent               => 'PE Infrastructure',
      environment          => 'production',
      override_environment => false,
      rule                 => ['or',
        ['and', ['=', ['trusted', 'extensions', peadm::oid('peadm_role')], 'puppet/puppetdb-database']],
        ['=', 'name', $master_host],
      ],
      classes              => {
        'puppet_enterprise::profile::database' => { },
      },
    }
  }

  # Create data-only groups to store PuppetDB PostgreSQL database configuration
  # information specific to the master and master replica nodes.
  node_group { 'PE Master A':
    ensure => present,
    parent => 'PE Infrastructure',
    rule   => ['and',
      ['=', ['trusted', 'extensions', peadm::oid('peadm_role')], 'puppet/master'],
      ['=', ['trusted', 'extensions', peadm::oid('peadm_availability_group')], 'A'],
    ],
    data   => {
      'puppet_enterprise::profile::primary_master_replica' => {
        'database_host_puppetdb' => $puppetdb_database_host,
      },
      'puppet_enterprise::profile::puppetdb'               => {
        'database_host' => $puppetdb_database_host,
      },
    },
  }

  # Configure the A pool for compilers. There are up to two pools for HA, each
  # having an affinity for one "availability zone" or the other.
  node_group { 'PE Compiler Group A':
    ensure  => 'present',
    parent  => 'PE Master',
    rule    => ['and',
      ['=', ['trusted', 'extensions', peadm::oid('peadm_role')], 'puppet/compiler'],
      ['=', ['trusted', 'extensions', peadm::oid('peadm_availability_group')], 'A'],
    ],
    classes => {
      'puppet_enterprise::profile::puppetdb' => {
        'database_host' => $puppetdb_database_host,
      },
      'puppet_enterprise::profile::master'   => {
        'puppetdb_host' => ['${clientcert}', $master_replica_host].filter |$_| { $_ }, # lint:ignore:single_quote_string_with_variables
        'puppetdb_port' => [8081],
      }
    },
    data    => $compiler_data,
  }

  # Create the replica and B groups if a replica master and database host are
  # supplied
  if $master_replica_host {
    # We need to pre-create this group so that the master replica can be
    # identified as running PuppetDB, so that Puppet will create a pg_ident
    # authorization rule for it on the PostgreSQL nodes.
    node_group { 'PE HA Replica':
      ensure    => 'present',
      parent    => 'PE Infrastructure',
      rule      => ['or', ['=', 'name', $master_replica_host]],
      classes   => {
        'puppet_enterprise::profile::primary_master_replica' => { }
      },
      variables => { 'peadm_replica' => true },
    }

    node_group { 'PE Master B':
      ensure => present,
      parent => 'PE Infrastructure',
      rule   => ['and',
        ['=', ['trusted', 'extensions', peadm::oid('peadm_role')], 'puppet/master'],
        ['=', ['trusted', 'extensions', peadm::oid('peadm_availability_group')], 'B'],
      ],
      data   => {
        'puppet_enterprise::profile::primary_master_replica' => {
          'database_host_puppetdb' => $puppetdb_database_replica_host,
        },
        'puppet_enterprise::profile::puppetdb'               => {
          'database_host' => $puppetdb_database_replica_host,
        },
      },
    }

    node_group { 'PE Compiler Group B':
      ensure  => 'present',
      parent  => 'PE Master',
      rule    => ['and',
        ['=', ['trusted', 'extensions', peadm::oid('peadm_role')], 'puppet/compiler'],
        ['=', ['trusted', 'extensions', peadm::oid('peadm_availability_group')], 'B'],
      ],
      classes => {
        'puppet_enterprise::profile::puppetdb' => {
          'database_host' => $puppetdb_database_replica_host,
        },
        'puppet_enterprise::profile::master'   => {
          'puppetdb_host' => ['${clientcert}', $master_host], # lint:ignore:single_quote_string_with_variables
          'puppetdb_port' => [8081],
        }
      },
      data    => $compiler_data,
    }
  }

}
