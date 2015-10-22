#
# Cookbook Name:: omnibus
# HWRP:: ruby_install
#
# Copyright 2014, Chef Software, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
require_relative '_helper'

class Chef
  class Resource::RubyInstall < Resource::LWRPBase
    self.resource_name = :ruby_install

    actions :install
    default_action :install

    attribute :version,     kind_of: String, name_attribute: true
    attribute :environment, kind_of: Hash, default: {}
    attribute :patches,     kind_of: Array, default: []
    attribute :prefix,      kind_of: String, default: lazy { |r| ChefConfig.windows? ? ::File.join(ENV['SYSTEMDRIVE'], 'rubies', r.version) : "/opt/rubies/ruby-#{r.version}" }

    def patch(patch)
      @patches << patch
    end
  end

  class Provider::RubyInstallUnix < Provider::LWRPBase
    provides :ruby_install

    def whyrun_supported?
      true
    end

    action(:install) do
      if installed?
        Chef::Log.debug("#{new_resource} installed - skipping")
      else
        converge_by("install #{new_resource}") do
          install
        end
      end
    end

    def self.compile_flags
      [
        '--disable-install-rdoc',
        '--disable-install-ri',
        '--with-out-ext=tcl',
        '--with-out-ext=tk',
        '--without-tcl',
        '--without-tk',
        '--disable-dtrace',
      ].join(' ')
    end

    protected

    def version
      new_resource.version
    end

    def install
      install_dependencies

      # Need to compile the command outside of the execute resource because
      # Ruby is bad at instance_eval
      install_command = "ruby-install --no-install-deps --install-dir #{new_resource.prefix}"

      new_resource.patches.each do |p|
        install_command << " --patch #{p}"
      end

      install_command << " ruby #{version} -- #{Provider::RubyInstallUnix.compile_flags}"

      execute = Resource::Execute.new("install ruby-#{version}", run_context)
      execute.command(install_command)
      execute.environment(new_resource.environment)
      execute.run_action(:run)
    end

    # Check if the given Ruby is installed in the given prefix.
    #
    # @return [true, false]
    def installed?
      ::File.directory?(new_resource.prefix)
    end

    def install_dependencies
      recipe_eval do
        run_context.include_recipe 'build-essential::default'
      end

      # install ruby-install
      return if Chef::Sugar::Shell.installed_at_version?('/usr/local/bin/ruby-install', '0.4.1')
      ruby_install = Chef::Resource::RemoteInstall.new('ruby-install', run_context)
      ruby_install.source('https://codeload.github.com/postmodern/ruby-install/tar.gz/v0.4.1')
      ruby_install.version('0.4.1')
      ruby_install.checksum('1b35d2b6dbc1e75f03fff4e8521cab72a51ad67e32afd135ddc4532f443b730e')
      ruby_install.install_command("make -j #{parallelism} install")
      ruby_install.run_action(:install)
    end

    # The number of builders to use for make. By default, this is the total
    # number of CPUs, with a minimum being 2.
    def parallelism
      [node['cpu'] && node['cpu']['total'].to_i, 2].max
    end
  end

  class Provider::RubyInstallWindows < Provider::LWRPBase
    include Languages::Helper

    provides :ruby_install, platform_family: 'windows'

    def whyrun_supported?
      true
    end

    action(:install) do
      if installed?
        Chef::Log.debug("#{new_resource} installed - skipping")
      else
        converge_by("install #{new_resource}") do
          install_ruby
          install_devkit
          configure_ca
        end
      end
    end

    protected

    def version
      new_resource.version
    end

    def installer_url
      "http://dl.bintray.com/oneclick/rubyinstaller/rubyinstaller-#{version}.exe"
    end

    def installer_download_path
      windows_safe_path_join(Chef::Config[:file_cache_path], ::File.basename(installer_url))
    end

    # Determines the proper version of the DevKit based on Ruby version.
    def devkit_url
      # 2.0 64-bit
      if version =~ /^2\.\d\.\d.*x64$/
        'http://cdn.rubyinstaller.org/archives/devkits/DevKit-mingw64-64-4.7.2-20130224-1432-sfx.exe'
      # 2.0 32-bit
      elsif version =~ /^2\.\d\.\d.*$/
        'http://cdn.rubyinstaller.org/archives/devkits/DevKit-mingw64-32-4.7.2-20130224-1151-sfx.exe'
      # Ruby 1.8.7 and 1.9.3
      else
        'https://github.com/downloads/oneclick/rubyinstaller/DevKit-tdm-32-4.5.2-20111229-1559-sfx.exe'
      end
    end

    def devkit_download_path
      windows_safe_path_join(Chef::Config[:file_cache_path], ::File.basename(devkit_url))
    end

    def cacerts_download_path
      windows_safe_path_join(Chef::Config[:file_cache_path], ::File.basename(devkit_url))
    end

    def ruby_install_path
      new_resource.prefix
    end

    def ruby_bin
      windows_safe_path_join(ruby_install_path, 'bin', 'ruby')
    end

    # Installs the desired version of the RubyInstaller
    def install_ruby
      ruby_installer = Resource::RemoteFile.new("fetch ruby-#{version}", run_context)
      ruby_installer.path(installer_download_path)
      ruby_installer.source(installer_url)
      ruby_installer.backup(false)
      ruby_installer.run_action(:create)

      install_command = %(#{installer_download_path} /verysilent /dir="#{ruby_install_path}" /tasks="assocfiles")

      execute = Resource::Execute.new("install ruby-#{version}", run_context)
      execute.command(install_command)
      execute.run_action(:run)
    end

    # Installs the DevKit in the Ruby so we can compile gems with native extensions.
    def install_devkit
      devkit = Resource::RemoteFile.new("fetch devkit for ruby-#{version}", run_context)
      devkit.path(devkit_download_path)
      devkit.source(devkit_url)
      devkit.backup(false)
      devkit.run_action(:create)

      # Generate config.yml which is used by DevKit install
      require 'yaml'
      config_yml = Resource::File.new(windows_safe_path_join(ruby_install_path, 'config.yml'), run_context)
      config_yml.content([ruby_install_path].to_yaml)
      config_yml.run_action(:create)

      install_command = %(#{devkit_download_path} -y -o"#{ruby_install_path}" & "#{ruby_bin}" dk.rb install)

      execute = Resource::Execute.new("install devkit for ruby-#{version}", run_context)
      execute.command(install_command)
      execute.cwd(ruby_install_path)
      execute.run_action(:run)
    end

    # Ensures a certificate authority is available and configured. See:
    #
    #   https://gist.github.com/fnichol/867550
    #
    def configure_ca
      ssl_certs_dir = windows_safe_path_join(ruby_install_path, 'ssl', 'certs')
      cacert_file   = windows_safe_path_join(ssl_certs_dir, 'cacert.pem')

      certs_dir = Resource::Directory.new(ssl_certs_dir, run_context)
      certs_dir.recursive(true)
      certs_dir.run_action(:create)

      cacerts = Resource::CookbookFile.new("install cacerts bundle for ruby-#{version}", run_context)
      cacerts.path(cacert_file)
      cacerts.source('cacert.pem')
      cacerts.cookbook('languages')
      cacerts.backup(false)
      cacerts.sensitive(true)
      cacerts.run_action(:create)
    end

    # Check if the given Ruby is installed by directory.
    #
    # @return [true, false]
    def installed?
      ::File.directory?(ruby_install_path)
    end
  end
end
