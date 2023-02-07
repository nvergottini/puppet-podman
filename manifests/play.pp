# @summary Create pods and containers using Kubernetes YAML using podman play command.
#
# @param ensure
#   Ensure the pod and containers are either present or absent. In order for existing
#   pods and containers to be removed by this resource when absent is specified, the
#   provided YAML must describe the existing pod and containers.
#
# @param user
#   Optional user for running rootless containers.  When using this parameter,
#   the user must also be defined as a Puppet resource and must include the
#   'uid', 'gid', and 'home'
#
# @param source
#   Source path for YAML file in module repository. Note that this path is used with the
#   file function, so it must conform to the path specification for that function. It is
#   not a path as passed to a file resource.
#
# @param content
#   Kubernetes YAML either as a string or hash. Content and source parameters are
#   mutually exclusive.
#
class podman::play (
  Enum['present', 'absent'] $ensure = 'present',
  Optional[String] $user = undef,
  Optional[String] $source = undef,
  Optional[Variant[String, Hash]] $content = undef,
) {

  unless $source or $content {
    fail('either source or content parameters are required')
  }

  if $source and $content {
    fail('source and content parameters are mutually exclusive')
  }

  require podman::install

  if $user {
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

  # Get YAML as hash.
  if $source {
    $_yaml = parseyaml(file($source))
  } elsif $content =~ String {
    $_yaml = parseyaml($content)
  } else {
    $_yaml = $content
  }

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

  # Store YAML in file on node.
  file { '/etc/containers/kubes.d':
    ensure => directory,
    owner  => 'root',
    group  => 'root',
    mode   => '0755',
  }

  $yaml_file = "/etc/containers/kubes.d/${pod_name}.yaml"

  file { $yaml_file:
    content => to_yaml($_yaml),
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
  }

  if $ensure == 'present' {
    # Ensure the pod is present.

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
    # Ensure the pod is absent.

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
