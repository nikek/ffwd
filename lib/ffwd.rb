# $LICENSE
# Copyright 2013-2014 Spotify AB. All rights reserved.
#
# The contents of this file are licensed under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with the
# License. You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations under
# the License.

require 'yaml'
require 'optparse'

require_relative 'ffwd/core'
require_relative 'ffwd/logging'
require_relative 'ffwd/plugin'
require_relative 'ffwd/plugin_loader'
require_relative 'ffwd/processor'
require_relative 'ffwd/schema'
require_relative 'ffwd/version'

module FFWD
  DEFAULT_PLUGIN_DIRECTORIES = [
    './plugins'
  ]

  def self.load_yaml path
    return YAML.load_file path
  rescue => e
    log.error "Failed to load config: #{path} (#{e})"
    return nil
  end

  def self.merge_configurations target, source
    if target.is_a? Hash
      raise "source not a Hash: #{source}" unless source.is_a? Hash

      source.each do |key, value|
        target[key] = merge_configurations target[key], source[key]
      end

      return target
    end

    if target.is_a? Array
      raise "source not an Array: #{source}" unless source.is_a? Array
      return target + source
    end

    # override source
    return source
  end

  def self.load_config_dir dir, config
    Dir.entries(dir).sort.each do |entry|
      entry_path = File.join dir, entry

      next unless File.file? entry_path

      if entry.start_with? "."
        log.debug "Ignoring: #{entry_path} (hidden file)"
        next
      end

      c = load_yaml entry_path

      if c.nil?
        log.warn "Ignoring: #{entry_path} (invalid yaml)"
        next
      end

      yield c
    end
  end

  def self.opts
    @@opts ||= {:debug => false, :config => nil, :config_dir => nil,
                :list_plugins => false, :list_schemas => false,
                :dump_config => false, :show_version => false,
                :config_paths => [],
                :plugin_directories => DEFAULT_PLUGIN_DIRECTORIES}
  end

  def self.parser
    @@parser ||= OptionParser.new do |o|
      o.banner = "Usage: ffwd [options]"

      o.on "-d", "--[no-]debug" do |d|
        opts[:debug] = d
      end

      o.on "-c", "--config <path>", "Load the specified configuration file." do |path|
        opts[:config_paths] << path
      end

      o.on "-d", "--config-directory <path>", "Load configuration files from the specified directory." do |path|
        opts[:config_dir] = path
      end

      o.on "--plugins", "Print loaded and activated plugins." do
        opts[:list_plugins] = true
      end

      o.on "--schemas", "Print available schemas." do
        opts[:list_schemas] = true
      end

      o.on "--dump", "Dump the configuration that has been loaded." do
        opts[:dump_config] = true
      end

      o.on "--plugin-directory <dir>", "Load plugins from the specified directory." do |dir|
        opts[:plugin_directories] << dir
      end

      o.on "-v", "--version", "Show version." do
        opts[:show_version] = true
      end
    end
  end

  def self.parse_options args
    parser.parse args
  end

  def self.setup_plugins config
    plugins = {}

    plugins[:tunnel] = FFWD::Plugin.load_plugins(
      log, "Tunnel", config[:tunnel], :tunnel)

    plugins[:input] = FFWD::Plugin.load_plugins(
      log, "Input", config[:input], :input)

    plugins[:output] = FFWD::Plugin.load_plugins(
      log, "Output", config[:output], :output)

    plugins
  end

  def self.dump_loaded_plugins
    FFWD::Plugin.loaded.each do |name, plugin|
      puts "  Plugin '#{name}'"
      puts "    Source: #{plugin.source}"
      puts "    Supports: #{plugin.capabilities.join(' ')}"
      puts "    Description: #{plugin.description}" if plugin.description
      unless plugin.options.empty?
        puts "    Available Options:"
        plugin.options.each do |opt|
          puts "      :#{opt[:name]} (default: #{opt[:default].inspect})"
          puts "        #{opt[:help]}" if opt[:help]
        end
      end
    end
  end

  def self.dump_activated_plugins plugins
    plugins.each do |kind, kind_plugins|
      puts "  #{kind}:"

      if kind_plugins.empty?
        puts "    (no active plugins)"
        next
      end

      kind_plugins.each do |p|
        puts "    #{p.name}: #{p.config}"
      end
    end
  end

  def self.activated_plugins_warning
    puts "  NO ACTIVATED PLUGINS!"
    puts ""
    puts "  1) Did you specify a valid configuration?"
    puts "  Example ways to configure:"
    puts "    ffwd -c /etc/ffwd.conf"
    puts "    ffwd -d /etc/ffwd.d/"
    puts ""
    puts "  2) Are your plugins loaded?"
    puts "  Check with:"
    puts "    ffwd -c .. --list-plugins"
    puts ""
    puts "  3) Did any errors happen when loading the plugins?"
    puts "  Check with:"
    puts "    ffwd -c .. --debug"
    puts ""
    puts "  4) If you think you've stumbled on a bug, report it to:"
    puts "    https://github.com/spotify/ffwd"
  end

  def self.main args
    parse_options args

    if opts[:show_version]
      puts "ffwd version: #{FFWD::VERSION}"
      return 0
    end

    FFWD.log_config[:level] = opts[:debug] ? Logger::DEBUG : Logger::INFO

    config = {}

    opts[:config_paths].each do |path|
      unless File.file? path
        puts "Configuration path does not exist: #{path}"
        puts ""
        puts parser.help
        return 1
      end

      return 0 unless source = load_yaml(path)

      merge_configurations config, source
    end

    if config_dir = opts[:config_dir]
      unless File.directory? config_dir
        puts "Configuration directory does not exist: #{path}"
        puts ""
        puts parser.help
        return 1
      end

      load_config_dir(config_dir, config) do |c|
        merge_configurations config, c
      end
    end

    if config[:logging]
      if opts[:debug]
        puts "Ignoring :logging directive, --debug in effect"
      else
        config[:logging].each do |key, value|
          FFWD.log_config[key] = value
        end
      end
    end

    FFWD.log_reload

    if FFWD.log_config[:file]
      puts "Logging to file: #{FFWD.log_config[:file]}"
    end

    blacklist = config[:blacklist] || {}

    directories = ((config[:plugin_directories] || []) +
                   (opts[:plugin_directories] || []))

    PluginLoader.plugin_directories = directories

    PluginLoader.load FFWD::Plugin, blacklist[:plugins] || []
    PluginLoader.load FFWD::Processor, blacklist[:processors] || []
    PluginLoader.load FFWD::Schema, blacklist[:schemas] || []

    stop_early = false
    stop_early ||= opts[:list_plugins]
    stop_early ||= opts[:list_schemas]
    stop_early ||= opts[:dump_config]

    plugins = setup_plugins config

    all_empty = plugins.values.map(&:empty?).all?

    if opts[:list_plugins]
      puts ""
      puts "Loaded Plugins:"
      dump_loaded_plugins
      puts ""
      if all_empty
        activated_plugins_warning
      else
        puts "Activated Plugins:"
        dump_activated_plugins plugins
      end
      puts ""
    end

    if opts[:list_schemas]
      puts "Available Schemas:"

      FFWD::Schema.loaded.each do |key, schema|
        name, content_type = key
        puts "Schema '#{name}' #{content_type} (#{schema.source})"
      end
    end

    if opts[:dump_config]
      puts "Configuration:"
      puts config
    end

    if stop_early
      return 0
    end

    if all_empty
      puts ""
      activated_plugins_warning
      puts ""
      return 1
    end

    core = FFWD::Core.new plugins, config
    core.run
    return 0
  end
end
