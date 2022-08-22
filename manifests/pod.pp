# @summary Create a podman pod with defined flags
#
# @param ensure
#   State of the resource, which must be either 'present' or 'absent'.
#
# @param flags
#   All flags for the 'podman pod create' command are supported, using only the
#   long form of the flag name.  The resource name (namevar) will be used as the
#   pod name unless the 'name' flag is included in the hash of flags.
#
# @param user
#   Optional user for running rootless containers.  When using this parameter,
#   the user must also be defined as a Puppet resource and must include the
#   'uid', 'gid', and 'home'
#
# @param kube_yaml
#   String containing YAML to build pod and containers. Kube YAML is generated using
#   podman generate kube command.
#
# @example
#   podman::pod { 'mypod':
#     flags => {
#              label => 'use=test, app=wordpress',
#              }
#   }
#
define podman::pod (
  Enum['present', 'absent'] $ensure = 'present',
  Hash $flags                       = {},
  String $user                      = '',
  Optional[String] $kube_yaml       = undef,
) {
  require podman::install

  if $user != '' {
    ensure_resource('podman::rootless', $user, {})
    $systemctl = 'systemctl --user '
    $service_unit_dir = "${User[$user]['home']}/.config/systemd/user"

    # Set execution environment for the rootless user
    $exec_defaults = {
      path        => '/sbin:/usr/sbin:/bin:/usr/bin',
      environment => [
        "HOME=${User[$user]['home']}",
        "XDG_RUNTIME_DIR=/run/user/${User[$user]['uid']}",
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${User[$user]['uid']}/bus",
      ],
      cwd         => User[$user]['home'],
      provider    => 'shell',
      user        => $user,
      require     => [
        Podman::Rootless[$user],
        Service['podman systemd-logind'],
      ],
    }

    # Reload systemd when service files are updated
    ensure_resource('Exec', "podman_systemd_${user}_reload", {
        path        => '/sbin:/usr/sbin:/bin:/usr/bin',
        command     => "${systemctl} daemon-reload",
        refreshonly => true,
        environment => [
          "HOME=${User[$user]['home']}",
          "XDG_RUNTIME_DIR=/run/user/${User[$user]['uid']}",
        ],
        cwd         => User[$user]['home'],
        provider    => 'shell',
        user        => $user,
      }
    )
    $podman_systemd_reload = "podman_systemd_${user}_reload"

  } else {
    $systemctl = 'systemctl '
    $service_unit_dir = '/etc/systemd/system/'
    $exec_defaults = {
      path     => '/sbin:/usr/sbin:/bin:/usr/bin',
      provider => 'shell',
    }

    # Reload systemd when service files are updated
    ensure_resource('Exec', 'podman_systemd_reload', {
        path        => '/sbin:/usr/sbin:/bin:/usr/bin',
        command     => "${systemctl} daemon-reload",
        refreshonly => true,
      }
    )
    $podman_systemd_reload = 'podman_systemd_reload'
  }

  if !$kube_yaml {
    # Create an empty pod.

    # The resource name will be the pod name by default
    $name_flags = merge({ name => $title }, $flags )
    $pod_name = $name_flags['name']

    # Convert $flags hash to command arguments
    $_flags = $name_flags.reduce('') |$mem, $flag| {
      if $flag[1] =~ String {
        "${mem} --${flag[0]} '${flag[1]}'"
      } elsif $flag[1] =~ Undef {
        "${mem} --${flag[0]}"
      } else {
        $dup = $flag[1].reduce('') |$mem2, $value| {
          "${mem2} --${flag[0]} '${value}'"
        }
        "${mem} ${dup}"
      }
    }

    if $ensure == 'present' {
      exec { "create_pod_${pod_name}":
        command => "podman pod create ${_flags}",
        unless  => "podman pod exists ${pod_name}",
        *       => $exec_defaults,
      }
    } else {
      exec { "remove_pod_${pod_name}":
        command => "podman pod rm ${pod_name}",
        unless  => "podman pod exists ${pod_name}; test $? -eq 1",
        *       => $exec_defaults,
      }
    }

  } else {
    # Load the pod and containers from YAML.

    $_yaml = parseyaml($kube_yaml, {})
    if $_yaml['kind'] != 'Pod' {
      fail('unable to parse pod YAML or incorrect kind')
    }

    $pod_name = $_yaml['metadata']['name']
    if !$pod_name {
      fail('pod name not found in pod YAML')
    }

    $_containers = $_yaml['spec']['containers']
    if !$_containers {
      fail('containers not found in pod YAML')
    }
    $containers = $_containers.map |$container| { "${pod_name}-${container['name']}" }

    $_temp_dir = "${facts['env_temp_variable']}/${module_name}-pod-${title}"
    $yaml_file = "${_temp_dir}/kube.yaml"

    file { $_temp_dir:
      ensure => directory,
      owner  => 'root',
      group  => User[$user]['gid'],
      mode   => '0750',
    }

    file { $yaml_file:
      content => $kube_yaml,
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
    }

    if $ensure == 'present' {

      # Create the pod if it doesn't exist.
      exec { "create_pod_${title}":
        command => "podman play kube --start=false ${yaml_file}",
        unless  => "podman pod exists ${pod_name}",
        notify  => Exec["generate_systemd_${title}"],
        *       => $exec_defaults,
      }
      File[$yaml_file] -> Exec["create_pod_${title}"]

      # Replace the pod if the YAML changes.
      exec { "replace_pod_${title}":
        command     => "podman play kube --start=false --replace ${yaml_file}",
        onlyif      => "podman pod exists ${pod_name}",
        refreshonly => true,
        subscribe   => File[$yaml_file],
        notify      => Exec["generate_systemd_${title}"],
        *           => $exec_defaults,
      }

      # Generate systemd service unit files.
      exec { "generate_systemd_${title}":
        command     => "podman generate systemd -f -n ${pod_name}",
        refreshonly => true,
        notify      => Exec[$podman_systemd_reload],
        *           => $exec_defaults + {cwd => $service_unit_dir},
      }

      exec { "start_pod_${title}":
        command => "${systemctl} start pod-${pod_name}",
        unless  => "${systemctl} -q is-active pod-${pod_name}",
        *       => $exec_defaults,
      }

    } else {

      exec { "stop_pod_${title}":
        command => "${systemctl} stop pod-${pod_name}",
        onlyif  => "${systemctl} -q is-active pod-${pod_name}",
        *       => $exec_defaults,
      }

      file { "${service_unit_dir}/pod-${pod_name}.service":
        ensure  => absent,
        before  => Exec["remove_pod_${title}"],
        notify  => Exec[$podman_systemd_reload],
        require => Exec["stop_pod_${title}"],
      }

      $containers.each |$container| {
        file { "${service_unit_dir}/container-${container}.service":
          ensure  => absent,
          before  => Exec["remove_pod_${title}"],
          notify  => Exec[$podman_systemd_reload],
          require => Exec["stop_pod_${title}"],
        }
      }

      exec { "remove_pod_${title}":
        command => "podman play kube --down ${yaml_file}",
        onlyif  => "podman pod exists ${pod_name}",
        *       => $exec_defaults,
      }
      Exec[$podman_systemd_reload] -> Exec["remove_pod_${title}"]
    }
  }
}
