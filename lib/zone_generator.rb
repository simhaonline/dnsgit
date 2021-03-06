require "pathname"
require "yaml"

class ZoneGenerator
  def self.run(basedir)
    new(basedir).deploy
  end

  attr_reader :workspace

  def initialize(basedir)
    basedir     = Pathname.new(basedir)
    @workspace  = basedir.join("tmp/cache")
    config      = YAML.load workspace.join("config.yaml").read
    config.deep_symbolize_keys!
    check_config!(config)

    @backend = if config.key?(:bind)
      Backend::BIND.new(basedir, config)
    elsif config.key?(:sqlite)
      Backend::SQLite.new(basedir, config)
    end

    @after_deploy = [*config[:execute]]
  end

  # Performs deployment and executes callbacks
  def deploy
    @backend.deploy
    @backend.close if @backend.respond_to?(:close)

    env = {
      "ZONES_CHANGED" => @backend.zones_changed.join(","),
    }
    @after_deploy.each do |cmd|
      Dir.chdir(workspace) do
        puts_in_yellow "Executing '#{cmd}' ..."
        puts IO.popen(env, cmd, "r", err: [:child, :out], &:read)
        if $?.exitstatus != 0
          puts_in_red "command finished with status #{$?.exitstatus}"
          exit $?.exitstatus
        end
      end
    end
  end

  private

  def check_config!(config)
    errors = []

    if !(config.key?(:bind) ^ config.key?(:sqlite))
      errors << "please ensure you have exactly one setting for 'bind' or 'sqlite'"

    elsif config.key?(:bind)
      if !config[:bind].key?(:named_conf)
        errors << "mssing 'bind.named_conf'"
      end

      if !config[:bind].key?(:zones_dir)
        errors << "missing 'bind.zones_dir'"
      end

    elsif config.key?(:sqlite)
      if !config[:sqlite].key?(:db_path)
        errors << "missing 'sqlite.db_path'"
      end
    end

    if !config.key?(:soa)
      errors << "missing 'soa' settings"
    end

    if errors.length > 0
      puts_in_red "incomplete or invalid configuration"
      errors.each do |err|
        puts_in_yellow "  - #{err}"
      end
      exit 1
    end
  end

  def puts_in_yellow(msg)
    printf "\e[33m%s\e[0m\n", msg
  end

  def puts_in_red(msg)
    printf "\e[31;1m%s\e[0m\n", msg
  end
end
