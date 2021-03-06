class Zone
  include ::DebugLog::Logger

  class Nested < Struct.new(:zone, :host)
    def cname(name, ttl=nil)
      zone.cname(*[name, host, ttl].compact)
    end

    def txt(text, ttl=nil)
      zone.txt(*[host, text, ttl].compact)
    end
  end

  SOA_FIELDS = %i(
    ttl
    origin
    ttl
    primary
    email
    serial
    refresh
    retry
    expire
    minimumTTL
  )

  attr_reader :zonefile

  def initialize(domain, template_dir, soa={})
    @domain   = domain
    @zonefile = Zonefile.new("", "output/#{domain}", domain)
    logger.debug { format "<init> soa: %p", soa }
    @zonefile.soa.merge! soa
    @template_dir = template_dir
  end

  def template(name)
    eval_file "#{@template_dir}/#{name}.rb"
  end

  # Merge
  def soa(**options)
    if (invalid_keys = options.keys - SOA_FIELDS).any?
      raise ArgumentError, "invalid options: #{invalid_keys.inspect}"
    end
    logger.debug { format "<soa> %p", options }
    @zonefile.soa.merge! options
  end

  # 1.2.3.4           - host
  # 1.2.3.4, 600      - host with TTL
  # www, 1.2.3.4, 600 - name, host and TTL
  def a(*args, &block)
    if [String, String, String] == args[0..2].map(&:class)
      # name, ipv4 and ipv6
      name, ipv4, ipv6 = args.shift(3)
      a_record :a, name, ipv4, *args, &block
      a_record :a4, name, ipv6, *args
    else
      a_record :a, *args, &block
    end
  end

  def aaaa(*args, &block)
    a_record :a4, *args, &block
  end

  def a_record(type, *args, &block)
    ttl  = extract_ttl! args
    host = args.pop
    name = args.pop || '@'

    push(type, name, ttl, host: host) if present?(host)
    Nested.new(self, name).instance_eval(&block) if block_given?
  end

  # mx                - host with default priority (10)
  # mx, 15            - host and priority
  # mx, 15, 600       - host, priority and TTL
  # name, mx, 15      - name, host, priority
  # name, mx, 15, 600 - name, host, priority and TTL
  def mx(*args)
    if args[1].is_a?(String)
      # name and host given
      name, host = args.shift(2)
    else
      # only host given
      host = args.shift || '@'
      name = '@'
    end

    pri = args.shift || 10
    ttl = args.shift

    push :mx, name, ttl, host: host, pri: pri
  end

  # ns1.example.com.      - host
  # ns1.example.com., 600 - host with TTL
  def ns(*args)
    ttl  = extract_ttl! args
    host = args.pop
    name = args.pop || '@'

    push(:ns, name, ttl, host: host) if present?(host)
  end

  def cname(name, *args)
    ttl  = extract_ttl! args
    host = args.pop || "@"

    push :cname, name, ttl, host: host
  end

  def srv(*args)
    options  = extract_options! args
    name     = "." << args.shift if args[0].is_a?(String)

    raise ArgumentError, "wrong number of arguments" unless (4..5).include?(args.count)

    service, proto, host, port = args.shift(4)
    ttl = extract_ttl! args

    options.each do |key, val|
      case key
      when :pri, :weight
        raise ArgumentError, "invalid #{key}: #{val}" if val.to_s !~ /^\d+$/
      else
        raise ArgumentError, "unknown option: #{key}"
      end
    end

    # default values
    options[:pri]    ||= 10
    options[:weight] ||= 0

    push :srv, "_#{service}._#{proto}#{name}", ttl, options.merge(host: host, port: port)
  end

  def txt(*args)
    ttl  = extract_ttl! args
    text = args.pop.to_s.strip
    name = args.pop || '@'
    text = "\"#{text}\"" if text =~ /\s/

    push :txt, name, ttl, text: text
  end

  def tlsa(*args)
    ttl      = extract_ttl! args
    name     = args.shift if String===args[0]
    name     = (name=="@" || !name) ? '' : "." << name
    port, proto, usage, selector, matching, data = args.shift(6)

    raise ArgumentError, "invalid port: #{port}"              if port < 0 || port > 65535
    raise ArgumentError, "invalid protocol: #{proto}"         if proto.to_s !~ /^[a-z]+$/
    raise ArgumentError, "no data given"                      unless data
    raise ArgumentError, "invalid usage: #{usage}"            unless Integer === usage
    raise ArgumentError, "invalid selector: #{selector}"      unless Integer === selector
    raise ArgumentError, "invalid matching_type: #{matching}" unless Integer === matching

    push :tlsa, "_#{port}._#{proto}#{name}", ttl,
      certificate_usage:  usage,
      selector:           selector,
      matching_type:      matching,
      data:               data
  end

  # name in not-reversed order
  def ptr(name, host, ttl=nil)
    host = "#{host}." if host[-1] != '.'
    push :ptr, name.to_s, ttl, host: host
  end

  def ptr6(name, *args)
    raise ArgumentError, "no double colon allowed" if name.include?("::")

    # left fill blocks with zeros, reverse order all characters and join them with points
    ptr name.split(":").map{|b| b.rjust(4,"0") }.join.reverse.split("").join("."), *args
  end

  protected

  # evaluates a file
  def eval_file(file)
    instance_eval File.read(file), file
  end

  def push(type, name, ttl, options={})
    rrdata = {
      class:  "IN",
      name:   name,
      ttl:    ttl,
    }.merge(options)

    logger.debug { format "<push>  %s  %p", type, rrdata }
    @zonefile.send(type) << rrdata
  end

  # extracts the last argument if it is a Hash
  def extract_options!(args)
    args.last.is_a?(Hash) ? args.pop : {}
  end

  # extracts the last argument if it is an Integer
  def extract_ttl!(args)
    args.pop if args.last.is_a?(Integer)
  end

  def present?(s)
    !s.nil? && s != ""
  end
end

