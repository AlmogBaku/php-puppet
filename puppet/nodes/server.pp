if $server_values == undef { $server_values = hiera_hash('server', false) }

include ntp
include swap_file
include puphpet
include puphpet::params

Exec { path => [ '/bin/', '/sbin/', '/usr/bin/', '/usr/sbin/' ] }
group { 'puppet':   ensure => present }
group { 'www-data': ensure => present }
group { 'www-user': ensure => present }

user { ['apache', 'nginx', 'httpd', 'www-data']:
  shell  => '/bin/bash',
  ensure => present,
  groups => 'www-data',
  require => Group['www-data']
}

$user_homedir = "/home/${::ssh_username}"
user { $::ssh_username:
  shell   => '/bin/bash',
  home    => $user_homedir,
  ensure  => present,
  groups  => ['www-data', 'www-user'],
  require => [Group['www-data'], Group['www-user']],
  managehome => true
}

## copy ssh key from root
file { "${user_homedir}/.ssh":
  ensure => "directory",
  owner  => $::ssh_username,
}
file { "${user_homedir}/.ssh/authorized_keys":
  ensure => file,
  owner  => $::ssh_username,
  source => "/root/.ssh/authorized_keys"
}

# copy dot files to ssh user's home directory
exec { 'dotfiles':
  cwd     => $user_homedir,
  command => "cp -r /vagrant/puphpet/files/dot/.[a-zA-Z0-9]* ${user_homedir}/ \
              && chown -R ${::ssh_username} ${user_homedir}/.[a-zA-Z0-9]* \
              && cp -r /vagrant/puphpet/files/dot/.[a-zA-Z0-9]* /root/",
  onlyif  => 'test -d /vagrant/puphpet/files/dot',
  returns => [0, 1],
  require => User[$::ssh_username]
}

case $::osfamily {
  'debian': {
    include apt

    Class['apt::update'] -> Package <|
        title != 'python-software-properties'
    and title != 'software-properties-common'
    |>

    if ! defined(Package['augeas-tools']) {
      package { 'augeas-tools':
        ensure => present,
      }
    }
  }
  'redhat': {
    class { 'yum': extrarepo => ['epel'] }

    class { 'yum::repo::rpmforge': }
    class { 'yum::repo::repoforgeextras': }

    Class['::yum'] -> Yum::Managed_yumrepo <| |> -> Package <| |>

    if ! defined(Package['git']) {
      package { 'git':
        ensure  => latest,
        require => Class['yum::repo::repoforgeextras']
      }
    }

    if ! defined(Package['augeas']) {
      package { 'augeas':
        ensure => present,
      }
    }

    link_dot_files { 'do': }
  }
}

case $::operatingsystem {
  'debian': {
    include apt::backports

    add_dotdeb { 'packages.dotdeb.org': release => $::lsbdistcodename }

    $server_lsbdistcodename = downcase($::lsbdistcodename)

    apt::force { 'git':
      release => "${server_lsbdistcodename}-backports",
      timeout => 60
    }
  }
  'ubuntu': {
    if ! defined(Apt::Key['4F4EA0AAE5267A6C']){
      apt::key { '4F4EA0AAE5267A6C': key_server => 'hkp://keyserver.ubuntu.com:80' }
    }
    if ! defined(Apt::Key['4CBEDD5A']){
      apt::key { '4CBEDD5A': key_server => 'hkp://keyserver.ubuntu.com:80' }
    }

    if $::lsbdistcodename in ['lucid', 'precise'] {
      apt::ppa { 'ppa:pdoes/ppa': require => Apt::Key['4CBEDD5A'], options => '' }
    } else {
      apt::ppa { 'ppa:pdoes/ppa': require => Apt::Key['4CBEDD5A'] }
    }
  }
  'redhat', 'centos': {
  }
}

if is_array($server_values['packages']) and count($server_values['packages']) > 0 {
  each( $server_values['packages'] ) |$package| {
    if ! defined(Package[$package]) {
      package { $package:
        ensure => present,
      }
    }
  }
}

define add_dotdeb ($release){
   apt::source { "${name}-repo.puphpet":
    location          => 'http://repo.puphpet.com/dotdeb/',
    release           => $release,
    repos             => 'all',
    required_packages => 'debian-keyring debian-archive-keyring',
    key               => '89DF5277',
    key_server        => 'keys.gnupg.net',
    include_src       => true
  }
}

define link_dot_files {
  file_line { 'link ~/.bash_git':
    ensure  => present,
    line    => 'if [ -f ~/.bash_git ] ; then source ~/.bash_git; fi',
    path    => "/home/${::ssh_username}/.bash_profile",
    require => Exec['dotfiles'],
  }

  file_line { 'link ~/.bash_git for root':
    ensure  => present,
    line    => 'if [ -f ~/.bash_git ] ; then source ~/.bash_git; fi',
    path    => '/root/.bashrc',
    require => Exec['dotfiles'],
  }

  file_line { 'link ~/.bash_aliases':
    ensure  => present,
    line    => 'if [ -f ~/.bash_aliases ] ; then source ~/.bash_aliases; fi',
    path    => "/home/${::ssh_username}/.bash_profile",
    require => Exec['dotfiles'],
  }

  file_line { 'link ~/.bash_aliases for root':
    ensure  => present,
    line    => 'if [ -f ~/.bash_aliases ] ; then source ~/.bash_aliases; fi',
    path    => '/root/.bashrc',
    require => Exec['dotfiles'],
  }
}


## Cron
$new_server_values = hiera_hash('server', false) #after we having the user home now
$cron_values = $new_server_values['cron']
if (count($cron_values) > 0) {
  each($cron_values) |$cronkey, $cron_values| {
    $cronjob = merge({
      'minute'  => '*',
      'hour'    => '*',
      'monthday'=> '*',
      'month'   => '*',
      'weekday' => '*',
      'user' => $::ssh_username,
    }, $cron_values)
    if(!$cronjob['command']) {
      fail("cron job command is required (${cronkey})")
    } else {
      cron { $cronkey:
        command => $cronjob['command'],
        user    => $cronjob['user'],
        minute  => $cronjob['minute'],
        hour    => $cronjob['hour'],
        monthday=> $cronjob['monthday'],
        month   => $cronjob['monthy'],
        weekday => $cronjob['weekday']
      }
    }
  }
}

class { raxmonitoragent:
  rax_username  => $::rs_username,
  rax_apikey   => $::rs_apikey
}
class { 'locales':
  default_locale  => 'en_US.UTF-8',
  locales         => ['en_US.UTF-8 UTF-8', 'he_IL.UTF-8 UTF-8'],
}
if(value_true($server_values['timezone'])) {
  class { 'timezone':
    timezone => $server_values['timezone'],
  }
}