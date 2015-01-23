# Base class to install FreeRADIUS
class freeradius (
  $control_socket   = false,
  $max_servers      = '4096',
  $max_requests     = '4096',
  $manage_logrotate = true,
  $mysql_support    = false,
  $perl_support     = false,
  $utils_support    = false,
  $ldap_support     = false,
  $wpa_supplicant   = false,
  $winbind_support  = false,
  $syslog           = false,
) inherits freeradius::params {

  file { 'radiusd.conf':
    name    => "${freeradius::fr_basepath}/radiusd.conf",
    mode    => '0640',
    owner   => 'root',
    group   => $freeradius::fr_group,
    content => template('freeradius/radiusd.conf.erb'),
    require => [Package[$freeradius::fr_package], Group[$freeradius::fr_group]],
    notify  => Service[$freeradius::fr_service],
  }

  # Create various directories
  file { [
    "${freeradius::fr_basepath}/clients.d",
    "${freeradius::fr_basepath}/statusclients.d",
    $freeradius::fr_basepath,
    "${freeradius::fr_basepath}/instantiate",
    "${freeradius::fr_basepath}/conf.d",
    "${freeradius::fr_basepath}/attr.d",
    "${freeradius::fr_basepath}/users.d",
    "${freeradius::fr_basepath}/policy.d",
    "${freeradius::fr_basepath}/dictionary.d",
    "${freeradius::fr_basepath}/scripts",
    "${freeradius::fr_basepath}/certs",
  ]:
    ensure  => directory,
    mode    => '0750',
    owner   => 'root',
    group   => $freeradius::fr_group,
    require => [Package[$freeradius::fr_package], Group[$freeradius::fr_group]],
    notify  => Service[$freeradius::fr_service],
  }

  # Set up concat policy file, as there is only one global policy
  # We also add standard header and footer
  concat { "${freeradius::fr_basepath}/policy.conf":
    owner   => 'root',
    group   => $freeradius::fr_group,
    mode    => '0640',
    require => [Package[$freeradius::fr_package], Group[$freeradius::fr_group]],
  }
  concat::fragment { 'policy_header':
    target  => "${freeradius::fr_basepath}/policy.conf",
    content => "policy {\n",
    order   => 10,
  }
  concat::fragment { 'policy_footer':
    target  => "${freeradius::fr_basepath}/policy.conf",
    content => "}\n",
    order   => '99',
  }

  # Install a slightly tweaked stock dictionary that includes
  # our custom dictionaries
  concat { "${freeradius::fr_basepath}/dictionary":
    owner   => 'root',
    group   => $freeradius::fr_group,
    mode    => '0640',
    require => [Package[$freeradius::fr_package], Group[$freeradius::fr_group]],
  }
  concat::fragment { 'dictionary_header':
    target => "${freeradius::fr_basepath}/dictionary",
    source => 'puppet:///modules/freeradius/dictionary.header',
    order  => 10,
  }
  concat::fragment { 'dictionary_footer':
    target => "${freeradius::fr_basepath}/dictionary",
    source => 'puppet:///modules/freeradius/dictionary.footer',
    order  => 90,
  }

  # Install FreeRADIUS packages
  package { 'freeradius':
    ensure => installed,
    name   => $freeradius::fr_package,
  }
  if $mysql_support {
    package { 'freeradius-mysql':
      ensure => installed,
    }
  }
  if $perl_support {
    package { 'freeradius-perl':
      ensure => installed,
    }
  }
  if $utils_support {
    package { 'freeradius-utils':
      ensure => installed,
    }
  }
  if $ldap_support {
    package { 'freeradius-ldap':
      ensure => installed,
    }
  }
  if $wpa_supplicant {
    package { 'wpa_supplicant':
      ensure => installed,
      name   => $freeradius::fr_wpa_supplicant,
    }
  }

  # radiusd always tests its config before restarting the service, to avoid outage. If the config is not valid, the service
  # won't get restarted, and the puppet run will fail.
  service { $freeradius::fr_service:
    ensure     => running,
    name       => $freeradius::fr_service,
    require    => [Exec['radiusd-config-test'], File['radiusd.conf'], User[$freeradius::fr_user], Package[$freeradius::fr_package],],
    enable     => true,
    hasstatus  => $freeradius::fr_service_has_status,
    hasrestart => true,
  }

  # We don't want to create the radiusd user, just add it to the
  # wbpriv group if the user needs winbind support. We depend on
  # the FreeRADIUS package to be sure that the user has been created
  user { $freeradius::fr_user:
    ensure  => present,
    groups  => $winbind_support ? {
      true    => $freeradius::fr_wbpriv_user,
      default => undef,
    },
    require => Package[$freeradius::fr_package],
  }

  # We don't want to add the radiusd group but it must be defined
  # here so we can depend on it. WE depend on the FreeRADIUS
  # package to be sure that the group has been created.
  group { $freeradius::fr_group:
    ensure  => present,
    require => Package[$freeradius::fr_package]
  }

  # Install a few modules required on all FR installations
  freeradius::module  { 'always':
    source  => 'puppet:///modules/freeradius/modules/always',
  }
  freeradius::module { 'detail':
    source  => 'puppet:///modules/freeradius/modules/detail',
  }
  freeradius::module { 'detail.log':
    source  => 'puppet:///modules/freeradius/modules/detail.log',
  }

  ::freeradius::module { 'logtosyslog':
    source => 'puppet:///modules/freeradius/modules/logtosyslog',
  }
  ::freeradius::module { 'logtofile':
    source => 'puppet:///modules/freeradius/modules/logtofile',
  }

  # Syslog rules
  if $syslog == true {
    syslog::rule { 'radiusd-log':
      command => "if \$programname == \'radiusd\' then ${freeradius::fr_logpath}/radius.log\n&~",
      order   => '12',
    }
  }

  # Install a couple of virtual servers needed on all FR installations
  if $control_socket == true {
    freeradius::site { 'control-socket':
      source => template('freeradius/sites-enabled/control-socket.erb'),
    }
  }

  # Make the radius log dir traversable
  file { [
    $freeradius::fr_logpath,
    "${freeradius::fr_logpath}/radacct",
  ]:
    mode    => '0750',
    require => Package[$freeradius::fr_package],
  }

  file { "${freeradius::fr_logpath}/radius.log":
    owner   => $freeradius::fr_user,
    group   => $freeradius::fr_group,
    seltype => 'radiusd_log_t',
    require => [Package[$freeradius::fr_package], User[$freeradius::fr_user], Group[$freeradius::fr_group]],
  }

  # Updated logrotate file to include radiusd-*.log
  if $manage_logrotate == true {
    file { '/etc/logrotate.d/radiusd':
      mode    => '0640',
      owner   => 'root',
      group   => $freeradius::fr_group,
      content => template('freeradius/radiusd.logrotate.erb'),
      require => [Package[$freeradius::fr_package], Group[$freeradius::fr_group]],
    }
  }

  # Generate global SSL parameters
  exec { 'dh':
    command => "openssl dhparam -out ${freeradius::fr_basepath}/certs/dh 1024",
    creates => "${freeradius::fr_basepath}/certs/dh",
    path    => '/usr/bin',
  }

  # Generate global SSL parameters
  exec { 'random':
    command => "dd if=/dev/urandom of=${freeradius::fr_basepath}/certs/random count=10 >/dev/null 2>&1",
    creates => "${freeradius::fr_basepath}/certs/random",
    path    => '/bin',
  }

  # This exec tests the radius config and fails if it's bad
  # It isn't run every time puppet runs, but only when freeradius is to be restarted
  exec { 'radiusd-config-test':
    command     => 'sudo radiusd -XC | grep \'Configuration appears to be OK.\' | wc -l',
    returns     => 0,
    refreshonly => true,
    logoutput   => on_failure,
    path        => ['/bin/', '/sbin/', '/usr/bin/', '/usr/sbin/'],
  }

  # Blank a couple of default files that will break our config. This is more effective than deleting them
  # as they won't get overwritten when FR is upgraded from RPM, whereas missing files are replaced.
  file { [
    "${freeradius::fr_basepath}/sites-available/default",
    "${freeradius::fr_basepath}/sites-available/inner-tunnel",
    "${freeradius::fr_basepath}/proxy.conf",
    "${freeradius::fr_basepath}/clients.conf",
    "${freeradius::fr_basepath}/sql.conf",
  ]:
    content => "# FILE INTENTIONALLY BLANK\n",
    mode    => '0644',
    owner   => 'root',
    group   => $freeradius::fr_group,
    require => [Package[$freeradius::fr_package], Group[$freeradius::fr_group]],
    notify  => Service[$freeradius::fr_service],
  }

  # Delete *.rpmnew and *.rpmsave files from the radius config dir because
  # radiusd stupidly reads these files in, and they break the config
  # This should be fixed in FreeRADIUS 2.2.0
  # http://lists.freeradius.org/pipermail/freeradius-users/2012-October/063232.html
  # Only affects RPM-based systems
  if $::osfamily == 'RedHat' {
    exec { 'delete-radius-rpmnew':
      command => "find ${freeradius::fr_basepath} -name *.rpmnew -delete",
      onlyif  => "find ${freeradius::fr_basepath} -name *.rpmnew | grep rpmnew",
      path    => ['/bin/', '/sbin/', '/usr/bin/', '/usr/sbin/'],
    }
    exec { 'delete-radius-rpmsave':
      command => "find ${freeradius::fr_basepath} -name *.rpmsave -delete",
      onlyif  => "find ${freeradius::fr_basepath} -name *.rpmsave | grep rpmsave",
      path    => ['/bin/', '/sbin/', '/usr/bin/', '/usr/sbin/'],
    }
  }
}
